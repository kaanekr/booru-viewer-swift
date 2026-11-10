import Foundation
import XCTest
@testable import BooruViewer

/// Pure media-selection rules (Sources/Media). No real network: the only async path
/// (`MP4Upgrade.upgradedURL`) is exercised through `FakeHTTPClient`.
final class MediaTests: XCTestCase {
    // MARK: - Fixtures

    private func makePost(
        id: String = "1",
        sourceID: SourceID = .gelbooru,
        previewURL: String? = nil,
        previewVideoURL: String? = nil,
        previewThumbURL: String? = nil,
        previewThumbs: [String]? = nil,
        sampleURL: String? = nil,
        originalURL: String? = nil,
        fileExt: String? = nil,
        generalTags: [String] = []
    ) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: "Example",
            title: nil,
            previewURL: previewURL.flatMap { URL(string: $0) },
            previewFallbackURL: nil,
            previewVideoURL: previewVideoURL.flatMap { URL(string: $0) },
            previewThumbURL: previewThumbURL.flatMap { URL(string: $0) },
            previewThumbs: previewThumbs?.compactMap { URL(string: $0) },
            sampleURL: sampleURL.flatMap { URL(string: $0) },
            originalURL: originalURL.flatMap { URL(string: $0) },
            width: 100,
            height: 100,
            aspectRatio: 1.0,
            rating: .general,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(artist: [], character: [], copyright: [], general: generalTags, meta: []),
            allTags: generalTags,
            sourceLink: nil,
            fileExt: fileExt,
            fileSize: nil,
            createdAt: "2026-01-01T00:00:00Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: - MediaURLNormalizer (src/utils/media.ts:175-204)

