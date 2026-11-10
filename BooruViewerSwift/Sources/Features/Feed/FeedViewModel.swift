import Foundation
import Observation

/// Explore feed state for `FeedScreen`.
///
/// Mirrors the RN Explore screen (src/screens/FeedScreen.tsx:79-330):
/// - one page size and "load more" that stops on an empty or fully duplicated page;
/// - source-aware quick-filter chips, with the saved order snapped to the active source;
/// - blacklist filtering applied to loaded posts (`BlacklistMatcher`);
/// - stale responses from a previous source/order change are dropped;
/// - a trending-tag row derived from the loaded posts. RN fetched those from the RedGifs
///   trending endpoint (FeedScreen.tsx:113-125); the native sources expose no such call,
///   so the row is computed from tag frequencies instead.
@MainActor
@Observable
final class FeedViewModel {
    /// Full-screen phase of the feed. `.ready` also covers an empty result.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// One trending tag chip.
    struct TrendingTag: Identifiable, Hashable, Sendable {
        /// Tag name with underscores, exactly as stored on the post.
        let name: String
        let category: TagCategory
        /// How many loaded posts carry the tag.
        let count: Int

        var id: String { name }
    }

    /// Picks a source per id. Defaults to the shared registry; other layers inject
    /// a provider so the feed can be exercised without the network.
    typealias SourceProvider = (SourceID) -> (any BooruSource)?

    private(set) var context: SourceContext
    private let sourceProvider: SourceProvider
    private let blacklist: BlacklistMatcher

    private(set) var sourceID: SourceID
    /// Structured feed filter: the saved order plus any quick-filter patch.
    private(set) var filter: SearchFilterConfig
    private(set) var posts: [BooruPost] = []
    private(set) var trendingTags: [TrendingTag] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var isRefreshing = false
    /// False once a page comes back empty or fully duplicated.
    private(set) var hasMore = true
    /// Last error while posts are still on screen; the grid keeps showing them.
    private(set) var errorMessage: String?

    /// Page the next `loadMore()` requests. Sources may report their own next page.
    private var nextPage = 1
    /// Bumped on every reload so a slow response from a previous source/order is dropped.
    private var generation = 0

    private static let trendingTagLimit = 12

    /// - Parameters:
    ///   - sourceID: source the Explore tab opens on (RN default `gelbooru`).
    ///   - context: transport/credentials for the source requests.
    ///   - feedOrder: saved order; snapped to the first chip `sourceID` exposes.
    ///   - blacklistedTags: raw blacklist entries, matched by `BlacklistMatcher`.
    ///   - sourceProvider: source lookup, injectable for previews and tests.
    init(
        sourceID: SourceID,
        context: SourceContext,
        feedOrder: FeedOrder? = nil,
        blacklistedTags: [String] = [],
        sourceProvider: @escaping SourceProvider = { SourceRegistry.source(for: $0) }
    ) {
        self.sourceID = sourceID
        self.context = context
        self.blacklist = BlacklistMatcher(tags: blacklistedTags)
        self.sourceProvider = sourceProvider

        let normalized = SourceQuickFilters.normalizedFeedOrder(for: sourceID, saved: feedOrder)
        var config = SearchFilterConfig()
        config.sortBy = normalized.sortBy
        config.timeRange = normalized.timeRange
        config.hentaiHavenSection = normalized.hentaiHavenSection
        filter = config
    }

    // MARK: Derived state

    /// Chips the active source's adapter actually honors (RN `getSourceQuickFilters`).
    var quickFilters: [SourceQuickFilter] {
        SourceQuickFilters.options(for: sourceID, context: .feed)
    }

    /// Feed order currently applied, for persistence by the app layer.
    var order: FeedOrder {
        FeedOrder(
            sortBy: filter.sortBy,
            timeRange: filter.timeRange,
            hentaiHavenSection: filter.hentaiHavenSection
        )
    }

    func isActive(_ option: SourceQuickFilter) -> Bool {
        SourceQuickFilters.isActive(option, in: filter)
    }

    // MARK: Loading

