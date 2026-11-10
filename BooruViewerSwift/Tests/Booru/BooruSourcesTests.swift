import XCTest
@testable import BooruViewer

/// Canned transport for these tests. It records requests and returns a fixed body. It never touches the network.
private actor BooruSourcesCannedHTTPClient: HTTPClientProtocol {
    private let body: Data
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(body: String, statusCode: Int = 200) {
        self.body = Data(body.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url ?? URL(string: "https://example.com/")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class BooruSourcesTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-09 12:00 UTC.
    private var fixedNow: Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
    }

    private func query(_ tags: String = "", _ filter: SearchFilterConfig = SearchFilterConfig()) -> SearchQuery {
        SearchQuery(tags: tags, filter: filter)
    }

    private func context(http: any HTTPClientProtocol, gelbooru: ApiAuth? = nil, rule34: ApiAuth? = nil) -> SourceContext {
        SourceContext(http: http, proxy: ProxyConfig(), gelbooruAuth: gelbooru, rule34Auth: rule34, imageQuality: .auto)
    }

    // MARK: - Query translation (RN buildQueryTags, booruApi.ts:248-383)

    func testGelbooruScoreUserRatingSortTranslation() {
        let filter = SearchFilterConfig(sortBy: .score, timeRange: .all, rating: .safe, minScore: 10, user: "someone")
        let text = BooruQueryTranslator.tagString(for: query("cat_girl", filter), source: .gelbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "cat_girl score:>=10 user:someone rating:general sort:score:desc")
    }

    func testRule34UsesSafeRatingSpelling() {
        let text = BooruQueryTranslator.tagString(for: query("", SearchFilterConfig(rating: .safe)), source: .rule34, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "rating:safe")
    }

    func testDanbooruTimeWindowUsesAgeRangeAndOrder() {
        let filter = SearchFilterConfig(sortBy: .score, timeRange: .oneWeek)
        let text = BooruQueryTranslator.tagString(for: query("", filter), source: .danbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "age:<1week order:score")
    }

    func testDanbooruRatingAndIdSort() {
        let filter = SearchFilterConfig(sortBy: .id, rating: .explicit)
        let text = BooruQueryTranslator.tagString(for: query("", filter), source: .danbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "rating:e order:id")
    }

    func testMoebooruScoreWindowUsesDateRange() {
        // 2026-11-09 minus 7 days is 2026-11-02 (RN pastYMD / formatYMD, booruApi.ts:130-140, 339).
        let filter = SearchFilterConfig(sortBy: .score, timeRange: .oneWeek, rating: .explicit)
        let text = BooruQueryTranslator.tagString(for: query("", filter), source: .yandere, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "rating:e order:score date:2026-11-02..2026-11-09")
    }

    func testMoebooruIdSortUsesDescendingKeyword() {
        let text = BooruQueryTranslator.tagString(for: query("", SearchFilterConfig(sortBy: .id)), source: .yandere, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "order:id_desc")
    }

    func testLeaderboardDateIsTrimmed() {
        let text = BooruQueryTranslator.tagString(for: query("", SearchFilterConfig(leaderboardDate: " 2026-01-01 ")), source: .gelbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "date:2026-01-01")
    }

    func testFilterTagsFallBackWhenRawTextIsEmpty() {
        let text = BooruQueryTranslator.tagString(for: query("", SearchFilterConfig(tags: ["a", " b "])), source: .gelbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(text, "a b")
    }

    func testZeroMinScoreAndDefaultFilterSendNothing() {
        let zero = BooruQueryTranslator.tagString(for: query("cat", SearchFilterConfig(minScore: 0)), source: .gelbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(zero, "cat")
        let empty = BooruQueryTranslator.tagString(for: query(), source: .danbooru, now: fixedNow, calendar: utc)
        XCTAssertEqual(empty, "")
    }

    func testGelbooruWindowDaysOnlyForScoreSortWithRange() {
        XCTAssertEqual(BooruQueryTranslator.gelbooruWindowDays(for: SearchFilterConfig(sortBy: .score, timeRange: .oneDay)), 1)
        XCTAssertEqual(BooruQueryTranslator.gelbooruWindowDays(for: SearchFilterConfig(sortBy: .id, timeRange: .oneDay)), 0)
        XCTAssertEqual(BooruQueryTranslator.gelbooruWindowDays(for: SearchFilterConfig(sortBy: .score, timeRange: .all)), 0)
    }

    // MARK: - Gelbooru lower-bound walk (RN booruApi.ts:677-734)

    func testBoundWalkRewritesScoreSortAndAppendsIDBound() {
        XCTAssertEqual(BooruQueryTranslator.gelbooruWalkTags("x sort:score:desc"), "x sort:id:desc")
        XCTAssertEqual(BooruQueryTranslator.gelbooruBoundedTags("x sort:score:desc", lowerBound: 500), "x sort:score:desc id:>499")
        XCTAssertEqual(BooruQueryTranslator.gelbooruBoundedTags("", lowerBound: 500), "id:>499")
    }

    func testBoundCutoffIsWindowBeforeNow() {
        let cutoff = BooruQueryTranslator.gelbooruBoundCutoff(windowDays: 1, now: fixedNow)
        XCTAssertEqual(cutoff, fixedNow.addingTimeInterval(-86_400))
    }

    func testPageAndLimitRules() {
        XCTAssertEqual(BooruQueryTranslator.gelbooruPID(page: 1), 0)
        XCTAssertEqual(BooruQueryTranslator.gelbooruPID(page: 0), 0)
        XCTAssertEqual(BooruQueryTranslator.gelbooruPID(page: 3), 2)
        XCTAssertEqual(BooruQueryTranslator.pageLimit(for: SearchFilterConfig()), 24)
        XCTAssertEqual(BooruQueryTranslator.pageLimit(for: SearchFilterConfig(jumpToPage: 2)), 100)
    }

    // MARK: - URL building and suggestion input

    func testQueryItemsAreStrictlyPercentEncoded() {
        let items = BooruQueryTranslator.gelbooruPostItems(tags: "a+b c", pid: 2, limit: 24)
        let url = BooruJSONSupport.url(baseURL: "https://example.com/", path: "index.php", items: items)
        XCTAssertEqual(url?.absoluteString, "https://example.com/index.php?page=dapi&s=post&q=index&json=1&limit=24&pid=2&tags=a%2Bb%20c")
    }

    func testAbsoluteURLJoinsRelativePaths() {
        XCTAssertEqual(BooruJSONSupport.absoluteURL("/images/a.jpg", baseURL: "https://example.com/")?.absoluteString, "https://example.com/images/a.jpg")
        XCTAssertEqual(BooruJSONSupport.absoluteURL("//cdn.example.com/x.jpg", baseURL: "https://example.com")?.absoluteString, "https://cdn.example.com/x.jpg")
        XCTAssertNil(BooruJSONSupport.absoluteURL("", baseURL: "https://example.com"))
    }

    func testSuggestionInputNeedsTwoTrimmedCharacters() {
        XCTAssertNil(BooruQueryTranslator.suggestionQuery(" a "))
        XCTAssertEqual(BooruQueryTranslator.suggestionQuery(" ab "), "ab")
    }

    func testCredentialItemsNeedBothTrimmedValues() {
        XCTAssertNil(BooruJSONSupport.credentialItems(ApiAuth(userID: " ", apiKey: "example-key")))
        XCTAssertNil(BooruJSONSupport.credentialItems(nil))
        let items = BooruJSONSupport.credentialItems(ApiAuth(userID: " example-user ", apiKey: "example-key"))
        XCTAssertEqual(items, [URLQueryItem(name: "api_key", value: "example-key"), URLQueryItem(name: "user_id", value: "example-user")])
    }

    func testRatingNormalizationMatchesRN() {
        XCTAssertEqual(BooruJSONSupport.rating("general"), .safe)
        XCTAssertEqual(BooruJSONSupport.rating("sensitive"), .safe)
        XCTAssertEqual(BooruJSONSupport.rating("q"), .questionable)
        XCTAssertEqual(BooruJSONSupport.rating("Explicit"), .explicit)
        XCTAssertEqual(BooruJSONSupport.rating(nil), .safe)
    }

    func testISOStringMatchesJavaScriptFormat() {
        XCTAssertEqual(BooruJSONSupport.isoString(unixSeconds: 1_700_000_000), "2023-11-14T22:13:20.000Z")
    }

    // MARK: - Tag category mappings (RN booruApi.ts:94-107, 2307-2312, 2366-2371)

    func testTagCategoryMappings() {
        XCTAssertEqual(DanbooruSource.category(for: 1), .artist)
        XCTAssertEqual(DanbooruSource.category(for: 3), .copyright)
        XCTAssertEqual(DanbooruSource.category(for: 4), .character)
        XCTAssertEqual(DanbooruSource.category(for: 5), .meta)
        XCTAssertEqual(DanbooruSource.category(for: 0), .general)
        XCTAssertEqual(GelbooruSource.tagListCategory(5), .meta)
        XCTAssertEqual(GelbooruSource.autocompleteCategory("metadata"), .meta)
        XCTAssertEqual(GelbooruSource.autocompleteCategory(nil), .general)
    }

    func testPostCountReadsParenthesizedLabel() {
        XCTAssertEqual(GelbooruSource.postCount(inLabel: "cat (123)"), 123)
        XCTAssertEqual(GelbooruSource.postCount(inLabel: "cat"), 0)
        XCTAssertEqual(GelbooruSource.postCount(inLabel: nil), 0)
    }

    // MARK: - Lenient DTO decoding

    func testLenientArraySkipsMalformedElements() throws {
        let json = """
        [
          {"id": 1, "tags": "a", "file_url": "https://example.com/1.jpg"},
          {"score": 9},
          "not an object",
          {"id": "3", "file_url": "https://example.com/3.jpg", "score": "12"}
        ]
        """
        let decoded = try JSONDecoder().decode(BooruLenientArray<GelbooruPostDTO>.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.elements.map(\.id), ["1", "3"])
        XCTAssertEqual(decoded.elements.last?.score, 12)
    }

    func testLenientArrayIgnoresNonArrayBody() throws {
        let decoded = try JSONDecoder().decode(BooruLenientArray<GelbooruPostDTO>.self, from: Data(#"{"post": []}"#.utf8))
        XCTAssertEqual(decoded.elements.count, 0)
    }

    func testInvalidJSONStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(BooruLenientArray<GelbooruPostDTO>.self, from: Data("[{".utf8)))
    }

    func testGelbooruEnvelopeShapes() throws {
        let single = try JSONDecoder().decode(GelbooruDAPIResponse.self, from: Data(#"{"post": {"id": 5, "file_url": "https://example.com/5.jpg"}}"#.utf8))
        XCTAssertEqual(single.posts.map(\.id), ["5"])

        let failure = try JSONDecoder().decode(GelbooruDAPIResponse.self, from: Data(#"{"success": false, "message": "Invalid api key"}"#.utf8))
        XCTAssertEqual(failure.success, false)
        XCTAssertEqual(failure.message, "Invalid api key")

        let bare = try JSONDecoder().decode(GelbooruDAPIResponse.self, from: Data(#""Missing auth""#.utf8))
        XCTAssertEqual(bare.text, "Missing auth")
    }

    // MARK: - fetchPosts mapping and auth (canned transport, no network)

    func testGelbooruFetchPostsMapsCannedDAPIResponse() async throws {
        let body = """
        [
          {"id": 101, "score": 7, "width": 800, "height": 600, "rating": "general",
           "source": "https://example.com/src/101", "change": 1700000000,
           "directory": "1234", "image": "abc.png", "tags": "cat_girl solo",
           "file_url": "https://example.com/images/1234/abc.png",
           "preview_url": "https://example.com/thumbnails/1234/thumbnail_abc.jpg",
           "sample_url": "https://example.com/samples/1234/sample_abc.jpg"},
          {"score": 1, "tags": "orphan_without_id"}
        ]
        """
        let http = BooruSourcesCannedHTTPClient(body: body)
        let page = try await GelbooruSource().fetchPosts(query: query("cat_girl solo"), page: 1, context: context(http: http))

        XCTAssertEqual(page.posts.map(\.id), ["101"])
        let post = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(post.sourceID, .gelbooru)
        XCTAssertEqual(post.sourceName, "Gelbooru")
        XCTAssertEqual(post.rating, .safe)
        XCTAssertEqual(post.score, 7)
        XCTAssertEqual(post.favCount, 1_700_000_000)
        XCTAssertEqual(post.width, 800)
        XCTAssertEqual(post.tags.general, ["cat_girl", "solo"])
        XCTAssertEqual(post.allTags, ["cat_girl", "solo"])
        XCTAssertEqual(post.fileExt, "png")
        XCTAssertEqual(post.createdAt, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://example.com/images/1234/abc.png")
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://example.com/samples/1234/sample_abc.jpg")
        XCTAssertEqual(post.previewURL?.absoluteString, "https://example.com/thumbnails/1234/thumbnail_abc.jpg")
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://example.com/src/101")
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertTrue(page.hasMore)

        let requests = await http.requests
        let url = try XCTUnwrap(requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "page", value: "dapi")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "pid", value: "0")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "24")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "tags", value: "cat_girl solo")))
        // Anonymous Gelbooru sends no credentials.
        XCTAssertFalse(items.contains { $0.name == "api_key" })
    }

    func testGelbooruAppendsCredentialsWhenProvided() async throws {
        let http = BooruSourcesCannedHTTPClient(body: "[]")
        let auth = ApiAuth(userID: " example-user ", apiKey: "example-key")
        _ = try await GelbooruSource().fetchPosts(query: query("cat"), page: 1, context: context(http: http, gelbooru: auth))

        let requests = await http.requests
        let url = try XCTUnwrap(requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "api_key", value: "example-key")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "user_id", value: "example-user")))
    }

    func testRule34WithoutCredentialsThrowsAuthRequiredBeforeAnyRequest() async throws {
        let http = BooruSourcesCannedHTTPClient(body: "[]")
        do {
            _ = try await GelbooruSource(id: .rule34).fetchPosts(query: query("cat"), page: 1, context: context(http: http))
            XCTFail("Expected authRequired for Rule34 without credentials")
        } catch BooruError.authRequired(let source) {
            XCTAssertEqual(source, .rule34)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testRule34TagSuggestionsUseAutocompletePHPAndParseCount() async throws {
        let http = BooruSourcesCannedHTTPClient(body: #"[{"label":"cat (123)","value":"cat"}]"#)
        let suggestions = try await GelbooruSource(id: .rule34).tagSuggestions(prefix: "ca", context: context(http: http))
        XCTAssertEqual(suggestions, [BooruTagSuggestion(name: "cat", category: .general, postCount: 123)])

        let requests = await http.requests
        XCTAssertTrue(requests.first?.url?.absoluteString.hasPrefix("https://api.rule34.xxx/autocomplete.php?") ?? false)
    }

    func testMoebooruTagSuggestionsMapCountsAndDropBlankNames() async throws {
        let http = BooruSourcesCannedHTTPClient(body: #"[{"name":"tag_a","count":5},{"name":"","count":2}]"#)
        let suggestions = try await MoebooruSource().tagSuggestions(prefix: "ta", context: context(http: http))
        XCTAssertEqual(suggestions, [BooruTagSuggestion(name: "tag_a", category: .general, postCount: 5)])

        let requests = await http.requests
        XCTAssertTrue(requests.first?.url?.absoluteString.hasPrefix("https://yande.re/tag.json?") ?? false)
    }
}
