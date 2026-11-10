import XCTest
@testable import BooruViewer

/// Pornhub scraper and challenge-solver tests. All JSON and HTML is synthetic and written inline.
/// The WebKit resolver itself is never instantiated: `PornhubSource` takes a fake `PornhubChallengeSolving`.
final class PornhubTests: XCTestCase {

    // MARK: - Helpers

    /// Routes a request by URL. A URL with no route fails like an unreachable host, so a test can prove
    /// which requests a code path must not make.
    private struct FakeHTTPClient: HTTPClientProtocol {
        let route: @Sendable (URL) -> (body: String, status: Int)?

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, let match = route(url) else {
                throw BooruError.network("unexpected URL in test")
            }
            guard let response = HTTPURLResponse(url: url, statusCode: match.status, httpVersion: nil, headerFields: nil) else {
                throw BooruError.network("no response in test")
            }
            return (Data(match.body.utf8), response)
        }
    }

    private func makeContext(client: FakeHTTPClient) -> SourceContext {
        SourceContext(http: client, proxy: ProxyConfig(), gelbooruAuth: nil, rule34Auth: nil, imageQuality: .auto)
    }

    /// Records which pages the solver was asked for.
    private actor SolverRecorder {
        private var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
        func recorded() -> [URL] { urls }
    }

    /// Stands in for the headless WKWebView: returns canned HTML and records the page.
    private struct FakeChallengeSolver: PornhubChallengeSolving {
        let html: String
        let recorder: SolverRecorder

        func resolvePageHTML(url: URL, timeout: TimeInterval) async throws -> String {
            await recorder.record(url)
            return html
        }
    }

    /// One Pornhub listing card, used by the detail tests.
    private static func listingCard(vkey: String = "ph5f1a2b3c4d") -> String {
        #"<li class="pcVideoListItem videoBox" data-video-vkey="\#(vkey)" data-poster="https://cdn.example/poster1.jpg"><a href="/view_video.php?viewkey=\#(vkey)" title="Sample Clip"><img class="videoThumb" src="https://cdn.example/thumb1.jpg" alt="Sample Clip"></a><div class="videoViews">12.5K</div><span class="bgEffect time">08:15</span></li>"#
    }

    /// Stream block of a fully served page, in the key order the site emits (pornhub.ts:283-286).
    private static let playableDetailHTML = #"""
    <script>var flashvars_9001 = {"mediaDefinitions":[{"group":1,"height":480,"width":854,"defaultQuality":false,"format":"mp4","videoUrl":"https:\/\/cdn.example\/480.mp4","quality":"480"},{"group":2,"height":1080,"width":1920,"defaultQuality":true,"format":"hls","videoUrl":"https:\/\/cdn.example\/1080.m3u8","quality":"1080"}]};</script>
    """#

    /// The JS proof-of-work wall RN's hidden WebView exists for.
    private static let challengeHTML = #"""
    <html><head><title>Attention Required</title></head><body><script>function leastFactor(n){for(var i=2;i*i<=n;i++){if(n%i===0)return i;}return n;}</script></body></html>
    """#

    // MARK: - Timeline thumbs

    func testPornhubSequentialThumbsBuildEightTimelineFrames() {
        let frames = [1, 3, 5, 7, 9, 11, 13, 15].map { "https://cdn.example/poster\($0)_medium.jpg" }
        XCTAssertEqual(PornhubSource.sequentialThumbs("https://cdn.example/poster1_medium.jpg"), frames)
        XCTAssertEqual(
            PornhubSource.sequentialThumbs("https://cdn.example/default.jpg")?.last,
            "https://cdn.example/15.jpg"
        )
        XCTAssertNil(PornhubSource.sequentialThumbs("https://cdn.example/blank.gif"))
        XCTAssertNil(PornhubSource.sequentialThumbs(nil))
    }

    // MARK: - HTML listing

    func testPornhubListingParsesCardFields() {
        let html = #"""
        <li class="pcVideoListItem videoBox" data-video-vkey="ph5f1a2b3c4d" data-webm="https://cdn.example/ph5f1a2b3c4d_fb.mp4" data-poster="https://cdn.example/poster1.jpg"><a href="/view_video.php?viewkey=ph5f1a2b3c4d" title="Sample Clip"><img class="videoThumb" src="https://cdn.example/thumb1.jpg" alt="Sample Clip"></a><div class="videoViews">12.5K</div><span class="bgEffect time">08:15</span></li>
        """#
        let posts = PornhubSource.parseListing(html: html)
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.id, "ph_ph5f1a2b3c4d")
        XCTAssertEqual(post.sourceID, .pornhub)
        XCTAssertEqual(post.title, "Sample Clip")
        XCTAssertEqual(post.rating, .explicit)
        XCTAssertEqual(post.score, 0)
        XCTAssertEqual(post.previewURL?.absoluteString, "https://cdn.example/poster1.jpg")
        XCTAssertEqual(post.previewVideoURL?.absoluteString, "https://cdn.example/ph5f1a2b3c4d_fb.mp4")
        // The flipbook stays on `previewVideoURL`; `sampleURL` keeps the image thumbnail.
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://cdn.example/poster1.jpg")
        XCTAssertNil(post.originalURL)
        XCTAssertEqual(post.previewThumbs?.count, 8)
        XCTAssertEqual(post.previewThumbURL?.absoluteString, "https://cdn.example/poster15.jpg")
        XCTAssertEqual(post.tags.general, ["duration:08:15", "views:12.5K"])
        XCTAssertEqual(post.tags.meta, ["video"])
        XCTAssertEqual(post.fileExt, "mp4")
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://www.pornhub.com/view_video.php?viewkey=ph5f1a2b3c4d")
    }

    func testPornhubListingSkipsCardsWithoutAThumb() {
        let html = #"<div data-video-vkey="phEmpty"></div>"#
        XCTAssertTrue(PornhubSource.parseListing(html: html).isEmpty)
        XCTAssertTrue(PornhubSource.parseListing(html: "").isEmpty)
    }

    // MARK: - List URL

    func testPornhubSearchURLMatchesTheWebmastersQuery() {
        XCTAssertEqual(
            PornhubSource.searchURL(page: 2, keyword: "red hair", ordering: .featured, period: .monthly),
            "https://www.pornhub.com/webmasters/search?search=red+hair&page=2&thumbsize=medium&ordering=featured&period=monthly"
        )
        XCTAssertEqual(
            PornhubSource.htmlListURL(page: 3, keyword: "red hair"),
            "https://www.pornhub.com/video/search?search=red%20hair&page=3"
        )
        XCTAssertEqual(
            PornhubSource.htmlListURL(page: 1, keyword: ""),
            "https://www.pornhub.com/video?o=mv&page=1"
        )
    }

    func testPornhubOrderingAndPeriodFollowRNSortMapping() {
        var filter = SearchFilterConfig()
        XCTAssertEqual(PornhubSource.ordering(keyword: "", filter: filter), .mostviewed)
        XCTAssertEqual(PornhubSource.period(keyword: "", filter: filter), .daily)

        filter.sortBy = .rating
        filter.timeRange = .oneWeek
        XCTAssertEqual(PornhubSource.ordering(keyword: "red", filter: filter), .rating)
        XCTAssertEqual(PornhubSource.period(keyword: "red", filter: filter), .weekly)

        filter.sortBy = .id
        filter.timeRange = .oneYear
        XCTAssertEqual(PornhubSource.ordering(keyword: "red", filter: filter), .newest)
        XCTAssertEqual(PornhubSource.period(keyword: "red", filter: filter), .alltime)
    }

    // MARK: - Webmasters API

    private static let apiJSON = #"""
    {"videos":[{"video_id":"ph123","title":" Sample ","url":"https://www.pornhub.com/view_video.php?viewkey=ph123","duration":"12:34","views":1500,"rating":87.5,"ratings":20,"default_thumb":"https://cdn.example/covers/1.jpg","thumbs":[{"size":"medium","width":"1280","height":"720","src":"https://cdn.example/covers/1.jpg"}],"publish_date":"2025-11-10 20:09:26","tags":[{"tag_name":"Red Hair"}],"categories":[{"category":"Amateur"}],"pornstars":[{"pornstar_name":"Jane Doe"}]}]}
    """#

    func testPornhubFetchPostsMapsWebmastersJSON() async throws {
        let client = FakeHTTPClient { url in
            let text = url.absoluteString
            if text.contains("/webmasters/search") { return (Self.apiJSON, 200) }
            return nil
        }
        let page = try await PornhubSource().fetchPosts(
            query: SearchQuery(tags: "red hair", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["ph_ph123"])
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertTrue(page.hasMore)

        let post = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(post.title, "Sample")
        XCTAssertEqual(post.sourceID, .pornhub)
        XCTAssertEqual(post.previewURL?.absoluteString, "https://cdn.example/covers/1.jpg")
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://cdn.example/covers/1.jpg")
        XCTAssertNil(post.originalURL)
        XCTAssertEqual(post.width, 1280)
        XCTAssertEqual(post.height, 720)
        XCTAssertEqual(post.aspectRatio, 1280.0 / 720.0)
        XCTAssertEqual(post.score, 8750)
        XCTAssertEqual(post.favCount, 20)
        XCTAssertEqual(post.tags.artist, ["jane_doe"])
        XCTAssertEqual(post.tags.copyright, ["amateur"])
        XCTAssertEqual(post.tags.general, ["red_hair"])
        XCTAssertEqual(post.tags.meta, ["video", "duration:754s"])
        XCTAssertEqual(post.allTags, ["jane_doe", "amateur", "red_hair"])
        XCTAssertEqual(post.previewThumbs?.count, 8)
        XCTAssertEqual(post.previewThumbURL?.absoluteString, "https://cdn.example/covers/15.jpg")
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://www.pornhub.com/view_video.php?viewkey=ph123")
        XCTAssertEqual(post.fileExt, "mp4")
        XCTAssertEqual(post.createdAt, "2025-11-10T20:09:26.000Z")
    }

    func testPornhubFetchPostsMergesHTMLPreviewIntoAPICards() async throws {
        let card = #"<li data-video-vkey="ph123" data-poster="https://cdn.example/covers/1.jpg"><a href="/view_video.php?viewkey=ph123" title="Sample"><img class="videoThumb" src="https://cdn.example/covers/1.jpg" alt="Sample"></a></li>"#
        let client = FakeHTTPClient { url in
            let text = url.absoluteString
            if text.contains("/webmasters/search") { return (Self.apiJSON, 200) }
            if text.contains("/video/search") { return (card, 200) }
            return nil
        }
        let page = try await PornhubSource().fetchPosts(
            query: SearchQuery(tags: "red hair", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        // The API card keeps its own metadata; only the HTML timeline thumbs are merged in.
        XCTAssertEqual(page.posts.map(\.id), ["ph_ph123"])
        XCTAssertEqual(page.posts.first?.title, "Sample")
        XCTAssertEqual(page.posts.first?.previewThumbs?.count, 8)
        XCTAssertEqual(page.posts.first?.previewThumbURL?.absoluteString, "https://cdn.example/covers/15.jpg")
    }

    func testPornhubFetchPostsFallsBackToHTMLWhenAPIIsUnreadable() async throws {
        let client = FakeHTTPClient { url in
            let text = url.absoluteString
            if text.contains("/webmasters/search") { return (#"{"code":"2001","message":"search not found"}"#, 200) }
            if text.contains("/video/search") { return (Self.listingCard(), 200) }
            return nil
        }
        let page = try await PornhubSource().fetchPosts(
            query: SearchQuery(tags: "red hair", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["ph_ph5f1a2b3c4d"])
        XCTAssertEqual(page.posts.first?.title, "Sample Clip")
    }

    func testPornhubFetchPostsThrowsWhenBothPathsAreEmpty() async throws {
        let client = FakeHTTPClient { url in
            let text = url.absoluteString
            if text.contains("/webmasters/search") { return (#"{"videos":[]}"#, 200) }
            if text.contains("/video/search") { return ("<html></html>", 200) }
            return nil
        }
        do {
            _ = try await PornhubSource().fetchPosts(
                query: SearchQuery(tags: "red hair", filter: SearchFilterConfig()),
                page: 1,
                context: makeContext(client: client)
            )
            XCTFail("an empty Pornhub page must throw")
        } catch BooruError.network(let message) {
            XCTAssertTrue(message.contains("Could not load Pornhub videos"))
        }
    }

    func testPornhubExplorePageUsesTheHomepageCards() async throws {
        let client = FakeHTTPClient { url in
            url.absoluteString == "https://www.pornhub.com/" ? (Self.listingCard(), 200) : nil
        }
        let page = try await PornhubSource().fetchPosts(
            query: SearchQuery(tags: "", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["ph_ph5f1a2b3c4d"])
    }

    func testPornhubFetchPostsMapsRateLimit() async throws {
        let client = FakeHTTPClient { url in
            url.absoluteString.contains("/webmasters/search") ? ("", 429) : nil
        }
        do {
            _ = try await PornhubSource().fetchPosts(
                query: SearchQuery(tags: "red hair", filter: SearchFilterConfig()),
                page: 1,
                context: makeContext(client: client)
            )
            XCTFail("429 must throw")
        } catch BooruError.rateLimited {
            // expected
        }
    }

    func testPornhubTagSuggestionsAreEmpty() async throws {
        let client = FakeHTTPClient { _ in nil }
        let suggestions = try await PornhubSource().tagSuggestions(prefix: "red", context: makeContext(client: client))
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Detail streams

    func testPornhubDetailPrefersDefaultHLSOverMP4() {
        let files = PornhubSource.parseDetailFiles(html: Self.playableDetailHTML)
        XCTAssertEqual(files.high, "https://cdn.example/1080.m3u8")
        XCTAssertEqual(files.low, "https://cdn.example/1080.m3u8")
        XCTAssertEqual(files.hls, "https://cdn.example/1080.m3u8")
        XCTAssertEqual(
            PornhubSource.playableURL(html: Self.playableDetailHTML)?.absoluteString,
            "https://cdn.example/1080.m3u8"
        )
    }

    func testPornhubDetailWithoutHLSFallsBackToMP4Quality() {
        let mp4Only = #"""
        <script>var flashvars_9002 = {"mediaDefinitions":[{"group":1,"height":480,"width":854,"defaultQuality":false,"format":"mp4","videoUrl":"https:\/\/cdn.example\/480.mp4","quality":"480"},{"group":2,"height":720,"width":1280,"defaultQuality":false,"format":"mp4","videoUrl":"https:\/\/cdn.example\/720.mp4","quality":"720"}]};</script>
        """#
        let files = PornhubSource.parseDetailFiles(html: mp4Only)
        XCTAssertEqual(files.high, "https://cdn.example/720.mp4")
        XCTAssertEqual(files.low, "https://cdn.example/480.mp4")
        XCTAssertEqual(files.hls, "")
        XCTAssertEqual(PornhubSource.playableURL(html: mp4Only)?.absoluteString, "https://cdn.example/720.mp4")
    }

    func testPornhubDetailUnescapesTheDoubleEscapedBlock() {
        let escaped = #"""
        <script>var flashvars_9003 = {"mediaDefinitions\":[{\"group\":1,\"height\":720,\"width\":1280,\"defaultQuality\":true,\"format\":\"mp4\",\"videoUrl\":\"https://cdn.example/720.mp4\",\"quality\":\"720\"}]};</script>
        """#
        XCTAssertEqual(
            PornhubSource.playableURL(html: escaped)?.absoluteString,
            "https://cdn.example/720.mp4"
        )
    }

    func testPornhubDetailWithoutMediaDefinitionsHasNoStream() {
        XCTAssertNil(PornhubSource.playableURL(html: Self.challengeHTML))
        XCTAssertNil(PornhubSource.playableURL(html: ""))
    }

    // MARK: - JS challenge

    func testPornhubChallengeMarkerDetection() {
        XCTAssertTrue(PornhubChallengeMarkers.looksLikeChallenge(Self.challengeHTML))
        XCTAssertTrue(PornhubChallengeMarkers.looksLikeChallenge(#"<script>document.cookie="accessPH=1";</script>"#))
        XCTAssertFalse(PornhubChallengeMarkers.looksLikeChallenge(Self.playableDetailHTML))
        XCTAssertFalse(PornhubChallengeMarkers.looksLikeChallenge(""))

        XCTAssertTrue(PornhubChallengeMarkers.hasStreams(Self.playableDetailHTML))
        XCTAssertFalse(PornhubChallengeMarkers.hasStreams(Self.challengeHTML))
    }

    func testPornhubResolveMediaSolvesTheJSChallengeWithTheSolver() async throws {
        let post = try XCTUnwrap(PornhubSource.parseListing(html: Self.listingCard()).first)
        let recorder = SolverRecorder()
        let solver = FakeChallengeSolver(html: Self.playableDetailHTML, recorder: recorder)
        // Both the embed and the watch page answer with the bot wall.
        let client = FakeHTTPClient { _ in (Self.challengeHTML, 403) }

        let media = try await PornhubSource(challengeResolver: solver)
            .resolveMedia(for: post, context: makeContext(client: client))

        XCTAssertEqual(media.videoURL?.absoluteString, "https://cdn.example/1080.m3u8")
        XCTAssertTrue(media.isVideo)
        let solved = await recorder.recorded().map(\.absoluteString)
        // The lighter embed page is tried first, and it is the one the solver had to read.
        XCTAssertEqual(solved, ["https://www.pornhub.com/embed/ph5f1a2b3c4d"])
    }

    func testPornhubResolveMediaUsesThePlainPageWithoutTheSolver() async throws {
        let post = try XCTUnwrap(PornhubSource.parseListing(html: Self.listingCard()).first)
        let recorder = SolverRecorder()
        let solver = FakeChallengeSolver(html: Self.challengeHTML, recorder: recorder)
        let client = FakeHTTPClient { _ in (Self.playableDetailHTML, 200) }

        let media = try await PornhubSource(challengeResolver: solver)
            .resolveMedia(for: post, context: makeContext(client: client))

        XCTAssertEqual(media.videoURL?.absoluteString, "https://cdn.example/1080.m3u8")
        let solved = await recorder.recorded()
        XCTAssertTrue(solved.isEmpty)
    }

    func testPornhubResolveMediaFallsBackToTheHoverClip() async throws {
        let post = try XCTUnwrap(PornhubSource.parseListing(html: Self.listingCard()).first)
        // Without an injected solver a challenged page yields no stream, so the card keeps its thumbnail.
        let client = FakeHTTPClient { _ in (Self.challengeHTML, 200) }
        let media = try await PornhubSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertNil(media.videoURL)
        XCTAssertFalse(media.isVideo)
        XCTAssertEqual(media.imageURL?.absoluteString, "https://cdn.example/poster1.jpg")
    }

    // MARK: - Viewer hand-off

    /// A `.webm` flipbook lives on `previewVideoURL`; the viewer must not read it as the
    /// post's own WebM and guess an unverified `.mp4` for the main video.
    func testPornhubFlipbookIsNotUpgradedIntoTheMainVideo() throws {
        let html = #"""
        <li class="pcVideoListItem videoBox" data-video-vkey="ph5f1a2b3c4d" data-webm="https://cdn.example/ph5f1a2b3c4d_fb.webm" data-poster="https://cdn.example/poster1.jpg"><a href="/view_video.php?viewkey=ph5f1a2b3c4d" title="Sample Clip"><img class="videoThumb" src="https://cdn.example/thumb1.jpg" alt="Sample Clip"></a><div class="videoViews">12.5K</div><span class="bgEffect time">08:15</span></li>
        """#
        let post = try XCTUnwrap(PornhubSource.parseListing(html: html).first)
        XCTAssertEqual(post.previewVideoURL?.absoluteString, "https://cdn.example/ph5f1a2b3c4d_fb.webm")
        XCTAssertEqual(post.sampleURL?.absoluteString, "https://cdn.example/poster1.jpg")

        XCTAssertNil(ViewerViewModel.webmMediaURL(for: post))
        let media = ViewerViewModel.fallbackMedia(for: post, quality: .auto)
        XCTAssertNil(media.videoURL)
        XCTAssertFalse(media.isVideo)
        XCTAssertEqual(media.imageURL?.absoluteString, "https://cdn.example/poster1.jpg")
    }
}
