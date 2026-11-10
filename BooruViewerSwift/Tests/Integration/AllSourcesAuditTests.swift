import XCTest
@testable import BooruViewer

/// Routes canned bodies by URL substring, records every request, and never touches the network.
///
/// `HEAD` answers 200 for every URL so the WebM → MP4 probe can be exercised; an unmatched URL
/// answers 404 so a scraper's candidate loop moves on instead of hanging.
private actor AuditHTTPClient: HTTPClientProtocol {
    struct Rule {
        let match: String
        let body: String
        let status: Int

        init(match: String, body: String, status: Int = 200) {
            self.match = match
            self.body = body
            self.status = status
        }
    }

    private let rules: [Rule]
    private(set) var requests: [URLRequest] = []

    init(rules: [Rule]) {
        self.rules = rules
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else {
            throw BooruError.network("missing URL in audit test")
        }
        let matched = match(for: request)
        let statusCode = request.httpMethod == "HEAD" ? 200 : (matched?.status ?? 404)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        let text = request.httpMethod == "HEAD" ? "" : (matched?.body ?? "")
        return (Data(text.utf8), response)
    }

    /// Rules match the *decoded* URL, so a Worker-relayed `<worker>?url=<encoded>` request still
    /// reaches the canned body of the origin host.
    private func match(for request: URLRequest) -> Rule? {
        guard let raw = request.url?.absoluteString else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        return rules.first { decoded.contains($0.match) }
    }
}

/// Source that always resolves one post to a WebM stream, so the viewer's upgrade path can be
/// driven for a post of every source id without depending on a scraper that still serves WebM.
private struct WebMResolvingSource: BooruSource {
    let id: SourceID
    let video: URL

    var displayName: String { id.rawValue }
    var supportsVideo: Bool { true }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        PostPage(posts: [], nextPage: nil, hasMore: false)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        ResolvedMedia(imageURL: nil, videoURL: video, isVideo: true, placeholderURL: post.previewURL)
    }
}

/// End-to-end audit of every registered source: listing → HTTPS media URLs → media headers →
/// `resolveMedia` → WebM upgrade → Worker routing.
///
/// Everything is synthetic: each source gets canned JSON/HTML keyed by its real request hosts,
/// so the suite proves the wiring without any network call.
final class AllSourcesAuditTests: XCTestCase {

    // MARK: - Fixtures

    /// Canned responses, listing query, and the Referer the media pipeline must attach.
    private struct SourceFixture {
        let rules: [AuditHTTPClient.Rule]
        let tags: String
        let referer: String
    }

    /// The 13 sources from `AVAILABLE_SOURCES` (src/services/sources.ts:5-108).
    private static let expectedSourceIDs: Set<SourceID> = [
        .gelbooru, .rule34, .danbooru, .yandere, .realbooru, .cumst, .redgifs,
        .nhentai, .hentaihaven, .xvideos, .xhamster, .sexcom, .pornhub,
    ]

