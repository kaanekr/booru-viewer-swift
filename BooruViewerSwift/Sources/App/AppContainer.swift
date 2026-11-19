import Foundation
import Observation

/// Shared application graph.
///
/// Owns the stores, the network transport, the security services, and the in-memory copies the
/// views render (settings, credentials, favorite keys, blocked tags). It is created once by
/// `BooruViewerApp` and injected into `RootTabView`.
@MainActor
@Observable
final class AppContainer {
    // MARK: - Stores

    /// One JSON actor shared by every file-backed store so read-modify-write is serialized app-wide.
    let fileStore: JSONFileStore
    /// In `-demoMode` these are the in-memory stores from `DemoData`; otherwise the file-backed ones.
    let settingsStore: any SettingsStoring
    let favoritesStore: any FavoritesStoring
    let favoriteTagsStore: any TagListStoring
    let blacklistedTagsStore: any TagListStoring
    let searchHistoryStore: any SearchHistoryStoring
    let recentViewsStore: any RecentViewsStoring

    // MARK: - Launch

    /// Parsed launch arguments; every flag is off for a normal launch.
    let launchOptions: LaunchOptions
    /// Source lookup: the demo adapter in `-demoMode`, the real registry otherwise.
    let sourceProvider: @Sendable (SourceID) -> (any BooruSource)?

    // MARK: - Services

    let securityService: SecurityService
    let lockController: AppLockController
    let backupService: BackupService
    let httpClient: URLSessionHTTPClient

    // MARK: - Rendered state

    private(set) var settings = AppSettings()
    /// Keychain-backed credentials; `nil` while unset.
    private(set) var gelbooruAuth: ApiAuth?
    private(set) var rule34Auth: ApiAuth?
    /// Source-qualified `postKey` values currently favorited, used for card badges.
    private(set) var favoriteKeys: Set<String> = []
    /// Raw blocked-tag entries applied to every loaded page.
    private(set) var blacklistedTags: [String] = []

    // MARK: - Init

    init(directory: URL = JSONFileStore.defaultDirectory()) {
        let options = LaunchOptions.current()
        self.launchOptions = options
        if options.demoMode {
            self.sourceProvider = DemoBooruSource.provider
        } else {
            self.sourceProvider = { SourceRegistry.source(for: $0) }
        }

        let fileStore = JSONFileStore(directory: directory)
        self.fileStore = fileStore
        if options.demoMode {
            // Demo state stays in memory: no demo data is written to the JSON storage files.
            self.settingsStore = DemoSettingsStore(settings: DemoData.settings)
            self.favoritesStore = DemoFavoritesStore(posts: DemoData.favorites)
            self.favoriteTagsStore = DemoTagListStore(tags: DemoData.favoriteTags)
            self.blacklistedTagsStore = DemoTagListStore(tags: DemoData.blacklistedTags)
            self.searchHistoryStore = DemoSearchHistoryStore(queries: DemoData.searchHistory)
            self.recentViewsStore = DemoRecentViewsStore(posts: DemoData.recentViews)
        } else {
            self.settingsStore = SettingsStore(file: fileStore)
            self.favoritesStore = FavoritesStore(file: fileStore)
            self.favoriteTagsStore = TagListStore(file: fileStore, kind: .favorite)
            self.blacklistedTagsStore = TagListStore(file: fileStore, kind: .blacklisted)
            self.searchHistoryStore = SearchHistoryStore(file: fileStore)
            self.recentViewsStore = RecentViewsStore(file: fileStore)
        }
        self.httpClient = URLSessionHTTPClient()

        let securityService = SecurityService()
        self.securityService = securityService
        self.lockController = AppLockController(service: securityService, settings: settingsStore)

        self.backupService = BackupService(
            favorites: favoritesStore,
            favoriteTags: favoriteTagsStore,
            blacklistedTags: blacklistedTagsStore,
            searchHistory: searchHistoryStore,
            recentViews: recentViewsStore
        )

        if options.demoMode {
            // Seed the first render too, so no tab flashes empty before `bootstrap()` runs.
            settings = DemoData.settings
            favoriteKeys = Set(DemoData.favorites.map(postKey))
            blacklistedTags = DemoData.blacklistedTags
        }
    }

    // MARK: - Launch

