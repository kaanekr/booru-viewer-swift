import Foundation
import Observation

/// Favorites tab state: saved posts with a source filter, the favorite tag list, and recent views.
/// Backed by `FavoritesStoring`, `TagListStoring` (favorite kind), and `RecentViewsStoring`
/// (RN `FavoritesScreen.tsx`).
@MainActor
@Observable
final class FavoritesViewModel {
    enum Segment: String, CaseIterable, Identifiable {
        case savedPosts
        case favoriteTags
        case recentViews

        var id: String { rawValue }

        var title: String {
            switch self {
            case .savedPosts: return "Saved Posts"
            case .favoriteTags: return "Favorite Tags"
            case .recentViews: return "Recent Views"
            }
        }
    }

    /// One row of the saved-posts source filter.
    struct SourceSummary: Identifiable, Hashable {
        var id: SourceID
        var name: String
        var count: Int
    }

    // MARK: Dependencies

    private let favoritesStore: any FavoritesStoring
    private let tagStore: any TagListStoring
    private let recentViewsStore: any RecentViewsStoring
    /// `RecentViewsStoring` has no delete operation, so the host app injects the clear when it can.
    private let clearRecentViewsHandler: (() async -> Void)?

    // MARK: State

    var segment: Segment = .savedPosts
    /// nil shows every source (RN `selectedSource === 'all'`).
    var sourceFilter: SourceID?
    private(set) var favorites: [BooruPost] = []
    private(set) var favoriteTags: [String] = []
    private(set) var recentViews: [BooruPost] = []
    private(set) var isLoading = false
    private var favoriteKeys: Set<String> = []
    private var didLoad = false

    /// True when the host app supplied a way to clear the persisted recent-view list.
    var canClearRecentViews: Bool { clearRecentViewsHandler != nil }

    init(
        favoritesStore: any FavoritesStoring,
        tagStore: any TagListStoring,
        recentViewsStore: any RecentViewsStoring,
        clearRecentViews: (() async -> Void)? = nil
    ) {
        self.favoritesStore = favoritesStore
        self.tagStore = tagStore
        self.recentViewsStore = recentViewsStore
        self.clearRecentViewsHandler = clearRecentViews
    }

    /// Saved posts matching the source filter, newest saved first.
    var visibleFavorites: [BooruPost] {
        guard let sourceFilter else { return favorites }
        return favorites.filter { $0.sourceID == sourceFilter }
    }

    /// Sources present in the saved posts, most populated first (FavoritesScreen.tsx:224-243).
    var sourceCounts: [SourceSummary] {
        var counts: [SourceID: Int] = [:]
        var names: [SourceID: String] = [:]
        for post in favorites {
            counts[post.sourceID, default: 0] += 1
            if names[post.sourceID] == nil {
                names[post.sourceID] = post.sourceName.isEmpty ? post.sourceID.rawValue : post.sourceName
            }
        }
        return counts
            .map { SourceSummary(id: $0.key, name: names[$0.key] ?? $0.key.rawValue, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Name of the active source filter for the toolbar label.
    var selectedSourceName: String {
        guard let sourceFilter else { return "All Sources" }
        return sourceCounts.first(where: { $0.id == sourceFilter })?.name ?? sourceFilter.rawValue
    }

    // MARK: Loading

    func load() async {
        if !didLoad {
            isLoading = true
        }
        async let favoritesTask = favoritesStore.list()
        async let tagsTask = tagStore.list()
        async let recentTask = recentViewsStore.list()

        let savedPosts = (try? await favoritesTask) ?? []
        let tags = (try? await tagsTask) ?? []
        let recent = (try? await recentTask) ?? []
        favoriteKeys = Set(savedPosts.map(postKey))

        favorites = savedPosts
        favoriteTags = tags
        recentViews = recent
        if let sourceFilter, !savedPosts.contains(where: { $0.sourceID == sourceFilter }) {
            self.sourceFilter = nil
        }
        isLoading = false
        didLoad = true
    }

    // MARK: Saved posts

    func isFavorite(_ post: BooruPost) -> Bool {
        favoriteKeys.contains(postKey(post))
    }

    /// Removes a saved post (long press on a saved card, or unfavoriting from the viewer).
    func removeFavorite(_ post: BooruPost) async {
        try? await favoritesStore.remove(id: post.id, sourceID: post.sourceID)
        let key = postKey(post)
        favoriteKeys.remove(key)
        favorites.removeAll { postKey($0) == key }
    }

    // MARK: Favorite tags

    /// Adds a normalized tag to the front of the list (the store normalizes and dedupes).
    func addFavoriteTag(_ tag: String) async {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await tagStore.add(trimmed)
        await reloadFavoriteTags()
    }

    func removeFavoriteTag(_ tag: String) async {
        try? await tagStore.remove(tag)
        await reloadFavoriteTags()
    }

    private func reloadFavoriteTags() async {
        let tags = (try? await tagStore.list()) ?? []
        favoriteTags = tags
    }

    // MARK: Recent views

    /// Clears the persisted list when the host supplied a handler, and always empties the grid.
    func clearRecentViews() async {
        if let clearRecentViewsHandler {
            await clearRecentViewsHandler()
        }
        recentViews = []
    }
}
