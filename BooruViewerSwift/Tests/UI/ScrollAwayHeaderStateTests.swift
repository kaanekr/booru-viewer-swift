import CoreGraphics
import XCTest
@testable import BooruViewer

/// Pure collapse rules behind the Explore/Search scroll-away headers
/// (Sources/UI/Common/ScrollAwayHeaderState.swift).
///
/// The behaviour being tested: the bar follows the finger continuously instead of
/// waiting for a full header height, the top of the list always shows it, upward
/// movement reveals it anywhere, and rubber-band/jitter samples cannot flicker it.
final class ScrollAwayHeaderStateTests: XCTestCase {
    private let height: CGFloat = 132

    /// Drives the state through a list of offsets and returns the last slide.
    @discardableResult
    private func scroll(
        _ state: inout ScrollAwayHeaderState,
        offsets: [CGFloat],
        height: CGFloat? = nil
    ) -> CGFloat {
        var slide: CGFloat = 0
        for offset in offsets {
            slide = state.update(offset: offset, height: height ?? self.height)
        }
        return slide
    }

    // MARK: - Continuous collapse

    /// The reported bug: the old state kept the bar pinned until the whole header
    /// height had scrolled away. A short first scroll must already move it.
    func testShortFirstScrollStartsCollapsing() {
        var state = ScrollAwayHeaderState()
        // Prime the baseline at the top of the list.
        _ = state.update(offset: 0, height: height)
        let slide = state.update(offset: 20, height: height)

        XCTAssertEqual(slide, -20, accuracy: 0.001)
        XCTAssertEqual(state.collapse, 20, accuracy: 0.001)
        XCTAssertFalse(state.isFullyCollapsed)
    }

    /// Collapse is clamped to the header height: no over-scroll past full hide.
    func testCollapseClampsToHeaderHeight() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 40, 200, 900])

        XCTAssertEqual(state.collapse, height, accuracy: 0.001)
        XCTAssertEqual(state.slide, -height, accuracy: 0.001)
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)
        XCTAssertTrue(state.isFullyCollapsed)
    }

    /// Full hide happens exactly at `height`, not before.
    func testFullyCollapsedOnlyAtFullHeight() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, height - 1])

        XCTAssertFalse(state.isFullyCollapsed)
        XCTAssertLessThan(state.progress, 1)

        _ = state.update(offset: height, height: height)
        XCTAssertTrue(state.isFullyCollapsed)
    }

    // MARK: - Reveal

    /// An upward drag anywhere in the list reveals the bar, even far down the feed;
    /// the reveal tracks the upward distance instead of waiting for the top.
    func testUpwardScrollRevealsFarFromTop() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 600, 1200])
        XCTAssertTrue(state.isFullyCollapsed)

        _ = scroll(&state, offsets: [1290, 1280])

        XCTAssertEqual(state.collapse, height - 10, accuracy: 0.001)
        XCTAssertFalse(state.isFullyCollapsed)

        // Enough upward travel reveals the whole bar without reaching offset 0.
        _ = scroll(&state, offsets: [1270, 1200, 1150])
        XCTAssertEqual(state.collapse, 0, accuracy: 0.001)
        XCTAssertEqual(state.slide, 0, accuracy: 0.001)
    }

    /// A partial upward drag reveals exactly as far as it moved.
    func testPartialUpwardScrollPartiallyReveals() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 300, 600])
        XCTAssertEqual(state.collapse, height, accuracy: 0.001)

        _ = state.update(offset: 550, height: height)

        XCTAssertEqual(state.collapse, height - 50, accuracy: 0.001)
    }

    // MARK: - Top / pull-to-refresh

    /// The pull-to-refresh rubber band (negative offset) keeps the bar fully open
    /// and never accumulates travel, so the release does not flicker.
    func testRubberBandKeepsHeaderFullyOpen() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 60])
        XCTAssertEqual(state.collapse, 60, accuracy: 0.001)

        _ = scroll(&state, offsets: [-8, -40, -120])

        XCTAssertEqual(state.slide, 0, accuracy: 0.001)
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.isFullyCollapsed)
    }

    /// Returning to the top always shows the full bar, then the next scrolled point
    /// collapses from zero again (no stale jump from the previous position).
    func testReturningToTopResetsBaseline() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 480])
        XCTAssertEqual(state.collapse, height, accuracy: 0.001)

        _ = state.update(offset: 0, height: height)
        XCTAssertEqual(state.collapse, 0, accuracy: 0.001)

        let slide = state.update(offset: 12, height: height)
        XCTAssertEqual(slide, -12, accuracy: 0.001)
    }

    // MARK: - Filtering

    /// Sub-point jitter is buffered, not applied, so a resting finger cannot wobble
    /// the bar.
    func testJitterBelowThresholdIsIgnored() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 40])
        let resting = state.collapse

        // Alternating sub-point samples that cancel out around the resting point.
        _ = scroll(&state, offsets: [40.2, 40.0, 40.15, 40.05])

        XCTAssertEqual(state.collapse, resting, accuracy: 0.001)
    }

    /// A tiny reversal does not flip direction on its own, but once a deliberate
    /// upward move accumulates the withheld travel is applied too.
    func testSmallReversalIsWithheldUntilDeliberate() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 300, 600])
        let hidden = state.collapse

        _ = scroll(&state, offsets: [598, 597])
        XCTAssertEqual(state.collapse, hidden, accuracy: 0.001)

        _ = state.update(offset: 590, height: height)
        XCTAssertEqual(state.collapse, hidden - 10, accuracy: 0.001)
    }

    // MARK: - Height changes

    /// A bar that grows or shrinks (chips appearing, source switch) re-clamps the
    /// current collapse instead of reporting more than the header height.
    func testHeightChangeReclampsCollapse() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 300])
        XCTAssertEqual(state.collapse, height, accuracy: 0.001)

        state.syncHeight(200)
        XCTAssertEqual(state.height, 200, accuracy: 0.001)
        XCTAssertEqual(state.collapse, 200, accuracy: 0.001)

        let slide = state.update(offset: 320, height: 200)
        XCTAssertEqual(slide, -200, accuracy: 0.001)

        // A small upward move after the resize reveals against the new height.
        _ = state.update(offset: 308, height: 200)
        XCTAssertEqual(state.collapse, 188, accuracy: 0.001)
    }

    /// A zero-height header stays open instead of dividing by zero.
    func testZeroHeightNeverCollapses() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 100, 400], height: 0)

        XCTAssertEqual(state.slide, 0, accuracy: 0.001)
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.isFullyCollapsed)
    }

    // MARK: - Reset

    /// Reset (refresh, sheet, source/filter change) shows the bar and forgets the
    /// baseline, so the next sample cannot replay the previous distance.
    func testResetRevealsAndRebases() {
        var state = ScrollAwayHeaderState()
        _ = scroll(&state, offsets: [0, 500])
        XCTAssertTrue(state.isFullyCollapsed)

        state.reset()
        XCTAssertEqual(state.collapse, 0, accuracy: 0.001)
        XCTAssertEqual(state.slide, 0, accuracy: 0.001)

        let slide = state.update(offset: 500, height: height)
        XCTAssertEqual(slide, 0, accuracy: 0.001)

        let next = state.update(offset: 510, height: height)
        XCTAssertEqual(next, -10, accuracy: 0.001)
    }

    /// A newly built state (fresh source/filter context) also starts revealed.
    func testFreshStateStartsRevealed() {
        let state = ScrollAwayHeaderState()

        XCTAssertEqual(state.slide, 0, accuracy: 0.001)
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.isFullyCollapsed)
    }
}
