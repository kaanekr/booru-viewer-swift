import Foundation

/// Launch arguments understood by the app.
///
/// The simulator UI smoke job (`-demoMode`, `-initialTab <feed|search|favorites|settings>`,
/// `-forceLock`) launches the app with these flags so screens can be inspected without a
/// live source. Without arguments every flag is off and the app behaves exactly as before.
struct LaunchOptions: Sendable, Equatable {
    /// Tab the app opens on. `feed` maps to the Explore tab.
    enum InitialTab: String, Sendable, CaseIterable {
        case feed
        case search
        case favorites
        case settings
    }

    /// Seeds sample posts, tags, and history and swaps in the demo source adapter.
    var demoMode = false
    /// Initially selected tab; `nil` keeps the normal Explore default.
    var initialTab: InitialTab?
    /// Locks the app at launch so the PIN pad can be captured.
    var forceLock = false

    init(demoMode: Bool = false, initialTab: InitialTab? = nil, forceLock: Bool = false) {
        self.demoMode = demoMode
        self.initialTab = initialTab
        self.forceLock = forceLock
    }

    /// Parses `simctl launch` style arguments (`-key value` pairs and bare switches).
    /// User defaults are consulted as a fallback so `-initialTab favorites` also works when
    /// the value lands in `NSArgumentDomain` instead of the raw argument list.
    init(arguments: [String], defaults: UserDefaults = .standard) {
        var demo = defaults.bool(forKey: "demoMode")
        var force = defaults.bool(forKey: "forceLock")
        var tab = InitialTab(rawValue: (defaults.string(forKey: "initialTab") ?? "").lowercased())

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "-demoMode", "--demoMode":
                demo = true
            case "-forceLock", "--forceLock":
                force = true
            case "-initialTab", "--initialTab":
                if index + 1 < arguments.count {
                    let raw = arguments[index + 1].lowercased()
                    // `explore` is the on-screen name of the `feed` tab.
                    if raw == "explore" {
                        tab = .feed
                    } else {
                        tab = InitialTab(rawValue: raw)
                    }
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        self.init(demoMode: demo, initialTab: tab, forceLock: force)
    }

    /// Options of the current process.
    static func current() -> LaunchOptions {
        LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    }
}

/// Deterministic sample content for the simulator UI smoke job.
///
/// Neutral, safe placeholder imagery only (`picsum.photos` seeds). Nothing here is written to
/// the JSON storage files: `-demoMode` swaps in the in-memory stores below instead.
enum DemoData {
    // MARK: - Seeded lists

    static let favoriteTags: [String] = ["landscape", "city skyline", "portrait"]
    static let blacklistedTags: [String] = ["low_res", "watermark"]
    static let searchHistory: [String] = ["landscape", "city skyline", "portrait", "mountain sunset"]

    /// Settings used in demo mode, so the first render already matches the seeded content.
    static let settings = AppSettings(
        imageQuality: .auto,
        gridPreviews: true,
        activeSourceID: .gelbooru
    )

    // MARK: - Posts