    private func fixtures() -> [SourceID: SourceFixture] {
        [
            .gelbooru: SourceFixture(
                rules: [.init(match: "gelbooru.com/index.php", body: Self.gelbooruBody)],
                tags: "cat_girl",
                referer: "https://gelbooru.com/"
            ),
            .rule34: SourceFixture(
                rules: [.init(match: "api.rule34.xxx/index.php", body: Self.rule34Body)],
                tags: "cat_girl",
                referer: "https://rule34.xxx/"
            ),
            .danbooru: SourceFixture(
                rules: [.init(match: "danbooru.donmai.us/posts.json", body: Self.danbooruBody)],
                tags: "",
                referer: "https://danbooru.donmai.us/"
            ),
            .yandere: SourceFixture(
                rules: [.init(match: "yande.re/post.json", body: Self.yandereBody)],
                tags: "",
                referer: "https://yande.re/"
            ),
            .realbooru: SourceFixture(
                rules: [.init(match: "realbooru.com/index.php", body: Self.realbooruBody)],
                tags: "",
                referer: "https://realbooru.com/"
            ),
            .cumst: SourceFixture(
                rules: [.init(match: "cum.st/api/v1/posts", body: Self.cumstBody)],
                tags: "",
                referer: "https://cum.st/"
            ),
            .redgifs: SourceFixture(
                rules: [
                    .init(match: "api.redgifs.com/v2/auth/temporary", body: #"{"token":"tok_audit"}"#),
                    .init(match: "api.redgifs.com/v2/gifs/search", body: Self.redGifsBody),
                ],
                tags: "cat_girl",
                referer: "https://www.redgifs.com/"
            ),
            .nhentai: SourceFixture(
                rules: [
                    .init(match: "nhentai.net/api/v2/galleries/11", body: Self.nhentaiDetailBody),
                    .init(match: "nhentai.net/api/v2/galleries?page=1", body: Self.nhentaiListingBody),
                ],
                tags: "",
                referer: "https://nhentai.net/"
            ),
            .hentaihaven: SourceFixture(
                rules: [
                    .init(match: "api.hentaihaven.app/v1/warden", body: #"{"data":{"token":"warden_audit"}}"#),
                    .init(match: "api.hentaihaven.app/v1/hentai/321", body: Self.hentaiHavenDetailBody),
                    .init(match: "api.hentaihaven.app/v1/hentai/all", body: Self.hentaiHavenListingBody),
                ],
                tags: "",
                referer: "https://hentaihaven.xxx/"
            ),
            .xvideos: SourceFixture(
                rules: [
                    .init(match: "xvideos.com/video.abc/sample", body: Self.xvideosDetailBody),
                    .init(match: "xvideos.com", body: Self.xvideosListingBody),
                ],
                tags: "",
                referer: "https://www.xvideos.com/"
            ),
            .xhamster: SourceFixture(
                rules: [
                    .init(match: "xhamster.com/videos/sample-555", body: Self.xhamsterDetailBody),
                    .init(match: "xhamster.com", body: Self.xhamsterListingBody),
                ],
                tags: "",
                referer: "https://xhamster.com/"
            ),
            .sexcom: SourceFixture(
                rules: [
                    .init(match: "sex.com/en/videos/1040312", body: Self.sexComDetailBody),
                    .init(match: "sex.com/en/videos", body: Self.sexComListingBody),
                ],
                tags: "",
                referer: "https://www.sex.com/"
            ),
            .pornhub: SourceFixture(
                rules: [
                    .init(match: "pornhub.com/webmasters/search", body: Self.pornhubAPIBody),
                    .init(match: "pornhub.com/video/search", body: Self.pornhubCardBody),
                    .init(match: "pornhub.com/embed", body: Self.pornhubDetailBody),
                    .init(match: "pornhub.com/view_video.php", body: Self.pornhubDetailBody),
                ],
                tags: "sample",
                referer: "https://www.pornhub.com/"
            ),
        ]
    }

    // MARK: - Helpers

    private func query(_ tags: String) -> SearchQuery {
        SearchQuery(tags: tags, filter: SearchFilterConfig())
    }

    /// Rule34 refuses to fetch without credentials; the other sources stay anonymous.
    private func context(_ http: any HTTPClientProtocol, for id: SourceID) -> SourceContext {
        SourceContext(
            http: http,
            proxy: ProxyConfig(),
            gelbooruAuth: nil,
            rule34Auth: id == .rule34 ? ApiAuth(userID: "123", apiKey: "audit-key") : nil,
            imageQuality: .auto
        )
    }

    private func source(for id: SourceID) throws -> any BooruSource {
        try XCTUnwrap(SourceRegistry.source(for: id), "source \(id.rawValue) is not registered")
    }

    private func fetchFixturePage(
        for id: SourceID,
        http: (any HTTPClientProtocol)? = nil
    ) async throws -> PostPage {
        let fixture = try XCTUnwrap(fixtures()[id], "missing fixture for \(id.rawValue)")
        let client: any HTTPClientProtocol
        if let http {
            client = http
        } else {
            client = AuditHTTPClient(rules: fixture.rules)
        }
        return try await source(for: id).fetchPosts(
            query: query(fixture.tags),
            page: 1,
            context: context(client, for: id)
        )
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - (a) Registration and HTTPS media URLs

    func testAll13SourcesRegisteredAndProduceValidHTTPSMediaURLs() async throws {
        XCTAssertEqual(Set(SourceID.allCases), Self.expectedSourceIDs)
        XCTAssertEqual(SourceID.allCases.count, 13)

        for id in SourceID.allCases {
            await RedGifsSource.RedGifsTokenCache.shared.clear()
            await HentaiHavenSource.HentaiHavenWardenCache.shared.clear()

            let fixture = try XCTUnwrap(fixtures()[id], "missing fixture for \(id.rawValue)")
            let page = try await fetchFixturePage(for: id)
            XCTAssertFalse(page.posts.isEmpty, "\(id.rawValue) returned no posts")

            for post in page.posts {
                XCTAssertEqual(post.sourceID, id, "\(id.rawValue) produced a post of another source")
                let preview = try XCTUnwrap(
                    post.previewURL,
                    "\(id.rawValue) post \(post.id) has no preview URL"
                )
                let raw = preview.absoluteString
                XCTAssertEqual(preview.scheme?.lowercased(), "https", "\(id.rawValue) preview is not HTTPS: \(raw)")
                XCTAssertFalse(raw.hasPrefix("//"), "\(id.rawValue) preview is protocol-relative: \(raw)")
                XCTAssertFalse(raw.contains("&amp;"), "\(id.rawValue) preview kept an HTML entity: \(raw)")

                let headers = MediaRequestConfiguration.headers(for: preview)
                let userAgent = header("User-Agent", in: headers) ?? ""
                XCTAssertFalse(userAgent.isEmpty, "\(id.rawValue) media headers have no User-Agent")
                XCTAssertEqual(
                    header("Referer", in: headers),
                    fixture.referer,
                    "\(id.rawValue) media headers carry the wrong Referer"
                )
            }
        }
    }

    // MARK: - (b) Media resolution and WebM upgrade

    @MainActor
    func testAll13SourcesResolveMediaAndUpgradeWebM() async throws {
        for id in SourceID.allCases {
            await RedGifsSource.RedGifsTokenCache.shared.clear()
            await HentaiHavenSource.HentaiHavenWardenCache.shared.clear()

            let fixture = try XCTUnwrap(fixtures()[id], "missing fixture for \(id.rawValue)")
            let http = AuditHTTPClient(rules: fixture.rules)
            let sourceContext = context(http, for: id)
            let page = try await source(for: id).fetchPosts(
                query: query(fixture.tags),
                page: 1,
                context: sourceContext
            )
            let post = try XCTUnwrap(page.posts.first, "\(id.rawValue) returned no posts")

            let media = try await source(for: id).resolveMedia(for: post, context: sourceContext)
            XCTAssertNotNil(
                media.videoURL ?? media.imageURL,
                "\(id.rawValue) resolved no playable media"
            )
            XCTAssertEqual(media.isVideo, media.videoURL != nil, "\(id.rawValue) video flag disagrees with the URL")
            for url in [media.imageURL, media.videoURL].compactMap({ $0 }) {
                XCTAssertEqual(url.scheme?.lowercased(), "https", "\(id.rawValue) resolved a non-HTTPS URL: \(url)")
            }

            // The viewer upgrades a WebM stream when the server has its MP4 sibling.
            let webm = try XCTUnwrap(URL(string: "https://media.example.com/clip_\(id.rawValue).webm"))
            let synthetic = BooruPost(
                id: "\(id.rawValue)_webm",
                sourceID: id,
                sourceName: id.rawValue,
                title: nil,
                previewURL: URL(string: "https://media.example.com/clip_\(id.rawValue).jpg"),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: webm,
                originalURL: webm,
                width: 720,
                height: 1280,
                aspectRatio: 720.0 / 1280.0,
                rating: .explicit,
                score: 0,
                favCount: 0,
                tags: BooruTagGroups(general: []),
                allTags: [],
                sourceLink: nil,
                fileExt: "webm",
                fileSize: nil,
                createdAt: "2026-01-02T03:04:05.000Z",
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            )
            let viewer = ViewerViewModel(
                posts: [synthetic],
                context: sourceContext,
                sourceProvider: { _ in WebMResolvingSource(id: id, video: webm) }
            )
            await viewer.loadMedia(for: synthetic)
            let upgraded = try XCTUnwrap(viewer.media(for: synthetic), "\(id.rawValue) cached no media")
            XCTAssertEqual(
                upgraded.videoURL?.absoluteString,
                webm.absoluteString.replacingOccurrences(of: ".webm", with: ".mp4"),
                "\(id.rawValue) did not upgrade WebM to MP4"
            )
            XCTAssertTrue(upgraded.isVideo, "\(id.rawValue) upgraded media is not a video")
        }
    }

    // MARK: - (c) Worker routing

    func testProxyWorkerRoutingForAllSourcesAndMedia() async throws {
        let worker = "https://worker.example.com"
        let proxyOn = ProxyConfig(enabled: true, workerURL: worker)
        let proxyOff = ProxyConfig(enabled: false, workerURL: worker)
        let originalProxy = MediaRequestConfiguration.currentProxy()
        defer { MediaRequestConfiguration.updateCurrentProxy(originalProxy) }

        // Media pipeline state follows the settings path.
        MediaRequestConfiguration.updateCurrentProxy(proxyOn)
        let current = MediaRequestConfiguration.currentProxy()
        XCTAssertTrue(current.enabled)
        XCTAssertEqual(current.workerURL, worker)

        for id in SourceID.allCases {
            await RedGifsSource.RedGifsTokenCache.shared.clear()
            await HentaiHavenSource.HentaiHavenWardenCache.shared.clear()

            let fixture = try XCTUnwrap(fixtures()[id], "missing fixture for \(id.rawValue)")
            let recorder = AuditHTTPClient(rules: fixture.rules)
            let proxied = ProxyAwareHTTPClient(direct: recorder, proxy: proxyOn)
            let page = try await source(for: id).fetchPosts(
                query: query(fixture.tags),
                page: 1,
                context: SourceContext(
                    http: proxied,
                    proxy: proxyOn,
                    gelbooruAuth: nil,
                    rule34Auth: id == .rule34 ? ApiAuth(userID: "123", apiKey: "audit-key") : nil,
                    imageQuality: .auto
                )
            )

            // Every API leg goes through `<worker>?url=<encodeURIComponent(original)>`.
            let requests = await recorder.requests
            XCTAssertFalse(requests.isEmpty, "\(id.rawValue) made no request")
            for request in requests {
                let raw = request.url?.absoluteString ?? ""
                XCTAssertTrue(
                    raw.hasPrefix("\(worker)?url="),
                    "\(id.rawValue) API request bypassed the Worker: \(raw)"
                )
            }

            // Every media URL of the page is routable through the same Worker.
            let post = try XCTUnwrap(page.posts.first, "\(id.rawValue) returned no posts")
            let preview = try XCTUnwrap(post.previewURL, "\(id.rawValue) post has no preview URL")
            XCTAssertEqual(
                MediaRequestConfiguration.routedURL(for: preview, proxy: proxyOn).absoluteString,
                ProxyRelay.relayURL(for: preview, workerURL: worker)?.absoluteString,
                "\(id.rawValue) media URL was not routed through the Worker"
            )
        }

        // TLS_FRAGILE_PATTERNS still use the Worker with the toggle off (proxyService.ts:204-209).
        let fragile = [
            "https://api-cdn.rule34.xxx/thumbnails/1/thumbnail_a.jpg",
            "https://thumb-cdn77.xvideos-cdn.com/thumb.jpg",
            "https://videos.sex.com/1/preview_240p.mp4",
            "https://i.nhentai.net/galleries/1/1.jpg",
        ]
        for raw in fragile {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(
                MediaRequestConfiguration.routedURL(for: url, proxy: proxyOff).absoluteString,
                ProxyRelay.relayURL(for: url, workerURL: worker)?.absoluteString,
                "TLS-fragile host was left direct with the toggle off: \(raw)"
            )
            XCTAssertEqual(
                MediaRequestConfiguration.routedURL(for: url, proxy: proxyOn).absoluteString,
                ProxyRelay.relayURL(for: url, workerURL: worker)?.absoluteString,
                "TLS-fragile host was left direct with the toggle on: \(raw)"
            )
        }

        // A non-fragile host with the toggle off and no Worker stays direct.
        let plain = try XCTUnwrap(URL(string: "https://img4.gelbooru.com/thumbnails/1/thumbnail_a.jpg"))
        XCTAssertEqual(
            MediaRequestConfiguration.routedURL(for: plain, proxy: ProxyConfig()),
            plain
        )

        // The transport rewrites a TLS-fragile leg even though the toggle is off.
        let recorder = AuditHTTPClient(rules: [.init(match: worker, body: "{}")])
        let transport = ProxyAwareHTTPClient(direct: recorder, proxy: proxyOff)
        let fragileURL = try XCTUnwrap(URL(string: "https://api-cdn.rule34.xxx/thumbnails/1/thumbnail_a.jpg"))
        _ = try await transport.data(for: URLRequest(url: fragileURL))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            ProxyRelay.relayURL(for: fragileURL, workerURL: worker)?.absoluteString,
            "ProxyAwareHTTPClient left a TLS-fragile leg direct with the toggle off"
        )
    }

    // MARK: - (d) Source-specific helpers and Explore quick filters

    func testNHentaiGalleryIDAndMediaResolution() async throws {
        XCTAssertEqual(NHentaiSource.galleryID(from: "nhentai_123456"), "123456")
        XCTAssertEqual(NHentaiSource.galleryID(from: "nh_123456"), "123456")
        XCTAssertEqual(NHentaiSource.galleryID(from: "123456"), "123456")

        let source = NHentaiSource()
        let post = BooruPost(
            id: "nhentai_123456",
            sourceID: .nhentai,
            sourceName: "nhentai",
            title: "Test Gallery",
            previewURL: URL(string: "https://t.nhentai.net/galleries/123456/thumb.jpg"),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: URL(string: "https://i.nhentai.net/galleries/123456/1.jpg"),
            originalURL: URL(string: "https://i.nhentai.net/galleries/123456/1.jpg"),
            width: 800,
            height: 1200,
            aspectRatio: 800.0 / 1200.0,
            rating: .explicit,
            score: 10,
            favCount: 5,
            tags: BooruTagGroups(general: []),
            allTags: [],
            sourceLink: URL(string: "https://nhentai.net/g/123456/"),
            fileExt: "jpg",
            fileSize: nil,
            createdAt: "2026-01-02T03:04:05.000Z",
            niches: nil,
            isPremium: nil,
            pageCount: 10,
            mediaId: "123456"
        )
        let emptyClient = AuditHTTPClient(rules: [])
        let sourceContext = context(emptyClient, for: .nhentai)
        let resolved = try await source.resolveMedia(for: post, context: sourceContext)
        XCTAssertNotNil(resolved.imageURL, "NHentaiSource resolveMedia must return a non-nil imageURL")
    }

    func testHentaiHavenFetchEpisodesReturnsSortedEpisodes() async throws {
        await HentaiHavenSource.HentaiHavenWardenCache.shared.clear()
        await HentaiHavenSource.HentaiHavenEpisodeCache.shared.clear()
        defer {
            Task {
                await HentaiHavenSource.HentaiHavenEpisodeCache.shared.clear()
            }
        }

        let source = HentaiHavenSource()
        let detailRule = AuditHTTPClient.Rule(
            match: "api.hentaihaven.app/v1/hentai/999",
            body: """
            {"data":{"post_ID":999,"post_name":"some-series","post_title":"Some Series","post_episodes":[
              {"chapter_id":22,"chapter_name":"Episode 2","chapter_content":"https://cdn.hentaihaven.app/hls/999/ep2.m3u8","preview":"https://cdn.hentaihaven.app/ep2.mp4"},
              {"chapter_id":11,"chapter_name":"Episode 1","chapter_content":"https://cdn.hentaihaven.app/hls/999/ep1.m3u8","preview":"https://cdn.hentaihaven.app/ep1.mp4"},
              {"chapter_id":33,"chapter_name":"Episode 3","chapter_content":"https://cdn.hentaihaven.app/hls/999/ep3.m3u8","preview":"https://cdn.hentaihaven.app/ep3.mp4"}
            ]}}
            """
        )
        let wardenRule = AuditHTTPClient.Rule(
            match: "api.hentaihaven.app/v1/warden",
            body: #"{"data":{"token":"warden_audit"}}"#
        )
        let http = AuditHTTPClient(rules: [wardenRule, detailRule])
        let sourceContext = context(http, for: .hentaihaven)

        let post = BooruPost(
            id: "hh_999",
            sourceID: .hentaihaven,
            sourceName: "hentaihaven",
            title: "Some Series",
            previewURL: URL(string: "https://hentaihaven.xxx/img/999.jpg"),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: nil,
            originalURL: nil,
            width: 1280,
            height: 720,
            aspectRatio: 16.0 / 9.0,
            rating: .explicit,
            score: 100,
            favCount: 50,
            tags: BooruTagGroups(general: []),
            allTags: [],
            sourceLink: URL(string: "https://hentaihaven.xxx/watch/some-series/"),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: "2026-01-02T03:04:05.000Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: "999"
        )

        let episodes: [HentaiHavenEpisode] = try await source.fetchEpisodes(for: post, context: sourceContext)
        XCTAssertEqual(episodes.count, 3)
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3], "fetchEpisodes must return sorted [HentaiHavenEpisode]")
    }

