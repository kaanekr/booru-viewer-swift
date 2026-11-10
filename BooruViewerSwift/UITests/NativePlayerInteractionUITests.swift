import XCTest

/// Real-gesture regression tests for `AVPlayerViewController` embedded inside
/// `ViewerScreen`'s horizontal post pager (`TabView(.page)`).
///
/// The bug they guard against: dragging horizontally on the native `AVPlayerViewController`
/// scrubber or tapping native controls hijacked by the enclosing post pager (`TabView`),
/// flipping the active post instead of scrubbing video time.
///
/// BLOCKED FIXTURE CONTRACT (`needs-videoFixture`) — no deterministic offline video fixture
/// exists in the app target today, and wiring one requires files outside this task's
/// writable set:
///
///   1. `Sources/App/DemoData.swift` — a demo video post backed by a bundled local `.mp4`
///      resource (or local stub HTTP video) followed by a second post so post-paging can
///      be observed, plus `DemoBooruSource.resolveMedia(for:context:)` returning a real
///      playable `videoURL` (`isVideo: true`) when `-videoFixture` is passed.
///   2. `Sources/App/DemoData.swift` (`LaunchOptions`) & `Sources/App/RootTabView.swift` —
///      support `-videoFixture` and `-initialVideo` launch arguments to open the viewer
///      directly on the synthetic video post.
///
/// Until that fixture contract is wired into the app target, each test explicitly skips
/// via `XCTSkip("needs-videoFixture ...")` (never passing vacuously on image posts).
final class NativePlayerInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let fixtureArgument = "-videoFixture"
    private static let openVideoArgument = "-initialVideo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-demoMode",
            "-initialTab", "feed",
            Self.fixtureArgument,
            Self.openVideoArgument,
        ]
        app.launch()
        try requireVideoFixture()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Dragging the native `AVPlayerViewController` scrubber horizontally must advance
    /// scrubber progress / playback time without switching away from the video post.
    func testScrubberDragChangesTimeWithoutSwitchingPage() throws {
        let badgeBefore = try XCTUnwrap(currentBadgeText(), "Viewer post badge missing")
        let playerContainer = app.otherElements["viewer.videoPlayer"]
        let scrubber = playerContainer.sliders.firstMatch
        XCTAssertTrue(
            scrubber.waitForExistence(timeout: 5),
            "Native AVPlayerViewController scrubber missing inside viewer.videoPlayer"
        )
        let beforeValue = scrubber.value as? String

        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertEqual(
            currentBadgeText(),
            badgeBefore,
            "Horizontal scrubber drag was stolen by the post pager and changed the active post"
        )
        let afterValue = scrubber.value as? String
        XCTAssertNotEqual(
            afterValue,
            beforeValue,
            "Native scrubber value did not change after horizontal drag"
        )
    }

    /// Tapping native transport controls inside `viewer.videoPlayer` must leave the post
    /// index unchanged, while swiping horizontally across the middle canvas still switches posts.
    func testNativeControlTapKeepsPageAndCanvasSwipeSwitchesPost() throws {
        let badgeBefore = try XCTUnwrap(currentBadgeText(), "Viewer post badge missing")
        let playerContainer = app.otherElements["viewer.videoPlayer"]
        let playPauseButton = playerContainer.buttons["Pause"].exists
            ? playerContainer.buttons["Pause"]
            : playerContainer.buttons["Play"]
        if playPauseButton.exists {
            playPauseButton.tap()
            XCTAssertEqual(
                currentBadgeText(),
                badgeBefore,
                "Tapping native playback control changed the active post"
            )
        }

        let centerStart = playerContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let centerEnd = playerContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        centerStart.press(forDuration: 0.05, thenDragTo: centerEnd)

        XCTAssertTrue(
            waitUntil(timeout: 5, {
                guard let after = self.currentBadgeText() else { return false }
                return after != badgeBefore
            }),
            "Swiping horizontally on the video canvas did not switch to the next post"
        )
    }

    // MARK: - Fixture gate

    private func requireVideoFixture() throws {
        let closeVisible = app.buttons["viewer.closeButton"].waitForExistence(timeout: 5)
        let infoVisible = app.buttons["viewer.infoButton"].exists
        let playerContainer = app.otherElements["viewer.videoPlayer"]
        let hasVideoContainer = playerContainer.waitForExistence(timeout: 5)
        let hasTimeSlider = playerContainer.sliders.firstMatch.waitForExistence(timeout: 5)

        if closeVisible && infoVisible && hasVideoContainer && hasTimeSlider {
            return
        }

        throw XCTSkip(
            """
            needs-videoFixture: Synthetic offline video fixture is not wired into the app \
            target (`viewer.videoPlayer` with viewer context and native time slider absent), \
            so inline AVPlayerViewController scrubber vs TabView(.page) arbitration cannot be \
            driven deterministically. Required contract (outside owned files):
              - DemoData / DemoBooruSource: expose a finite playable video post (bundled \
            local .mp4 or local stub URL) with resolved `videoURL` followed by a second \
            post when `-videoFixture` is present.
              - LaunchOptions / RootTabView: honor `-videoFixture` and `-initialVideo` to \
            open the viewer directly on the video post.
            """
        )
    }

    // MARK: - Helpers

    private func currentBadgeText() -> String? {
        let matches = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$"))
        guard matches.count > 0 else { return nil }
        return matches.element(boundBy: 0).label
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
