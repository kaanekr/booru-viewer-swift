import Foundation
import Observation

/// Search tab state. Mirrors RN `SearchScreen.tsx`:
/// - 250 ms debounced server tag autocomplete (`tagSuggestions`),
/// - search history persisted through `SearchHistoryStoring`,
/// - paginated results guarded by a generation counter so stale responses are dropped,
/// - loaded posts filtered through `BlacklistMatcher` unless `includeBlacklisted` is set.
@MainActor
@Observable
final class SearchViewModel {
    /// How the typed text merges with the tags already in the filter (SearchScreen.tsx:437-474).
    enum SearchMode {
        /// Replace the tag list with the incoming text (default).
        case replace
        /// Append the incoming tags that are not listed yet.
        case add
        /// Append the incoming tags, negated with a `-` prefix.
        case exclude
    }

    /// Resolves a source per id. Defaults to the shared registry; other layers inject
    /// a provider so the screen can be exercised without the network.
    typealias SourceProvider = (SourceID) -> (any BooruSource)?

    /// Autocomplete debounce (SearchScreen.tsx:323).
    static let autocompleteDebounce: Duration = .milliseconds(250)

    // MARK: Dependencies

    private(set) var context: SourceContext
    private let historyStore: any SearchHistoryStoring
    private let sourceProvider: SourceProvider
    private var blacklist: BlacklistMatcher

    // MARK: Input

    /// Raw search text. Change it through `setQuery(_:)` so autocomplete reschedules.
    var query: String
    /// Structured search options shared with `SearchFilterSheetView`.
    var filter: SearchFilterConfig
    private(set) var sourceID: SourceID
    private(set) var history: [String] = []
    private(set) var suggestions: [BooruTagSuggestion] = []
    private(set) var isAutocompleting = false

    // MARK: Results

    /// Blacklist-filtered results, in source order.
    private(set) var results: [BooruPost] = []
    private(set) var isSearchActive = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    /// Posts dropped by the blacklist for the current result set.
    private(set) var blacklistedCount = 0

    // MARK: Internals

    private var allResults: [BooruPost] = []
    private var currentPage = 1
    /// Bumped on every new search/source change; a slow response from an older one is dropped.
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var pendingInitialQuery: String?
    private var pendingInitialFilter: SearchFilterConfig?

    /// True when any structured option differs from the defaults; drives the filter button badge.
    var hasCustomFilters: Bool {
        filter.sortBy != .default
            || filter.timeRange != .all
            || filter.rating != .all
            || filter.minScore != nil
            || filter.user?.isEmpty == false
            || (filter.cumstService ?? .all) != .all
            || (filter.cumstMediaType ?? .all) != .all
            || filter.jumpToPage > 1
            || filter.leaderboardDate?.isEmpty == false
            || filter.hentaiHavenSection != nil
    }

    /// - Parameters:
    ///   - sourceID: source the search runs against; the Explore tab default is `gelbooru`.
    ///   - context: transport and credentials handed to the source adapters.
    ///   - historyStore: persisted search history.
    ///   - blacklistedTags: raw blacklist entries, matched by `BlacklistMatcher`.
    ///   - sourceProvider: source lookup, injectable for previews and tests.
    ///   - initialQuery: runs one search as soon as `start()` is called.
    ///   - initialFilter: filter-sheet style initial search; wins over `initialQuery`.
    init(
        sourceID: SourceID,
        context: SourceContext,
        historyStore: any SearchHistoryStoring,
        blacklistedTags: [String] = [],
        sourceProvider: @escaping SourceProvider = { SourceRegistry.source(for: $0) },
        initialQuery: String? = nil,
        initialFilter: SearchFilterConfig? = nil
    ) {
        self.sourceID = sourceID
        self.context = context
        self.historyStore = historyStore
        self.blacklist = BlacklistMatcher(tags: blacklistedTags)
        self.sourceProvider = sourceProvider

        if let initialFilter {
            self.filter = initialFilter
            self.query = initialFilter.tags.joined(separator: " ")
            self.pendingInitialFilter = initialFilter
        } else {
            self.filter = SearchFilterConfig()
            self.query = initialQuery ?? ""
            self.pendingInitialQuery = initialQuery
        }
    }