    func testSourceQuickFiltersExploreChips() {
        let options = SourceQuickFilters.options(for: .gelbooru, context: .feed)
        guard let topChip = options.first(where: { $0.id == "top" }),
              let dayChip = options.first(where: { $0.id == "day" }),
              let weekChip = options.first(where: { $0.id == "week" }),
              let monthChip = options.first(where: { $0.id == "month" }) else {
            XCTFail("Missing Explore quick filter chips")
            return
        }

        let base = SearchFilterConfig()

        let appliedTop = SourceQuickFilters.apply(topChip, to: base)
        XCTAssertEqual(appliedTop.sortBy, .score)
        XCTAssertEqual(appliedTop.timeRange, .all)

        let appliedDay = SourceQuickFilters.apply(dayChip, to: base)
        XCTAssertEqual(appliedDay.sortBy, .score)
        XCTAssertEqual(appliedDay.timeRange, .oneDay)

        let appliedWeek = SourceQuickFilters.apply(weekChip, to: base)
        XCTAssertEqual(appliedWeek.sortBy, .score)
        XCTAssertEqual(appliedWeek.timeRange, .oneWeek)

        let appliedMonth = SourceQuickFilters.apply(monthChip, to: base)
        XCTAssertEqual(appliedMonth.sortBy, .score)
        XCTAssertEqual(appliedMonth.timeRange, .oneMonth)
    }

