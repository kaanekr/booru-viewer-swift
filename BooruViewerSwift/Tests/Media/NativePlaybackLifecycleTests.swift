import Foundation
import XCTest
@testable import BooruViewer

/// Unit tests for `NativePlaybackLifecycle`: finite-clip looping, natural-EOF vs
/// mid-clip user pause callback orderings (pause-before-end and end-before-pause),
/// async programmatic pause KVO reconciliation (including failed-item pauses), seek
/// cancellation, stale-item/episode rejection, bounded proxy retries, and disposal.
final class NativePlaybackLifecycleTests: XCTestCase {
    private final class IdentityToken {}

    private let primaryURL = URL(string: "https://example.com/video-a.mp4")!
    private let episodeTwoURL = URL(string: "https://example.com/video-b.mp4")!

    // MARK: - Initial configuration

    func testConfigureActiveStartsPlaybackAndInactiveStaysPaused() {
        let player = IdentityToken()
        let item = IdentityToken()

        var active = NativePlaybackLifecycle()
        XCTAssertEqual(
            active.configure(
                url: primaryURL,
                playerID: ObjectIdentifier(player),
                itemID: ObjectIdentifier(item),
                routeAttemptCount: 2,
                isActive: true
            ),
            .play
        )
        XCTAssertTrue(active.isActive)
        XCTAssertFalse(active.isUserPaused)
        XCTAssertFalse(active.isDisposed)

        var inactive = NativePlaybackLifecycle()
        XCTAssertEqual(
            inactive.configure(
                url: primaryURL,
                playerID: ObjectIdentifier(player),
                itemID: ObjectIdentifier(item),
                routeAttemptCount: 2,
                isActive: false
            ),
            .none
        )
        XCTAssertFalse(inactive.isActive)
    }

    // MARK: - Finite looping & non-finite rejection

