import XCTest

/// Real-gesture UI tests for the app shell.
///
/// The regression these guard against is "the grid stopped scrolling and cards stopped
/// opening": a card gesture that swallows the scroll pan, or a tap target that no longer
/// reaches `PostCardView`'s `Button`. Both are invisible to unit tests, so these tests drive
/// the actual simulator: launch in `-demoMode` (offline `DemoBooruSource`, in-memory stores),
/// swipe the masonry grid, compare the first card's frame, tap a card to open the viewer, and
/// switch every tab.
final class AppInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Vertical offset below which a card sits behind the floating Explore header.
    private static let headerClearance: CGFloat = 170

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoMode", "-initialTab", "feed"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Scroll + tap

    /// Proves the feed's `ScrollView` receives a pan that starts on a card, then that a plain
    /// tap on a card still opens the viewer.
    func testGridScrollsAndTapOpensViewer() throws {
        XCTAssertTrue(
            exploreHeaderButton.waitForExistence(timeout: 30),
            "The Explore feed did not appear (launch arguments: -demoMode -initialTab feed)"
        )
        XCTAssertTrue(
            waitUntil(timeout: 30, { self.firstVisibleCard() != nil }),
            "The demo grid never rendered a tappable post card"
        )

        guard let firstCard = firstVisibleCard() else {
            return XCTFail("The demo grid never rendered a tappable post card")
        }
        let cardLabel = firstCard.label
        let beforeMinY = firstCard.frame.minY

        // The pan starts on a card. If a card gesture swallowed it, nothing moves.
        gridScrollView.swipeUp()

        let scrolledCard = gridScrollView.buttons
            .matching(NSPredicate(format: "label == %@", cardLabel))
            .firstMatch
        // A card that scrolled out of the lazy grid is recycled out of the accessibility tree
        // and reports a zero frame, which is still a decrease from its on-screen position.
        var afterMinY: CGFloat = 0
        if scrolledCard.exists {
            afterMinY = scrolledCard.frame.minY
        } else if firstCard.exists {
            afterMinY = firstCard.frame.minY
        }
        XCTAssertLessThan(
            afterMinY,
            beforeMinY,
            "The grid did not scroll: the first card stayed at minY \(beforeMinY)"
        )

        // Back to the top, then a real tap on a card.
        for _ in 0..<3 where firstVisibleCard() == nil {
            app.swipeDown()
            _ = waitUntil(timeout: 5, { self.firstVisibleCard() != nil })
        }
        guard let card = firstVisibleCard() else {
            return XCTFail("The grid did not come back after swipeDown")
        }
        card.tap()

        XCTAssertTrue(
            waitUntil(timeout: 20, { self.viewerIsPresented }),
            "Tapping a post card did not open the viewer"
        )

        closeViewer()
        XCTAssertTrue(
            waitUntil(timeout: 15, { self.exploreTabBarButton.exists }),
            "The viewer did not close (Explore tab never came back)"
        )
    }

    // MARK: - Tab bar

    /// Every tab bar item must still switch screens after a real tap.
    func testTabBarSwitches() throws {
        XCTAssertTrue(
            exploreTabBarButton.waitForExistence(timeout: 30),
            "The tab bar did not appear"
        )
        XCTAssertTrue(
            exploreHeaderButton.exists,
            "The Explore tab is not the launch tab"
        )

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 20, { self.searchField.exists }),
            "The Search tab did not show its search field"
        )

        app.tabBars.buttons["Favorites"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 20, { self.favoritesSegmentsAreVisible }),
            "The Favorites tab did not show its Saved Posts segment"
        )

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(
            app.staticTexts["YOUR SOURCE"].waitForExistence(timeout: 20),
            "The Settings tab did not show its source hero"
        )

        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(
            exploreHeaderButton.waitForExistence(timeout: 20),
            "Going back to Explore did not restore the feed"
        )
    }

    // MARK: - Viewer polish

    /// The viewer chrome must expose exactly one actionable info control (the top
    /// bar one) and the close control must still dismiss it.
    func testViewerHasExactlyOneInfoButtonAndCloseWorks() throws {
        openViewer()

        XCTAssertTrue(
            waitUntil(timeout: 20, { self.app.buttons["viewer.infoButton"].exists }),
            "The viewer never showed its info control (identifier viewer.infoButton)"
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: "viewer.infoButton").count,
            1,
            "The viewer chrome shows more than one info control"
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "Post info")).count,
            1,
            "Only the top-bar info button should be labelled \"Post info\""
        )

        XCTAssertTrue(
            app.buttons["viewer.closeButton"].exists,
            "The viewer close control is missing (identifier viewer.closeButton)"
        )
        app.buttons["viewer.closeButton"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 15, { self.exploreTabBarButton.exists }),
            "Tapping the viewer's close control did not dismiss it"
        )
    }

    /// The info sheet's `•••` menu must still be reachable from the tag chip and
    /// still offer all seven RN tag actions.
    ///
    /// This runs on image demo posts: it proves the tag chrome, not video playback
    /// or looping, and makes no claim about the transport centring.
    func testInfoSheetTagMenuOffersAllActions() throws {
        openViewer()

        let infoButton = app.buttons["viewer.infoButton"]
        XCTAssertTrue(
            infoButton.waitForExistence(timeout: 20),
            "The viewer never showed its info control"
        )
        infoButton.tap()

        let tagMenus = app.buttons.matching(identifier: "info.tagMenu")
        XCTAssertTrue(
            waitUntil(timeout: 20, { tagMenus.firstMatch.exists }),
            "The info sheet never rendered a tag menu control"
        )

        // The Tags section can sit below the fold in a short sheet; scroll until the
        // first menu control is actually hittable instead of tapping a hidden element.
        var scrollAttempts = 0
        while !tagMenus.firstMatch.isHittable && scrollAttempts < 4 {
            app.swipeUp()
            scrollAttempts += 1
            _ = waitUntil(timeout: 2, { tagMenus.firstMatch.isHittable })
        }
        XCTAssertTrue(
            tagMenus.firstMatch.isHittable,
            "The tag menu control never became hittable inside the info sheet"
        )
        tagMenus.firstMatch.tap()

        // The two state-dependent labels are asserted as either/or, matching the
        // pinned/blacklisted variants the menu renders.
        for label in ["Search Tag", "Add to Search (+tag)", "Exclude from Search (-tag)"] {
            XCTAssertTrue(
                app.buttons[label].waitForExistence(timeout: 10),
                "Tag menu action \"\(label)\" is missing"
            )
        }
        XCTAssertTrue(
            app.buttons["Pin to Favorite Tags"].exists || app.buttons["Unpin Favorite Tag"].exists,
            "The tag menu lost its pin/unpin action"
        )
        XCTAssertTrue(
            app.buttons["Add to Blacklist"].exists || app.buttons["Remove from Blacklist"].exists,
            "The tag menu lost its blacklist action"
        )
        for label in ["Save to Search History", "Copy Tag"] {
            XCTAssertTrue(
                app.buttons[label].exists,
                "Tag menu action \"\(label)\" is missing"
            )
        }
    }

    // MARK: - Elements

    /// Opens the viewer on the first demo post, reusing the same real-gesture path
    /// as `testGridScrollsAndTapOpensViewer`.
    private func openViewer() {
        XCTAssertTrue(
            exploreHeaderButton.waitForExistence(timeout: 30),
            "The Explore feed did not appear (launch arguments: -demoMode -initialTab feed)"
        )
        XCTAssertTrue(
            waitUntil(timeout: 30, { self.firstVisibleCard() != nil }),
            "The demo grid never rendered a tappable post card"
        )
        guard let card = firstVisibleCard() else {
            return XCTFail("The demo grid never rendered a tappable post card")
        }
        card.tap()
        XCTAssertTrue(
            waitUntil(timeout: 20, { self.viewerIsPresented }),
            "Tapping a post card did not open the viewer"
        )
    }

    private var exploreTabBarButton: XCUIElement {
        app.tabBars.buttons["Explore"]
    }

    /// The header title button (`FeedScreen` labels it "Explore. Scroll to top").
    private var exploreHeaderButton: XCUIElement {
        app.buttons["Explore. Scroll to top"]
    }

    /// The tallest scroll view on screen is the masonry grid; the header's chip rows are
    /// short horizontal scroll views and never win this comparison.
    private var gridScrollView: XCUIElement {
        let scrollViews = app.scrollViews.allElementsBoundByIndex
        return scrollViews.max(by: { $0.frame.height < $1.frame.height }) ?? app.scrollViews.firstMatch
    }

    /// The first post card that is on screen and clear of the floating header.
    private func firstVisibleCard() -> XCUIElement? {
        let cards = gridScrollView.buttons.allElementsBoundByIndex
        return cards.first { card in
            card.exists
                && card.isHittable
                && card.frame.height > 40
                && card.frame.minY > Self.headerClearance
        }
    }

    /// `SearchScreen`'s field; its placeholder is the element label while the field is empty.
    private var searchField: XCUIElement {
        let byPlaceholder = app.textFields["Search tags or creators..."]
        return byPlaceholder.exists ? byPlaceholder : app.textFields.firstMatch
    }

    private var favoritesSegmentsAreVisible: Bool {
        app.buttons["Saved Posts"].exists
            || app.segmentedControls.buttons["Saved Posts"].exists
            || app.navigationBars["Favorites"].exists
    }

    /// The viewer is a `fullScreenCover`, so the presenting hierarchy (tab bar included)
    /// leaves the accessibility tree; the badge and close control are extra signals.
    private var viewerIsPresented: Bool {
        if app.buttons["Close"].exists || app.buttons["xmark"].exists { return true }
        let badge = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$"))
        if badge.count > 0 { return true }
        return !exploreTabBarButton.exists
    }

    /// The viewer's own documented dismiss gesture (pull down past 80 pt), with a labelled
    /// close control as a fallback when one exists.
    private func closeViewer() {
        for _ in 0..<3 {
            if app.buttons["Close"].exists {
                app.buttons["Close"].tap()
            } else {
                app.swipeDown()
            }
            if waitUntil(timeout: 5, { self.exploreTabBarButton.exists }) { return }
        }
    }

    // MARK: - Waiting

    /// Polls `condition` without sleeping a fixed amount, because the demo load and the
    /// presentation animations finish at unpredictable times.
    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
