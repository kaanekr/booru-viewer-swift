import XCTest
@testable import BooruViewer

/// Security and backup tests.
///
/// No Keychain item and no biometric hardware are touched: the PIN hash store, the biometric
/// authenticator, and the settings store are all injected doubles. Backup stores write only to
/// a throwaway temporary directory.
final class SecurityBackupTests: XCTestCase {

    // MARK: - Doubles

    private final class InMemoryPasscodeStore: PasscodeHashStoring, @unchecked Sendable {
        var hash: String?

        init(hash: String? = nil) {
            self.hash = hash
        }

        func load() throws -> String? { hash }

        func save(_ hash: String) throws { self.hash = hash }

        func delete() throws { hash = nil }
    }

    private struct StubBiometrics: BiometricAuthenticating {
        var canEvaluate = true
        var result = true

        func canEvaluateBiometrics() -> Bool { canEvaluate }

        func authenticate(prompt: String) async -> Bool { result }
    }

    private actor StubSettingsStore: SettingsStoring {
        private var settings: AppSettings

        init(_ settings: AppSettings) {
            self.settings = settings
        }

        func load() async throws -> AppSettings { settings }

        func save(_ settings: AppSettings) async throws { self.settings = settings }
    }

    // MARK: - Fixtures

    private func makeSettings(
        enabled: Bool,
        useBiometrics: Bool = true,
        autoLockImmediately: Bool = true
    ) -> AppSettings {
        var settings = AppSettings()
        settings.security = SecurityConfig(
            enabled: enabled,
            passcodeHash: nil,
            useBiometrics: useBiometrics,
            autoLockImmediately: autoLockImmediately
        )
        return settings
    }

