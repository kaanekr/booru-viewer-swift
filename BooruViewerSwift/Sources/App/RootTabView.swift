import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App shell: four tabs, the viewer cover, tag navigation, and the app-lock overlay.
///
/// The screens own their feature view models, but the container stays the single source for
/// settings, credentials, favorites, and blocked tags. Every tab change re-reads that shared
/// state so edits made in Settings (or by a backup import) reach Explore and Search.
@MainActor
struct RootTabView: View {
    enum Tab: String, Hashable, CaseIterable {
        case explore
        case search
        case favorites
        case settings

        /// Label under the icon in the system tab bar.
        var title: String {
            switch self {
            case .explore: return "Explore"
            case .search: return "Search"
            case .favorites: return "Favorites"
            case .settings: return "Settings"
            }
        }

        /// SF Symbol for the system tab bar item.
        var symbol: String {
            switch self {
            case .explore: return "square.grid.2x2.fill"
            case .search: return "magnifyingglass"
            case .favorites: return "heart.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    /// The viewer needs its own identity: the same post list can be reopened.
    private struct ViewerPresentation: Identifiable {
        let id = UUID()
        let posts: [BooruPost]
        let index: Int
    }

    private let container: AppContainer

    @State private var selectedTab: Tab = .explore
    @State private var explorePath: [TagSearchTarget] = []
    @State private var viewer: ViewerPresentation?
    /// Search query requested from another tab (tag taps). Nil is the normal Search tab.
    @State private var pendingSearch: String?
    /// Bumped on every requested search so the Search screen is rebuilt with the new query.
    @State private var searchToken = 0
    @State private var settingsModel: SettingsViewModel

    init(container: AppContainer) {
        self.container = container
        _selectedTab = State(initialValue: Self.tab(for: container.launchOptions.initialTab))
        _settingsModel = State(initialValue: SettingsViewModel(
            settingsStore: container.settingsStore,
            blacklistedStore: container.blacklistedTagsStore,
            backupService: container.backupService,
            security: container.securityService,
            lockController: container.lockController,
            probeClient: { URLSessionHTTPClient.makeProbeClient() },
            clearSearchHistory: {
                if container.launchOptions.demoMode {
                    // Demo state lives in memory; never touch the storage file for it.
                    await container.clearDemoSearchHistory()
                    return
                }
                try await container.fileStore.write(SearchHistoryStore.fileName, [String]())
            },
            onSourceChanged: { _ in
                Task { @MainActor in
                    await container.reloadSharedState()
                }
            }
        ))
    }

    /// Maps `-initialTab` onto the tab selection; a normal launch keeps Explore.
    private static func tab(for initialTab: LaunchOptions.InitialTab?) -> Tab {
        switch initialTab {
        case .feed:
            return .explore
        case .search:
            return .search
        case .favorites:
            return .favorites
        case .settings:
            return .settings
        case nil:
            return .explore
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Plain SwiftUI `TabView`: styling is only `.tint` plus the root `.background`
            // below, which sits behind the translucent system bar and keeps the bottom edge
            // black-free.
            TabView(selection: $selectedTab) {
                exploreTab
                    .tabItem { Label(Tab.explore.title, systemImage: Tab.explore.symbol) }
                    .tag(Tab.explore)

                searchTab
                    .tabItem { Label(Tab.search.title, systemImage: Tab.search.symbol) }
                    .tag(Tab.search)

                favoritesTab
                    .tabItem { Label(Tab.favorites.title, systemImage: Tab.favorites.symbol) }
                    .tag(Tab.favorites)

                settingsTab
                    .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.symbol) }
                    .tag(Tab.settings)
            }
            .tint(AppTheme.primary)

            // The lock/curtain covers the whole window, including the tab bar.
            // `-forceLock` skips the biometric auto-prompt so the PIN pad stays on screen.
            // No `.ignoresSafeArea()` here: the pad keeps its top inset so the padlock badge
            // clears the Dynamic Island, and `LockScreenView` bleeds its opaque layers itself.
            LockScreenView(
                controller: container.lockController,
                useBiometrics: !container.launchOptions.forceLock
            )
            .allowsHitTesting(
                container.lockController.isLocked
                    || container.lockController.isPrivacyCurtainVisible
            )
        }
        .background(AppTheme.background.ignoresSafeArea())
        .fullScreenCover(item: $viewer, onDismiss: { reloadAfterViewer() }) { presentation in
            ViewerScreen(
                posts: presentation.posts,
                initialIndex: presentation.index,
                context: container.makeSourceContext(),
                recentViews: container.recentViewsStore,
                favorites: container.favoritesStore,
                favoriteTags: container.favoriteTagsStore,
                blacklistedTags: container.blacklistedTagsStore,
                searchHistory: container.searchHistoryStore,
                hentaiHavenLastEpisodes: container.settings.hentaiHavenLastEpisodes,
                onSaveHentaiHavenEpisode: { postID, episode in
                    Task { @MainActor in
                        saveHentaiHavenEpisode(postID, episode)
                    }
                },
                onModifySearch: { modification in
                    Task { @MainActor in
                        viewer = nil
                        applySearchModification(modification)
                    }
                },
                onSelectTag: { tag in
                    viewer = nil
                    openTag(tag)
                },
                onClose: { viewer = nil }
            )
        }
        .onChange(of: selectedTab) { _, tab in
            // Fires only on an actual tab change (not on first appearance).
            Self.playTabSelectionHaptic()
            Task { @MainActor in
                await container.reloadSharedState()
                if tab == .settings {
                    await settingsModel.load(force: true)
                }
            }
        }
    }