    // MARK: - Canned bodies

    private static let gelbooruBody = """
    [
      {"id": 101, "score": 7, "width": 800, "height": 600, "rating": "general",
       "source": "https://gelbooru.com/index.php?page=post&s=view&id=101", "change": 1700000000,
       "directory": "1234", "image": "abc.png", "tags": "cat_girl solo",
       "file_url": "https://img4.gelbooru.com/images/1234/abc.png",
       "preview_url": "https://img4.gelbooru.com/thumbnails/1234/thumbnail_abc.jpg",
       "sample_url": "https://img4.gelbooru.com/samples/1234/sample_abc.jpg"}
    ]
    """

    private static let rule34Body = """
    [
      {"id": 202, "score": 5, "width": 800, "height": 1000, "rating": "explicit",
       "source": "https://rule34.xxx/index.php?page=post&s=view&id=202", "change": 1700000001,
       "tags": "cat_girl",
       "file_url": "https://api-cdn.rule34.xxx/images/202/a.png",
       "preview_url": "https://api-cdn.rule34.xxx/thumbnails/202/thumbnail_a.jpg",
       "sample_url": "https://api-cdn.rule34.xxx/samples/202/sample_a.jpg"}
    ]
    """

    private static let danbooruBody = """
    [
      {"id": "d1", "file_url": "https://cdn.donmai.us/original/d1.jpg",
       "large_file_url": "https://cdn.donmai.us/large/d1.jpg",
       "preview_file_url": "https://cdn.donmai.us/preview/d1.jpg",
       "image_width": 800, "image_height": 1200, "rating": "q", "score": 12, "fav_count": 3,
       "file_ext": "jpg", "created_at": "2026-01-02T03:04:05.000Z", "tag_string": "a b",
       "source": "https://danbooru.donmai.us/posts/d1"}
    ]
    """