    /// Swaps the transport/credentials after a Settings edit.
    ///
    /// When the Worker settings or API keys actually changed and the feed has nothing usable
    /// on screen (empty or failed), the current source is fetched again, so a new proxy or key
    /// takes effect without restarting the app. An unchanged context is a no-op.
    func updateContext(_ newContext: SourceContext) {
        let previous = context
        context = newContext

        let proxyChanged = newContext.proxy.enabled != previous.proxy.enabled
            || newContext.proxy.workerURL != previous.proxy.workerURL
        let authChanged = !Self.sameCredentials(newContext.gelbooruAuth, previous.gelbooruAuth)
            || !Self.sameCredentials(newContext.rule34Auth, previous.rule34Auth)
        guard proxyChanged || authChanged else { return }
        guard phase != .loading, !isRefreshing else { return }

        let needsReload: Bool
        switch phase {
        case .idle, .failed:
            needsReload = true
        case .ready:
            needsReload = posts.isEmpty
        case .loading:
            needsReload = false
        }
        guard needsReload else { return }
        Task { await reload(showLoading: posts.isEmpty) }
    }

    /// First load only; later appearances keep the loaded pages.
    func loadInitialIfNeeded() async {
        guard phase == .idle else { return }
        await reload(showLoading: true)
    }

    func retry() async {
        await reload(showLoading: true)
    }