    // MARK: - Tabs

    private var exploreTab: some View {
        NavigationStack(path: $explorePath) {
            FeedScreen(
                settings: container.settings,
                context: container.makeSourceContext(),
                blacklistedTags: container.blacklistedTags,
                favoriteKeys: container.favoriteKeys,
                contextVersion: container.contextVersion,
                sourceProvider: container.sourceProvider,
                onSelectTag: { tag in
                    explorePath.append(
                        TagSearchTarget(sourceID: container.settings.activeSourceID, tags: tag)
                    )
                },
                onSelectSource: { id in
                    // Keep Explore, Search, and Settings on the same source.
                    Task { @MainActor in await container.persistActiveSource(id) }
                },
                onPinTag: { tag in
                    Task { @MainActor in
                        try? await container.favoriteTagsStore.add(tag)
                    }
                },
                onBlacklistTag: { tag in
                    Task { @MainActor in
                        try? await container.blacklistedTagsStore.add(tag)
                        await container.reloadSharedState()
                    }
                },
                onSearchAction: { tag, action in
                    switch action {
                    case .replace:
                        openTag(tag)
                    case .include:
                        appendToSearch(tag)
                    case .exclude:
                        appendToSearch("-" + tag)
                    }
                },
                onOpenPost: { posts, index in openViewer(posts, index) }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TagSearchTarget.self) { target in
                detailScreen(for: target)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var searchTab: some View {
        NavigationStack {
            SearchScreen(
                activeSourceID: container.settings.activeSourceID,
                context: container.makeSourceContext(),
                historyStore: container.searchHistoryStore,
                blacklistedTags: container.blacklistedTags,
                favoriteKeys: container.favoriteKeys,
                imageQuality: container.settings.imageQuality,
                gridPreviewsEnabled: container.settings.gridPreviews,
                contextVersion: container.contextVersion,
                sourceProvider: container.sourceProvider,
                initialQuery: pendingSearch,
                favoriteTagsStore: container.favoriteTagsStore,
                blacklistStore: container.blacklistedTagsStore,
                onOpenTag: { tag in openTag(tag) },
                onToggleFavorite: { post in
                    Task { @MainActor in await container.toggleFavorite(post) }
                },
                onOpenPost: { posts, index in openViewer(posts, index) }
            )
            .toolbar(.hidden, for: .navigationBar)
            .id(searchToken)
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var favoritesTab: some View {
        NavigationStack {
            FavoritesScreen(
                favoritesStore: container.favoritesStore,
                tagStore: container.favoriteTagsStore,
                recentViewsStore: container.recentViewsStore,
                clearRecentViews: { await container.clearRecentViews() },
                isActive: selectedTab == .favorites,
                imageQuality: container.settings.imageQuality,
                gridPreviewsEnabled: container.settings.gridPreviews,
                blacklistStore: container.blacklistedTagsStore,
                onSelectTag: { tag in openTag(tag) },
                onOpenPost: { posts, index in openViewer(posts, index) }
            )
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var settingsTab: some View {
        NavigationStack {
            SettingsScreen(viewModel: settingsModel)
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    // MARK: - Haptics

    /// Light tap feedback on every tab change, mirroring RN's `Haptics.impactAsync(.Light)`.
    private static func playTabSelectionHaptic() {
        #if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }

    // MARK: - Navigation

    private func detailScreen(for target: TagSearchTarget) -> some View {
        SearchDetailScreen(
            sourceID: target.sourceID,
            tags: target.tags,
            context: container.makeSourceContext(),
            historyStore: container.searchHistoryStore,
            blacklistedTags: container.blacklistedTags,
            imageQuality: container.settings.imageQuality,
            gridPreviewsEnabled: container.settings.gridPreviews,
            contextVersion: container.contextVersion,
            sourceProvider: container.sourceProvider,
            onOpenPost: { posts, index in openViewer(posts, index) }
        )
    }

    private func openViewer(_ posts: [BooruPost], _ index: Int) {
        viewer = ViewerPresentation(posts: posts, index: index)
    }

    /// Tag taps outside Explore switch to the Search tab with a fresh query.
    private func openTag(_ tag: String) {
        pendingSearch = tag
        searchToken += 1
        selectedTab = .search
    }

    /// Appends a `+tag` / `-tag` token to the query pushed into the Search tab.
    ///
    /// The Search screen owns its live text, so the query this layer last pushed is the
    /// base the token is appended to.
    private func appendToSearch(_ token: String) {
        let base = (pendingSearch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSearch = base.isEmpty ? token : base + " " + token
        searchToken += 1
        selectedTab = .search
    }

    /// Applies a tag modification picked in the viewer tag menu (RN `onModifySearch`).
    private func applySearchModification(_ modification: TagSearchModification) {
        switch modification {
        case .replace(let tag):
            openTag(tag)
        case .include(let tag):
            appendToSearch(tag)
        case .exclude(let tag):
            appendToSearch("-" + tag)
        }
    }

    /// Persists the HentaiHaven episode the viewer resumed, so the next visit starts there
    /// (RN `lastHentaiHavenEpisodes`). The settings store is re-read first so a stale
    /// snapshot cannot drop episodes saved from another tab.
    private func saveHentaiHavenEpisode(_ postID: String, _ episode: Int) {
        Task { @MainActor in
            guard var updated = try? await container.settingsStore.load() else { return }
            updated.hentaiHavenLastEpisodes[postID] = episode
            try? await container.settingsStore.save(updated)
            await container.reloadSharedState()
        }
    }

    private func reloadAfterViewer() {
        Task { @MainActor in await container.reloadFavorites() }
    }
}
