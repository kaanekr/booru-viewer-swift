import XCTest
@testable import BooruViewer

/// Routes canned bodies by URL substring, records every request and body, and never touches the network.
private actor SourcesAPIFakeHTTPClient: HTTPClientProtocol {
    struct Rule {
        let match: String
        let body: String
        let statusCode: Int

        init(match: String, body: String, statusCode: Int = 200) {
            self.match = match
            self.body = body
            self.statusCode = statusCode
        }
    }

    private let rules: [Rule]
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [Data?] = []

    init(rules: [Rule]) {
        self.rules = rules
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        requestBodies.append(request.httpBody)
        let url = request.url ?? URL(string: "https://example.com/")!
        let haystack = request.url?.absoluteString ?? ""
        let rule = rules.first { haystack.contains($0.match) }
        let body = Data((rule?.body ?? "{}").utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: rule?.statusCode ?? 404,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

/// Same routing as `SourcesAPIFakeHTTPClient`, but each rule replays a scripted sequence of responses
/// (clamped to its last entry) so retry and token-refresh paths can be exercised in order.
private actor SourcesAPISequencedHTTPClient: HTTPClientProtocol {
    struct Response {
        let body: String
        let statusCode: Int

        init(body: String, statusCode: Int = 200) {
            self.body = body
            self.statusCode = statusCode
        }
    }

    struct Rule {
        let match: String
        let responses: [Response]
    }

    private let rules: [Rule]
    private var cursors: [String: Int] = [:]
    private(set) var requests: [URLRequest] = []

    init(rules: [Rule]) {
        self.rules = rules
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url ?? URL(string: "https://example.com/")!
        let haystack = url.absoluteString
        var scripted = Response(body: "{}", statusCode: 404)
        if let rule = rules.first(where: { haystack.contains($0.match) && !$0.responses.isEmpty }) {
            let cursor = cursors[rule.match] ?? 0
            cursors[rule.match] = cursor + 1
            scripted = rule.responses[min(cursor, rule.responses.count - 1)]
        }
        let body = Data(scripted.body.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: scripted.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

/// Synthetic coverage for the Cum.st, RedGifs, nhentai, and HentaiHaven adapters. No real network calls.
final class SourcesAPITests: XCTestCase {
    private func query(_ tags: String = "", _ filter: SearchFilterConfig = SearchFilterConfig()) -> SearchQuery {
        SearchQuery(tags: tags, filter: filter)
    }

    private func context(
        http: any HTTPClientProtocol,
        proxy: ProxyConfig = ProxyConfig(),
        imageQuality: ImageQuality = .auto
    ) -> SourceContext {
        SourceContext(http: http, proxy: proxy, gelbooruAuth: nil, rule34Auth: nil, imageQuality: imageQuality)
    }

    /// The token caches are process-wide; each test starts from a cold cache.
    private func resetCaches() async {
        await RedGifsSource.RedGifsTokenCache.shared.clear()
        await HentaiHavenSource.HentaiHavenWardenCache.shared.clear()
        await HentaiHavenSource.HentaiHavenGenreCache.shared.clear()
        await HentaiHavenSource.HentaiHavenEpisodeCache.shared.clear()
    }

    // MARK: - Cum.st (booruApi.ts:2097-2290)

    func testCumstServiceAndMediaTypeFiltersBecomeQueryParams() {
        let filter = SearchFilterConfig(cumstService: .onlyfans, cumstMediaType: .videos)
        let tags = CumstSource.searchTags(for: query("cat_girl", filter))
        XCTAssertEqual(tags, "cat_girl service:onlyfans type:videos")

        XCTAssertEqual(
            CumstSource.requestURL(tags: tags, page: 1)?.absoluteString,
            "https://cum.st/api/v1/posts?o=0&n=50&service=onlyfans&type=videos&q=cat%20girl"
        )
        XCTAssertEqual(
            CumstSource.requestURL(tags: tags, page: 2)?.absoluteString,
            "https://cum.st/api/v1/posts?o=50&n=50&service=onlyfans&type=videos&q=cat%20girl"
        )
    }

    func testCumstAllFiltersAreOmitted() {
        let filter = SearchFilterConfig(cumstService: .all, cumstMediaType: .all)
        XCTAssertEqual(CumstSource.searchTags(for: query("", filter)), "")
        XCTAssertEqual(
            CumstSource.requestURL(tags: "", page: 1)?.absoluteString,
            "https://cum.st/api/v1/posts?o=0&n=50"
        )
    }

    func testCumstLeaderboardPeriodUsesThePopularEndpoint() {
        let filter = SearchFilterConfig(sortBy: .score, timeRange: .oneDay)
        let tags = CumstSource.searchTags(for: query("", filter))
        XCTAssertEqual(tags, "period:day sort:popular")
        XCTAssertEqual(
            CumstSource.requestURL(tags: tags, page: 2)?.absoluteString,
            "https://cum.st/api/v1/posts/popular?period=day&o=50&n=50"
        )
    }

    func testCumstDateAnchorSnapsWeeklyToMonday() {
        // 2026-01-07 is a Wednesday; the weekly anchor snaps back to Monday 2026-01-05.
        let filter = SearchFilterConfig(timeRange: .oneWeek, leaderboardDate: " 2026-01-07 ")
        let tags = CumstSource.searchTags(for: query("", filter))
        XCTAssertEqual(tags, "date:2026-01-05")
        XCTAssertEqual(
            CumstSource.requestURL(tags: tags, page: 1)?.absoluteString,
            "https://cum.st/api/v1/posts/popular?period=day&o=0&n=50&date=2026-01-05"
        )
        // Monthly anchors snap to the 1st, daily ones pass through untouched.
        XCTAssertEqual(CumstSource.snappedAnchor("2026-01-07", timeRange: .oneMonth), "2026-01-01")
        XCTAssertEqual(CumstSource.snappedAnchor("2026-02-30", timeRange: .oneWeek), "2026-02-30")
    }

    func testCumstUserAndSortTokens() {
        let filter = SearchFilterConfig(sortBy: .id, user: " someone ")
        XCTAssertEqual(CumstSource.searchTags(for: query("", filter)), "creator:someone sort:recent")
        XCTAssertEqual(
            CumstSource.requestURL(tags: "creator:someone sort:recent", page: 1)?.absoluteString,
            "https://cum.st/api/v1/posts?o=0&n=50&sort=recent&q=someone"
        )
    }

    func testCumstMapsAttachmentsAndSkipsBrokenItems() async throws {
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/api/v1/posts", body: cumstPostsBody),
        ])

        let page = try await CumstSource().fetchPosts(query: query(), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["cumst_9_1", "cumst_9_2"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextPage, 2)

        let first = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(first.sourceID, .cumst)
        XCTAssertEqual(first.sourceName, "Cum.st")
        XCTAssertEqual(first.rating, .explicit)
        XCTAssertEqual(first.score, 7)
        XCTAssertEqual(first.favCount, 7)
        XCTAssertEqual(first.width, 1280)
        XCTAssertEqual(first.height, 720)
        XCTAssertEqual(first.fileExt, "mov")
        XCTAssertEqual(first.fileSize, 12_345)
        XCTAssertEqual(first.previewURL?.absoluteString, "https://img.cum.st/thumbnail/aaa/preview.webp")
        XCTAssertEqual(first.sampleURL?.absoluteString, "https://e1.cum.st/media/aaa/original.mov")
        XCTAssertEqual(first.originalURL?.absoluteString, "https://e1.cum.st/media/aaa/original.mov")
        XCTAssertEqual(first.tags.artist, ["Someone"])
        XCTAssertEqual(first.tags.copyright, ["onlyfans"])
        XCTAssertEqual(first.tags.general, ["tag_a", "tag_b", "tag_c"])
        XCTAssertEqual(first.tags.meta, ["video", "video/mp4", "onlyfans"])
        XCTAssertEqual(first.allTags, ["Someone", "onlyfans", "tag_a", "tag_b", "tag_c", "video", "video/mp4"])
        XCTAssertEqual(first.sourceLink?.absoluteString, "https://cum.st/creators/onlyfans/c1/post/9")
        XCTAssertEqual(first.createdAt, "2023-11-14T22:13:20.000Z")

        let second = try XCTUnwrap(page.posts.last)
        XCTAssertEqual(second.fileExt, "jpg")
        XCTAssertEqual(second.width, 800)
        XCTAssertEqual(second.height, 1000)
        XCTAssertEqual(second.tags.meta, ["photo", "onlyfans"])
        XCTAssertEqual(second.previewURL?.absoluteString, "https://img.cum.st/thumbnail/bbb/preview.webp")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://cum.st/api/v1/posts?o=0&n=50")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Referer"), "https://cum.st/")
    }

    func testCumstRetriesOnceAfterAServerError() async throws {
        let http = SourcesAPISequencedHTTPClient(rules: [
            .init(match: "/api/v1/posts", responses: [
                .init(body: "{}", statusCode: 500),
                .init(body: cumstPostsBody),
            ]),
        ])

        let page = try await CumstSource().fetchPosts(query: query(), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["cumst_9_1", "cumst_9_2"])

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://cum.st/api/v1/posts?o=0&n=50")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://cum.st/api/v1/posts?o=0&n=50")
    }

    // MARK: - RedGifs (booruApi.ts:1199-1470)

    func testRedGifsAcquiresTemporaryTokenThenMapsSearchResults() async throws {
        await resetCaches()
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/v2/auth/temporary", body: #"{"token":"tok_example"}"#),
            .init(match: "/v2/gifs/search", body: redGifsSearchBody),
        ])

        let page = try await RedGifsSource().fetchPosts(query: query("cat_girl"), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["rg_abc123"])

        let post = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(post.sourceID, .redgifs)
        XCTAssertEqual(post.sourceName, "RedGifs")
        XCTAssertEqual(post.rating, .explicit)
        XCTAssertEqual(post.previewURL?.absoluteString, "https://media.redgifs.com/abc-thumb.jpg")
        XCTAssertEqual(post.previewFallbackURL?.absoluteString, "https://media.redgifs.com/abc-poster.jpg")
        XCTAssertEqual(post.previewVideoURL?.absoluteString, "https://media.redgifs.com/abc-silent.mp4")
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://media.redgifs.com/abc-sd.mp4")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://media.redgifs.com/abc-hd.mp4")
        XCTAssertEqual(post.width, 720)
        XCTAssertEqual(post.height, 1280)
        XCTAssertEqual(post.aspectRatio, 720.0 / 1280.0, accuracy: 0.000_001)
        XCTAssertEqual(post.score, 42)
        XCTAssertEqual(post.favCount, 42)
        XCTAssertEqual(post.tags.artist, ["Studio X"])
        XCTAssertEqual(post.tags.general, ["big_breasts", "cosplay"])
        XCTAssertEqual(post.tags.meta, ["video", "sound"])
        XCTAssertEqual(post.allTags, ["Studio X", "big_breasts", "cosplay", "video", "sound"])
        XCTAssertEqual(post.niches, ["3-somes", "12"])
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://www.redgifs.com/watch/abc123")
        XCTAssertEqual(post.fileExt, "mp4")
        XCTAssertEqual(post.createdAt, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertTrue(page.hasMore)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.redgifs.com/v2/auth/temporary")
        XCTAssertEqual(requests[1].url?.path, "/v2/gifs/search")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok_example")

        let items = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "type", value: "g")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "order", value: "trending")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "count", value: "24")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "page", value: "1")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "tags", value: "cat girl")))

        // The cached token serves the next page: only one auth request in total.
        _ = try await RedGifsSource().fetchPosts(query: query("cat_girl"), page: 2, context: context(http: http))
        let allRequests = await http.requests
        XCTAssertEqual(allRequests.count, 3)
        XCTAssertEqual(allRequests.filter { $0.url?.path == "/v2/auth/temporary" }.count, 1)
    }

    func testRedGifsRefreshesTheTokenOnceAfterA401() async throws {
        await resetCaches()
        let http = SourcesAPISequencedHTTPClient(rules: [
            .init(match: "/v2/auth/temporary", responses: [
                .init(body: #"{"token":"tok_one"}"#),
                .init(body: #"{"token":"tok_two"}"#),
            ]),
            .init(match: "/v2/gifs/search", responses: [
                .init(body: #"{"error":"unauthorized"}"#, statusCode: 401),
                .init(body: redGifsSearchBody),
            ]),
        ])

        let page = try await RedGifsSource().fetchPosts(query: query("cat_girl"), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["rg_abc123"])

        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.path == "/v2/auth/temporary" }.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok_one")
        XCTAssertEqual(requests[2].url?.path, "/v2/auth/temporary")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer tok_two")
    }

    func testRedGifsOrderNicheAndExclusionMapping() {
        XCTAssertEqual(RedGifsSource.order(for: SearchFilterConfig(sortBy: .score, timeRange: .oneWeek)), "top7")
        XCTAssertEqual(RedGifsSource.order(for: SearchFilterConfig(sortBy: .score, timeRange: .oneMonth)), "top28")
        XCTAssertEqual(RedGifsSource.order(for: SearchFilterConfig(sortBy: .score, timeRange: .oneDay)), "trending")
        XCTAssertEqual(RedGifsSource.order(for: SearchFilterConfig(sortBy: .id)), "latest")
        XCTAssertEqual(RedGifsSource.order(for: SearchFilterConfig()), "trending")
        XCTAssertEqual(RedGifsSource.count(for: SearchFilterConfig()), 24)

        let parsed = RedGifsSource.parseSearch(
            tags: "cat_girl -tag_x -niche:3-somes -user:someone user:someone",
            filter: SearchFilterConfig()
        )
        XCTAssertEqual(parsed.includeTags, "cat girl")
        XCTAssertEqual(parsed.excludeTags, ["tag_x", "niche:3-somes", "user:someone"])
        XCTAssertEqual(parsed.nicheExcludes, ["3-somes"])
        XCTAssertEqual(parsed.userExcludes, ["someone"])
        XCTAssertEqual(parsed.searchUsername, "someone")
        XCTAssertEqual(RedGifsSource.searchText("real_couples big__tits"), "real couples big tits")

        // A niche token switches the endpoint and the remaining tags are filtered client-side.
        let niche = RedGifsSource.parseSearch(tags: "niche:3-somes cat_girl", filter: SearchFilterConfig())
        XCTAssertEqual(niche.nicheId, "3-somes")
        XCTAssertEqual(
            RedGifsSource.searchURL(niche, filter: SearchFilterConfig(), page: 1)?.absoluteString,
            "https://api.redgifs.com/v2/niches/3-somes/gifs?count=24&page=1"
        )
    }

    func testRedGifsResolveMediaSelectsHDForAutoAndFullAndSDForPreview() async throws {
        await resetCaches()
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/v2/auth/temporary", body: #"{"token":"tok_example"}"#),
            .init(match: "/v2/gifs/search", body: redGifsSearchBody),
        ])
        let source = RedGifsSource()
        let page = try await source.fetchPosts(query: query("cat_girl"), page: 1, context: context(http: http))
        let post = try XCTUnwrap(page.posts.first)

        let autoMedia = try await source.resolveMedia(for: post, context: context(http: http, imageQuality: .auto))
        XCTAssertEqual(autoMedia.videoURL?.absoluteString, "https://media.redgifs.com/abc-hd.mp4")

        let fullMedia = try await source.resolveMedia(for: post, context: context(http: http, imageQuality: .full))
        XCTAssertEqual(fullMedia.videoURL?.absoluteString, "https://media.redgifs.com/abc-hd.mp4")

        let previewMedia = try await source.resolveMedia(for: post, context: context(http: http, imageQuality: .preview))
        XCTAssertEqual(previewMedia.videoURL?.absoluteString, "https://media.redgifs.com/abc-sd.mp4")
    }

    // MARK: - nhentai (nhentai.ts:286-465)

    func testNhentaiGalleryPageURLsFollowTheDetailNumbers() throws {
        let detail = try JSONDecoder().decode(NHentaiGalleryDetailDTO.self, from: Data("""
        {"media_id":"555","num_pages":3,"pages":[
          {"number":2,"path":"galleries/555/2.webp"},
          {"number":1,"path":"galleries/555/1.webp"},
          {"path":"galleries/555/extra.webp"}
        ]}
        """.utf8))

        XCTAssertEqual(
            NHentaiSource.pageURLs(fromDetail: detail).map(\.absoluteString),
            [
                "https://i3.nhentai.net/galleries/555/1.webp",
                "https://i3.nhentai.net/galleries/555/2.webp",
                "https://i3.nhentai.net/galleries/555/extra.webp",
            ]
        )
    }

    func testNhentaiLegacyPagesUseTheTypeExtensionMap() throws {
        let detail = try JSONDecoder().decode(NHentaiGalleryDetailDTO.self, from: Data("""
        {"media_id":777,"images":{"pages":[{"t":"j"},{"path":"galleries/777/2.png"}]}}
        """.utf8))

        XCTAssertEqual(
            NHentaiSource.pageURLs(fromDetail: detail).map(\.absoluteString),
            [
                "https://i3.nhentai.net/galleries/777/1.jpg",
                "https://i3.nhentai.net/galleries/777/2.png",
            ]
        )
    }

    func testNhentaiSyntheticPagesUseMediaIDAndExtension() {
        XCTAssertEqual(
            NHentaiSource.syntheticPageURLs(mediaID: "42", pageCount: 3, fileExt: "jpeg").map(\.absoluteString),
            [
                "https://i3.nhentai.net/galleries/42/1.jpg",
                "https://i3.nhentai.net/galleries/42/2.jpg",
                "https://i3.nhentai.net/galleries/42/3.jpg",
            ]
        )
        XCTAssertEqual(
            NHentaiSource.syntheticPageURLs(mediaID: "42", pageCount: 1, fileExt: nil).map(\.absoluteString),
            ["https://i3.nhentai.net/galleries/42/1.webp"]
        )
        XCTAssertTrue(NHentaiSource.syntheticPageURLs(mediaID: "", pageCount: 3, fileExt: "webp").isEmpty)
        XCTAssertTrue(NHentaiSource.syntheticPageURLs(mediaID: "42", pageCount: 0, fileExt: "webp").isEmpty)
    }

    func testNhentaiListingUsesThumbHostsAndResolvesTheGallery() async throws {
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(
                match: "/api/v2/galleries/11",
                body: #"{"media_id":"99","num_pages":2,"pages":[{"number":1,"path":"galleries/99/1.png"}]}"#
            ),
            .init(match: "/api/v2/galleries?page=1", body: nhentaiListingBody),
        ])
        let source = NHentaiSource()

        let page = try await source.fetchPosts(query: query(), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["nh_11"])

        let post = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(post.sourceID, .nhentai)
        XCTAssertEqual(post.sourceName, "nhentai")
        XCTAssertEqual(post.title, "A & B")
        XCTAssertEqual(post.rating, .explicit)
        XCTAssertEqual(post.score, 7)
        XCTAssertEqual(post.favCount, 7)
        XCTAssertEqual(post.pageCount, 12)
        XCTAssertEqual(post.mediaId, "99")
        XCTAssertEqual(post.fileExt, "webp")
        XCTAssertEqual(post.width, 250)
        XCTAssertEqual(post.height, 350)
        XCTAssertEqual(post.previewURL?.absoluteString, "https://t2.nhentai.net/galleries/99/thumb.webp")
        XCTAssertEqual(post.previewFallbackURL?.absoluteString, "https://t3.nhentai.net/galleries/99/thumb.webp")
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://t3.nhentai.net/galleries/99/cover.webp")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://i3.nhentai.net/galleries/99/1.webp")
        XCTAssertEqual(post.tags.meta, ["manga"])
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://nhentai.net/g/11/")

        let resolved = try await source.resolveMedia(for: post, context: context(http: http))
        XCTAssertFalse(resolved.isVideo)
        XCTAssertEqual(resolved.imageURL?.absoluteString, "https://i3.nhentai.net/galleries/99/1.png")
        XCTAssertEqual(resolved.placeholderURL?.absoluteString, "https://t2.nhentai.net/galleries/99/thumb.webp")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://nhentai.net/api/v2/galleries?page=1&per_page=25")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(requests[1].url?.absoluteString, "https://nhentai.net/api/v2/galleries/11")
    }

    func testNhentaiGalleryDetailParsesCategorizedTags() async throws {
        await resetCaches()
        let detailBody = """
        {"media_id":"99","pages":[{"number":1,"path":"galleries/99/1.jpg"},{"number":2,"path":"galleries/99/2.jpg"}],
         "tags":[
           {"name":"Example Artist","type":"artist","count":10},
           {"name":"Original Work","type":"parody","count":50},
           {"name":"Heroine","type":"character","count":20},
           {"name":"English","type":"language","count":1000},
           {"name":"Full &amp; Color","type":"tag","count":40}
         ]}
        """
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/api/v2/galleries/11", body: detailBody),
            .init(match: "/api/v2/galleries", body: nhentaiListingBody),
        ])
        let source = NHentaiSource()
        let page = try await source.fetchPosts(query: query(), page: 1, context: context(http: http))
        let post = try XCTUnwrap(page.posts.first)

        let detail = try await source.galleryDetail(for: post, context: context(http: http))
        XCTAssertEqual(detail.pages.count, 2)
        XCTAssertEqual(detail.tags.artist, ["Example Artist"])
        XCTAssertEqual(detail.tags.copyright, ["Original Work"])
        XCTAssertEqual(detail.tags.character, ["Heroine"])
        XCTAssertEqual(detail.tags.general, ["Full & Color"])
        XCTAssertEqual(detail.tags.meta, ["manga", "English"])
    }

    func testNhentaiSortAndCandidateURLs() {
        XCTAssertEqual(NHentaiSource.apiSort(for: SearchFilterConfig()), "date")
        XCTAssertEqual(NHentaiSource.apiSort(for: SearchFilterConfig(sortBy: .score, timeRange: .oneDay)), "popular-today")
        XCTAssertEqual(NHentaiSource.apiSort(for: SearchFilterConfig(sortBy: .score, timeRange: .oneWeek)), "popular-week")
        XCTAssertEqual(NHentaiSource.apiSort(for: SearchFilterConfig(sortBy: .score, timeRange: .oneMonth)), "popular-month")
        XCTAssertEqual(NHentaiSource.apiSort(for: SearchFilterConfig(sortBy: .score, timeRange: .oneYear)), "popular")

        XCTAssertEqual(
            NHentaiSource.candidateURLs(page: 1, keyword: "", sort: "popular-today", minScore: nil).map(\.absoluteString),
            ["https://nhentai.net/api/v2/galleries/popular"]
        )
        XCTAssertTrue(NHentaiSource.candidateURLs(page: 2, keyword: "", sort: "popular-today", minScore: nil).isEmpty)
        XCTAssertEqual(
            NHentaiSource.candidateURLs(page: 3, keyword: "", sort: "popular", minScore: nil).map(\.absoluteString),
            ["https://nhentai.net/api/v2/search?query=*&sort=popular&page=3"]
        )
        XCTAssertEqual(
            NHentaiSource.candidateURLs(page: 1, keyword: "big breasts", sort: "date", minScore: 100).map(\.absoluteString),
            ["https://nhentai.net/api/v2/search?query=big%20breasts%20favorites%3A%3E%3D100&sort=date&page=1"]
        )
    }

    // MARK: - HentaiHaven (hentaihavens.ts:34-160, 739-830)

    func testHentaiHavenAcquiresWardenTokenAndMapsLatestListing() async throws {
        await resetCaches()
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/v1/warden", body: #"{"data":{"token":"warden_example"}}"#),
            .init(match: "/v1/hentai/all?p=1", body: hentaiHavenListingBody),
        ])

        let page = try await HentaiHavenSource().fetchPosts(query: query(), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["hh_321", "hh_322"])

        let first = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(first.sourceID, .hentaihaven)
        XCTAssertEqual(first.sourceName, "HentaiHaven")
        XCTAssertEqual(first.title, "Some Series")
        XCTAssertEqual(first.rating, .explicit)
        XCTAssertEqual(first.previewURL?.absoluteString, "https://cdn.hentaihaven.app/321.jpg")
        XCTAssertEqual(first.sampleURL?.absoluteString, "https://cdn.hentaihaven.app/321.jpg")
        XCTAssertNil(first.originalURL)
        XCTAssertEqual(first.score, 1_500)
        XCTAssertEqual(first.favCount, 1_500)
        XCTAssertEqual(first.tags.meta, ["video"])
        XCTAssertEqual(first.allTags, [])
        XCTAssertEqual(first.mediaId, "321")
        XCTAssertEqual(first.fileExt, "mp4")
        XCTAssertEqual(first.width, 600)
        XCTAssertEqual(first.height, 900)
        XCTAssertEqual(first.sourceLink?.absoluteString, "https://hentaihaven.xxx/watch/some-series/")
        XCTAssertEqual(first.createdAt, "2026-01-02T03:04:05.000Z")

        let second = try XCTUnwrap(page.posts.last)
        XCTAssertEqual(second.mediaId, "322")
        XCTAssertNil(second.title)
        XCTAssertEqual(second.previewURL?.absoluteString, "https://hentaihaven.xxx/img/322.jpg")
        XCTAssertEqual(second.sourceLink?.absoluteString, "https://hentaihaven.xxx/watch/other/")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.hentaihaven.app/v1/warden")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "HH_xxx_APP")
        let wardenText = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(wardenText.contains("sdkInt=33"))
        XCTAssertTrue(wardenText.contains("board=goldfish_x86_64"))
        XCTAssertTrue(wardenText.contains("model=sdk_gphone_x86_64"))
        XCTAssertTrue(
            wardenText.contains(
                "fingerprint=google%2Fsdk_gphone_x86_64%2Femu64xa%3A13%2FTE1A.220922.028%2F10190541%3Auserdebug%2Fdev-keys"
            )
        )
        XCTAssertFalse(wardenText.contains("generic_android"))

        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.hentaihaven.app/v1/hentai/all?p=1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "warden"), "warden_example")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "User-Agent"), "HH_xxx_APP")

        // The warden token is cached: the next page does not ask for another one.
        _ = try await HentaiHavenSource().fetchPosts(query: query(), page: 1, context: context(http: http))
        let allRequests = await http.requests
        XCTAssertEqual(allRequests.count, 3)
        XCTAssertEqual(allRequests.filter { $0.url?.path == "/v1/warden" }.count, 1)
    }

    func testHentaiHavenRefreshesTheWardenTokenAfterA401() async throws {
        await resetCaches()
        let http = SourcesAPISequencedHTTPClient(rules: [
            .init(match: "/v1/warden", responses: [
                .init(body: #"{"data":{"token":"warden_one"}}"#),
                .init(body: #"{"data":{"token":"warden_two"}}"#),
            ]),
            .init(match: "/v1/hentai/all?p=1", responses: [
                .init(body: "{}", statusCode: 401),
                .init(body: hentaiHavenListingBody),
            ]),
        ])

        let page = try await HentaiHavenSource().fetchPosts(query: query(), page: 1, context: context(http: http))
        XCTAssertEqual(page.posts.map(\.id), ["hh_321", "hh_322"])

        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/warden" }.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "warden"), "warden_one")
        XCTAssertEqual(requests[2].url?.path, "/v1/warden")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "warden"), "warden_two")
    }

    func testHentaiHavenResolveMediaUsesTheNewestEpisodeStream() async throws {
        await resetCaches()
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/v1/warden", body: #"{"data":{"token":"warden_example"}}"#),
            .init(match: "/v1/hentai/321", body: hentaiHavenDetailBody),
            .init(match: "/v1/hentai/all?p=1", body: hentaiHavenListingBody),
        ])
        let source = HentaiHavenSource()

        let page = try await source.fetchPosts(query: query(), page: 1, context: context(http: http))
        let post = try XCTUnwrap(page.posts.first)

        let resolved = try await source.resolveMedia(for: post, context: context(http: http))
        XCTAssertTrue(resolved.isVideo)
        XCTAssertEqual(resolved.videoURL?.absoluteString, "https://cdn.hentaihaven.app/hls/321/ep2.m3u8")
        XCTAssertEqual(resolved.imageURL?.absoluteString, "https://cdn.hentaihaven.app/ep2.jpg")
        XCTAssertEqual(resolved.placeholderURL?.absoluteString, "https://cdn.hentaihaven.app/321.jpg")
    }

    func testHentaiHavenSectionRoutingAndQueryParsing() {
        XCTAssertEqual(HentaiHavenSource.genreID(for: .yuri), 102)
        XCTAssertEqual(HentaiHavenSource.genreID(for: .uncensored), 107)
        XCTAssertNil(HentaiHavenSource.genreID(for: .latest))

        let parsed = HentaiHavenSource.parseQuery("tag:\"big breasts\" -ugly yuri")
        XCTAssertEqual(parsed.include, ["big breasts", "yuri"])
        XCTAssertEqual(parsed.exclude, ["ugly"])

        XCTAssertEqual(HentaiHavenSource.rawPhrase("tag:\"big breasts\""), "big breasts")
        XCTAssertEqual(HentaiHavenSource.normalizedToken(" Teen_Hentai "), "teen hentai")

        let genres = HentaiHavenSource.knownGenres
        XCTAssertEqual(HentaiHavenSource.findGenre(genres, "uncensored")?.termID, 107)
        XCTAssertEqual(HentaiHavenSource.findGenre(genres, "Yaoi")?.termID, 104)
        XCTAssertNil(HentaiHavenSource.findGenre(genres, "no such genre"))
    }

    func testHentaiHavenNeverReturnsCoverImageAsVideoStream() async throws {
        await resetCaches()
        let http = SourcesAPIFakeHTTPClient(rules: [
            .init(match: "/v1/warden", body: #"{"data":{"token":"warden_example"}}"#),
            .init(match: "/v1/hentai/all?p=1", body: hentaiHavenListingBody),
            .init(match: "/v1/hentai/321", body: #"{"data":{"post_ID":321,"post_episodes":[]}}"#),
        ])
        let source = HentaiHavenSource()
        let page = try await source.fetchPosts(query: query(), page: 1, context: context(http: http))
        let post = try XCTUnwrap(page.posts.first)

        let resolved = try await source.resolveMedia(for: post, context: context(http: http))
        XCTAssertFalse(resolved.isVideo)
        XCTAssertNil(resolved.videoURL)

        let dummyEpisode = HentaiHavenEpisode(
            id: "ep_1",
            number: 1,
            title: "Ep 1",
            streamURL: nil,
            thumbnailURL: post.previewURL
        )
        let stream = try await source.resolveEpisodeStream(episode: dummyEpisode, post: post, context: context(http: http))
        XCTAssertNil(stream)
    }

    // MARK: - Canned bodies

    private let cumstPostsBody = """
    {"posts":[
      {"id":9,"creatorName":"Someone","creatorId":"c1","service":"onlyfans","score":7,"published":1700000000,
       "tags":["tag_a",{"slug":"tag_b"},{"label":"tag_c"}],
       "attachments":[
         {"sha256":"aaa","kind":"video","mimeType":"video/mp4","originalFilename":"clip.mov","width":1280,"height":720,"bytes":12345},
         {"sha256":"bbb","kind":"photo"},
         {"kind":"photo"}
       ]},
      {"id":10,"attachments":[]},
      {"no_id":true}
    ]}
    """

    private let redGifsSearchBody = """
    {"gifs":[
      {"id":"abc123","width":720,"height":1280,"likes":42,"userName":"Studio X","hasAudio":true,"createDate":1700000000,
       "tags":["Big Breasts","cosplay"],
       "niches":["3-somes"," 3-Somes ",12],
       "urls":{"hd":"https://media.redgifs.com/abc-hd.mp4","sd":"https://media.redgifs.com/abc-sd.mp4",
               "silent":"https://media.redgifs.com/abc-silent.mp4","thumbnail":"https://media.redgifs.com/abc-thumb.jpg",
               "poster":"https://media.redgifs.com/abc-poster.jpg"}},
      {"width":1}
    ]}
    """

    private let nhentaiListingBody = """
    {"result":[
      {"id":11,"media_id":99,"english_title":"A &amp; B","thumbnail":"galleries/99/thumb.webp",
       "thumbnail_width":250,"thumbnail_height":350,"num_favorites":7,"num_pages":12},
      {"id":12,"media_id":98,"blacklisted":true,"thumbnail":"galleries/98/thumb.webp"},
      {"media_id":97}
    ]}
    """

    private let hentaiHavenListingBody = """
    {"data":{"hentais":[
      {"post_ID":321,"post_name":"some-series","post_title":"Some Series","post_thumbnail":"https://cdn.hentaihaven.app/321.jpg","post_views":1500,"post_date":"2026-01-02T03:04:05.000Z"},
      {"post_title":"no id"},
      {"post_ID":"322","post_name":"other","post_thumbnail":"/img/322.jpg"}
    ]}}
    """

    private let hentaiHavenDetailBody = """
    {"data":{"post_ID":321,"post_name":"some-series","post_title":"Some Series","post_episodes":[
      {"chapter_id":11,"chapter_name":"Episode 1","chapter_content":"https://cdn.hentaihaven.app/hls/321/ep1.m3u8","chapter_thumbnail":"https://cdn.hentaihaven.app/ep1.jpg","preview":"https://cdn.hentaihaven.app/ep1.mp4"},
      {"chapter_id":12,"chapter_name":"Episode 2","chapter_content":"https://cdn.hentaihaven.app/hls/321/ep2.m3u8","chapter_thumbnail":"https://cdn.hentaihaven.app/ep2.jpg","preview":"https://cdn.hentaihaven.app/ep2.mp4"}
    ]}}
    """
}