    func testNormalizeRewritesGelbooruCDNHostsToImg4() {
        // media.ts:190-196: img1/img2/img3/samples/thumbnails and the apex all move to img4.
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "https://img1.gelbooru.com/images/ab/cd/file.jpg"))?.absoluteString,
            "https://img4.gelbooru.com/images/ab/cd/file.jpg"
        )
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "http://img2.gelbooru.com/samples/ab/cd/file.jpg"))?.absoluteString,
            "https://img4.gelbooru.com/samples/ab/cd/file.jpg"
        )
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "https://gelbooru.com/thumbnails/ab/thumb.jpg"))?.absoluteString,
            "https://img4.gelbooru.com/thumbnails/ab/thumb.jpg"
        )
    }

    func testNormalizeUpgradesPlainHTTPOutsideGelbooru() {
        // media.ts:194-195: only the scheme changes; host and path stay.
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "http://example.com/p/1/original.jpg"))?.absoluteString,
            "https://example.com/p/1/original.jpg"
        )
        XCTAssertNil(MediaURLNormalizer.normalize(nil))
    }

    func testNormalizeRewritesXHamsterAV1Renditions() {
        // media.ts:198-201: AVPlayer cannot decode AV1.
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "https://cdnt-stream.xhcdn.com/a/clip.av1.mp4"))?.absoluteString,
            "https://cdnt-stream.xhcdn.com/a/clip.h264.mp4"
        )
        XCTAssertEqual(
            MediaURLNormalizer.normalize(URL(string: "https://xhamster.com/v/clip.av1.webm"))?.absoluteString,
            "https://xhamster.com/v/clip.h264.webm"
        )
    }

    func testImageURLAppliesMediaNormalization() {
        // ImageQualityResolver runs every field through normalizeBooruMediaUrl.
        let post = makePost(
            sampleURL: "https://img3.gelbooru.com/samples/ab/cd/sample.jpg",
            originalURL: "http://img2.gelbooru.com/images/ab/cd/original.jpg"
        )

        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .preview)?.absoluteString,
                       "https://img4.gelbooru.com/samples/ab/cd/sample.jpg")
        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .full)?.absoluteString,
                       "https://img4.gelbooru.com/images/ab/cd/original.jpg")
    }

    // MARK: - ImageQualityResolver (src/utils/media.ts:133-170)

    func testImageURLPreviewAndAutoUseSampleChain() {
        let post = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            sampleURL: "https://example.com/p/1/sample.jpg",
            originalURL: "https://example.com/p/1/original.jpg"
        )

        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .preview)?.absoluteString,
                       "https://example.com/p/1/sample.jpg")
        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .auto)?.absoluteString,
                       "https://example.com/p/1/sample.jpg")
    }

    func testImageURLFullUsesOriginal() {
        let post = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            sampleURL: "https://example.com/p/1/sample.jpg",
            originalURL: "https://example.com/p/1/original.jpg"
        )

        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .full)?.absoluteString,
                       "https://example.com/p/1/original.jpg")
    }

    func testImageURLFallsBackWhenSampleMissing() {
        // media.ts:148 sample = sampleUrl || originalUrl || previewUrl.
        let post = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            originalURL: "https://example.com/p/1/original.jpg"
        )

        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .preview)?.absoluteString,
                       "https://example.com/p/1/original.jpg")
        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .auto)?.absoluteString,
                       "https://example.com/p/1/original.jpg")
        XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: .full)?.absoluteString,
                       "https://example.com/p/1/original.jpg")
    }

    func testImageURLFallsBackToPreviewWhenNothingElseExists() {
        let post = makePost(previewURL: "https://example.com/p/1/preview.jpg")

        for quality in ImageQuality.allCases {
            XCTAssertEqual(ImageQualityResolver.imageURL(for: post, quality: quality)?.absoluteString,
                           "https://example.com/p/1/preview.jpg")
        }
    }

    func testImageURLIsNilForEvidenceFreePost() {
        let post = makePost()

        for quality in ImageQuality.allCases {
            XCTAssertNil(ImageQualityResolver.imageURL(for: post, quality: quality))
        }
        XCTAssertNil(ImageQualityResolver.placeholderURL(for: post))
    }

    func testPlaceholderPrefersPreviewThenSample() {
        // media.ts:161 placeholder = preview || sample.
        let withPreview = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            sampleURL: "https://example.com/p/1/sample.jpg"
        )
        XCTAssertEqual(ImageQualityResolver.placeholderURL(for: withPreview)?.absoluteString,
                       "https://example.com/p/1/preview.jpg")

        let withoutPreview = makePost(
            sampleURL: "https://example.com/p/1/sample.jpg",
            originalURL: "https://example.com/p/1/original.jpg"
        )
        XCTAssertEqual(ImageQualityResolver.placeholderURL(for: withoutPreview)?.absoluteString,
                       "https://example.com/p/1/sample.jpg")

        let originalOnly = makePost(originalURL: "https://example.com/p/1/original.jpg")
        XCTAssertEqual(ImageQualityResolver.placeholderURL(for: originalOnly)?.absoluteString,
                       "https://example.com/p/1/original.jpg")
    }

    // MARK: - VideoCandidateSelector (src/utils/media.ts:649-698)

    func testVideoCandidatesKeepMp4AndPreserveRNOrder() {
        // media.ts:655-656 pushes sampleUrl first, then originalUrl.
        let post = makePost(
            sampleURL: "https://example.com/v/sample.mp4",
            originalURL: "https://example.com/v/original.mp4"
        )

        XCTAssertEqual(VideoCandidateSelector.videoCandidates(for: post).map(\.absoluteString),
                       ["https://example.com/v/sample.mp4", "https://example.com/v/original.mp4"])
    }

    func testVideoCandidatesDropWebM() {
        // media.ts:364-374: AVPlayer cannot open WebM.
        let post = makePost(
            sampleURL: "https://example.com/v/clip.webm",
            originalURL: "https://example.com/v/clip.mp4"
        )

        XCTAssertEqual(VideoCandidateSelector.videoCandidates(for: post).map(\.absoluteString),
                       ["https://example.com/v/clip.mp4"])

        let webmOnly = makePost(originalURL: "https://example.com/v/clip.webm?token=abc")
        XCTAssertTrue(VideoCandidateSelector.videoCandidates(for: webmOnly).isEmpty)
    }

    func testVideoCandidatesDropAV1Renditions() {
        let post = makePost(originalURL: "https://example.com/v/clip.av1.mp4")

        XCTAssertTrue(VideoCandidateSelector.videoCandidates(for: post).isEmpty)
    }

    func testVideoCandidatesKeepXHamsterAV1AfterNormalization() {
        // media.ts:199-201 rewrites `.av1.` to `.h264.` before the iOS AV1 filter runs, so
        // the XHamster rendition is playable instead of being dropped (F3).
        let post = makePost(
            sampleURL: "https://cdnt-stream.xhcdn.com/a/sample.av1.mp4",
            originalURL: "https://cdnt-stream.xhcdn.com/a/original.av1.mp4"
        )

        XCTAssertEqual(VideoCandidateSelector.videoCandidates(for: post).map(\.absoluteString),
                       ["https://cdnt-stream.xhcdn.com/a/sample.h264.mp4",
                        "https://cdnt-stream.xhcdn.com/a/original.h264.mp4"])
    }

    func testVideoCandidatesExcludeImagesAndRankHLSBelowMP4() {
        // media.ts:670-697: images out, mp4/mov/m4v > m3u8.
        let post = makePost(
            sampleURL: "https://example.com/v/stream.m3u8",
            originalURL: "https://example.com/v/clip.mp4"
        )
        XCTAssertEqual(VideoCandidateSelector.videoCandidates(for: post).map(\.absoluteString),
                       ["https://example.com/v/clip.mp4", "https://example.com/v/stream.m3u8"])

        let imagePost = makePost(
            previewURL: "https://example.com/p/preview.jpg",
            sampleURL: "https://example.com/p/sample.png",
            originalURL: "https://example.com/p/original.jpg"
        )
        XCTAssertTrue(VideoCandidateSelector.videoCandidates(for: imagePost).isEmpty)
    }

    func testVideoCandidatesDedupeAndIgnoreQueryForExtensionChecks() {
        let post = makePost(
            sampleURL: "https://example.com/v/clip.mp4?t=5",
            originalURL: "https://example.com/v/clip.mp4?t=5"
        )

        XCTAssertEqual(VideoCandidateSelector.videoCandidates(for: post).count, 1)
    }

    func testVideoCandidatesEmptyWithoutVideoFields() {
        XCTAssertTrue(VideoCandidateSelector.videoCandidates(for: makePost()).isEmpty)
    }

    // MARK: - MP4Upgrade URL derivation (src/utils/media.ts:725-736)

    func testMp4CandidateURLRewritesWebMExtension() throws {
        let webm = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm"))

        XCTAssertEqual(MP4Upgrade.mp4CandidateURL(for: webm)?.absoluteString,
                       "https://example.com/v/clip.mp4")
    }

    func testMp4CandidateURLPreservesQueryAndFragment() throws {
        let withQuery = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm?t=10&k=abc"))
        XCTAssertEqual(MP4Upgrade.mp4CandidateURL(for: withQuery)?.absoluteString,
                       "https://example.com/v/clip.mp4?t=10&k=abc")

        let withFragment = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm#frag"))
        XCTAssertEqual(MP4Upgrade.mp4CandidateURL(for: withFragment)?.absoluteString,
                       "https://example.com/v/clip.mp4#frag")
    }

    func testMp4CandidateURLIsCaseInsensitive() throws {
        let upper = try XCTUnwrap(URL(string: "https://example.com/v/clip.WEBM"))

        XCTAssertEqual(MP4Upgrade.mp4CandidateURL(for: upper)?.absoluteString,
                       "https://example.com/v/clip.mp4")
    }

    func testMp4CandidateURLRejectsNonWebMPaths() throws {
        // media.ts:730 requires ".webm" to terminate the path.
        XCTAssertNil(MP4Upgrade.mp4CandidateURL(for: URL(string: "https://example.com/v/clip.mp4")!))
        XCTAssertNil(MP4Upgrade.mp4CandidateURL(for: URL(string: "https://example.com/v/clip.webm/extra")!))
        XCTAssertNil(MP4Upgrade.mp4CandidateURL(for: URL(string: "https://example.com/v/clip.webmish")!))
    }

    // MARK: - MP4Upgrade probe wiring (fake transport, no network)

    func testUpgradedURLReturnsMp4OnSuccessStatusCode() async throws {
        let client = FakeHTTPClient(statusCode: 200)
        let webm = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm"))

        let upgraded = await MP4Upgrade.upgradedURL(for: webm, http: client)

        XCTAssertEqual(upgraded?.absoluteString, "https://example.com/v/clip.mp4")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests.first?.httpMethod, "HEAD") // media.ts:775
        XCTAssertEqual(client.requests.first?.url?.absoluteString, "https://example.com/v/clip.mp4")
    }

    func testUpgradedURLReturnsNilOutsideSuccessRange() async throws {
        let webm = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm"))

        let notFound = await MP4Upgrade.upgradedURL(for: webm, http: FakeHTTPClient(statusCode: 404))
        XCTAssertNil(notFound) // media.ts:780-783

        let serverError = await MP4Upgrade.upgradedURL(for: webm, http: FakeHTTPClient(statusCode: 500))
        XCTAssertNil(serverError)
    }

    func testUpgradedURLSkipsRequestForNonWebm() async throws {
        let client = FakeHTTPClient(statusCode: 200)
        let mp4 = try XCTUnwrap(URL(string: "https://example.com/v/clip.mp4"))

        let upgraded = await MP4Upgrade.upgradedURL(for: mp4, http: client)
        XCTAssertNil(upgraded)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testUpgradedURLReturnsNilWhenTransportThrows() async throws {
        // media.ts:784-785: a failed/timed-out probe is "no mp4", never an error.
        let webm = try XCTUnwrap(URL(string: "https://example.com/v/clip.webm"))

        let upgraded = await MP4Upgrade.upgradedURL(for: webm, http: ThrowingHTTPClient())
        XCTAssertNil(upgraded)
    }

    // MARK: - GridPreviewPolicy (src/utils/gridPreviews.ts, gridPreviewMedia.ts:33-62)

    func testInlinePreviewHonoursMasterSwitch() {
        let post = makePost(previewVideoURL: "https://example.com/v/clip.mp4")

        XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: post, enabled: true, quality: .auto))
        // gridPreviews.ts:5, PostCard.tsx:113-114: the switch off keeps the static cover.
        XCTAssertFalse(GridPreviewPolicy.shouldPlayInlinePreview(post: post, enabled: false, quality: .auto))
    }

    func testInlinePreviewRequiresACandidate() {
        // Image-only card: no clip, no frames.
        let imageOnly = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            sampleURL: "https://example.com/p/2/sample.jpg"
        )
        XCTAssertFalse(GridPreviewPolicy.shouldPlayInlinePreview(post: imageOnly, enabled: true, quality: .auto))

        // A WebM-only post has nothing AVPlayer can play (gridPreviewMedia.ts:27-30).
        let webmOnly = makePost(originalURL: "https://example.com/v/clip.webm")
        XCTAssertFalse(GridPreviewPolicy.shouldPlayInlinePreview(post: webmOnly, enabled: true, quality: .auto))

        // Frame thumbs alone still animate the slideshow (PostCard.tsx:125).
        let framesOnly = makePost(previewThumbURL: "https://example.com/p/1/thumb.jpg")
        XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: framesOnly, enabled: true, quality: .auto))
    }

    func testInlinePreviewSkipsSampleAliasedToOriginal() {
        // gridPreviewMedia.ts:46-49: sampleUrl aliased to the full attachment is not a
        // lightweight auto preview, but an explicit hold (allowOriginal) may still play it
        // and PostCard.tsx:125 counts those manualCandidates as "has a preview".
        let aliased = makePost(sampleURL: "https://example.com/v/full.mp4", originalURL: "https://example.com/v/full.mp4")

        XCTAssertTrue(GridPreviewPolicy.videoCandidates(for: aliased, quality: .auto).isEmpty)
        XCTAssertEqual(
            GridPreviewPolicy.videoCandidates(for: aliased, quality: .auto, allowOriginal: true).map(\.absoluteString),
            ["https://example.com/v/full.mp4"]
        )
        XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: aliased, enabled: true, quality: .auto))
    }

    func testInlinePreviewGateMatchesManualCandidates() {
        // F1: PostCard.tsx:125 gates on `manualCandidates` (allowOriginal = true), so an
        // originals-only post still counts as previewable even though the auto set is empty.
        let originalOnly = makePost(originalURL: "https://example.com/v/full.mp4")

        XCTAssertTrue(GridPreviewPolicy.videoCandidates(for: originalOnly, quality: .auto).isEmpty)
        XCTAssertEqual(
            GridPreviewPolicy.videoCandidates(for: originalOnly, quality: .auto, allowOriginal: true).map(\.absoluteString),
            ["https://example.com/v/full.mp4"]
        )
        XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: originalOnly, enabled: true, quality: .auto))

        // The master switch still wins over any candidate (gridPreviews.ts:5).
        XCTAssertFalse(GridPreviewPolicy.shouldPlayInlinePreview(post: originalOnly, enabled: false, quality: .auto))
    }

    func testGifCheckUsesOriginalWithSingleSampleFallback() {
        // F2: gifMedia.ts:39 inspects `originalUrl || sampleUrl`, a single fallback, so an
        // mp4 original with a gif sample is not a GIF post.
        let post = makePost(
            sampleURL: "https://example.com/p/1/thumb.gif",
            originalURL: "https://example.com/v/clip.mp4"
        )

        XCTAssertTrue(GridPreviewPolicy.videoCandidates(for: post, quality: .auto).isEmpty)
        XCTAssertEqual(
            GridPreviewPolicy.videoCandidates(for: post, quality: .auto, allowOriginal: true).map(\.absoluteString),
            ["https://example.com/v/clip.mp4"]
        )
        XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: post, enabled: true, quality: .auto))

        // With no original the sample is the only probe and a gif sample still means GIF.
        let sampleGifOnly = makePost(sampleURL: "https://example.com/p/1/sample.gif")
        XCTAssertTrue(GridPreviewPolicy.videoCandidates(for: sampleGifOnly, quality: .auto).isEmpty)
    }

    func testInlinePreviewPrefersListingClipOverOriginal() {
        let post = makePost(
            previewVideoURL: "https://example.com/v/listing.mp4",
            sampleURL: "https://example.com/v/full.webm",
            originalURL: "https://example.com/v/full.webm"
        )

        XCTAssertEqual(GridPreviewPolicy.videoCandidates(for: post, quality: .auto).map(\.absoluteString),
                       ["https://example.com/v/listing.mp4"])
    }

    func testInlinePreviewIgnoresGifPosts() {
        // gridPreviewMedia.ts:34-36 + gifMedia.ts:34-38: a realbooru `gif`-tagged post
        // stays on its thumbnail cover even when a guessed .mp4 exists.
        let gifPost = makePost(
            sourceID: .realbooru,
            sampleURL: "https://example.com/v/guessed.mp4",
            fileExt: "mp4",
            generalTags: ["gif"]
        )

        XCTAssertTrue(GridPreviewPolicy.videoCandidates(for: gifPost, quality: .auto).isEmpty)
        XCTAssertFalse(GridPreviewPolicy.shouldPlayInlinePreview(post: gifPost, enabled: true, quality: .auto))
    }

    func testInlinePreviewIsIndependentOfImageQuality() {
        let post = makePost(previewVideoURL: "https://example.com/v/listing.mp4")

        for quality in ImageQuality.allCases {
            XCTAssertEqual(GridPreviewPolicy.videoCandidates(for: post, quality: quality).count, 1)
            XCTAssertTrue(GridPreviewPolicy.shouldPlayInlinePreview(post: post, enabled: true, quality: quality))
        }
    }

    func testFrameCandidatesSkipVideosAndPages() {
        let post = makePost(
            previewURL: "https://example.com/p/1/preview.jpg",
            previewThumbURL: "https://example.com/p/1/thumb.jpg",
            previewThumbs: [
                "https://example.com/p/1/frame1.jpg",
                "https://example.com/p/1/frame1.jpg",
                "https://example.com/p/1/clip.mp4",
                "https://example.com/page.php",
            ]
        )

        XCTAssertEqual(GridPreviewPolicy.frameCandidates(for: post).map(\.absoluteString),
                       [
                           "https://example.com/p/1/frame1.jpg",
                           "https://example.com/p/1/thumb.jpg",
                       ])
    }

    // MARK: - GridPreviewTiming (src/components/PostCard.tsx:196-199)

    func testNextFrameIndexAdvancesAndWraps() {
        XCTAssertEqual(GridPreviewTiming.nextFrameIndex(current: 0, frameCount: 3), 1)
        XCTAssertEqual(GridPreviewTiming.nextFrameIndex(current: 2, frameCount: 3), 0)
        XCTAssertEqual(GridPreviewTiming.nextFrameIndex(current: 5, frameCount: 3), 0)
        XCTAssertEqual(GridPreviewTiming.nextFrameIndex(current: 0, frameCount: 0), 0)
    }

    func testTimingConstantsMatchRN() {
        XCTAssertEqual(GridPreviewTiming.frameIntervalMilliseconds, 1200) // PostCard.tsx:198
        XCTAssertEqual(GridPreviewTiming.stallTimeoutMilliseconds, 15_000) // PostCard.tsx:162
    }
}

/// Transport double: records the request and answers with a fixed status. Never
/// touches the network.
private final class FakeHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (Data(), response)
    }
}

/// Transport double that always fails, standing in for a timeout or offline probe.
private final class ThrowingHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut)
    }
}