    func testFiniteClipLoopsFromZeroAndResumesWhenSeekCompletes() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 0.1, duration: 12.0)

        let endAction = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 12.0,
            liveTimeControlState: .playing
        )
        guard case let .seekToZeroAndResume(generation) = endAction else {
            return XCTFail("Expected seekToZeroAndResume, got \(endAction)")
        }

        // Duplicate end notification before seek completion must not stack another seek.
        XCTAssertEqual(
            lifecycle.handleDidPlayToEnd(
                playerID: pID,
                itemID: iID,
                duration: 12.0,
                liveTimeControlState: .playing
            ),
            .none
        )

        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .play
        )
    }

    func testNonFiniteOrZeroDurationNeverLoops() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 5.0, duration: .nan)

        for duration in [Double.nan, Double.infinity, 0, -5] {
            XCTAssertEqual(
                lifecycle.handleDidPlayToEnd(
                    playerID: pID,
                    itemID: iID,
                    duration: duration,
                    liveTimeControlState: .playing
                ),
                .none
            )
        }
    }

    // MARK: - Callback orderings: natural-EOF pause vs user pause (HIGH-loop & F3)

    /// Pause-at-EOF before end notification: player stays `.paused` all the way through
    /// `didPlayToEndTime` and seek completion; must NOT freeze at zero and MUST return `.play`.
    func testPausedAtNaturalEOFBeforeEndNotificationResumesPlaybackOnSeekCompletionWhilePaused() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 1.0, duration: 10.0)

        // KVO `.paused` arrives at natural EOF before `didPlayToEndTimeNotification`.
        lifecycle.observeTimeControlState(.paused, currentTime: 9.98, duration: 10.0)
        XCTAssertFalse(lifecycle.isUserPaused)
        XCTAssertTrue(lifecycle.pausedAtNaturalEOF)

        guard case let .seekToZeroAndResume(generation) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 10.0,
            liveTimeControlState: .paused
        ) else {
            return XCTFail("Natural EOF pause before end notification should still seek to zero")
        }

        // Player remains `.paused` when seek completion fires (no artificial `.waitingToPlay` injection).
        XCTAssertEqual(lifecycle.timeControlState, .paused)
        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .play
        )
    }

    /// End-before-pause at natural EOF: `didPlayToEndTime` triggers seek while player may
    /// transition through `.paused` at EOF; seek completion still returns `.play` when user did not pause.
    func testEndBeforeNaturalPauseResumesPlaybackOnSeekCompletion() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 9.95, duration: 10.0)

        guard case let .seekToZeroAndResume(generation) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 10.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected seekToZeroAndResume at end")
        }

        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .play
        )
    }

    /// Pause-before-end mid-clip: user pauses at 4.0s of 10.0s, then scrubs to 10.0s.
    /// Must latch `isUserPaused` and ignore the resulting `didPlayToEndTime`.
    func testPauseBeforeEndMidClipSuppressesLoopEvenWhenScrubbedToEnd() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 4.0, duration: 10.0)

        // User taps Pause mid-clip (`4.0 < 10.0 - 0.05`).
        lifecycle.observeTimeControlState(.paused, currentTime: 4.0, duration: 10.0)
        XCTAssertTrue(lifecycle.isUserPaused)
        XCTAssertFalse(lifecycle.pausedAtNaturalEOF)

        // Scrubbing to EOF while paused emits `.paused` at EOF and `didPlayToEndTime`; neither restarts.
        lifecycle.observeTimeControlState(.paused, currentTime: 10.0, duration: 10.0)
        XCTAssertEqual(
            lifecycle.handleDidPlayToEnd(
                playerID: pID,
                itemID: iID,
                duration: 10.0,
                liveTimeControlState: .paused
            ),
            .none
        )
    }

    /// Genuine user pause mid-seek: `didPlayToEndTime` starts seek-to-zero, then user
    /// pauses while seek is in flight. Seek completion MUST return `.none`.
    func testGenuineUserPauseMidSeekSuppressesSeekCompletionResume() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 9.9, duration: 10.0)

        guard case let .seekToZeroAndResume(generation) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 10.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected loop seek")
        }

        // User taps Pause while seeking back to zero.
        lifecycle.observeTimeControlState(.paused, currentTime: 0.2, duration: 10.0)
        XCTAssertTrue(lifecycle.isUserPaused)
        XCTAssertEqual(lifecycle.loopStage, .idle)

        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .none
        )
    }

    func testNativePausePreservesPauseAcrossOffscreenRoundTripUntilNativePlay() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 3.0, duration: 8.0)

        lifecycle.observeTimeControlState(.paused, currentTime: 3.0, duration: 8.0)
        XCTAssertTrue(lifecycle.isUserPaused)

        // Paging away and back preserves the user's explicit pause.
        XCTAssertEqual(lifecycle.setActive(false, currentTime: 3.0, duration: 8.0), .pause)
        XCTAssertEqual(lifecycle.setActive(true, currentTime: 3.0, duration: 8.0), .none)
        XCTAssertTrue(lifecycle.isUserPaused)

        // Tapping native Play clears user pause and restores finite looping.
        lifecycle.observeTimeControlState(.playing, currentTime: 7.5, duration: 8.0)
        XCTAssertFalse(lifecycle.isUserPaused)
        guard case .seekToZeroAndResume = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 8.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected loop after native play resumed")
        }
    }

    func testOffscreenPauseDoesNotMarkUserPausedAndReplaysFromStartWhenReactivatedAtEnd() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 9.9, duration: 10.0)

        XCTAssertEqual(lifecycle.setActive(false, currentTime: 9.9, duration: 10.0), .pause)
        lifecycle.willIssueProgrammaticPause()
        lifecycle.observeTimeControlState(.paused, currentTime: 9.9, duration: 10.0)
        XCTAssertFalse(lifecycle.isUserPaused)

        // Stale end notification while offscreen is ignored.
        XCTAssertEqual(
            lifecycle.handleDidPlayToEnd(
                playerID: pID,
                itemID: iID,
                duration: 10.0,
                liveTimeControlState: .playing
            ),
            .none
        )

        // Returning to a clip stopped near its end seeks to zero and resumes.
        let reactivate = lifecycle.setActive(true, currentTime: 9.9, duration: 10.0)
        guard case let .seekToZeroAndResume(generation) = reactivate else {
            return XCTFail("Expected seekToZeroAndResume on reactivation near end, got \(reactivate)")
        }
        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .play
        )
    }

    func testCancelledSeekDoesNotResumePlayback() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 9.9, duration: 10.0)

        guard case let .seekToZeroAndResume(gen) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 10.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected loop seek")
        }

        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: gen,
                finished: false,
                playerID: pID,
                itemID: iID
            ),
            .none
        )
    }

    // MARK: - Async KVO & failed-item programmatic pause reconciliation

    func testAsyncProgrammaticPauseKVODuringFastSwipeRoundTripDoesNotMarkUserPaused() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 2.0, duration: 10.0)

        XCTAssertEqual(lifecycle.setActive(false, currentTime: 2.0, duration: 10.0), .pause)
        lifecycle.willIssueProgrammaticPause()

        XCTAssertEqual(lifecycle.setActive(true, currentTime: 2.0, duration: 10.0), .play)

        lifecycle.observeTimeControlState(.paused, currentTime: 2.0, duration: 10.0)
        XCTAssertFalse(lifecycle.isUserPaused, "Delayed programmatic pause KVO must not latch user pause")

        lifecycle.observeTimeControlState(.playing, currentTime: 2.1, duration: 10.0)
        lifecycle.observeTimeControlState(.paused, currentTime: 3.5, duration: 10.0)
        XCTAssertTrue(lifecycle.isUserPaused)
    }

    /// Reconciles `ignoredProgrammaticPauses` when the observed `.paused` KVO also sees `itemFailed: true`:
    /// repeated inactive + itemFailed cycles must decrement the pending count so a subsequent real
    /// user pause is never swallowed by a stale counter.
    func testRepeatedInactivePlusItemFailedReconcilesCounterForSubsequentNativePause() {
        let player = IdentityToken()
        let item0 = IdentityToken()
        let item1 = IdentityToken()
        let item2 = IdentityToken()
        let pID = ObjectIdentifier(player)
        let i0 = ObjectIdentifier(item0)
        let i1 = ObjectIdentifier(item1)
        let i2 = ObjectIdentifier(item2)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: i0, routeAttemptCount: 3, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 1.0, duration: 10.0)

        // Cycle 1: go inactive (programmatic pause) while item0 fails.
        XCTAssertEqual(lifecycle.setActive(false, currentTime: 1.0, duration: 10.0), .pause)
        lifecycle.willIssueProgrammaticPause()
        lifecycle.observeTimeControlState(.paused, currentTime: 1.0, duration: 10.0, itemFailed: true)
        XCTAssertEqual(lifecycle.ignoredProgrammaticPauses, 0)
        XCTAssertFalse(lifecycle.isUserPaused)

        XCTAssertEqual(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: i0), 1)
        XCTAssertEqual(lifecycle.bindRetryItem(itemID: i1), .none)
        XCTAssertEqual(lifecycle.setActive(true, currentTime: 0, duration: 10.0), .play)
        lifecycle.observeTimeControlState(.playing, currentTime: 0.5, duration: 10.0)

        // Cycle 2: go inactive again while item1 also fails.
        XCTAssertEqual(lifecycle.setActive(false, currentTime: 0.5, duration: 10.0), .pause)
        lifecycle.willIssueProgrammaticPause()
        lifecycle.observeTimeControlState(.paused, currentTime: 0.5, duration: 10.0, itemFailed: true)
        XCTAssertEqual(lifecycle.ignoredProgrammaticPauses, 0)

        XCTAssertEqual(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: i1), 2)
        XCTAssertEqual(lifecycle.bindRetryItem(itemID: i2), .none)
        XCTAssertEqual(lifecycle.setActive(true, currentTime: 0, duration: 10.0), .play)
        lifecycle.observeTimeControlState(.playing, currentTime: 2.0, duration: 10.0)

        // Now a genuine native user pause must latch immediately (no stale counter left).
        lifecycle.observeTimeControlState(.paused, currentTime: 2.0, duration: 10.0)
        XCTAssertTrue(lifecycle.isUserPaused)
    }

    // MARK: - Identity, HentaiHaven URL swap, and proxy fallback

    func testUnrelatedItemAndStaleEpisodeSwitchRebinding() {
        let player = IdentityToken()
        let item1 = IdentityToken()
        let item2 = IdentityToken()
        let unrelatedItem = IdentityToken()
        let pID = ObjectIdentifier(player)
        let i1 = ObjectIdentifier(item1)
        let i2 = ObjectIdentifier(item2)
        let other = ObjectIdentifier(unrelatedItem)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: i1, routeAttemptCount: 1, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 4.5, duration: 5.0)

        // Notification from an unrelated item is rejected.
        XCTAssertEqual(
            lifecycle.handleDidPlayToEnd(
                playerID: pID,
                itemID: other,
                duration: 5.0,
                liveTimeControlState: .playing
            ),
            .none
        )

        // Start seek on item1, then switch HentaiHaven episode to item2.
        guard case let .seekToZeroAndResume(oldGen) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: i1,
            duration: 5.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected seek on item1")
        }

        XCTAssertEqual(
            lifecycle.replaceURL(episodeTwoURL, itemID: i2, routeAttemptCount: 2, isActive: true),
            .play
        )

        // Old seek completion and old item end notification are both ignored.
        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: oldGen,
                finished: true,
                playerID: pID,
                itemID: i1
            ),
            .none
        )
        XCTAssertEqual(
            lifecycle.handleDidPlayToEnd(
                playerID: pID,
                itemID: i1,
                duration: 5.0,
                liveTimeControlState: .playing
            ),
            .none
        )

        // New episode item loops properly.
        lifecycle.observeTimeControlState(.playing, currentTime: 14.9, duration: 15.0)
        guard case .seekToZeroAndResume = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: i2,
            duration: 15.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected loop on rebound episode item")
        }
    }

    func testProxyFallbackIsBoundedAndFailedItemPauseDoesNotBlockRetry() {
        let player = IdentityToken()
        let item0 = IdentityToken()
        let item1 = IdentityToken()
        let pID = ObjectIdentifier(player)
        let i0 = ObjectIdentifier(item0)
        let i1 = ObjectIdentifier(item1)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: i0, routeAttemptCount: 2, isActive: true)

        // Failed item transitioning AVPlayer to `.paused` must not mark user-paused.
        lifecycle.observeTimeControlState(.paused, currentTime: 0, duration: .nan, itemFailed: true)
        XCTAssertFalse(lifecycle.isUserPaused)

        XCTAssertEqual(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: i0), 1)
        XCTAssertEqual(lifecycle.bindRetryItem(itemID: i1), .play)

        // Duplicate failure for superseded item0 is ignored; failure on final leg stops.
        XCTAssertNil(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: i0))
        XCTAssertNil(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: i1))
    }

    // MARK: - Disposal

    func testDisposeInvalidatesAllFutureEventsAndLooping() {
        let player = IdentityToken()
        let item = IdentityToken()
        let pID = ObjectIdentifier(player)
        let iID = ObjectIdentifier(item)

        var lifecycle = NativePlaybackLifecycle()
        _ = lifecycle.configure(url: primaryURL, playerID: pID, itemID: iID, routeAttemptCount: 2, isActive: true)
        lifecycle.observeTimeControlState(.playing, currentTime: 5.9, duration: 6.0)

        guard case let .seekToZeroAndResume(gen) = lifecycle.handleDidPlayToEnd(
            playerID: pID,
            itemID: iID,
            duration: 6.0,
            liveTimeControlState: .playing
        ) else {
            return XCTFail("Expected seek before dispose")
        }

        lifecycle.dispose()
        XCTAssertTrue(lifecycle.isDisposed)
        XCTAssertEqual(
            lifecycle.handleLoopSeekCompleted(
                generation: gen,
                finished: true,
                playerID: pID,
                itemID: iID
            ),
            .none
        )
        XCTAssertEqual(lifecycle.setActive(true, currentTime: 0, duration: 6.0), .none)
        XCTAssertEqual(lifecycle.replaceURL(episodeTwoURL, itemID: iID, routeAttemptCount: 1, isActive: true), .none)
        XCTAssertNil(lifecycle.nextRetryAttemptIndex(playerID: pID, itemID: iID))
    }
}