    // MARK: Lifecycle

    /// Refreshes the history and runs the initial query, if one was supplied (RN `initialTag`).
    func start() async {
        await loadHistory()
        if let config = pendingInitialFilter {
            pendingInitialFilter = nil
            query = config.tags.joined(separator: " ")
            executeSearch(config)
        } else if let initial = pendingInitialQuery {
            pendingInitialQuery = nil
            search(text: initial, mode: .replace)
        }
    }

    /// Reloads the persisted search history.
    func loadHistory() async {
        history = (try? await historyStore.list()) ?? []
    }

    /// Swaps the transport/credentials after a Settings edit.
    ///
    /// A Worker or API-key change only matters once a search is active; when the current
    /// search has no results (empty or failed) it is retried immediately, so the new proxy
    /// takes effect without restarting the app. An unchanged context is a no-op.
    func updateContext(_ newContext: SourceContext) {
        let previous = context
        context = newContext

        let proxyChanged = newContext.proxy.enabled != previous.proxy.enabled
            || newContext.proxy.workerURL != previous.proxy.workerURL
        let authChanged = !Self.sameCredentials(newContext.gelbooruAuth, previous.gelbooruAuth)
            || !Self.sameCredentials(newContext.rule34Auth, previous.rule34Auth)
        guard proxyChanged || authChanged else { return }
        guard isSearchActive, results.isEmpty, !isLoading, !isLoadingMore else { return }
        executeSearch(filter)
    }

    /// Applies a new blacklist and re-filters the posts already on screen.
    func updateBlacklist(_ tags: [String]) {
        blacklist = BlacklistMatcher(tags: tags)
        applyBlacklist()
    }

    // MARK: Source

    /// Switches source and drops the previous source's results and suggestions
    /// (SearchScreen.tsx:259-280). The typed text stays as tags.
    func selectSource(_ id: SourceID) {
        guard id != sourceID else { return }
        sourceID = id
        cancelSearch()
        cancelSuggestions()
        isSearchActive = false
        isLoading = false
        isLoadingMore = false
        hasMore = false
        allResults = []
        results = []
        blacklistedCount = 0
        errorMessage = nil
        currentPage = 1
        filter = SearchFilterConfig(tags: Self.parseTags(query))
    }

    // MARK: Tag autocomplete

    /// Stores the typed text and reschedules the debounced autocomplete.
    func setQuery(_ text: String) {
        query = text
        scheduleTagSuggestions()
    }

    /// Autocomplete runs only while the field is focused (SearchScreen.tsx:283-326).
    func inputFocusChanged(_ focused: Bool) {
        if focused {
            scheduleTagSuggestions()
        } else {
            cancelSuggestions()
        }
    }