    /// Loads persisted state, restores credentials, then arms the cold-start lock.
    /// `-forceLock` additionally locks the app so the PIN pad can be screenshotted.
    func bootstrap() async {
        await reloadSharedState()
        MediaRequestConfiguration.updateCurrentProxy(settings.proxy)
        await lockController.prepareForLaunch()
        if launchOptions.forceLock {
            lockController.lockNow()
        }
    }

    // MARK: - Shared state

    /// Re-reads settings, credentials, favorites, and the blacklist.
    ///
    /// Screens mutate these through their own store handles, so the tabs call this whenever the
    /// selection changes to pick up edits made elsewhere (Settings, Viewer, Backup import).
    func reloadSharedState() async {
        if let loaded = try? await settingsStore.load() {
            settings = loaded
        }
        MediaRequestConfiguration.updateCurrentProxy(settings.proxy)
        blacklistedTags = (try? await blacklistedTagsStore.list()) ?? []
        await reloadFavorites()
        await loadCredentials()
    }

    /// Bumped whenever `makeSourceContext()` would produce a different request context.
    ///
    /// Screens watch this to swap their `SourceContext` after a Settings edit (Worker URL,
    /// proxy toggle, API key, image quality) instead of keeping the value they were built with.
    var contextVersion: Int {
        var hasher = Hasher()
        hasher.combine(settings.proxy.enabled)
        hasher.combine(settings.proxy.workerURL)
        hasher.combine(settings.imageQuality.rawValue)
        hasher.combine(gelbooruAuth?.userID)
        hasher.combine(gelbooruAuth?.apiKey)
        hasher.combine(rule34Auth?.userID)
        hasher.combine(rule34Auth?.apiKey)
        return hasher.finalize()
    }

    /// Persists a source picked from a screen's source sheet.
    ///
    /// Explore, Search, and Settings all read `activeSourceID` from these settings, so the
    /// switch has to be stored here rather than only in the view model.
    func persistActiveSource(_ id: SourceID) async {
        guard settings.activeSourceID != id else { return }
        var updated = settings
        updated.activeSourceID = id
        do {
            try await settingsStore.save(updated)
        } catch {
            return
        }
        settings = updated
        // Unchanged, but the media pipeline reads the stored Worker from this path too.
        MediaRequestConfiguration.updateCurrentProxy(settings.proxy)
    }

    /// Refreshes only the favorite key set, e.g. after the viewer toggled a favorite.
    func reloadFavorites() async {
        let posts = (try? await favoritesStore.list()) ?? []
        favoriteKeys = Set(posts.map(postKey))
    }

    func isFavorite(_ post: BooruPost) -> Bool {
        favoriteKeys.contains(postKey(post))
    }

    /// Adds or removes `post`, then refreshes the in-memory badges.
    func toggleFavorite(_ post: BooruPost) async {
        if isFavorite(post) {
            try? await favoritesStore.remove(id: post.id, sourceID: post.sourceID)
        } else {
            try? await favoritesStore.add(post)
        }
        await reloadFavorites()
    }

    // MARK: - Requests

    /// Per-request dependencies handed to source adapters. Rebuilt so proxy and quality edits
    /// made in Settings reach the next fetch without restarting the app.
    func makeSourceContext() -> SourceContext {
        SourceContext(
            http: ProxyAwareHTTPClient(direct: httpClient, proxy: settings.proxy),
            proxy: settings.proxy,
            gelbooruAuth: gelbooruAuth,
            rule34Auth: rule34Auth,
            imageQuality: settings.imageQuality
        )
    }

    // MARK: - History

    /// Persists an empty recent-views document. `RecentViewsStoring` has no delete operation, so
    /// `FavoritesScreen`'s "Clear History" calls this app-level hook instead.
    func clearRecentViews() async {
        if launchOptions.demoMode {
            // Demo state lives in memory; never touch the storage file for it.
            await (recentViewsStore as? DemoRecentViewsStore)?.clear()
            return
        }
        try? await fileStore.write(RecentViewsStore.fileName, [BooruPost]())
    }

    /// Demo-mode helper: empties the in-memory search history instead of the storage file.
    func clearDemoSearchHistory() async {
        await (searchHistoryStore as? DemoSearchHistoryStore)?.clear()
    }

    // MARK: - Credentials

    private func loadCredentials() async {
        gelbooruAuth = try? KeychainStore.load(ApiAuth.self, for: KeychainStore.gelbooruAuthAccount)
        rule34Auth = try? KeychainStore.load(ApiAuth.self, for: KeychainStore.rule34AuthAccount)
    }
}
