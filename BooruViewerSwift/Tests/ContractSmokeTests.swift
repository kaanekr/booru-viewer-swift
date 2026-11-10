import XCTest
@testable import BooruViewer

final class ContractSmokeTests: XCTestCase {
    func testBooruPostRoundTripsThroughJSON() throws {
        let original = BooruPost(
            id: "123",
            sourceID: .gelbooru,
            sourceName: "Gelbooru",
            title: nil,
            previewURL: URL(string: "https://example.com/preview.jpg"),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: URL(string: "https://example.com/sample.jpg"),
            originalURL: URL(string: "https://example.com/original.jpg"),
            width: 1536,
            height: 1024,
            aspectRatio: 1.5,
            rating: .general,
            score: 10,
            favCount: 3,
            tags: BooruTagGroups(artist: ["example_artist"], character: [], copyright: [], general: ["example_tag"], meta: []),
            allTags: ["example_tag", "example_artist"],
            sourceLink: nil,
            fileExt: "jpg",
            fileSize: 2048,
            createdAt: "2026-01-01T00:00:00Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BooruPost.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Post identity (expected strings derived from src/utils/postIdentity.ts:7-15)

    private func makePost(id: String, sourceID: SourceID) -> BooruPost {
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
            originalURL: nil,
            width: 1,
            height: 1,
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

    func testPostKeyStripsNumericPrefixForGelbooru() {
        // "gelbooru_123" -> id "123" -> JSON.stringify(["gelbooru", "123"])
        XCTAssertEqual(postKey(makePost(id: "gelbooru_123", sourceID: .gelbooru)), "[\"gelbooru\",\"123\"]")
        XCTAssertEqual(postKey(makePost(id: "123", sourceID: .gelbooru)), "[\"gelbooru\",\"123\"]")
    }

    func testPostKeyLeavesNonNumericIDsUntouched() {
        // nhentai is not in NUMERIC_BOORUS, so its prefix stays.
        XCTAssertEqual(postKey(makePost(id: "nhentai_123", sourceID: .nhentai)), "[\"nhentai\",\"nhentai_123\"]")
        // The gelbooru suffix is not numeric, so the regex fails and the id stays.
        XCTAssertEqual(postKey(makePost(id: "gelbooru_abc", sourceID: .gelbooru)), "[\"gelbooru\",\"gelbooru_abc\"]")
    }

    // MARK: - Source IDs

    func testSourceIDAllCasesMatchRNIDs() {
        // Order and values from src/services/sources.ts ids.
        XCTAssertEqual(SourceID.allCases.map(\.rawValue), [
            "gelbooru", "yandere", "danbooru", "realbooru", "rule34", "cumst", "redgifs",
            "xvideos", "xhamster", "pornhub", "sexcom", "hentaihaven", "nhentai",
        ])
    }

    // MARK: - Settings and filters (partial decode uses defaults)

    func testAppSettingsDecodesEmptyObjectToDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.imageQuality, .auto)
        XCTAssertTrue(settings.gridPreviews)
        XCTAssertEqual(settings.activeSourceID, .gelbooru)
        XCTAssertNil(settings.feedOrder)
        XCTAssertTrue(settings.hentaiHavenLastEpisodes.isEmpty)
        XCTAssertFalse(settings.proxy.enabled)
        XCTAssertEqual(settings.proxy.workerURL, "")
        XCTAssertFalse(settings.security.enabled)
        XCTAssertNil(settings.security.passcodeHash)
        XCTAssertTrue(settings.security.useBiometrics)
        XCTAssertTrue(settings.security.autoLockImmediately)
    }

    func testSearchFilterConfigDecodesEmptyObjectToDefaults() throws {
        let filter = try JSONDecoder().decode(SearchFilterConfig.self, from: Data("{}".utf8))

        XCTAssertEqual(filter, SearchFilterConfig())
        XCTAssertEqual(filter.jumpToPage, 1)
        XCTAssertTrue(filter.autocompleteFromServer)
        XCTAssertFalse(filter.includeBlacklisted)
    }

    // MARK: - Backup leniency

    private func postJSON(id: String, sourceID: String) -> String {
        """
        {"id": "\(id)", "sourceId": "\(sourceID)", "sourceName": "Example", "previewUrl": "https://example.com/p\(id).jpg", "width": 10, "height": 10, "aspectRatio": 1.0, "rating": "g", "score": 0, "favCount": 0, "tags": {"artist": [], "character": [], "copyright": [], "general": [], "meta": []}, "allTags": [], "createdAt": "2026-01-01T00:00:00Z"}
        """
    }

    func testBackupSchemaKeepsValidPostsWhenOneSourceIDIsUnknown() throws {
        let json = """
        {
          "creatorName": "BooruViewer",
          "backupVersion": "1.0",
          "exportDate": "2026-01-01T00:00:00.000Z",
          "favoritesCount": 3,
          "favorites": [
            \(postJSON(id: "1", sourceID: "gelbooru")),
            \(postJSON(id: "2", sourceID: "unknown_source")),
            \(postJSON(id: "3", sourceID: "danbooru"))
          ],
          "favoriteTags": ["example_tag"]
        }
        """

        let schema = try JSONDecoder().decode(BackupSchema.self, from: Data(json.utf8))

        XCTAssertEqual(schema.favorites.map(\.id), ["1", "3"])
        XCTAssertEqual(schema.favoritesCount, 3)
        XCTAssertEqual(schema.favoriteTags, ["example_tag"])
        XCTAssertEqual(schema.recentViews, [])
        XCTAssertEqual(schema.searchHistory, [])
        XCTAssertEqual(schema.blacklistedTags, [])
    }
}
