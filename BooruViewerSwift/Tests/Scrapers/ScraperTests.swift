import XCTest
@testable import BooruViewer

/// Scraper parsing tests. All HTML is synthetic and written inline. No test touches the network:
/// fetch paths use `StubHTTPClient`, which returns canned bytes.
final class ScraperTests: XCTestCase {

    // MARK: - Helpers

    /// Returns canned HTML for any request whose URL contains `expectedFragment`. Never performs I/O.
    private struct StubHTTPClient: HTTPClientProtocol {
        let body: String
        let status: Int
        let expectedFragment: String

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, url.absoluteString.contains(expectedFragment) else {
                throw BooruError.network("unexpected URL in test")
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw BooruError.network("no response in test")
            }
            return (Data(body.utf8), response)
        }
    }

    private func makeContext(client: StubHTTPClient) -> SourceContext {
        SourceContext(http: client, proxy: ProxyConfig(), gelbooruAuth: nil, rule34Auth: nil, imageQuality: .auto)
    }

    // MARK: - HTMLScanner

    func testDecodeEntitiesDecodesEachReferenceOnce() {
        XCTAssertEqual(
            HTMLScanner.decodeEntities("Tom &amp; Jerry &lt;b&gt; &quot;x&quot; &#39;y&#39; &#x41; &amp;lt; &unknown;"),
            "Tom & Jerry <b> \"x\" 'y' A &lt; &unknown;"
        )
    }

    func testAttributeSkipsLongerNamesAndDecodesValues() {
        let tag = #"<img data-src="a.jpg" src="b.jpg?x=1&amp;y=2" alt='Tom &amp; Jerry'>"#
        XCTAssertEqual(HTMLScanner.attribute("src", in: tag), "b.jpg?x=1&y=2")
        XCTAssertEqual(HTMLScanner.attribute("alt", in: tag), "Tom & Jerry")
        XCTAssertNil(HTMLScanner.attribute("missing", in: tag))
    }

    func testParseCountReadsAbbreviatedCounts() {
        XCTAssertEqual(HTMLScanner.parseCount("2.4K"), 2400)
        XCTAssertEqual(HTMLScanner.parseCount("1.2M"), 1_200_000)
        XCTAssertEqual(HTMLScanner.parseCount("850"), 850)
        XCTAssertEqual(HTMLScanner.parseCount("1,234"), 1234)
        XCTAssertEqual(HTMLScanner.parseCount("&lt;1K"), 1000)
        XCTAssertEqual(HTMLScanner.parseCount("125K views"), 125_000)
        XCTAssertEqual(HTMLScanner.parseCount(""), 0)
    }

    func testAbsoluteURLResolvesRelativeAndProtocolRelativeValues() {
        XCTAssertEqual(
            HTMLScanner.absoluteURL("//cdn.example/a.jpg", base: "https://realbooru.com")?.absoluteString,
            "https://cdn.example/a.jpg"
        )
        XCTAssertEqual(
            HTMLScanner.absoluteURL("/videos/1", base: "https://xhamster.com/")?.absoluteString,
            "https://xhamster.com/videos/1"
        )
        XCTAssertNil(HTMLScanner.absoluteURL("data:image/gif;base64,R0lG", base: "https://xhamster.com"))
    }

    func testEmptyHTMLProducesNoPostsForEverySource() {
        XCTAssertTrue(RealbooruSource.parseListing(html: "").isEmpty)
        XCTAssertTrue(XVideosSource.parseListing(html: "").isEmpty)
        XCTAssertTrue(XHamsterSource.parseListing(html: "").isEmpty)
        XCTAssertTrue(SexComSource.parseListing(html: "").isEmpty)
    }

    func testHTTPErrorMapsRateLimitSeparately() {
        if case .rateLimited = HTMLScanner.httpError(for: 429) {} else { XCTFail("429 must map to rateLimited") }
        if case .http(let status) = HTMLScanner.httpError(for: 503) {
            XCTAssertEqual(status, 503)
        } else {
            XCTFail("503 must map to http(status:)")
        }
    }

    // MARK: - Realbooru

    func testRealbooruParsesVideoCard() {
        let html = #"""
        <div class="col thumb" id="s42"><a id="p42" href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=42"><img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg" title="1girl, video, webm, rating:explicit score:17" alt="Image: 42" /></a></div>
        """#
        let posts = RealbooruSource.parseListing(html: html)
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.id, "realbooru_42")
        XCTAssertEqual(post.sourceID, .realbooru)
        XCTAssertEqual(post.rating, .explicit)
        XCTAssertEqual(post.score, 17)
        XCTAssertEqual(post.tags.general, ["1girl", "video", "webm"])
        XCTAssertEqual(post.tags.meta, ["video"])
        // The tags say `webm`, so the listing reports — and points at — WebM, not a made-up .mp4.
        XCTAssertEqual(post.fileExt, "webm")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://realbooru.com/images/ab/cd/abcd42.webm")
        XCTAssertEqual(post.previewURL?.absoluteString, "https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg")
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://realbooru.com/index.php?page=post&s=view&id=42")
    }

    func testRealbooruVideoCardWithoutAContainerTagInventsNoExtension() {
        // `video`/`animated`/`sound` alone never name a container, so no `.mp4` is assumed
        // and no `/images/` guess is attached to the card.
        let html = #"""
        <div class="col thumb" id="s43"><a href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=43"><img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd43.jpg" title="video, sound, solo" alt="Image: 43" /></a></div>
        """#
        let post = RealbooruSource.parseListing(html: html).first
        XCTAssertEqual(post?.tags.meta, ["video"])
        XCTAssertNil(post?.fileExt)
        XCTAssertNil(post?.originalURL)
    }

    func testRealbooruGifCardStaysOutOfTheVideoPath() {
        let html = #"""
        <div class="col thumb" id="s1001"><a id="p1001" href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=1001"><img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd1001.jpg" title="animated, gif, solo" alt="Image: 1001" /></a></div>
        """#
        let post = RealbooruSource.parseListing(html: html).first
        XCTAssertEqual(post?.fileExt, "gif")
        XCTAssertEqual(post?.tags.meta, [])
        XCTAssertTrue(post?.sampleURL?.absoluteString.hasSuffix(".jpg") ?? false)
        XCTAssertEqual(post?.originalURL?.absoluteString, "https://realbooru.com/images/ab/cd/abcd1001.gif")
    }

    func testRealbooruSkipsCardWithoutImage() {
        let html = #"<div class="col thumb" id="s7"><a href="/index.php?page=post&amp;s=view&amp;id=7">no image</a></div>"#
        XCTAssertTrue(RealbooruSource.parseListing(html: html).isEmpty)
    }

    func testRealbooruListURLFollowsRNPaging() {
        XCTAssertEqual(
            RealbooruSource.listURL(page: 3, tags: "red hair")?.absoluteString,
            "https://realbooru.com/index.php?page=post&s=list&pid=84&tags=red+hair"
        )
        XCTAssertEqual(
            RealbooruSource.listURL(page: 1, tags: "")?.absoluteString,
            "https://realbooru.com/index.php?page=post&s=list&pid=0"
        )
    }

    func testRealbooruSearchTagsAddRatingAndScoreTokensInRNOrder() {
        var filter = SearchFilterConfig()
        filter.minScore = 5
        filter.rating = .safe
        filter.sortBy = .score
        let query = SearchQuery(tags: "red hair", filter: filter)
        XCTAssertEqual(RealbooruSource.searchTags(for: query), "red hair score:>=5 rating:safe sort:score:desc")
    }

    func testRealbooruFetchPostsUsesPidAndReturnsNextPage() async throws {
        let html = #"<div class="col thumb" id="s42"><a id="p42" href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=42"><img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg" title="1girl" alt="Image: 42" /></a></div>"#
        let client = StubHTTPClient(body: html, status: 200, expectedFragment: "pid=42")
        let page = try await RealbooruSource().fetchPosts(
            query: SearchQuery(tags: "", filter: SearchFilterConfig()),
            page: 2,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["realbooru_42"])
        XCTAssertEqual(page.nextPage, 3)
        XCTAssertTrue(page.hasMore)
    }

    func testRealbooruSearchTagsMapEverySortOrder() {
        var filter = SearchFilterConfig()
        filter.sortBy = .id
        XCTAssertEqual(RealbooruSource.searchTags(for: SearchQuery(tags: "", filter: filter)), "sort:id:desc")
        filter.sortBy = .height
        XCTAssertEqual(RealbooruSource.searchTags(for: SearchQuery(tags: "", filter: filter)), "sort:height:desc")
        filter.sortBy = .width
        XCTAssertEqual(RealbooruSource.searchTags(for: SearchQuery(tags: "", filter: filter)), "sort:width:desc")
        filter.sortBy = .rating
        XCTAssertEqual(RealbooruSource.searchTags(for: SearchQuery(tags: "", filter: filter)), "")
    }

    func testRealbooruSearchTagsSendLeaderboardDateBeforeRating() {
        var filter = SearchFilterConfig()
        filter.rating = .explicit
        filter.leaderboardDate = "  2024-05-01  "
        XCTAssertEqual(
            RealbooruSource.searchTags(for: SearchQuery(tags: "red hair", filter: filter)),
            "red hair date:2024-05-01 rating:explicit"
        )
        // No anchor means no date tag.
        filter.leaderboardDate = nil
        XCTAssertEqual(
            RealbooruSource.searchTags(for: SearchQuery(tags: "red hair", filter: filter)),
            "red hair rating:explicit"
        )
    }

    // MARK: - XVideos

    func testXVideosClassicCardDecodesPreviewAndClip() {
        let html = #"""
        <div id="video_abc" data-id="123"><a href="/video.abc/sample"><img data-src="//cdn.example/thumb_THUMBNUM.jpg" data-pvv="//cdn.example/clip.mp4?token=abc&amp;expires=123" /></a><p class="title"><a title="Sample &amp; Title">Sample</a></p><span class="name">Profile</span><span>720p</span></div>
        """#
        let posts = XVideosSource.parseListing(html: html)
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.id, "xv_123")
        XCTAssertEqual(post.previewURL?.absoluteString, "https://cdn.example/thumb_1.jpg")
        XCTAssertEqual(post.previewThumbs?.count, 8)
        XCTAssertEqual(post.previewVideoURL?.absoluteString, "https://cdn.example/clip.mp4?token=abc&expires=123")
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://www.xvideos.com/video.abc/sample")
        XCTAssertEqual(post.title, "Sample & Title")
        XCTAssertEqual(post.tags.artist, ["Profile"])
        XCTAssertEqual(post.height, 720)
        XCTAssertEqual(post.width, 1280)
        XCTAssertNil(post.originalURL)
    }

    func testXVideosBestCardUsesNumericIDAndJSONPreview() {
        let html = #"""
        <div id="video-thumb-enc1" data-video='{"id":77,"encodedId":"enc1","previewVideo":"/previews/p.mp4"}'><a href="/video.enc1/x"><img data-src="https://cdn.example/t_THUMBNUM.jpg" /></a><span>480p</span></div>
        """#
        let posts = XVideosSource.parseListing(html: html)
        XCTAssertEqual(posts.first?.id, "xv_77")
        XCTAssertEqual(posts.first?.previewVideoURL?.absoluteString, "https://www.xvideos.com/previews/p.mp4")
        XCTAssertEqual(posts.first?.height, 480)
    }

    func testXVideosSkipsCardWithoutWatchLink() {
        let html = #"<div id="video_x" data-id="5"><img data-src="https://cdn.example/t.jpg" /></div>"#
        XCTAssertTrue(XVideosSource.parseListing(html: html).isEmpty)
    }

    func testXVideosCandidateURLsForDiscoverAndSearch() {
        XCTAssertEqual(
            XVideosSource.candidateURLs(page: 1, keyword: "", sort: .relevance, datef: .all, bestMonth: ""),
            ["https://www.xvideos.com/", "https://www.xvideos.com/best", "https://www.xvideos.com/new", "https://www.xvideos.com/new/1"]
        )
        XCTAssertEqual(
            XVideosSource.candidateURLs(page: 2, keyword: "red hair", sort: .relevance, datef: .all, bestMonth: ""),
            [
                "https://www.xvideos.com/?k=red+hair&sort=relevance&durf=allduration&datef=all&quality=all&p=1",
                "https://www.xvideos.com/?k=red+hair&sort=relevance&durf=allduration&datef=all&quality=all&p=2",
            ]
        )
    }

    func testXVideosFetchPostsReturnsFirstNonEmptyCandidate() async throws {
        let html = #"<div id="video_abc" data-id="123"><a href="/video.abc/sample"><img data-src="//cdn.example/thumb_THUMBNUM.jpg" /></a></div>"#
        let client = StubHTTPClient(body: html, status: 200, expectedFragment: "xvideos.com")
        let page = try await XVideosSource().fetchPosts(
            query: SearchQuery(tags: "", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["xv_123"])
        XCTAssertEqual(page.nextPage, 2)
    }

    func testXVideosEncodedIDPrefixMatchesUpperCase() {
        let html = #"<div id="video-thumb-ABC123xyz"><a href="/video.abc/x"><img data-src="https://cdn.example/t_THUMBNUM.jpg" /></a></div>"#
        XCTAssertEqual(XVideosSource.parseListing(html: html).map(\.id), ["xv_ABC123xyz"])
    }

    func testXVideosDetailPageSuppliesThePlayableStream() async throws {
        let card = #"<div id="video_abc" data-id="123"><a href="/video.abc/sample"><img data-src="//cdn.example/thumb_THUMBNUM.jpg" /></a></div>"#
        let post = try XCTUnwrap(XVideosSource.parseListing(html: card).first)
        let detail = #"""
        <script>html5player.setVideoHLS('https://cdn.example/hls.m3u8');html5player.setVideoUrlLow('https://cdn.example/low.mp4');html5player.setVideoUrlHigh('https://cdn.example/high.mp4');</script>
        """#
        let client = StubHTTPClient(body: detail, status: 200, expectedFragment: "xvideos.com/video.abc/sample")
        let media = try await XVideosSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://cdn.example/high.mp4")
        XCTAssertTrue(media.isVideo)
    }

    func testXVideosDetailWithoutFilesKeepsTheCard() async throws {
        let card = #"<div id="video_abc" data-id="123"><a href="/video.abc/sample"><img data-src="//cdn.example/thumb_THUMBNUM.jpg" /></a></div>"#
        let post = try XCTUnwrap(XVideosSource.parseListing(html: card).first)
        // A 5xx answer must not fail viewer resolution: the card has no playable file, so the media is empty.
        let client = StubHTTPClient(body: "unavailable", status: 503, expectedFragment: "xvideos.com/video.abc/sample")
        let media = try await XVideosSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertNil(media.videoURL)
        XCTAssertFalse(media.isVideo)
    }

    // MARK: - XHamster

    func testXHamsterCardUsesLazyThumbAndViewCount() {
        let html = #"""
        <div class="thumb-item" data-video-id="555"><a href="/videos/sample-555" data-role="thumb-link"><img data-role="thumb-preview-img" data-thumb-url="https://xh.example/t.jpg" src="data:image/gif;base64,R0lGOD" alt="Sample"></a><div data-role="video-duration">03:10</div><div class="video-thumb-views">2.5K</div></div>
        """#
        let posts = XHamsterSource.parseListing(html: html)
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.id, "xh_555")
        XCTAssertEqual(post.previewURL?.absoluteString, "https://xh.example/t.jpg")
        XCTAssertEqual(post.title, "Sample")
        XCTAssertEqual(post.score, 2500)
        XCTAssertEqual(post.tags.general, ["duration:03:10"])
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://xhamster.com/videos/sample-555")
        XCTAssertNil(post.previewVideoURL)
    }

    func testXHamsterRewritesAV1PreviewToH264AndPicksLargestSrcset() {
        let html = #"""
        <div data-video-id="12345"><a data-role="thumb-link" href="/videos/test-12345" data-previewvideo="https://xhcdn.example/video_TPL_.av1.mp4&amp;token=abc"><img data-role="thumb-preview-img" srcset="https://xhcdn.example/thumb_240.jpg 240w, https://xhcdn.example/thumb_526.jpg 526w" src="https://xhcdn.example/thumb_240.jpg" alt="Sample" /></a><div data-role="video-duration">12:34</div></div>
        """#
        let post = XHamsterSource.parseListing(html: html).first
        XCTAssertEqual(post?.previewVideoURL?.absoluteString, "https://xhcdn.example/video_TPL_.h264.mp4&token=abc")
        XCTAssertEqual(post?.previewURL?.absoluteString, "https://xhcdn.example/thumb_526.jpg")
        XCTAssertNil(post?.previewThumbs)
    }

    func testXHamsterInitialsJSONSuppliesTitleAndThumb() {
        let html = #"""
        <script id="initials-script">window.initials={"videoList":[{"id":555,"thumbURL":"https://xh.example/j.jpg","title":"From JSON"}]};</script>
        <div class="thumb-item" data-video-id="555"><a href="/videos/json-555" data-role="thumb-link"></a><div data-role="video-duration">01:00</div></div>
        """#
        let post = XHamsterSource.parseListing(html: html).first
        XCTAssertEqual(post?.title, "From JSON")
        XCTAssertEqual(post?.previewURL?.absoluteString, "https://xh.example/j.jpg")
    }

    func testXHamsterCandidateURLs() {
        XCTAssertEqual(
            XHamsterSource.candidateURLs(page: 2, keyword: "", sort: .views, date: .weekly),
            ["https://xhamster.com/best/weekly/2", "https://xhamster.com/best/weekly?page=2"]
        )
        XCTAssertEqual(
            XHamsterSource.candidateURLs(page: 1, keyword: "red hair", sort: .views, date: nil),
            [
                "https://xhamster.com/search/red%20hair?sort=views",
                "https://xhamster.com/search?q=red%20hair&sort=views",
                "https://xhamster.com/search/red%20hair",
                "https://xhamster.com/search?q=red%20hair",
            ]
        )
    }

    func testXHamsterDetailInitialsSupplyTheHighMP4() async throws {
        let card = #"<div data-video-id="12345"><a data-role="thumb-link" href="/videos/test-12345"><img data-role="thumb-preview-img" src="https://xhcdn.example/thumb.jpg" alt="Sample" /></a></div>"#
        let post = try XCTUnwrap(XHamsterSource.parseListing(html: card).first)
        let detail = #"""
        <script id="initials-script">window.initials={"xplayerSettings":{"sources":{"hls":{"h264":{"url":"https://xhcdn.example/hls/_TPL_.h264.mp4.m3u8"}},"standard":{"h264":[{"url":"https://xhcdn.example/480p.h264.mp4","quality":"480"},{"url":"https://xhcdn.example/720p.h264.mp4","quality":720}]}}}}</script>
        """#
        let client = StubHTTPClient(body: detail, status: 200, expectedFragment: "xhamster.com/videos/test-12345")
        let media = try await XHamsterSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://xhcdn.example/720p.h264.mp4")
        XCTAssertTrue(media.isVideo)
    }

    func testXHamsterDetailRewritesAV1HLSAndFallsBackToTheTrailer() async throws {
        let av1Only = #"""
        <script id="initials-script">window.initials={"xplayerSettings":{"sources":{"hls":{"av1":{"url":"https://xhcdn.example/hls/_TPL_.av1.mp4.m3u8?token=1"}}}}}</script>
        """#
        let av1Files = XHamsterSource.parseDetailFiles(html: av1Only)
        XCTAssertEqual(av1Files.high, "")
        XCTAssertEqual(av1Files.hls, "https://xhcdn.example/hls/_TPL_.h264.mp4.m3u8?token=1")

        // A detail page without any source keeps the card's trailer mp4.
        let card = #"<div data-video-id="777"><a data-role="thumb-link" href="/videos/trailer-777" data-previewvideo="https://xhcdn.example/trailer.mp4"><img data-role="thumb-preview-img" src="https://xhcdn.example/t.jpg" alt="Sample" /></a></div>"#
        let post = try XCTUnwrap(XHamsterSource.parseListing(html: card).first)
        let client = StubHTTPClient(body: "<html><body>no player</body></html>", status: 200, expectedFragment: "xhamster.com/videos/trailer-777")
        let media = try await XHamsterSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://xhcdn.example/trailer.mp4")
    }

    // MARK: - Sex.com

    func testSexComCardParsesFieldsAndCounts() {
        let html = #"""
        <div data-testid="video-card" data-analytics-video_id="1040312" data-premium="0"><div data-title="Sample Walk"><a href="/en/videos/1040312-sample-walk"><img src="https://images.sxccdn.com/videos/1040312/288/thumbnail.0000012.jpg.webp" alt="Sample Walk"></a><video src="https://videos.example/1040312/preview_240p.mp4"></video><time>10:01</time><a data-testid="video-link-to-source-channel" href="/channel/x">Channel X</a><span data-testid="view-count"><span>2.4K</span></span><span>98%</span></div></div>
        """#
        let posts = SexComSource.parseListing(html: html)
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.id, "sx_1040312")
        XCTAssertEqual(post.title, "Sample Walk")
        XCTAssertEqual(post.previewURL?.absoluteString, "https://images.sxccdn.com/videos/1040312/288/thumbnail.0000012.jpg.webp")
        XCTAssertEqual(post.previewVideoURL?.absoluteString, "https://videos.example/1040312/preview_240p.mp4")
        XCTAssertEqual(post.score, 2400)
        XCTAssertEqual(post.tags.artist, ["Channel X"])
        XCTAssertEqual(post.tags.general, ["duration:10:01", "views:2.4K", "rating:98%"])
        XCTAssertEqual(post.isPremium, false)
        XCTAssertEqual(post.sourceLink?.absoluteString, "https://www.sex.com/en/videos/1040312-sample-walk")
    }

    func testSexComExcludesPremiumCardsFromTheList() {
        let html = #"<div data-testid="video-card" data-analytics-video_id="999" data-premium="1"><div data-title="Locked"><a href="/en/videos/999-locked"></a><video src="https://videos.example/999/preview_240p.mp4"></video></div></div>"#
        let parsed = SexComSource.parseListing(html: html)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.isPremium, true)
        XCTAssertTrue(SexComSource.excludingPremium(parsed).isEmpty)
    }

    func testSexComSearchURLs() {
        XCTAssertEqual(SexComSource.searchURL(page: 1, keyword: ""), "https://www.sex.com/en/videos")
        XCTAssertEqual(SexComSource.searchURL(page: 3, keyword: ""), "https://www.sex.com/en/videos?page=3")
        XCTAssertEqual(SexComSource.searchURL(page: 1, keyword: "beach walk"), "https://www.sex.com/en/videos?search=beach%20walk")
        XCTAssertEqual(SexComSource.searchURL(page: 4, keyword: "beach"), "https://www.sex.com/en/videos?page=4&search=beach")
    }

    func testSexComFetchPostsDropsPremiumButKeepsPaging() async throws {
        let free = #"<div data-testid="video-card" data-analytics-video_id="1" data-premium="0"><div data-title="Free"><a href="/en/videos/1-free"></a><video src="https://videos.example/1/p.mp4"></video></div></div>"#
        let locked = #"<div data-testid="video-card" data-analytics-video_id="2" data-premium="1"><div data-title="Locked"><a href="/en/videos/2-locked"></a><video src="https://videos.example/2/p.mp4"></video></div></div>"#
        let client = StubHTTPClient(body: free + locked, status: 200, expectedFragment: "sex.com/en/videos?page=2")
        let page = try await SexComSource().fetchPosts(
            query: SearchQuery(tags: "", filter: SearchFilterConfig()),
            page: 2,
            context: makeContext(client: client)
        )
        XCTAssertEqual(page.posts.map(\.id), ["sx_1"])
        XCTAssertEqual(page.nextPage, 3)
        XCTAssertTrue(page.hasMore)
    }

    func testSexComPremiumOnlyPageReportsNoMorePosts() async throws {
        let locked = #"<div data-testid="video-card" data-analytics-video_id="2" data-premium="1"><div data-title="Locked"><a href="/en/videos/2-locked"></a><video src="https://videos.example/2/p.mp4"></video></div></div>"#
        let client = StubHTTPClient(body: locked, status: 200, expectedFragment: "sex.com/en/videos")
        let page = try await SexComSource().fetchPosts(
            query: SearchQuery(tags: "", filter: SearchFilterConfig()),
            page: 1,
            context: makeContext(client: client)
        )
        XCTAssertTrue(page.posts.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testSexComDetailJSONLDSuppliesTheHLSStream() async throws {
        let card = Self.sexComCard(id: "1040312")
        let post = try XCTUnwrap(SexComSource.parseListing(html: card).first)
        let detail = #"""
        <script type="application/ld+json">{"contentUrl":"https://videos.example/1040312/master.m3u8?token=abc","thumbnailUrl":"https://images.sxccdn.com/videos/1040312/poster.webp"}</script>
        """#
        let client = StubHTTPClient(body: detail, status: 200, expectedFragment: "sex.com/en/videos/1040312-sample")
        let media = try await SexComSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://videos.example/1040312/master.m3u8?token=abc")
        XCTAssertTrue(media.isVideo)
    }

    func testSexComPremiumDetailFallsBackToThePreviewClip() async throws {
        let post = try XCTUnwrap(SexComSource.parseListing(html: Self.sexComCard(id: "1040312")).first)
        let detail = #"""
        <script type="application/ld+json">{"contentUrl":"https://premium-cdn.example/1040312/master.m3u8"}</script>
        """#
        let files = SexComSource.parseDetailFiles(html: detail)
        XCTAssertTrue(files.premium)
        XCTAssertNil(SexComSource.playableURL(from: files))

        let client = StubHTTPClient(body: detail, status: 200, expectedFragment: "sex.com/en/videos/1040312-sample")
        let media = try await SexComSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://videos.example/1040312/preview_240p.mp4")
    }

    func testSexComDetailFetchFailureKeepsThePreviewClip() async throws {
        let post = try XCTUnwrap(SexComSource.parseListing(html: Self.sexComCard(id: "1040312")).first)
        let client = StubHTTPClient(body: "", status: 500, expectedFragment: "sex.com/en/videos/1040312-sample")
        let media = try await SexComSource().resolveMedia(for: post, context: makeContext(client: client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://videos.example/1040312/preview_240p.mp4")
    }

    /// One Sex.com card with a cover image and a preview clip, so the listing accepts it.
    private static func sexComCard(id: String) -> String {
        #"<div data-testid="video-card" data-analytics-video_id="\#(id)" data-premium="0"><div data-title="Sample"><a href="/en/videos/\#(id)-sample"><img src="https://images.sxccdn.com/videos/\#(id)/288/thumbnail.0000012.jpg.webp" alt="Sample"></a><video src="https://videos.example/\#(id)/preview_240p.mp4"></video></div></div>"#
    }

    // MARK: - Tag suggestions

    func testNonRealbooruSourcesReturnNoTagSuggestions() async throws {
        let client = StubHTTPClient(body: "", status: 200, expectedFragment: "unused")
        let context = makeContext(client: client)
        let xvideos = try await XVideosSource().tagSuggestions(prefix: "red", context: context)
        let xhamster = try await XHamsterSource().tagSuggestions(prefix: "red", context: context)
        let sexcom = try await SexComSource().tagSuggestions(prefix: "red", context: context)
        XCTAssertTrue(xvideos.isEmpty)
        XCTAssertTrue(xhamster.isEmpty)
        XCTAssertTrue(sexcom.isEmpty)
    }
}
