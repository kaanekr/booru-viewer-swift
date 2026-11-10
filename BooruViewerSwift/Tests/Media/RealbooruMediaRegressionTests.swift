import XCTest
@testable import BooruViewer

/// Regression fixtures for the Realbooru media pipeline: `//images/` path resolution,
/// detail-page file discovery, and the rule that only a server-confirmed `.mp4` sibling
/// may replace a WebM URL.
///
/// Everything is synthetic and offline: the HTML is written inline and the only transport
/// is a stub that records requests and answers a canned status per URL. No test touches the
/// network, and none of the URLs here is claimed to be live.
final class RealbooruMediaRegressionTests: XCTestCase {

    // MARK: - Fixtures

    /// The exact original path shape the user supplied as data, kept verbatim: leading
    /// double slash on the path, nested hash folders, a real `.webm` container. This is a
    /// shape fixture only — the tests never fetch or display the media.
    private static let userReportedPath = "https://realbooru.com//images/25/a2/25a25a1c2c446e23e77588b415ea3192.webm"
    private static let userReportedHash = "25a25a1c2c446e23e77588b415ea3192"

    /// Routes by URL substring and records every request. `HEAD` bodies are empty.
    private actor RouteStubHTTPClient: HTTPClientProtocol {
        struct Rule {
            let match: String
            let status: Int
            let body: String

            init(match: String, status: Int = 200, body: String = "") {
                self.match = match
                self.status = status
                self.body = body
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
                throw BooruError.network("missing URL in regression test")
            }
            let matched = rules.first { url.absoluteString.contains($0.match) }
            let status = matched?.status ?? 404
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            ) else {
                throw BooruError.network("no response in regression test")
            }
            let body = request.httpMethod == "HEAD" ? "" : (matched?.body ?? "")
            return (Data(body.utf8), response)
        }

