import XCTest

/// Real-gesture regression tests for the multi-page (manga) reader's scroll extent.
///
/// The bug they guard against: a fast nH gallery fling stopped as if the gallery had
/// ended, and further pages only became reachable after their images had loaded. The fix
/// reserves every page's finite width *and* height from source metadata, so the scroll
/// view's content extent is complete before any page image exists.
///
/// Unlike `AppInteractionUITests`, these tests need a *synthetic* gallery whose page
/// images are deliberately delayed: only then can the two states the bug lives in (extent
/// before images, extent after images) be told apart. They never touch a real CDN.
///
/// BLOCKED FIXTURE CONTRACT — no such fixture exists in the app target today, and wiring
/// one needs files outside this task's writable set:
///
///   1. `Sources/App/DemoData.swift` — a demo gallery post plus a demo provider that
///      answers `galleryPages` with a known page list (`-mangaFixture`).
///   2. `Sources/App/AppContainer.swift` — register that provider in `-demoMode`.
///   3. `Sources/Features/Viewer/ViewerViewModel.swift` — `loadGalleryPages(for:)` casts
///      the provider to the concrete `NHentaiSource` (`as? NHentaiSource`) and otherwise
///      falls back to a live `NHentaiSource()`, so an injected provider is ignored. It
///      needs a `galleryPages(for:context:)` protocol member or closure instead.
///   4. A delayed image transport for the fixture URLs (`URLProtocol` double, or a
///      `MediaImageLoader` session injection point).
///
/// Until that lands each test skips with this reason instead of passing vacuously.
/// `Tests/Media/MangaPageLayoutTests.swift` proves the reserved geometry on the pure
/// layout helper in the meantime.
final class MangaScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Launch argument the fixture contract above would honour.
    private static let fixtureArgument = "-mangaFixture"
    /// Direct-open hook: the fixture opens its gallery post instead of the grid.
    private static let openGalleryArgument = "-initialGallery"
    /// Page count the fixture would expose, matching `DemoData`'s gallery post
    /// (`pageCount: 24`). Only used to read the reader's `n / total` indicator.
    private static let fixturePageCount = 24

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-demoMode",
            "-initialTab", "feed",
            Self.fixtureArgument,
            Self.openGalleryArgument,
        ]
        app.launch()
        try requireGalleryFixture()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// The reader must expose its whole extent immediately: before any page image has
    /// decoded, the indicator already counts the full gallery and a fling moves off page 1.
    func testReaderHasFullExtentBeforePageImagesLoad() throws {
        let reader = app.scrollViews["viewer.mangaReader"]
        let indicator = app.staticTexts["viewer.mangaPageIndicator"]

        XCTAssertTrue(indicator.waitForExistence(timeout: 10),
                      "The gallery reader never showed its page indicator")
        XCTAssertEqual(indicator.label, "1 / \(Self.fixturePageCount)",
                       "The reader did not open on page 1 of \(Self.fixturePageCount)")
        XCTAssertEqual(
            app.staticTexts.matching(identifier: "viewer.mangaPageIndicator").count,
            1,
            "The reader rendered more than one page indicator"
        )

        // No image wait on purpose: the assertion is about state *before* load.
        reader.swipeUp(velocity: .fast)
        XCTAssertTrue(
            waitUntil(timeout: 10, { self.pageNumberFromIndicator() > 1 }),
            "A fast fling did not advance the reader while page images were pending; "
                + "indicator stuck at \(indicator.label)"
        )
    }

    /// Repeated flings must reach the final page while the fixture keeps returning
    /// pending images, i.e. the extent never depends on decoded pages.
    func testFastFlingReachesLastPageWhileImagesStayPending() throws {
        let reader = app.scrollViews["viewer.mangaReader"]
        var lastPage = 0

        for _ in 0..<12 {
            reader.swipeUp(velocity: .fast)
            let page = pageNumberFromIndicator()
            XCTAssertGreaterThanOrEqual(page, lastPage, "The reader went backwards")
            lastPage = page
            if page >= Self.fixturePageCount { break }
        }
        XCTAssertEqual(
            lastPage,
            Self.fixturePageCount,
            "Fast flings stopped short of page \(Self.fixturePageCount) while images were pending"
        )
    }

    /// Once images arrive the extent must not change, so the current page cannot shift.
    func testExtentSurvivesImageArrival() throws {
        let reader = app.scrollViews["viewer.mangaReader"]

        reader.swipeUp()
        _ = waitUntil(timeout: 10, { self.pageNumberFromIndicator() > 1 })
        let pageBeforeImages = pageNumberFromIndicator()
        XCTAssertGreaterThan(pageBeforeImages, 1)

        // Let the fixture's delayed images land, then re-read the page indicator.
        _ = waitUntil(timeout: 20, {
            self.pageNumberFromIndicator() >= pageBeforeImages
        })
        XCTAssertGreaterThanOrEqual(
            pageNumberFromIndicator(),
            pageBeforeImages,
            "Image arrival moved the reader backwards (content extent reflowed)"
        )
    }

    // MARK: - Fixture gate

    /// Skips — never passes — when the synthetic gallery fixture is not wired into the app.
    ///
    /// It deliberately does *not* fall back to opening the demo gallery card: `-demoMode`'s
    /// gallery post resolves its pages through a live `NHentaiSource` (see contract item 3),
    /// so that path would make the test depend on a real CDN.
    private func requireGalleryFixture() throws {
        if app.scrollViews["viewer.mangaReader"].waitForExistence(timeout: 5) { return }

        throw XCTSkip(
            """
            Synthetic gallery fixture is not wired into the app target, so the manga \
            reader's fixed-extent behaviour cannot be driven deterministically. Required \
            contract (all outside this task's writable files):
              - DemoData: a demo gallery post + provider returning a known page list \
            (\(Self.fixturePageCount) pages) with deliberately delayed images.
              - AppContainer: register that provider in -demoMode for \(Self.fixtureArgument).
              - ViewerViewModel.loadGalleryPages(for:): stop hard-casting the provider to \
            NHentaiSource (it currently ignores an injected provider and falls back to a \
            live NHentaiSource).
              - A delayed image transport (URLProtocol double or MediaImageLoader session \
            injection) for the fixture URLs.
            MangaPageLayoutTests proves the reserved geometry unit-side in the meantime.
            """
        )
    }

    // MARK: - Helpers

    /// `n` from the `n / total` indicator, or `0` when it cannot be read yet.
    private func pageNumberFromIndicator() -> Int {
        let label = app.staticTexts["viewer.mangaPageIndicator"].label
        guard let first = label.split(separator: "/").first else { return 0 }
        return Int(String(first).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Polls `condition` without sleeping a fixed amount, because the fixture's delays and
    /// the presentation animations finish at unpredictable times.
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