    /// Pull-to-refresh: the list stays visible while page 1 is fetched again
    /// (FeedScreen.tsx:247-254).
    ///
    /// `.refreshable` cancels its task as soon as a view update lands (setting
    /// `isRefreshing` redraws the header), which used to abort the shared `load` on its
    /// `Task.isCancelled` guard and made the pull work only sometimes. The fetch therefore
    /// runs in an unstructured task that `.refreshable` cannot cancel; only a source/order
    /// switch (a new `generation`) still discards its response.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // A manual refresh must not reuse a Gelbooru lower bound cached before it.
        await GelbooruBoundCache.shared.clear()
        await Task { @MainActor in
            await self.loadPage(1, replacing: true, ignoreCancellation: true)
        }.value
    }

    /// Next page, guarded exactly like `handleLoadMore` (FeedScreen.tsx:256-260).
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isRefreshing, phase == .ready, !posts.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await load(page: nextPage, replacing: false, generation: generation)
    }

    /// Switches source and reloads from page 1. Timed/rating/type patches belong to the
    /// previous source's chips, so only the normalized order carries over
    /// (FeedScreen.tsx:94-98, 228-238).
    func selectSource(_ id: SourceID) async {
        guard id != sourceID else { return }
        sourceID = id

        let normalized = SourceQuickFilters.normalizedFeedOrder(for: id, saved: order)
        var config = SearchFilterConfig()
        config.sortBy = normalized.sortBy
        config.timeRange = normalized.timeRange
        config.hentaiHavenSection = normalized.hentaiHavenSection
        filter = config

        posts = []
        trendingTags = []
        await reload(showLoading: true)
    }

    /// Applies a chip patch and reloads (FeedScreen.tsx:240-245, 228-238).
    ///
    /// Tapping the already-active chip is a manual refresh, not a no-op: the user is
    /// telling the feed to fetch again with the same order.
    func applyQuickFilter(_ option: SourceQuickFilter) async {
        await GelbooruBoundCache.shared.clear()
        let next = SourceQuickFilters.apply(option, to: filter)
        guard next != filter else {
            await refresh()
            return
        }
        filter = next
        await reload(showLoading: true)
    }

    /// Grid tap target: the loaded list plus the tapped index (RN pushes `pushViewer(posts, idx)`).
    func openTarget(for post: BooruPost) -> (posts: [BooruPost], index: Int)? {
        let key = postKey(post)
        guard let index = posts.firstIndex(where: { postKey($0) == key }) else { return nil }
        return (posts, index)
    }

    // MARK: Requests

    private func loadPage(_ page: Int, replacing: Bool, ignoreCancellation: Bool = false) async {
        generation += 1
        let requestGeneration = generation
        if replacing && posts.isEmpty {
            phase = .loading
        }
        errorMessage = nil
        hasMore = true
        nextPage = page
        await load(
            page: page,
            replacing: replacing,
            generation: requestGeneration,
            ignoreCancellation: ignoreCancellation
        )
    }

    private func reload(showLoading: Bool, ignoreCancellation: Bool = false) async {
        generation += 1
        let requestGeneration = generation
        if showLoading {
            phase = .loading
        }
        errorMessage = nil
        hasMore = true
        nextPage = 1
        await load(
            page: 1,
            replacing: true,
            generation: requestGeneration,
            ignoreCancellation: ignoreCancellation
        )
    }

    private func load(
        page: Int,
        replacing: Bool,
        generation requestGeneration: Int,
        ignoreCancellation: Bool = false
    ) async {
        guard let source = sourceProvider(sourceID) else {
            if replacing {
                posts = []
                trendingTags = []
                phase = .failed("The \(sourceID.rawValue) source is not available yet.")
            } else {
                hasMore = false
            }
            return
        }

        do {
            let result = try await source.fetchPosts(
                query: SearchQuery(tags: "", filter: filter),
                page: page,
                context: context
            )
            // A stale request finishing during a source/order change must not overwrite
            // the new list (FeedScreen.tsx:161-162). A refresh's own unstructured task is
            // never cancelled, so `ignoreCancellation` keeps its result even when the
            // `.refreshable` task that started it was torn down.
            guard requestGeneration == generation,
                  ignoreCancellation || !Task.isCancelled else { return }

            let existing = replacing ? [] : posts
            let fresh = uniquePosts(result.posts, excluding: existing)
            if replacing {
                posts = fresh
            } else {
                posts += fresh
            }

            if fresh.isEmpty {
                // An empty or fully duplicated page ends the feed quietly
                // (FeedScreen.tsx:165-168, 189).
                hasMore = false
            } else {
                hasMore = result.hasMore
                nextPage = result.nextPage ?? (page + 1)
            }

            phase = .ready
            errorMessage = nil
            rebuildTrendingTags()
        } catch {
            guard requestGeneration == generation else { return }
            let message = Self.describe(error)
            if posts.isEmpty {
                phase = .failed(message)
            } else {
                // Keep the loaded grid; the footer carries the message
                // (FeedScreen.tsx:197-199 only surfaces page-1 failures).
                errorMessage = message
                phase = .ready
            }
        }
    }

    /// Applies the blacklist and drops posts already in the list
    /// (FeedScreen.tsx:182-190, booruApi.ts:385-464).
    private func uniquePosts(_ candidates: [BooruPost], excluding existing: [BooruPost]) -> [BooruPost] {
        var keys = Set(existing.map(postKey))
        var result: [BooruPost] = []
        result.reserveCapacity(candidates.count)
        for post in candidates {
            guard !blacklist.isBlocked(post) else { continue }
            guard keys.insert(postKey(post)).inserted else { continue }
            result.append(post)
        }
        return result
    }

    /// Tag frequencies across the loaded posts. A tag counts once per post, and only
    /// tags seen on at least two posts of a multi-post page are surfaced.
    private func rebuildTrendingTags() {
        guard !posts.isEmpty else {
            trendingTags = []
            return
        }

        var counts: [String: (category: TagCategory, count: Int)] = [:]
        for post in posts {
            var countedInPost = Set<String>()
            for (category, names) in groupedTags(post.tags) {
                for raw in names {
                    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard name.count > 1, countedInPost.insert(name).inserted else { continue }
                    let existing = counts[name]
                    counts[name] = (
                        category: existing?.category ?? category,
                        count: (existing?.count ?? 0) + 1
                    )
                }
            }
        }

        let minimum: Int = posts.count >= 2 ? 2 : 1
        var candidates: [TrendingTag] = []
        candidates.reserveCapacity(counts.count)
        for (name, entry) in counts where entry.count >= minimum {
            candidates.append(TrendingTag(name: name, category: entry.category, count: entry.count))
        }
        let sorted: [TrendingTag] = candidates.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
        let limited: ArraySlice<TrendingTag> = sorted.prefix(Self.trendingTagLimit)
        let tags: [TrendingTag] = Array(limited)
        trendingTags = tags
    }

    private func groupedTags(_ tags: BooruTagGroups) -> [(TagCategory, [String])] {
        [
            (.artist, tags.artist),
            (.character, tags.character),
            (.copyright, tags.copyright),
            (.general, tags.general),
            (.meta, tags.meta),
        ]
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let message = error.localizedDescription
        return message.isEmpty ? "An error occurred while loading images." : message
    }

    /// `ApiAuth` is not `Equatable`; compare the two stored fields instead.
    private static func sameCredentials(_ lhs: ApiAuth?, _ rhs: ApiAuth?) -> Bool {
        (lhs?.userID ?? "") == (rhs?.userID ?? "") && (lhs?.apiKey ?? "") == (rhs?.apiKey ?? "")
    }
}
