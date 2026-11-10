import XCTest
@testable import BooruViewer

/// Storage tests. Every store writes to a throwaway temporary directory; the real Application
/// Support container and the Keychain are never touched.
final class StorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BooruViewerStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private func makePost(id: String, sourceID: SourceID = .gelbooru, originalURL: String? = nil) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: "Example",
            title: nil,
            previewURL: nil,
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: nil,
            originalURL: originalURL.flatMap { URL(string: $0) },
            width: 10,
            height: 10,
            aspectRatio: 1.0,
            rating: .general,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(),
            allTags: [],
            sourceLink: nil,
            fileExt: nil,
            fileSize: nil,
            createdAt: "2026-01-01T00:00:00Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: - Favorites

    func testFavoritesAddDedupesByPostKeyAndPrepends() async throws {
        let store = FavoritesStore(directory: directory)
        try await store.add(makePost(id: "1"))
        try await store.add(makePost(id: "2"))
        try await store.add(makePost(id: "1"))

        let posts = try await store.list()
        XCTAssertEqual(posts.map(\.id), ["2", "1"])
    }

    func testFavoritesTreatSameIDOnDifferentSourcesAsDistinct() async throws {
        let store = FavoritesStore(directory: directory)
        try await store.add(makePost(id: "1"))
        try await store.add(makePost(id: "1", sourceID: .danbooru))

        let posts = try await store.list()
        XCTAssertEqual(posts.count, 2)
    }

    func testFavoritesContainsUsesSourceQualifiedKey() async throws {
        let store = FavoritesStore(directory: directory)
        try await store.add(makePost(id: "gelbooru_55"))

        let containsPlain = try await store.contains(makePost(id: "55"))
        let containsOtherSource = try await store.contains(makePost(id: "55", sourceID: .danbooru))
        XCTAssertTrue(containsPlain)
        XCTAssertFalse(containsOtherSource)
    }

    func testFavoritesRemoveUsesSourceQualifiedKey() async throws {
        let store = FavoritesStore(directory: directory)
        try await store.add(makePost(id: "gelbooru_123"))
        try await store.add(makePost(id: "123", sourceID: .danbooru))

        try await store.remove(id: "123", sourceID: .gelbooru)

        let posts = try await store.list()
        XCTAssertEqual(posts.map(\.sourceID), [.danbooru])
    }

    func testFavoritesPersistAcrossStoreInstances() async throws {
        try await FavoritesStore(directory: directory).add(makePost(id: "7"))

        let posts = try await FavoritesStore(directory: directory).list()
        XCTAssertEqual(posts.map(\.id), ["7"])
    }

    func testConcurrentAddsAreSerialized() async throws {
        let store = FavoritesStore(directory: directory)
        let posts = (0..<40).map { makePost(id: "\($0)") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for post in posts {
                group.addTask { try await store.add(post) }
            }
            try await group.waitForAll()
        }

        let stored = try await store.list()
        XCTAssertEqual(stored.count, posts.count)
    }

    // MARK: - Tags

    func testFavoriteTagsNormalizeDedupeAndPrepend() async throws {
        let store = TagListStore(directory: directory, kind: .favorite)
        try await store.add("  Example_Tag ")
        try await store.add("second   tag")
        try await store.add("example_tag")

        let tags = try await store.list()
        XCTAssertEqual(tags, ["second tag", "example_tag"])
    }

    func testBlacklistedTagsUseUnderscoreSeparator() async throws {
        let store = TagListStore(directory: directory, kind: .blacklisted)
        try await store.add(" Bad Tag ")

        let tags = try await store.list()
        XCTAssertEqual(tags, ["bad_tag"])
    }

    func testTagListRemoveNormalizesInput() async throws {
        let store = TagListStore(directory: directory, kind: .favorite)
        try await store.add("alpha")
        try await store.add("beta")

        try await store.remove("ALPHA")

        let tags = try await store.list()
        XCTAssertEqual(tags, ["beta"])
    }

    func testFavoriteAndBlacklistedTagsAreSeparateDocuments() async throws {
        let favorites = TagListStore(directory: directory, kind: .favorite)
        let blacklisted = TagListStore(directory: directory, kind: .blacklisted)
        try await favorites.add("one_tag")
        try await blacklisted.add("another_tag")

        let favoriteTags = try await favorites.list()
        let blacklistedTags = try await blacklisted.list()
        XCTAssertEqual(favoriteTags, ["one_tag"])
        XCTAssertEqual(blacklistedTags, ["another_tag"])
    }

    // MARK: - Search history

    func testSearchHistoryNormalizesAndDedupes() async throws {
        let store = SearchHistoryStore(directory: directory)
        try await store.record("Alpha")
        try await store.record("beta")
        try await store.record("  ALPHA  ")

        let history = try await store.list()
        XCTAssertEqual(history, ["alpha", "beta"])
    }

    func testSearchHistoryIgnoresBlankQueries() async throws {
        let store = SearchHistoryStore(directory: directory)
        try await store.record("   ")
        try await store.record("")

        let history = try await store.list()
        XCTAssertTrue(history.isEmpty)
    }

    func testSearchHistoryCapsAtThirtyNewestFirst() async throws {
        let store = SearchHistoryStore(directory: directory)
        for index in 0..<35 {
            try await store.record("term \(index)")
        }

        let history = try await store.list()
        XCTAssertEqual(history.count, PersistenceLimits.searchHistoryRuntime)
        XCTAssertEqual(history.first, "term 34")
        XCTAssertEqual(history.last, "term 5")
        XCTAssertFalse(history.contains("term 4"))
    }

    // MARK: - Recent views

    func testRecentViewsPrependAndDedupe() async throws {
        let store = RecentViewsStore(directory: directory)
        try await store.record(makePost(id: "a"))
        try await store.record(makePost(id: "b"))
        try await store.record(makePost(id: "c"))

        let recent = try await store.list()
        XCTAssertEqual(recent.map(\.id), ["c", "b", "a"])
    }

    func testRecentViewsIgnoreEmptyID() async throws {
        let store = RecentViewsStore(directory: directory)
        try await store.record(makePost(id: ""))

        let recent = try await store.list()
        XCTAssertTrue(recent.isEmpty)
    }

    func testRecentViewsReRecordingAnExistingPostMovesItToFront() async throws {
        let store = RecentViewsStore(directory: directory)
        let first = makePost(id: "a")
        try await store.record(first)
        try await store.record(makePost(id: "b"))
        try await store.record(makePost(id: "a"))

        let recent = try await store.list()
        XCTAssertEqual(recent.map(\.id), ["a", "b"])
    }

    func testRecentViewsMoveExistingPostToFrontWithNewMetadata() async throws {
        let store = RecentViewsStore(directory: directory)
        try await store.record(makePost(id: "a", originalURL: "https://example.com/old.jpg"))
        try await store.record(makePost(id: "b"))
        try await store.record(makePost(id: "a", originalURL: "https://example.com/new.jpg"))

        let recent = try await store.list()
        XCTAssertEqual(recent.map(\.id), ["a", "b"])
        XCTAssertEqual(recent.first?.originalURL, URL(string: "https://example.com/new.jpg"))
    }

    func testRecentViewsCapAtFiveHundred() async throws {
        let store = RecentViewsStore(directory: directory)
        for index in 0..<520 {
            try await store.record(makePost(id: "\(index)"))
        }

        let recent = try await store.list()
        XCTAssertEqual(recent.count, PersistenceLimits.recentViews)
        XCTAssertEqual(recent.first?.id, "519")
        XCTAssertEqual(recent.last?.id, "20")
        XCTAssertFalse(recent.contains { $0.id == "19" })
    }

    // MARK: - Settings

    func testSettingsLoadDefaultsWhenNoDocumentExists() async throws {
        let settings = try await SettingsStore(directory: directory).load()

        XCTAssertEqual(settings.imageQuality, .auto)
        XCTAssertTrue(settings.gridPreviews)
        XCTAssertEqual(settings.activeSourceID, .gelbooru)
        XCTAssertNil(settings.feedOrder)
        XCTAssertTrue(settings.hentaiHavenLastEpisodes.isEmpty)
        XCTAssertFalse(settings.proxy.enabled)
        XCTAssertEqual(settings.proxy.workerURL, "")
    }

    func testSettingsRoundTrip() async throws {
        var settings = AppSettings()
        settings.imageQuality = .full
        settings.gridPreviews = false
        settings.activeSourceID = .rule34
        settings.feedOrder = FeedOrder(sortBy: .score, timeRange: .oneMonth, hentaiHavenSection: .episodes)
        settings.hentaiHavenLastEpisodes = ["series": 7]
        settings.proxy = ProxyConfig(enabled: true, workerURL: "https://example.workers.dev")
        settings.security = SecurityConfig(
            enabled: true,
            passcodeHash: nil,
            useBiometrics: false,
            autoLockImmediately: true
        )

        try await SettingsStore(directory: directory).save(settings)

        let loaded = try await SettingsStore(directory: directory).load()
        XCTAssertEqual(loaded.imageQuality, .full)
        XCTAssertFalse(loaded.gridPreviews)
        XCTAssertEqual(loaded.activeSourceID, .rule34)
        XCTAssertEqual(loaded.feedOrder?.sortBy, .score)
        XCTAssertEqual(loaded.feedOrder?.timeRange, .oneMonth)
        XCTAssertEqual(loaded.feedOrder?.hentaiHavenSection, .episodes)
        XCTAssertEqual(loaded.hentaiHavenLastEpisodes, ["series": 7])
        XCTAssertTrue(loaded.proxy.enabled)
        XCTAssertEqual(loaded.proxy.workerURL, "https://example.workers.dev")
        XCTAssertTrue(loaded.security.enabled)
        XCTAssertNil(loaded.security.passcodeHash)
        XCTAssertFalse(loaded.security.useBiometrics)
        XCTAssertTrue(loaded.security.autoLockImmediately)
    }

    // MARK: - File store behaviour

    func testCorruptDocumentIsPreservedAndAddFails() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("favorites.json")
        try Data("{not json".utf8).write(to: url)

        let store = FavoritesStore(directory: directory)
        let listed = try await store.list()
        XCTAssertTrue(listed.isEmpty)

        do {
            try await store.add(makePost(id: "1"))
            XCTFail("add must throw instead of overwriting corrupt data")
        } catch {
            // Expected: corrupt data is kept for the user to inspect.
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{not json")
    }

    func testWriteLeavesOnlyTheDocumentAndNoTemporaryFiles() async throws {
        let store = FavoritesStore(directory: directory)
        try await store.add(makePost(id: "1"))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["favorites.json"])
    }
}
