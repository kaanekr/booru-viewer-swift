import XCTest
@testable import BooruViewer

/// Blacklist matching cases from RN `filterBlacklistedPosts` (src/services/booruApi.ts:385-464).
final class BlacklistTests: XCTestCase {
    private func makePost(allTags: [String], tags: BooruTagGroups = BooruTagGroups(), niches: [String]? = nil) -> BooruPost {
        BooruPost(
            id: "1",
            sourceID: .gelbooru,
            sourceName: "Gelbooru",
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
            rating: .safe,
            score: 0,
            favCount: 0,
            tags: tags,
            allTags: allTags,
            sourceLink: nil,
            fileExt: nil,
            fileSize: nil,
            createdAt: "2026-01-01T00:00:00.000Z",
            niches: niches,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    func testEmptyBlacklistBlocksNothing() {
        let matcher = BlacklistMatcher(tags: [])
        XCTAssertFalse(matcher.isBlocked(makePost(allTags: ["cat"])))
    }

    func testExactTagIsMatchedCaseInsensitively() {
        let matcher = BlacklistMatcher(tags: ["Cat"])
        XCTAssertTrue(matcher.isBlocked(makePost(allTags: ["cat", "dog"])))
    }

    func testSpaceAndUnderscoreAreInterchangeable() {
        XCTAssertTrue(BlacklistMatcher(tags: ["long hair"]).isBlocked(makePost(allTags: ["long_hair"])))
        // A whitespace run in the post tag becomes one `_` (booruApi.ts:415-420).
        XCTAssertTrue(BlacklistMatcher(tags: ["long_hair"]).isBlocked(makePost(allTags: ["Long  Hair"])))
    }

    func testTagGroupMatchesWhenAllTagsDoesNot() {
        let groups = BooruTagGroups(meta: ["blocked_meta"])
        XCTAssertTrue(BlacklistMatcher(tags: ["blocked_meta"]).isBlocked(makePost(allTags: [], tags: groups)))
    }

    func testNicheEntryMatchesNicheID() {
        let matcher = BlacklistMatcher(tags: ["niche:3-somes"])
        XCTAssertTrue(matcher.isBlocked(makePost(allTags: [], niches: ["3-Somes"])))
    }

    func testPlainEntryDoesNotMatchNiche() {
        // Niches only match the `niche:` prefix (booruApi.ts:432-438).
        let matcher = BlacklistMatcher(tags: ["3-somes"])
        XCTAssertFalse(matcher.isBlocked(makePost(allTags: [], niches: ["3-somes"])))
    }

    func testUserEntryMatchesArtist() {
        let matcher = BlacklistMatcher(tags: ["user:Example_Artist"])
        let groups = BooruTagGroups(artist: ["example_artist"])
        XCTAssertTrue(matcher.isBlocked(makePost(allTags: [], tags: groups)))
    }

    func testNonMatchingPostIsAllowed() {
        let matcher = BlacklistMatcher(tags: ["gore"])
        XCTAssertFalse(matcher.isBlocked(makePost(allTags: ["cat", "dog"])))
    }

    func testBlankEntriesAreIgnored() {
        let matcher = BlacklistMatcher(tags: ["   ", ""])
        XCTAssertFalse(matcher.isBlocked(makePost(allTags: ["cat"])))
    }
}