    private func cancelSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestions = []
        isAutocompleting = false
    }

    private func scheduleTagSuggestions() {
        cancelSuggestions()
        guard filter.autocompleteFromServer else { return }

        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A trailing space means the user has not started the next tag yet (SearchScreen.tsx:290).
        guard !text.hasSuffix(" ") else { return }

        let token = Self.activeSuggestionToken(in: text)
        // Autocomplete starts at two characters (SearchScreen.tsx:305).
        guard token.count >= 2 else { return }

        let expectedSource = sourceID
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: SearchViewModel.autocompleteDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.loadSuggestions(for: token, sourceID: expectedSource)
        }
    }

    private func loadSuggestions(for token: String, sourceID expectedSource: SourceID) async {
        guard let source = sourceProvider(expectedSource) else {
            suggestions = []
            return
        }
        isAutocompleting = true
        defer { isAutocompleting = false }
        do {
            let list = try await source.tagSuggestions(prefix: token, context: context)
            guard !Task.isCancelled, self.sourceID == expectedSource else { return }
            suggestions = Array(list.prefix(BooruQueryTranslator.suggestionLimit))
        } catch {
            guard !Task.isCancelled, self.sourceID == expectedSource else { return }
            suggestions = []
        }
    }

    /// Completes the token being typed with a suggestion (SearchScreen.tsx:397-428).
    func applySuggestion(_ suggestion: BooruTagSuggestion, immediateSearch: Bool = false) {
        query = Self.replacingActiveToken(in: query, with: suggestion.name)
        cancelSuggestions()
        if immediateSearch {
            search(text: query, mode: .replace)
        }
    }

    // MARK: Search

    /// Runs `text` according to `mode`, keeping the current structured options.
    func search(text: String, mode: SearchMode = .replace) {
        let incoming = Self.parseTags(text)
        var tags = filter.tags

        switch mode {
        case .replace:
            tags = incoming
        case .add:
            for tag in incoming where !tags.contains(tag) {
                tags.append(tag)
            }
        case .exclude:
            for tag in incoming {
                let negated = tag.hasPrefix("-") ? tag : "-" + tag
                if !tags.contains(negated) {
                    tags.append(negated)
                }
            }
        }

        query = tags.joined(separator: " ")
        var config = filter
        config.tags = tags
        config.jumpToPage = 1
        executeSearch(config)
    }

    /// Runs the current text with the current filter.
    func runSearch() {
        search(text: query, mode: .replace)
    }

    /// Applies a filter-sheet configuration and searches with its tag list (RN `handleApplyFilterModal`).
    func applyFilter(_ config: SearchFilterConfig) {
        query = config.tags.joined(separator: " ")
        executeSearch(config)
    }

    /// Clears results and returns to the explore state (RN `handleExitSearch`).
    func exitSearch() {
        cancelSearch()
        cancelSuggestions()
        isSearchActive = false
        isLoading = false
        isLoadingMore = false
        hasMore = false
        allResults = []
        results = []
        blacklistedCount = 0
        errorMessage = nil
        currentPage = 1
        query = ""
        let autocomplete = filter.autocompleteFromServer
        filter = SearchFilterConfig(autocompleteFromServer: autocomplete)
    }

    private func cancelSearch() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func executeSearch(_ config: SearchFilterConfig) {
        cancelSearch()
        cancelSuggestions()

        filter = config
        isSearchActive = true
        isLoading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        allResults = []
        results = []
        blacklistedCount = 0

        let startPage = max(1, config.jumpToPage)
        currentPage = startPage
        let requestGeneration = generation

        searchTask = Task { [weak self] in
            guard let self else { return }
            // Multi-tag searches stay one history entry (SearchScreen.tsx:352-356).
            if !config.tags.isEmpty {
                await self.recordHistory(config.tags.joined(separator: " "))
            }
            await self.fetchPage(
                config: config,
                page: startPage,
                generation: requestGeneration,
                isFirstPage: true
            )
        }
    }

    private func recordHistory(_ text: String) async {
        try? await historyStore.record(text)
        if let updated = try? await historyStore.list() {
            history = updated
        }
    }

    /// Fetches the next page. RN advances the page only on success, so a retry re-requests it.
    func loadMore() {
        guard isSearchActive, !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        let config = filter
        let requestGeneration = generation
        searchTask = Task { [weak self] in
            await self?.fetchPage(
                config: config,
                page: nextPage,
                generation: requestGeneration,
                isFirstPage: false
            )
        }
    }

    private func fetchPage(
        config: SearchFilterConfig,
        page: Int,
        generation requestGeneration: Int,
        isFirstPage: Bool
    ) async {
        guard let source = sourceProvider(sourceID) else {
            if isFirstPage {
                isLoading = false
                hasMore = false
                allResults = []
                results = []
                blacklistedCount = 0
                isSearchActive = true
                errorMessage = "The \(sourceID.rawValue) source is not available yet."
            } else {
                isLoadingMore = false
                hasMore = false
            }
            return
        }

        let query = SearchQuery(tags: config.tags.joined(separator: " "), filter: config)
        do {
            let pageResult = try await source.fetchPosts(query: query, page: page, context: context)
            // A stale request finishing after a source change must not overwrite the new list.
            guard requestGeneration == generation, !Task.isCancelled else { return }
            apply(pageResult, isFirstPage: isFirstPage)
        } catch {
            guard requestGeneration == generation else { return }
            if isFirstPage {
                allResults = []
                results = []
                blacklistedCount = 0
                hasMore = false
                isLoading = false
                errorMessage = Self.message(for: error)
            } else {
                isLoadingMore = false
            }
        }
    }

    private func apply(_ pageResult: PostPage, isFirstPage: Bool) {
        if isFirstPage {
            allResults = pageResult.posts
            isLoading = false
            // An empty page ends paging (SearchScreen.tsx:381).
            hasMore = pageResult.hasMore && !pageResult.posts.isEmpty
            errorMessage = pageResult.posts.isEmpty ? "No results found" : nil
        } else {
            var seen = Set(allResults.map(postKey))
            let unique = pageResult.posts.filter { post in
                let key = postKey(post)
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            guard !unique.isEmpty else {
                hasMore = false
                isLoadingMore = false
                return
            }
            allResults.append(contentsOf: unique)
            currentPage = pageResult.nextPage ?? (currentPage + 1)
            hasMore = pageResult.hasMore
            isLoadingMore = false
        }
        applyBlacklist()
    }

    // MARK: Blacklist

    private func applyBlacklist() {
        guard !allResults.isEmpty else {
            results = []
            blacklistedCount = 0
            return
        }
        guard !filter.includeBlacklisted else {
            results = allResults
            blacklistedCount = 0
            return
        }
        var visible: [BooruPost] = []
        visible.reserveCapacity(allResults.count)
        var hidden = 0
        for post in allResults {
            if blacklist.isBlocked(post) {
                hidden += 1
            } else {
                visible.append(post)
            }
        }
        results = visible
        blacklistedCount = hidden
    }

    /// Reveals the hidden posts for the current set without re-fetching (RN "show hidden" banner).
    func showBlacklistedPosts() {
        filter.includeBlacklisted = true
        applyBlacklist()
    }

    /// Grid tap target: the loaded list plus the tapped index (RN `pushViewer(results, idx)`).
    func openTarget(for post: BooruPost) -> (posts: [BooruPost], index: Int)? {
        let key = postKey(post)
        guard let index = results.firstIndex(where: { postKey($0) == key }) else { return nil }
        return (results, index)
    }

    // MARK: Static parsing helpers

    /// Last token being typed, with `-` negation and `tag:`/`artist:` prefixes and quotes stripped
    /// (SearchScreen.tsx:297-303).
    nonisolated static func activeSuggestionToken(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastToken = trimmed.split(whereSeparator: { $0.isWhitespace }).last else {
            return ""
        }
        var token = String(lastToken)
        while token.hasPrefix("-") {
            token.removeFirst()
        }
        let prefixes = ["tag:", "artist:", "character:", "parody:", "group:", "language:", "category:"]
        let lower = token.lowercased()
        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            token = String(token.dropFirst(prefix.count))
            if token.hasPrefix("\"") {
                token.removeFirst()
            }
        }
        if token.hasSuffix("\"") {
            token.removeLast()
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the token being typed with `tag`, keeping earlier tokens and a trailing space
    /// (SearchScreen.tsx:409-420).
    nonisolated static func replacingActiveToken(in text: String, with tag: String) -> String {
        let replacement = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parts = parseTags(text)
        if !parts.isEmpty, !text.hasSuffix(" ") {
            let last = parts.removeLast()
            parts.append(last.hasPrefix("-") ? "-" + replacement : replacement)
            return parts.joined(separator: " ") + " "
        }
        let existing = parts.joined(separator: " ")
        guard !existing.isEmpty else { return replacement.isEmpty ? "" : replacement + " " }
        return replacement.isEmpty ? existing + " " : existing + " " + replacement + " "
    }

    /// RN `parseQueryToTags` (SearchScreen.tsx:430-435): quoted groups stay one token and every
    /// token is lowercased. Quotes are kept so `tag:"big breasts"` survives a round trip.
    nonisolated static func parseTags(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if !inQuotes, character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let message = error.localizedDescription
        return message.isEmpty ? "An error occurred while searching." : message
    }

    /// `ApiAuth` is not `Equatable`; compare the two stored fields instead.
    private static func sameCredentials(_ lhs: ApiAuth?, _ rhs: ApiAuth?) -> Bool {
        (lhs?.userID ?? "") == (rhs?.userID ?? "") && (lhs?.apiKey ?? "") == (rhs?.apiKey ?? "")
    }
}