        func recordedRequests() -> [URLRequest] { requests }
    }

    private func context(_ client: any HTTPClientProtocol) -> SourceContext {
        SourceContext(http: client, proxy: ProxyConfig(), gelbooruAuth: nil, rule34Auth: nil, imageQuality: .auto)
    }

    /// One listing card whose thumbnail hash is `hash`, tagged with `title`.
    private func card(id: String, hash: String, title: String) -> String {
        let dir1 = String(hash.prefix(2))
        let dir2 = String(hash.dropFirst(2).prefix(2))
        return #"""
        <div class="col thumb" id="s\#(id)"><a id="p\#(id)" href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=\#(id)"><img src="https://realbooru.com/thumbnails/\#(dir1)/\#(dir2)/thumbnail_\#(hash).jpg" title="\#(title)" alt="Image: \#(id)" /></a></div>
        """#
    }

    /// A parsed listing post; the helper name never shadows a local `post` binding.
    private func makePost(id: String, hash: String, title: String) throws -> BooruPost {
        try XCTUnwrap(RealbooruSource.parseListing(html: card(id: id, hash: hash, title: title)).first)
    }

    // MARK: - Path resolution (acceptance 1)

    func testUserReportedDoubleSlashPathRoundTripsExactly() {
        // An already absolute URL must come back byte-for-byte: the path's intentional
        // double slash belongs to what the server wrote and is not collapsed.
        XCTAssertEqual(RealbooruSource.normalizeFileURL(Self.userReportedPath), Self.userReportedPath)
        let url = HTMLScanner.absoluteURL(Self.userReportedPath, base: RealbooruSource.baseURL)
        XCTAssertEqual(url?.absoluteString, Self.userReportedPath)
        XCTAssertEqual(url?.host, "realbooru.com", "the path's `//` must not become an external `images` host")
        XCTAssertTrue(url?.path.hasSuffix("/images/25/a2/\(Self.userReportedHash).webm") ?? false)
    }

    func testSameOriginDoubleSlashPathResolvesToRealbooruNotToAnImagesHost() {
        // `//images/…` is a same-origin path prefix, not a protocol-relative host.
        XCTAssertEqual(
            RealbooruSource.normalizeFileURL("//images/25/a2/\(Self.userReportedHash).webm"),
            "https://realbooru.com//images/25/a2/\(Self.userReportedHash).webm"
        )
        // Nested hash folders survive untouched.
        XCTAssertTrue(
            RealbooruSource
                .normalizeFileURL("//images/25/a2/\(Self.userReportedHash).webm")
                .hasSuffix("/images/25/a2/\(Self.userReportedHash).webm")
        )
        // A single-slash same-origin path is preserved as written.
        XCTAssertEqual(
            RealbooruSource.normalizeFileURL("/images/25/a2/x.webm"),
            "/images/25/a2/x.webm"
        )
        let resolved = HTMLScanner.absoluteURL("/images/25/a2/x.webm", base: RealbooruSource.baseURL)
        XCTAssertEqual(resolved?.absoluteString, "https://realbooru.com/images/25/a2/x.webm")
        XCTAssertEqual(resolved?.host, "realbooru.com")
    }

    func testGenuineProtocolRelativeHostKeepsItsOwnHost() {
        // A real CDN host is not one of the same-origin path roots, so it stays external.
        XCTAssertEqual(
            RealbooruSource.normalizeFileURL("//cdn.example.com/v/1.webm"),
            "https://cdn.example.com/v/1.webm"
        )
        XCTAssertEqual(
            RealbooruSource.normalizeFileURL("//media.example.org/images/1.jpg"),
            "https://media.example.org/images/1.jpg"
        )
        // Entities are decoded once, on both shapes.
        XCTAssertEqual(
            RealbooruSource.normalizeFileURL("https://realbooru.com//images/a/b/f.webm?x=1&amp;y=2"),
            "https://realbooru.com//images/a/b/f.webm?x=1&y=2"
        )
        XCTAssertEqual(RealbooruSource.normalizeFileURL(""), "")
    }

    // MARK: - Detail parsing (acceptance 2)

    func testDetailSourceTagsParseInBothQuoteStyles() {
        let doubleQuoted = #"""
        <video controls loop id="gelcomVideoPlayer">
          <source src="https://realbooru.com//images/25/a2/\#(Self.userReportedHash).mp4" type="video/mp4" />
          <source src="https://realbooru.com//images/25/a2/\#(Self.userReportedHash).webm" type="video/webm" />
        </video>
        """#
        let doubleFiles = RealbooruSource.parseDetailFiles(html: doubleQuoted)
        XCTAssertEqual(doubleFiles.mp4, "https://realbooru.com//images/25/a2/\(Self.userReportedHash).mp4")
        XCTAssertEqual(doubleFiles.webm, "https://realbooru.com//images/25/a2/\(Self.userReportedHash).webm")
        XCTAssertEqual(doubleFiles.image, "")

        let singleQuoted = "<video><source src='//images/25/a2/x.webm' type='video/webm'></video>"
        let singleFiles = RealbooruSource.parseDetailFiles(html: singleQuoted)
        XCTAssertEqual(singleFiles.mp4, "")
        XCTAssertEqual(singleFiles.webm, "https://realbooru.com//images/25/a2/x.webm")
    }

    func testDetailVideoElementAndRelativePathsResolve() {
        // Some markup puts the file on the `<video>` element itself.
        XCTAssertEqual(
            RealbooruSource.parseDetailFiles(html: #"<video src="/images/ab/cd/hash.webm"></video>"#).webm,
            "/images/ab/cd/hash.webm"
        )
        // A bare relative `images/…` path is the same tree.
        XCTAssertEqual(
            RealbooruSource.parseDetailFiles(html: #"<video><source src="images/ab/cd/hash.mp4"></video>"#).mp4,
            "images/ab/cd/hash.mp4"
        )
        // HTML entities in a path are decoded once; the query survives verbatim.
        XCTAssertEqual(
            RealbooruSource
                .parseDetailFiles(html: #"<video><source src='https://realbooru.com//images/a/b/f.mp4?x=1&amp;y=2'></video>"#)
                .mp4,
            "https://realbooru.com//images/a/b/f.mp4?x=1&y=2"
        )
    }

    func testDetailOriginalLinksAreReadAndThumbnailsAreNot() {
        // Gelbooru-engine pages link the file itself; only `/images/` media paths count.
        let html = #"""
        <div class="content">
          <a href="https://realbooru.com/index.php?page=post&amp;s=view&amp;id=42">Post</a>
          <a href="https://realbooru.com//images/65/d6/65d6d5876940b6a44981c2a014963d34.gif">Original image</a>
        </div>
        """#
        let files = RealbooruSource.parseDetailFiles(html: html)
        XCTAssertEqual(files.image, "https://realbooru.com//images/65/d6/65d6d5876940b6a44981c2a014963d34.gif")
        XCTAssertEqual(files.mp4, "")
        XCTAssertEqual(files.webm, "")

        // A thumbnail is a listing artifact, never the original.
        let thumbOnly = #"<img src="https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg" />"#
        XCTAssertEqual(RealbooruSource.parseDetailFiles(html: thumbOnly).image, "")
    }

    func testDetailStillFallbackKeepsAGifPostOffTheVideoPath() {
        let html = #"<div class="content"><img alt="gif" src="https://realbooru.com//images/65/d6/65d6d5876940b6a44981c2a014963d34.gif" /></div>"#
        let files = RealbooruSource.parseDetailFiles(html: html)
        XCTAssertEqual(files.image, "https://realbooru.com//images/65/d6/65d6d5876940b6a44981c2a014963d34.gif")
        XCTAssertEqual(files.mp4, "")
        XCTAssertEqual(files.webm, "")
    }

    func testActualWebMIsDetectedEvenWhenTheListingSaidMp4() async throws {
        // A legacy card once reached the app as `fileExt: mp4` with an `.mp4` guess. The
        // detail page's real `.webm` wins, and no `.mp4` is invented from the guess.
        var legacy = try makePost(id: "77", hash: "abcd42", title: "video, animated, solo")
        legacy.fileExt = "mp4"
        legacy.sampleURL = URL(string: "https://realbooru.com/images/ab/cd/abcd42.mp4")
        legacy.originalURL = URL(string: "https://realbooru.com/images/ab/cd/abcd42.mp4")

        let detail = #"<video><source src="https://realbooru.com//images/ab/cd/abcd42.webm" type="video/webm" /></video>"#
        let client = RouteStubHTTPClient(rules: [.init(match: "realbooru.com/index.php", body: detail)])
        let media = try await RealbooruSource().resolveMedia(for: legacy, context: context(client))

        XCTAssertTrue(
            media.videoURL?.absoluteString.hasSuffix("/images/ab/cd/abcd42.webm") ?? false,
            "the detail page's real .webm must win over the listing's .mp4 guess"
        )
        XCTAssertTrue(media.isVideo)
        // The still is the card's thumbnail, never the video container.
        XCTAssertEqual(media.imageURL?.absoluteString, "https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd42.jpg")
    }

    func testDetailPageMp4WinsAndWebmIsPreservedForTheOtherFields() async throws {
        let parsedPost = try makePost(id: "78", hash: "abcd43", title: "video, webm")
        let detail = #"""
        <video><source src="https://realbooru.com//images/ab/cd/abcd43.mp4" type="video/mp4" />
        <source src="https://realbooru.com//images/ab/cd/abcd43.webm" type="video/webm" /></video>
        """#
        let client = RouteStubHTTPClient(rules: [.init(match: "realbooru.com/index.php", body: detail)])
        let media = try await RealbooruSource().resolveMedia(for: parsedPost, context: context(client))
        XCTAssertEqual(media.videoURL?.absoluteString, "https://realbooru.com//images/ab/cd/abcd43.mp4")

        // Both files stay available to the layer that names the post's metadata.
        let files = RealbooruSource.parseDetailFiles(html: detail)
        XCTAssertEqual(files.mp4, "https://realbooru.com//images/ab/cd/abcd43.mp4")
        XCTAssertEqual(files.webm, "https://realbooru.com//images/ab/cd/abcd43.webm")
    }

    // MARK: - Viewer WebM → MP4 rule (acceptance 3)

    func testMp4ProbeAcceptsOnlyAServerConfirmedSibling() async throws {
        let webm = try XCTUnwrap(URL(string: "https://realbooru.com//images/ab/cd/abcd42.webm"))

        let ok = await ViewerViewModel.mp4URL(for: webm, http: RouteStubHTTPClient(rules: [.init(match: ".mp4")]))
        XCTAssertEqual(ok?.absoluteString, "https://realbooru.com//images/ab/cd/abcd42.mp4")

        let notFound = await ViewerViewModel.mp4URL(for: webm, http: RouteStubHTTPClient(rules: [.init(match: ".mp4", status: 404)]))
        XCTAssertNil(notFound, "404 is not proof of an alternative")

        let forbidden = await ViewerViewModel.mp4URL(for: webm, http: RouteStubHTTPClient(rules: [.init(match: ".mp4", status: 403)]))
        XCTAssertNil(forbidden, "403 is not proof of an alternative")

        let offline = await ViewerViewModel.mp4URL(for: webm, http: ThrowingProbeClient())
        XCTAssertNil(offline, "a transport failure is not proof of an alternative")
    }

    @MainActor
    func testVerifiedSiblingIsPlayedAndTheProbeIsAHead() async throws {
        let post = try makePost(id: "42", hash: "abcd42", title: "video, webm, sound")
        XCTAssertEqual(post.fileExt, "webm")
        XCTAssertEqual(post.originalURL?.absoluteString, "https://realbooru.com/images/ab/cd/abcd42.webm")

        // No detail page (404), but the server confirms the `.mp4` sibling (HEAD 200).
        let client = RouteStubHTTPClient(rules: [.init(match: ".mp4", status: 200)])
        let media = try await loadedMedia(post, client: client)

        XCTAssertEqual(media.videoURL?.absoluteString, "https://realbooru.com/images/ab/cd/abcd42.mp4")
        XCTAssertTrue(media.isVideo)
        let requests = await client.recordedRequests()
        let mp4Probes = requests.filter { $0.url?.absoluteString.hasSuffix(".mp4") == true }
        XCTAssertEqual(mp4Probes.map(\.httpMethod), ["HEAD"])
    }

    @MainActor
    func testRejectedHeadLeavesNoGuessedMp4AndShowsTheCover() async throws {
        let post = try makePost(id: "43", hash: "abcd43", title: "video, webm, sound")

        let client = RouteStubHTTPClient(rules: [.init(match: ".mp4", status: 404)])
        let media = try await loadedMedia(post, client: client)

        XCTAssertNil(media.videoURL, "a rejected HEAD must not surface a guessed .mp4")
        XCTAssertFalse(media.isVideo)
        // The page still shows the post's cover instead of a dead player.
        XCTAssertEqual(media.imageURL?.absoluteString, "https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd43.jpg")
    }

    @MainActor
    func testCancelledSourceCachesNoFallback() async throws {
        let post = try makePost(id: "45", hash: "abcd45", title: "video, webm")
        let client = RouteStubHTTPClient(rules: [.init(match: ".mp4", status: 200)])
        let viewModel = ViewerViewModel(
            posts: [post],
            context: context(client),
            sourceProvider: { _ in CancellingSource() }
        )
        await viewModel.loadMedia(for: post)

        XCTAssertNil(
            viewModel.media(for: post),
            "a cancelled load must leave the post uncached so it retries instead of showing a fallback"
        )
    }

    @MainActor
    func testFallbackMediaNeverPlaysAnUnverifiedRealbooruHashGuess() throws {
        let post = try makePost(id: "46", hash: "abcd46", title: "video, webm")
        // The listing's own `/images/<hash>.webm` is a thumbnail-hash derivation, so the pure
        // fallback (no detail page read, no probe) must not offer it as video.
        XCTAssertTrue(RealbooruSource.isThumbnailHashGuess(post.originalURL, for: post))

        let media = ViewerViewModel.fallbackMedia(for: post, quality: .auto)
        XCTAssertNil(media.videoURL)
        XCTAssertFalse(media.isVideo)
        XCTAssertEqual(media.imageURL?.absoluteString, "https://realbooru.com/thumbnails/ab/cd/thumbnail_abcd46.jpg")
    }

    // MARK: - Driven load helper

    /// Runs the real `ViewerViewModel.loadMedia` path for `post` with the real Realbooru
    /// source and returns the cached result.
    @MainActor
    private func loadedMedia(_ post: BooruPost, client: RouteStubHTTPClient) async throws -> ResolvedMedia {
        let viewModel = ViewerViewModel(
            posts: [post],
            context: context(client),
            sourceProvider: { _ in RealbooruSource() }
        )
        await viewModel.loadMedia(for: post)
        return try XCTUnwrap(viewModel.media(for: post), "viewer cached no media for the post")
    }
}

/// Source whose resolution is cancelled, so `loadMedia` must not cache anything.
private struct CancellingSource: BooruSource {
    let id: SourceID = .realbooru
    var displayName: String { "Realbooru" }
    var supportsVideo: Bool { true }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        PostPage(posts: [], nextPage: nil, hasMore: false)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] { [] }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        throw CancellationError()
    }
}

/// Transport double that always fails, standing in for a timeout or an offline probe.
private struct ThrowingProbeClient: HTTPClientProtocol {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut)
    }
}
