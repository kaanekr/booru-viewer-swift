import UIKit
import XCTest
@testable import BooruViewer

/// Grid-cover retention rules (Sources/UI/Common/AsyncMediaImage.swift,
/// Sources/UI/Common/PostCardView.swift).
///
/// The grid stacks a timed preview-frame layer on top of the card's base cover.
/// These tests pin the two pure decisions that keep a pending or failed frame from
/// masking that cover: what image a finished load attempt leaves behind, and which
/// layer identity a card's frames share. No network and no real decoding: the
/// images are 1x1 synthetic `UIImage`s.
final class CoverFrameRegressionTests: XCTestCase {
    // MARK: - Fixtures

    /// Minimal synthetic 1x1 image; identity checks only compare instances, so the
    /// pixels never matter. No network, no real media.
    private func solidImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Frame layer never erases a good image

    func testFailedFrameKeepsTheLastDecodedFrame() {
        // Both a failure and a still-pending retarget reach this rule with
        // `resolved == nil`; neither may blank the layer.
        let previous = solidImage(.red)
        let resolved = AsyncMediaImage.resolvedImage(
            previous: previous,
            resolved: nil,
            keepsPreviousImage: true
        )
        XCTAssertTrue(resolved === previous, "a failed/pending frame must keep the last decoded frame")
    }

    func testNewFrameReplacesTheLastDecodedFrame() {
        let previous = solidImage(.red)
        let next = solidImage(.green)
        let resolved = AsyncMediaImage.resolvedImage(
            previous: previous,
            resolved: next,
            keepsPreviousImage: true
        )
        XCTAssertTrue(resolved === next, "a decoded frame must win over the previous one")
    }

    func testRetainedLayerWithNoHistoryStaysEmptySoTheCoverShows() {
        let resolved = AsyncMediaImage.resolvedImage(
            previous: nil,
            resolved: nil,
            keepsPreviousImage: true
        )
        XCTAssertNil(resolved, "with no frame yet the layer stays clear and the cover shows")
    }

    func testBaseCoverStillClearsOnRetargetAndOnFailure() {
        // The base cover deliberately does not retain: a new cover must not show the
        // old post's image, so a cleared slot keeps the card fill.
        XCTAssertNil(
            AsyncMediaImage.resolvedImage(previous: solidImage(.red), resolved: nil, keepsPreviousImage: false)
        )
        let fresh = solidImage(.green)
        XCTAssertTrue(
            AsyncMediaImage.resolvedImage(previous: nil, resolved: fresh, keepsPreviousImage: false) === fresh
        )
    }

    // MARK: - Frame overlay wiring

    func testFrameOverlayNeverPaintsOpaqueFillAndRetainsItsLastFrame() {
        let configuration = AsyncMediaImage.overlayConfiguration
        XCTAssertEqual(
            configuration.placeholder,
            .transparent,
            "the frame overlay must not paint an opaque fill over the base cover"
        )
        XCTAssertTrue(
            configuration.keepsPreviousImageWhileLoading,
            "the frame overlay must keep its last decoded frame while the next loads"
        )
    }

    // MARK: - Frame layer identity

    func testFramesOfOneCardShareOneLayerIdentity() {
        let cover = URL(string: "https://cdn.example/cover.jpg")
        let first = PostCardView.frameLayerKey(postID: "ph_1", coverURL: cover)
        let second = PostCardView.frameLayerKey(postID: "ph_1", coverURL: cover)
        XCTAssertEqual(first, second, "slideshow advances must reuse one layer, not rebuild it")
    }

    func testDifferentPostsGetDifferentLayerIdentities() {
        let cover = URL(string: "https://cdn.example/cover.jpg")
        XCTAssertNotEqual(
            PostCardView.frameLayerKey(postID: "ph_1", coverURL: cover),
            PostCardView.frameLayerKey(postID: "ph_2", coverURL: cover),
            "a recycled card must not inherit the previous post's decoded frame"
        )
    }

    func testChangedCoverGetsAFreshLayerIdentity() {
        XCTAssertNotEqual(
            PostCardView.frameLayerKey(postID: "ph_1", coverURL: URL(string: "https://cdn.example/a.jpg")),
            PostCardView.frameLayerKey(postID: "ph_1", coverURL: URL(string: "https://cdn.example/b.jpg")),
            "a new cover must re-seed the frame layer"
        )
    }

    func testMissingCoverStillYieldsAStableIdentity() {
        XCTAssertEqual(
            PostCardView.frameLayerKey(postID: "ph_1", coverURL: nil),
            PostCardView.frameLayerKey(postID: "ph_1", coverURL: nil)
        )
    }
}