    private static let yandereBody = """
    [
      {"id": "y1", "preview_url": "https://yande.re/data/preview/y1.jpg",
       "sample_url": "https://yande.re/data/sample/y1.jpg",
       "file_url": "https://yande.re/data/y1.jpg", "width": 800, "height": 1200,
       "rating": "s", "score": 4, "source": "https://yande.re/post/show/y1",
       "file_ext": "jpg", "created_at": 1700000000, "tags": "a b"}
    ]
    """

    private static let realbooruBody = #"""
    <div class="col thumb" id="s42"><a id="p42" href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=42"><img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg" title="1girl, video, webm, rating:explicit score:17" alt="Image: 42" /></a></div>
    """#

    private static let cumstBody = """
    {"posts":[
      {"id":9,"creatorName":"Someone","creatorId":"c1","service":"onlyfans","score":7,"published":1700000000,
       "tags":["tag_a"],
       "attachments":[
         {"sha256":"aaa","kind":"video","mimeType":"video/mp4","originalFilename":"clip.mp4","width":1280,"height":720,"bytes":12345}
       ]}
    ]}
    """

    private static let redGifsBody = """
    {"gifs":[
      {"id":"abc123","width":720,"height":1280,"likes":42,"userName":"Studio X","hasAudio":true,"createDate":1700000000,
       "tags":["Big Breasts"],"niches":["3-somes"],
       "urls":{"hd":"https://media.redgifs.com/abc-hd.mp4","sd":"https://media.redgifs.com/abc-sd.mp4",
               "silent":"https://media.redgifs.com/abc-silent.mp4","thumbnail":"https://media.redgifs.com/abc-thumb.jpg",
               "poster":"https://media.redgifs.com/abc-poster.jpg"}}
    ]}
    """

    private static let nhentaiListingBody = """
    {"result":[
      {"id":11,"media_id":99,"english_title":"A &amp; B","thumbnail":"galleries/99/thumb.webp",
       "thumbnail_width":250,"thumbnail_height":350,"num_favorites":7,"num_pages":12}
    ]}
    """

    private static let nhentaiDetailBody = """
    {"media_id":"99","num_pages":2,"pages":[{"number":1,"path":"galleries/99/1.png"}]}
    """

    private static let hentaiHavenListingBody = """
    {"data":{"hentais":[
      {"post_ID":321,"post_name":"some-series","post_title":"Some Series","post_thumbnail":"/img/321.jpg",
       "post_views":1500,"post_date":"2026-01-02T03:04:05.000Z"}
    ]}}
    """

    private static let hentaiHavenDetailBody = """
    {"data":{"post_ID":321,"post_name":"some-series","post_title":"Some Series","post_episodes":[
      {"chapter_id":11,"chapter_name":"Episode 1","chapter_content":"https://cdn.hentaihaven.app/hls/321/ep1.m3u8",
       "chapter_thumbnail":"https://cdn.hentaihaven.app/ep1.jpg","preview":"https://cdn.hentaihaven.app/ep1.mp4"}
    ]}}
    """

    private static let xvideosListingBody = #"""
    <div id="video_abc" data-id="123"><a href="/video.abc/sample"><img data-src="https://thumb-cdn77.xvideos-cdn.com/thumb_THUMBNUM.jpg" data-pvv="https://cdn.xvideos-cdn.com/clip.mp4?token=abc&amp;expires=123" /></a><p class="title"><a title="Sample">Sample</a></p></div>
    """#

    private static let xvideosDetailBody = #"""
    <script>html5player.setVideoUrlHigh('https://mp4-cdn77.xvideos-cdn.com/high.mp4');html5player.setVideoUrlLow('https://mp4-cdn77.xvideos-cdn.com/low.mp4');</script>
    """#

    private static let xhamsterListingBody = #"""
    <div class="thumb-item" data-video-id="555"><a href="/videos/sample-555" data-role="thumb-link"><img data-role="thumb-preview-img" src="https://thumb-nss.xhcdn.com/thumb.jpg" alt="Sample"></a><div data-role="video-duration">03:10</div></div>
    """#

    private static let xhamsterDetailBody = #"""
    <script id="initials-script">window.initials={"xplayerSettings":{"sources":{"standard":{"h264":[{"url":"https://xhcdn.example/480p.h264.mp4","quality":"480"},{"url":"https://xhcdn.example/720p.h264.mp4","quality":720}]}}}}</script>
    """#

    private static let sexComListingBody = #"""
    <div data-testid="video-card" data-analytics-video_id="1040312" data-premium="0"><div data-title="Sample Walk"><a href="/en/videos/1040312-sample-walk"><img src="https://images.sxccdn.com/videos/1040312/288/thumbnail.0000012.jpg.webp" alt="Sample Walk"></a><video src="https://videos.sex.com/1040312/preview_240p.mp4"></video><time>10:01</time></div></div>
    """#

    private static let sexComDetailBody = #"""
    <script type="application/ld+json">{"contentUrl":"https://videos.sex.com/1040312/master.m3u8?token=abc","thumbnailUrl":"https://images.sxccdn.com/videos/1040312/poster.webp"}</script>
    """#

    private static let pornhubAPIBody = #"""
    {"videos":[{"video_id":"ph123","title":"Sample","url":"https://www.pornhub.com/view_video.php?viewkey=ph123","duration":"12:34","views":1500,"rating":87.5,"ratings":20,"default_thumb":"https://ei.phncdn.com/covers/1.jpg","thumbs":[{"size":"medium","width":"1280","height":"720","src":"https://ei.phncdn.com/covers/1.jpg"}],"publish_date":"2025-11-10 20:09:26","tags":[{"tag_name":"Red Hair"}]}]}
    """#

    private static let pornhubCardBody = #"""
    <li class="pcVideoListItem videoBox" data-video-vkey="ph123" data-poster="https://ei.phncdn.com/covers/1.jpg"><a href="/view_video.php?viewkey=ph123" title="Sample"><img class="videoThumb" src="https://ei.phncdn.com/covers/1.jpg" alt="Sample"></a></li>
    """#

    private static let pornhubDetailBody = #"""
    <script>var flashvars_9001 = {"mediaDefinitions":[{"group":1,"height":480,"width":854,"defaultQuality":false,"format":"mp4","videoUrl":"https:\/\/ei.phncdn.com\/480.mp4","quality":"480"},{"group":2,"height":1080,"width":1920,"defaultQuality":true,"format":"hls","videoUrl":"https:\/\/ei.phncdn.com\/1080.m3u8","quality":"1080"}]};</script>
    """#
}