    private func makeSecurityService(
        store: InMemoryPasscodeStore,
        biometrics: StubBiometrics = StubBiometrics()
    ) -> SecurityService {
        SecurityService(store: store, biometrics: biometrics)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BooruViewerSecurityBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct BackupStores {
        let favorites: FavoritesStore
        let favoriteTags: TagListStore
        let blacklistedTags: TagListStore
        let searchHistory: SearchHistoryStore
        let recentViews: RecentViewsStore
    }

    private func makeStores(directory: URL) -> BackupStores {
        BackupStores(
            favorites: FavoritesStore(directory: directory),
            favoriteTags: TagListStore(directory: directory, kind: .favorite),
            blacklistedTags: TagListStore(directory: directory, kind: .blacklisted),
            searchHistory: SearchHistoryStore(directory: directory),
            recentViews: RecentViewsStore(directory: directory)
        )
    }

    private func makeBackupService(
        _ stores: BackupStores,
        now: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> BackupService {
        BackupService(
            favorites: stores.favorites,
            favoriteTags: stores.favoriteTags,
            blacklistedTags: stores.blacklistedTags,
            searchHistory: stores.searchHistory,
            recentViews: stores.recentViews,
            now: { now }
        )
    }

    private func makePost(
        id: String,
        sourceID: SourceID = .gelbooru,
        sourceName: String = "Gelbooru",
        originalURL: String? = nil,
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: sourceName,
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
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    /// One native `BooruPost` JSON object.
    private func postJSON(
        id: String,
        sourceID: String = "gelbooru",
        sourceName: String = "Gelbooru",
        originalURL: String? = nil,
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "sourceId": sourceID,
            "sourceName": sourceName,
            "width": 10,
            "height": 10,
            "aspectRatio": 1.0,
            "rating": "s",
            "score": 0,
            "favCount": 0,
            "tags": [
                "artist": [String](),
                "character": [String](),
                "copyright": [String](),
                "general": [String](),
                "meta": [String](),
            ] as [String: Any],
            "allTags": [String](),
            "createdAt": createdAt,
        ]
        if let originalURL {
            json["originalUrl"] = originalURL
        }
        return json
    }

    private func nativeBackupJSON(
        favorites: [[String: Any]],
        favoriteTags: [String] = [],
        blacklistedTags: [String] = [],
        searchHistory: [Any] = [],
        recentViews: [[String: Any]] = []
    ) throws -> Data {
        let document: [String: Any] = [
            "creatorName": "BooruViewer",
            "backupVersion": "1.0",
            "exportDate": "2026-01-01T00:00:00.000Z",
            "favoritesCount": favorites.count,
            "favorites": favorites,
            "favoriteTags": favoriteTags,
            "searchHistory": searchHistory,
            "blacklistedTags": blacklistedTags,
            "recentViews": recentViews,
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }

    // MARK: - PIN hashing and verification

    /// `booru_salt_1234` hashed the way `securityService.ts:28-32` does. The expected value is
    /// `sha256("booru_salt_1234")`.
    func testPasscodeHashMatchesRNParity() {
        XCTAssertEqual(
            SecurityService.hashPasscode("1234"),
            "e536a21787ab9de41eaf11b9b1860aa3d81442867b24b5128fdff0c679520373"
        )
        XCTAssertEqual(SecurityService.hashPasscode("1234").count, 64)
        XCTAssertEqual(SecurityService.hashPasscode("1234"), SecurityService.hashPasscode("1234"))
        XCTAssertNotEqual(SecurityService.hashPasscode("1234"), SecurityService.hashPasscode("4321"))
    }

    func testSetAndVerifyPasscodeRejectsWrongOrInvalidPIN() throws {
        let store = InMemoryPasscodeStore()
        let service = makeSecurityService(store: store)

        var config = SecurityConfig()
        config.enabled = true

        let hash = try service.setPasscode("1234")
        XCTAssertEqual(hash, store.hash)
        XCTAssertEqual(hash, SecurityService.hashPasscode("1234"))
        XCTAssertTrue(try service.isPasscodeEnabled(config: config))
        XCTAssertTrue(try service.verifyPasscode("1234", config: config))
        XCTAssertFalse(try service.verifyPasscode("4321", config: config))

        XCTAssertThrowsError(try service.setPasscode("12a4")) { error in
            XCTAssertEqual(error as? SecurityError, .invalidPIN)
        }
        XCTAssertThrowsError(try service.setPasscode("12345")) { error in
            XCTAssertEqual(error as? SecurityError, .invalidPIN)
        }

        try service.clearPasscode()
        XCTAssertNil(store.hash)
        XCTAssertFalse(try service.isPasscodeEnabled(config: config))
    }

    func testDisabledLockVerifiesWithoutStoredHash() throws {
        let service = makeSecurityService(store: InMemoryPasscodeStore())
        XCTAssertFalse(try service.isPasscodeEnabled(config: SecurityConfig()))
        XCTAssertTrue(try service.verifyPasscode("0000", config: SecurityConfig()))
    }

    /// A config migrated from RN only has `SecurityConfig.passcodeHash`.
    func testConfigHashFallbackWhenKeychainIsEmpty() throws {
        let service = makeSecurityService(store: InMemoryPasscodeStore())
        var config = SecurityConfig()
        config.enabled = true
        config.passcodeHash = SecurityService.hashPasscode("1234")

        XCTAssertTrue(try service.isPasscodeEnabled(config: config))
        XCTAssertTrue(try service.verifyPasscode("1234", config: config))
        XCTAssertFalse(try service.verifyPasscode("4321", config: config))
    }

    func testKeychainHashTakesPrecedenceOverConfigPlaceholder() throws {
        let store = InMemoryPasscodeStore()
        try store.save(SecurityService.hashPasscode("9999"))
        let service = makeSecurityService(store: store)

        var config = SecurityConfig()
        config.enabled = true
        config.passcodeHash = SecurityService.hashPasscode("1234")

        XCTAssertTrue(try service.verifyPasscode("9999", config: config))
        XCTAssertFalse(try service.verifyPasscode("1234", config: config))
    }

    func testBiometricWrapperReportsAvailabilityAndPromptResult() async {
        let available = makeSecurityService(
            store: InMemoryPasscodeStore(),
            biometrics: StubBiometrics(canEvaluate: true, result: true)
        )
        let unlocked = await available.authenticateWithBiometrics()
        XCTAssertTrue(unlocked)
        XCTAssertTrue(available.canUseBiometrics())

        let unavailable = makeSecurityService(
            store: InMemoryPasscodeStore(),
            biometrics: StubBiometrics(canEvaluate: false, result: true)
        )
        let denied = await unavailable.authenticateWithBiometrics()
        XCTAssertFalse(denied)

        let cancelled = makeSecurityService(
            store: InMemoryPasscodeStore(),
            biometrics: StubBiometrics(canEvaluate: true, result: false)
        )
        let failed = await cancelled.authenticateWithBiometrics()
        XCTAssertFalse(failed)
    }

    // MARK: - App lock state

    @MainActor
    func testColdStartLocksWhenPasscodeEnabled() async throws {
        let store = InMemoryPasscodeStore()
        try store.save(SecurityService.hashPasscode("1234"))
        let controller = AppLockController(
            service: makeSecurityService(store: store),
            settings: StubSettingsStore(makeSettings(enabled: true))
        )

        XCTAssertFalse(controller.isLocked)
        await controller.prepareForLaunch()
        XCTAssertTrue(controller.isLocked)
        XCTAssertFalse(controller.isPrivacyCurtainVisible)
    }

    @MainActor
    func testColdStartStaysUnlockedWhenNoPasscode() async throws {
        let controller = AppLockController(
            service: makeSecurityService(store: InMemoryPasscodeStore()),
            settings: StubSettingsStore(makeSettings(enabled: false))
        )
        await controller.prepareForLaunch()
        XCTAssertFalse(controller.isLocked)

        await controller.handleScenePhase(.background)
        XCTAssertFalse(controller.isLocked)
    }

    @MainActor
    func testScenePhaseTransitionsFollowAppStateRules() async throws {
        let store = InMemoryPasscodeStore()
        try store.save(SecurityService.hashPasscode("1234"))

        // `inactive` covers the content but never mounts the PIN pad (App.tsx:176-178).
        let controller = AppLockController(
            service: makeSecurityService(store: store),
            settings: StubSettingsStore(makeSettings(enabled: true))
        )
        await controller.handleScenePhase(.inactive)
        XCTAssertTrue(controller.isPrivacyCurtainVisible)
        XCTAssertFalse(controller.isLocked)

        await controller.handleScenePhase(.active)
        XCTAssertFalse(controller.isPrivacyCurtainVisible)
        XCTAssertFalse(controller.isLocked)

        // `background` locks when a passcode is enabled (App.tsx:179-190).
        await controller.handleScenePhase(.background)
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(controller.isPrivacyCurtainVisible)
        XCTAssertFalse(controller.isCheckingBackgroundLock)

        // `autoLockImmediately == false` still locks on `background`: RN's AppState handler only
        // checks whether a passcode is enabled, never the auto-lock flag.
        let delayed = AppLockController(
            service: makeSecurityService(store: store),
            settings: StubSettingsStore(makeSettings(enabled: true, autoLockImmediately: false))
        )
        await delayed.handleScenePhase(.background)
        XCTAssertTrue(delayed.isLocked)
        XCTAssertTrue(delayed.isPrivacyCurtainVisible)
        XCTAssertFalse(delayed.isCheckingBackgroundLock)
    }

    @MainActor
    func testPINUnlockOnlySucceedsWithMatchingPasscode() async throws {
        let store = InMemoryPasscodeStore()
        try store.save(SecurityService.hashPasscode("1234"))
        let controller = AppLockController(
            service: makeSecurityService(store: store),
            settings: StubSettingsStore(makeSettings(enabled: true))
        )
        await controller.prepareForLaunch()
        XCTAssertTrue(controller.isLocked)

        let wrong = await controller.unlock(withPIN: "0000")
        XCTAssertFalse(wrong)
        XCTAssertTrue(controller.isLocked)

        let right = await controller.unlock(withPIN: "1234")
        XCTAssertTrue(right)
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(controller.isPrivacyCurtainVisible)
    }

    @MainActor
    func testBiometricUnlockRespectsSettingsAndPromptResult() async throws {
        let store = InMemoryPasscodeStore()
        try store.save(SecurityService.hashPasscode("1234"))

        let unlocked = AppLockController(
            service: makeSecurityService(store: store, biometrics: StubBiometrics(canEvaluate: true, result: true)),
            settings: StubSettingsStore(makeSettings(enabled: true))
        )
        await unlocked.prepareForLaunch()
        let succeeded = await unlocked.unlockWithBiometrics()
        XCTAssertTrue(succeeded)
        XCTAssertFalse(unlocked.isLocked)

        let failing = AppLockController(
            service: makeSecurityService(store: store, biometrics: StubBiometrics(canEvaluate: true, result: false)),
            settings: StubSettingsStore(makeSettings(enabled: true))
        )
        await failing.prepareForLaunch()
        let rejected = await failing.unlockWithBiometrics()
        XCTAssertFalse(rejected)
        XCTAssertTrue(failing.isLocked)

        // `useBiometrics == false`: the PIN pad stays authoritative.
        let noBiometrics = AppLockController(
            service: makeSecurityService(store: store, biometrics: StubBiometrics(canEvaluate: true, result: true)),
            settings: StubSettingsStore(makeSettings(enabled: true, useBiometrics: false))
        )
        await noBiometrics.prepareForLaunch()
        let skipped = await noBiometrics.unlockWithBiometrics()
        XCTAssertFalse(skipped)
        XCTAssertTrue(noBiometrics.isLocked)
    }

    // MARK: - Export

    func testExportDerivesFavoritesCountAndRNMetadata() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)

        try await stores.favorites.add(makePost(id: "1"))
        try await stores.favoriteTags.add("cats")
        try await stores.blacklistedTags.add("gross tag")
        try await stores.searchHistory.record("cat girl")

        let service = makeBackupService(stores)
        let schema = try await service.exportBackup()

        XCTAssertEqual(schema.creatorName, "BooruViewer")
        XCTAssertEqual(schema.backupVersion, "1.0")
        XCTAssertEqual(schema.exportDate, "2025-10-09T08:53:20.000Z")
        XCTAssertEqual(schema.favoritesCount, 1)
        XCTAssertEqual(schema.favorites.map(\.id), ["1"])
        XCTAssertEqual(schema.favoriteTags, ["cats"])
        XCTAssertEqual(schema.blacklistedTags, ["gross_tag"])
        XCTAssertEqual(schema.searchHistory, ["cat girl"])

        // The encoded document round-trips with a count that always matches the array.
        let data = try await service.exportJSONData()
        let decoded = try JSONDecoder().decode(BackupSchema.self, from: data)
        XCTAssertEqual(decoded.favoritesCount, decoded.favorites.count)
        XCTAssertEqual(decoded.creatorName, "BooruViewer")
    }

    // MARK: - Native import

    func testNativeImportMergesAndDedupesByPostKeyAndMediaKey() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        let existing = makePost(id: "1", originalURL: "https://img4.gelbooru.com/images/1.jpg")
        try await stores.favorites.add(existing)

        let duplicateByKey = postJSON(id: "1", originalURL: "https://img4.gelbooru.com/images/1.jpg")
        let duplicateByMedia = postJSON(id: "2", originalURL: "https://img4.gelbooru.com/images/1.jpg")
        let newPost = postJSON(id: "3", originalURL: "https://img4.gelbooru.com/images/3.jpg")

        let data = try nativeBackupJSON(
            favorites: [duplicateByKey, duplicateByMedia, newPost]
        )
        let summary = try await service.importBackup(data: data)

        XCTAssertEqual(summary.addedFavorites, 1)
        XCTAssertEqual(summary.skippedCount, 2)
        XCTAssertEqual(summary.totalFavorites, 2)

        let favorites = try await stores.favorites.list()
        XCTAssertEqual(favorites.map(\.id), ["3", "1"])
        XCTAssertEqual(favorites.last?.originalURL?.absoluteString, "https://img4.gelbooru.com/images/1.jpg")
    }

    func testNativeImportUnionsTagsAndSearchHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        try await stores.favoriteTags.add("cats")
        try await stores.searchHistory.record("old query")

        let data = try nativeBackupJSON(
            favorites: [],
            favoriteTags: ["Cats", "big  boobs"],
            blacklistedTags: ["Gross Tag"],
            searchHistory: ["New Query", "old query"]
        )
        let summary = try await service.importBackup(data: data)

        // RN quirk kept for parity (backupService.ts:249-252): plain-string history entries also
        // become favorite tags, so "new query" and "old query" are imported on top of the two
        // explicit favorite tags. Only "cats" was already present.
        XCTAssertEqual(summary.addedTags, 3)
        XCTAssertEqual(summary.addedBlacklistedTags, 1)
        XCTAssertEqual(summary.addedHistory, 1)

        let favoriteTags = try await stores.favoriteTags.list()
        XCTAssertEqual(favoriteTags, ["big boobs", "old query", "new query", "cats"])
        let blacklisted = try await stores.blacklistedTags.list()
        XCTAssertEqual(blacklisted, ["gross_tag"])
        let history = try await stores.searchHistory.list()
        XCTAssertEqual(history, ["new query", "old query"])
    }

    // MARK: - AnimeBoxes import

    func testAnimeBoxesImportMapsLegacyFavoritesAndTags() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        let favorite: [String: Any] = [
            "ppostId": 12345,
            "ppostUrl": "https://rule34.xxx/index.php?page=post&s=view&id=12345",
            "preview": [
                "url": "http://img.rule34.xxx/thumb/12345.jpg",
                "width": 200,
                "height": 300,
            ] as [String: Any],
            "sample": ["url": "http://img.rule34.xxx/samples/12345.jpg"] as [String: Any],
            "file": [
                "url": "http://img.rule34.xxx/images/12345.jpeg",
                "ext": "jpeg",
                "width": 1000,
                "height": 1500,
            ] as [String: Any],
            "tags": "big_breasts Solo 1girl",
            "rating": "explicit",
            "score": 42,
            "dateAdded": "2020-01-02T03:04:05.000Z",
        ]
        let searchHistory: [Any] = [
            ["searchText": "Cat Girl", "starred": true] as [String: Any],
            ["searchText": "Dark Skin"] as [String: Any],
            "Solo",
        ]
        let bannedTags: [Any] = ["gore", ["name": "Scat"] as [String: Any]]

        let document: [String: Any] = [
            "favorites": [favorite],
            "searchHistory": searchHistory,
            "bannedTags": bannedTags,
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let summary = try await service.importBackup(data: data)

        XCTAssertEqual(summary.addedFavorites, 1)
        XCTAssertEqual(summary.skippedCount, 0)
        XCTAssertEqual(summary.addedTags, 2)
        XCTAssertEqual(summary.addedBlacklistedTags, 2)

        let favorites = try await stores.favorites.list()
        let post = try XCTUnwrap(favorites.first)
        XCTAssertEqual(post.id, "rule34_12345")
        XCTAssertEqual(post.sourceID, .rule34)
        XCTAssertEqual(post.sourceName, "Rule34.xxx")
        XCTAssertEqual(post.rating, .explicit)
        XCTAssertEqual(post.score, 42)
        XCTAssertEqual(post.width, 1000)
        XCTAssertEqual(post.height, 1500)
        XCTAssertEqual(post.aspectRatio, 1000.0 / 1500.0, accuracy: 0.0001)
        XCTAssertEqual(post.createdAt, "2020-01-02T03:04:05.000Z")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://img.rule34.xxx/images/12345.jpeg")
        XCTAssertEqual(post.tags.general, ["big_breasts", "solo", "1girl"])
        XCTAssertEqual(post.allTags, ["big_breasts", "solo", "1girl"])
        XCTAssertEqual(post.fileExt, "jpeg")
        XCTAssertNil(post.title)

        let favoriteTags = try await stores.favoriteTags.list()
        XCTAssertEqual(Set(favoriteTags), Set(["cat girl", "solo"]))
        let blacklisted = try await stores.blacklistedTags.list()
        XCTAssertEqual(Set(blacklisted), Set(["gore", "scat"]))
        let history = try await stores.searchHistory.list()
        XCTAssertEqual(history, ["cat girl", "dark skin", "solo"])
    }

    func testAnimeBoxesRecentViewsMergeNewestFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        try await stores.recentViews.record(makePost(id: "old", createdAt: "2019-01-01T00:00:00Z"))

        let document: [String: Any] = [
            "favorites": [Any](),
            "recentViews": [
                postJSON(
                    id: "newer",
                    originalURL: "https://img4.gelbooru.com/images/newer.jpg",
                    createdAt: "2024-01-01T00:00:00Z"
                ),
                postJSON(
                    id: "older",
                    originalURL: "https://img4.gelbooru.com/images/older.jpg",
                    createdAt: "2020-01-01T00:00:00Z"
                ),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let summary = try await service.importBackup(data: data)

        XCTAssertEqual(summary.addedRecentViews, 2)
        XCTAssertEqual(summary.addedFavorites, 0)

        // Existing views stay first; imported ones follow newest-first (RN mergeRecentViews).
        let views = try await stores.recentViews.list()
        XCTAssertEqual(views.map(\.id), ["old", "newer", "older"])
    }

    // MARK: - Import caps

    /// Import keeps the 100-entry import cap (`backupService.ts:327`), not the store's 30-entry
    /// runtime cap (`storage.ts:208`): 45 imported entries merge on top of 10 existing ones.
    func testSearchHistoryImportKeepsImportedAndExistingEntries() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        let existing = (0..<10).map { "existing \($0)" }
        for query in existing.reversed() {
            try await stores.searchHistory.record(query)
        }

        let imported = (0..<45).map { "imported \($0)" }
        let data = try nativeBackupJSON(favorites: [], searchHistory: imported)
        let summary = try await service.importBackup(data: data)

        XCTAssertEqual(summary.addedHistory, 45)
        let history = try await stores.searchHistory.list()
        XCTAssertEqual(history.count, 55)
        XCTAssertEqual(Array(history.prefix(45)), imported)
        XCTAssertEqual(Set(history), Set(imported + existing))
    }

    /// Importing more than 500 recent views keeps the newest 500 (`PersistenceLimits.recentViews`).
    func testRecentViewsImportCapsAt500() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = makeStores(directory: directory)
        let service = makeBackupService(stores)

        let imported = (0..<520).map { index in
            postJSON(
                id: "post-\(index)",
                originalURL: "https://img4.gelbooru.com/images/\(index).jpg"
            )
        }
        let document: [String: Any] = [
            "favorites": [Any](),
            "recentViews": imported,
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let summary = try await service.importBackup(data: data)

        XCTAssertEqual(summary.addedRecentViews, 500)
        let views = try await stores.recentViews.list()
        XCTAssertEqual(views.count, 500)
        XCTAssertEqual(Set(views.map(\.id)), Set((0..<500).map { "post-\($0)" }))
    }
}