    static var posts: [BooruPost] {
        [
            BooruPost(
                id: "demo-01",
                sourceID: .gelbooru,
                sourceName: "Gelbooru",
                title: nil,
                previewURL: image("demo-01"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-01"),
                originalURL: image("demo-01"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 428,
                favCount: 61,
                tags: BooruTagGroups(
                    artist: ["demo_artist"],
                    character: [],
                    copyright: ["original"],
                    general: ["landscape", "mountain", "sunset"],
                    meta: []
                ),
                allTags: ["demo_artist", "original", "landscape", "mountain", "sunset"],
                sourceLink: URL(string: "https://example.com/post/demo-01"),
                fileExt: "jpg",
                fileSize: 184_320,
                createdAt: "2026-01-04 08:15:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-02",
                sourceID: .danbooru,
                sourceName: "Danbooru",
                title: nil,
                previewURL: image("demo-02"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-02"),
                originalURL: image("demo-02"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .safe,
                score: 512,
                favCount: 88,
                tags: BooruTagGroups(
                    artist: ["pixel_studio"],
                    character: [],
                    copyright: ["original"],
                    general: ["city", "skyline", "night", "architecture"],
                    meta: ["highres"]
                ),
                allTags: ["pixel_studio", "original", "city", "skyline", "night", "architecture", "highres"],
                sourceLink: URL(string: "https://example.com/post/demo-02"),
                fileExt: "mp4",
                fileSize: 402_115,
                createdAt: "2026-01-04 09:02:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-03",
                sourceID: .yandere,
                sourceName: "Yande.re",
                title: nil,
                previewURL: image("demo-03"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-03"),
                originalURL: image("demo-03"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 233,
                favCount: 19,
                tags: BooruTagGroups(
                    artist: [],
                    character: [],
                    copyright: ["original"],
                    general: ["portrait", "forest", "fog"],
                    meta: []
                ),
                allTags: ["original", "portrait", "forest", "fog"],
                sourceLink: URL(string: "https://example.com/post/demo-03"),
                fileExt: "jpg",
                fileSize: 156_700,
                createdAt: "2026-01-03 21:40:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-04",
                sourceID: .rule34,
                sourceName: "Rule34",
                title: nil,
                previewURL: image("demo-04"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-04"),
                originalURL: image("demo-04"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .questionable,
                score: 97,
                favCount: 12,
                tags: BooruTagGroups(
                    artist: ["demo_artist"],
                    character: [],
                    copyright: [],
                    general: ["ocean", "landscape", "sunset"],
                    meta: []
                ),
                allTags: ["demo_artist", "ocean", "landscape", "sunset"],
                sourceLink: URL(string: "https://example.com/post/demo-04"),
                fileExt: "jpg",
                fileSize: 210_004,
                createdAt: "2026-01-03 18:12:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-05",
                sourceID: .realbooru,
                sourceName: "Realbooru",
                title: nil,
                previewURL: image("demo-05"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-05"),
                originalURL: image("demo-05"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .safe,
                score: 64,
                favCount: 5,
                tags: BooruTagGroups(
                    artist: [],
                    character: [],
                    copyright: [],
                    general: ["architecture", "city", "daylight"],
                    meta: []
                ),
                allTags: ["architecture", "city", "daylight"],
                sourceLink: URL(string: "https://example.com/post/demo-05"),
                fileExt: "jpg",
                fileSize: 132_890,
                createdAt: "2026-01-02 11:25:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-06",
                sourceID: .redgifs,
                sourceName: "RedGifs",
                title: "Demo clip",
                previewURL: image("demo-06"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-06"),
                originalURL: image("demo-06"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 341,
                favCount: 27,
                tags: BooruTagGroups(
                    artist: [],
                    character: [],
                    copyright: [],
                    general: ["landscape", "river", "drone"],
                    meta: ["video"]
                ),
                allTags: ["landscape", "river", "drone", "video"],
                sourceLink: URL(string: "https://example.com/post/demo-06"),
                fileExt: "mp4",
                fileSize: 2_408_000,
                createdAt: "2026-01-02 10:05:00",
                niches: ["landscape"],
                isPremium: nil,
                pageCount: nil,
                mediaId: "demo-clip"
            ),
            BooruPost(
                id: "demo-07",
                sourceID: .gelbooru,
                sourceName: "Gelbooru",
                title: nil,
                previewURL: image("demo-07"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-07"),
                originalURL: image("demo-07"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 189,
                favCount: 30,
                tags: BooruTagGroups(
                    artist: ["pixel_studio"],
                    character: [],
                    copyright: [],
                    general: ["mountain", "sky", "landscape"],
                    meta: []
                ),
                allTags: ["pixel_studio", "mountain", "sky", "landscape"],
                sourceLink: URL(string: "https://example.com/post/demo-07"),
                fileExt: "jpg",
                fileSize: 175_000,
                createdAt: "2026-01-01 20:44:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-08",
                sourceID: .danbooru,
                sourceName: "Danbooru",
                title: nil,
                previewURL: image("demo-08"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-08"),
                originalURL: image("demo-08"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .explicit,
                score: 76,
                favCount: 9,
                tags: BooruTagGroups(
                    artist: [],
                    character: ["demo_character"],
                    copyright: [],
                    general: ["portrait", "studio", "lighting"],
                    meta: []
                ),
                allTags: ["demo_character", "portrait", "studio", "lighting"],
                sourceLink: URL(string: "https://example.com/post/demo-08"),
                fileExt: "png",
                fileSize: 288_400,
                createdAt: "2026-01-01 15:30:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-09",
                sourceID: .nhentai,
                sourceName: "nhentai",
                title: "Demo gallery",
                previewURL: image("demo-09"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: [image("demo-09"), image("demo-09-b"), image("demo-09-c")].compactMap { $0 },
                sampleURL: image("demo-09"),
                originalURL: image("demo-09"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 154,
                favCount: 22,
                tags: BooruTagGroups(
                    artist: [],
                    character: [],
                    copyright: ["original"],
                    general: ["gallery", "comic", "city"],
                    meta: ["multi-page"]
                ),
                allTags: ["original", "gallery", "comic", "city", "multi-page"],
                sourceLink: URL(string: "https://example.com/post/demo-09"),
                fileExt: "jpg",
                fileSize: 512_000,
                createdAt: "2025-12-31 22:10:00",
                niches: nil,
                isPremium: nil,
                pageCount: 24,
                mediaId: "123456"
            ),
            BooruPost(
                id: "demo-10",
                sourceID: .yandere,
                sourceName: "Yande.re",
                title: nil,
                previewURL: image("demo-10"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-10"),
                originalURL: image("demo-10"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .safe,
                score: 288,
                favCount: 34,
                tags: BooruTagGroups(
                    artist: ["demo_artist"],
                    character: [],
                    copyright: [],
                    general: ["forest", "path", "landscape"],
                    meta: []
                ),
                allTags: ["demo_artist", "forest", "path", "landscape"],
                sourceLink: URL(string: "https://example.com/post/demo-10"),
                fileExt: "jpg",
                fileSize: 199_000,
                createdAt: "2025-12-30 09:55:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-11",
                sourceID: .gelbooru,
                sourceName: "Gelbooru",
                title: nil,
                previewURL: image("demo-11"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-11"),
                originalURL: image("demo-11"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .general,
                score: 132,
                favCount: 14,
                tags: BooruTagGroups(
                    artist: [],
                    character: [],
                    copyright: ["original"],
                    general: ["skyline", "city", "night", "landscape"],
                    meta: []
                ),
                allTags: ["original", "skyline", "city", "night", "landscape"],
                sourceLink: URL(string: "https://example.com/post/demo-11"),
                fileExt: "jpg",
                fileSize: 143_200,
                createdAt: "2025-12-29 19:20:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
            BooruPost(
                id: "demo-12",
                sourceID: .rule34,
                sourceName: "Rule34",
                title: nil,
                previewURL: image("demo-12"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: image("demo-12"),
                originalURL: image("demo-12"),
                width: 600,
                height: 900,
                aspectRatio: 0.667,
                rating: .questionable,
                score: 58,
                favCount: 6,
                tags: BooruTagGroups(
                    artist: ["pixel_studio"],
                    character: [],
                    copyright: [],
                    general: ["portrait", "window", "light"],
                    meta: []
                ),
                allTags: ["pixel_studio", "portrait", "window", "light"],
                sourceLink: URL(string: "https://example.com/post/demo-12"),
                fileExt: "jpg",
                fileSize: 167_400,
                createdAt: "2025-12-28 13:45:00",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ),
        ]
    }

    /// Posts seeded into the Favorites tab.
    static var favorites: [BooruPost] {
        let all = posts
        return [all[0], all[4], all[8]]
    }

    /// Posts seeded into the recent-views list.
    static var recentViews: [BooruPost] {
        let all = posts
        return [all[1], all[3], all[10]]
    }

    /// Autocomplete suggestions derived from the sample tags.
    static let suggestions: [BooruTagSuggestion] = [
        BooruTagSuggestion(name: "landscape", category: .general, postCount: 7),
        BooruTagSuggestion(name: "city", category: .general, postCount: 4),
        BooruTagSuggestion(name: "portrait", category: .general, postCount: 3),
        BooruTagSuggestion(name: "mountain", category: .general, postCount: 2),
        BooruTagSuggestion(name: "skyline", category: .general, postCount: 2),
        BooruTagSuggestion(name: "sunset", category: .general, postCount: 2),
        BooruTagSuggestion(name: "night", category: .general, postCount: 2),
        BooruTagSuggestion(name: "forest", category: .general, postCount: 2),
        BooruTagSuggestion(name: "architecture", category: .general, postCount: 2),
        BooruTagSuggestion(name: "original", category: .copyright, postCount: 6),
        BooruTagSuggestion(name: "demo_artist", category: .artist, postCount: 4),
        BooruTagSuggestion(name: "demo_character", category: .character, postCount: 1),
    ]

    /// Safe, deterministic placeholder imagery (600x900 portrait).
    private static func image(_ slug: String) -> URL? {
        URL(string: "https://picsum.photos/seed/\(slug)/600/900")
    }
}

// MARK: - Demo source

/// Offline `BooruSource` that serves `DemoData`. No network, no dependencies.
struct DemoBooruSource: BooruSource {
    /// Posts returned per page.
    static let pageSize = 6

    /// Provider handed to the feature view models in `-demoMode`.
    static let provider: @Sendable (SourceID) -> (any BooruSource)? = { DemoBooruSource(id: $0) }

    let id: SourceID

    var displayName: String { "Demo" }
    var supportsVideo: Bool { false }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let all = DemoData.posts
        let start = max(page - 1, 0) * Self.pageSize
        guard start < all.count else {
            return PostPage(posts: [], nextPage: nil, hasMore: false)
        }
        let end = min(start + Self.pageSize, all.count)
        let slice = Array(all[start..<end])
        let hasMore = end < all.count
        return PostPage(posts: slice, nextPage: hasMore ? page + 1 : nil, hasMore: hasMore)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return DemoData.suggestions }
        return DemoData.suggestions.filter { $0.name.lowercased().contains(needle) }
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        ResolvedMedia(
            imageURL: post.originalURL ?? post.sampleURL ?? post.previewURL,
            videoURL: post.previewVideoURL,
            isVideo: false,
            placeholderURL: post.previewURL
        )
    }
}

// MARK: - In-memory stores

/// In-memory favorites for `-demoMode`. Nothing is written to the JSON storage files.
actor DemoFavoritesStore: FavoritesStoring {
    private var posts: [BooruPost]

    init(posts: [BooruPost] = []) {
        self.posts = posts
    }

    func list() async throws -> [BooruPost] {
        posts
    }

    func add(_ post: BooruPost) async throws {
        let key = postKey(post)
        guard !posts.contains(where: { postKey($0) == key }) else { return }
        posts.insert(post, at: 0)
    }

    func remove(id: String, sourceID: SourceID) async throws {
        posts.removeAll { $0.id == id && $0.sourceID == sourceID }
    }

    func contains(_ post: BooruPost) async throws -> Bool {
        let key = postKey(post)
        return posts.contains { postKey($0) == key }
    }
}

/// In-memory favorite or blacklisted tags for `-demoMode`.
actor DemoTagListStore: TagListStoring {
    private var tags: [String]

    init(tags: [String] = []) {
        self.tags = tags
    }

    func list() async throws -> [String] {
        tags
    }

    func add(_ tag: String) async throws {
        let normalized = normalize(tag)
        guard !normalized.isEmpty, !tags.contains(normalized) else { return }
        tags.insert(normalized, at: 0)
    }

    func remove(_ tag: String) async throws {
        let normalized = normalize(tag)
        tags.removeAll { $0 == normalized }
    }

    private func normalize(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
            .lowercased()
    }
}

/// In-memory search history for `-demoMode`.
actor DemoSearchHistoryStore: SearchHistoryStoring {
    private var queries: [String]

    init(queries: [String] = []) {
        self.queries = queries
    }

    func list() async throws -> [String] {
        queries
    }

    func record(_ query: String) async throws {
        let normalized = query.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !normalized.isEmpty else { return }
        queries.removeAll { $0.lowercased() == normalized }
        queries.insert(normalized, at: 0)
        let overflow = queries.count - PersistenceLimits.searchHistoryRuntime
        if overflow > 0 {
            queries.removeLast(overflow)
        }
    }

    /// Demo-only: the persistence protocol has no clear API, so the app layer calls this directly.
    func clear() async {
        queries = []
    }
}

/// In-memory recent views for `-demoMode`.
actor DemoRecentViewsStore: RecentViewsStoring {
    private var posts: [BooruPost]

    init(posts: [BooruPost] = []) {
        self.posts = posts
    }

    func list() async throws -> [BooruPost] {
        posts
    }

    func record(_ post: BooruPost) async throws {
        guard !post.id.isEmpty else { return }
        if posts.first == post { return }
        let key = postKey(post)
        posts.removeAll { postKey($0) == key }
        posts.insert(post, at: 0)
        let overflow = posts.count - PersistenceLimits.recentViews
        if overflow > 0 {
            posts.removeLast(overflow)
        }
    }

    /// Demo-only: the persistence protocol has no clear API, so the app layer calls this directly.
    func clear() async {
        posts = []
    }
}

/// In-memory settings for `-demoMode`; `AppLockController` and Settings share it.
actor DemoSettingsStore: SettingsStoring {
    private var settings: AppSettings

    init(settings: AppSettings = DemoData.settings) {
        self.settings = settings
    }

    func load() async throws -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) async throws {
        self.settings = settings
    }
}
