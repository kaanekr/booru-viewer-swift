import XCTest
import Foundation
import CoreGraphics
@testable import BooruViewer

/// Deterministic geometry of the manga reader's reserved page slots.
///
/// These run on the pure `MangaPageLayout` helper only: no images, no network, no UI, so
/// the reader's fixed scroll extent is provable before a single page has downloaded.
final class MangaPageLayoutTests: XCTestCase {
    /// Reader width used by most fixtures.
    private let width: CGFloat = 400
    /// A page that reserves 800 pt at `width` (`400 / 0.5`).
    private let tallPageRatio: Double = 0.5

    private func repeated(_ ratio: Double?, count: Int) -> [Double?] {
        Array(repeating: ratio, count: count)
    }

    /// Inclusive content-space band helper, so the tests read like the reader's window.
    private func band(_ lower: CGFloat, _ upper: CGFloat) -> ClosedRange<CGFloat> {
        lower...upper
    }

    // MARK: - Reservation on reader initialization

    func testTwentyPagesReserveKnownHeightsAndOffsetsBeforeAnyImageLoads() {
        let layout = MangaPageLayout(
            pageCount: 20,
            width: width,
            ratios: repeated(tallPageRatio, count: 20)
        )

        XCTAssertEqual(layout.pageCount, 20)
        XCTAssertEqual(layout.width, width)
        XCTAssertEqual(layout.slots.count, 20)
        XCTAssertEqual(layout.slots[0].originY, 0)
        XCTAssertEqual(layout.slots[0].height, 800, accuracy: 0.0001)
        XCTAssertEqual(layout.slots[1].originY, 800, accuracy: 0.0001)
        XCTAssertEqual(layout.totalHeight, 20 * 800, accuracy: 0.0001)

        // Every page is finite in both dimensions: no intrinsic-size guessing.
        for slot in layout.slots {
            XCTAssertEqual(slot.width, width)
            XCTAssertTrue(slot.height.isFinite)
            XCTAssertGreaterThan(slot.height, 0)
        }
        // The total is exactly the sum of the reserved heights (no gap here).
        XCTAssertEqual(layout.slots.map(\.height).reduce(0, +), layout.totalHeight, accuracy: 0.0001)
    }

    /// Page 15 (index 14) sits at a known content offset with no image loaded, and the
    /// content extent already reaches it.
    func testPageFifteenOffsetIsValidBeforeImagesArrive() throws {
        let layout = MangaPageLayout(
            pageCount: 20,
            width: width,
            ratios: repeated(tallPageRatio, count: 20)
        )

        let origin = try XCTUnwrap(layout.originY(of: 14))
        XCTAssertEqual(origin, 14 * 800, accuracy: 0.0001)
        XCTAssertEqual(layout.slots[14].originY, origin)
        XCTAssertEqual(layout.slots[14].height, 800, accuracy: 0.0001)

        // The gallery is long enough to scroll page 15 fully into view.
        XCTAssertGreaterThanOrEqual(layout.totalHeight, layout.slots[14].maxY)
        // And the target resolves from the offset alone, not from a mounted view.
        XCTAssertEqual(layout.index(atOffset: origin), 14)
        XCTAssertEqual(layout.index(atOffset: origin + 799), 14)
        XCTAssertEqual(layout.index(atOffset: layout.slots[14].maxY), 15)
    }

    /// Mixed slot heights: offsets accumulate exactly, so a page's position never depends
    /// on its neighbours' image state.
    func testMixedPageHeightsProduceContiguousOffsets() {
        // height = width / ratio: 400/0.5 = 800, 400/1 = 400, 400/2 = 200.
        let layout = MangaPageLayout(pageCount: 3, width: width, ratios: [0.5, 1.0, 2.0])

        XCTAssertEqual(layout.slots.map(\.height), [800, 400, 200])
        XCTAssertEqual(layout.slots.map(\.originY), [0, 800, 1200])
        XCTAssertEqual(layout.totalHeight, 1400, accuracy: 0.0001)
    }

    // MARK: - Extent invariant after an image arrives

    /// The reader freezes its ratio snapshot, so a page image that later reports a
    /// different measured ratio cannot resize the slot or move the total extent.
    func testExtentIsInvariantAfterImageArrival() throws {
        let urls = (0..<20).compactMap {
            URL(string: "https://manga-layout-tests.invalid/galleries/1/\($0 + 1).jpg")
        }
        XCTAssertEqual(urls.count, 20)
        let frozen = repeated(tallPageRatio, count: 20)
        let before = MangaPageLayout(pageCount: 20, width: width, ratios: frozen)

        // A decoded page records its real ratio in the shared memo. That measurement is
        // exactly what used to flow back into the body and resize the reserved slot.
        MediaAspectRatioCache.record(width: 1200, height: 1200, for: urls[3])
        let measured = try XCTUnwrap(MediaAspectRatioCache.aspectRatio(for: urls[3]))
        XCTAssertEqual(measured, 1.0, accuracy: 0.0001,
                       "Precondition: the measured ratio differs from the reserved one")

        // The layout built from the frozen snapshot is unchanged.
        let after = MangaPageLayout(pageCount: 20, width: width, ratios: frozen)
        XCTAssertEqual(after.totalHeight, before.totalHeight, accuracy: 0.0001)
        XCTAssertEqual(after.slots.map(\.originY), before.slots.map(\.originY))
        XCTAssertEqual(after.slots.map(\.height), before.slots.map(\.height))

        // Re-deriving from the live cache is what must be avoided: it changes the extent.
        let reread = MangaPageLayout(
            pageCount: 20,
            width: width,
            ratios: urls.map { MediaAspectRatioCache.aspectRatio(for: $0) }
        )
        XCTAssertNotEqual(reread.totalHeight, before.totalHeight, accuracy: 0.0001)
    }

    // MARK: - Invalid / missing dimensions

    func testInvalidAndNilRatiosFallBackToPortraitPage() {
        let ratios: [Double?] = [nil, 0, -2, Double.nan, Double.infinity, 0.001]
        let layout = MangaPageLayout(pageCount: 6, width: width, ratios: ratios)

        let expectedHeight = width / CGFloat(MangaPageLayout.fallbackRatio)
        for slot in layout.slots {
            XCTAssertEqual(slot.height, expectedHeight, accuracy: 0.0001)
        }
        XCTAssertEqual(layout.totalHeight, 6 * expectedHeight, accuracy: 0.0001)
        XCTAssertEqual(MangaPageLayout.fallbackRatio, 0.707, accuracy: 0.000_001)
    }

    func testRatioListShorterThanPageCountStillReservesEveryPage() {
        let layout = MangaPageLayout(pageCount: 3, width: width, ratios: [1.0])

        XCTAssertEqual(layout.slots.count, 3)
        XCTAssertEqual(layout.slots[0].height, 400, accuracy: 0.0001)
        let fallbackHeight = width / CGFloat(MangaPageLayout.fallbackRatio)
        XCTAssertEqual(layout.slots[1].height, fallbackHeight, accuracy: 0.0001)
        XCTAssertEqual(layout.slots[2].height, fallbackHeight, accuracy: 0.0001)
    }

    func testAbsurdRatiosAreClampedOrReplacedNotTrusted() {
        // A sliver ratio is not usable at all: the page falls back to the portrait page.
        XCTAssertEqual(MangaPageLayout.resolvedRatio(0.0001), MangaPageLayout.fallbackRatio)
        // A very wide but valid ratio is clamped so one page cannot reserve a kilometre.
        XCTAssertEqual(MangaPageLayout.resolvedRatio(1_000), MangaPageLayout.maximumRatio)
        XCTAssertNil(MangaPageLayout.validRatio(nil))
        XCTAssertNil(MangaPageLayout.validRatio(0))
        XCTAssertNil(MangaPageLayout.validRatio(Double.nan))
        XCTAssertNil(MangaPageLayout.validRatio(-1))
        let known = MangaPageLayout.validRatio(0.707) ?? 0
        XCTAssertEqual(known, 0.707, accuracy: 0.000_001)
    }

    func testUnusableWidthReservesZeroExtentInsteadOfInfiniteHeight() {
        let ratios = repeated(tallPageRatio, count: 5)
        for badWidth in [CGFloat(0), -100, .nan, .infinity] {
            let layout = MangaPageLayout(pageCount: 5, width: badWidth, ratios: ratios)
            XCTAssertEqual(layout.width, 0, "width \(badWidth) must not be trusted")
            XCTAssertEqual(layout.totalHeight, 0)
            XCTAssertTrue(layout.slots.allSatisfy { $0.height == 0 })
            // No page is reachable before a real width arrives, and nothing traps.
            XCTAssertEqual(layout.index(atOffset: 500), 0)
        }
    }

    func testEmptyAndNegativePageCountsProduceNoContent() {
        let empty = MangaPageLayout(pageCount: 0, width: width, ratios: [])
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertTrue(empty.slots.isEmpty)
        XCTAssertEqual(empty.totalHeight, 0)
        XCTAssertNil(empty.index(atOffset: 0))
        XCTAssertNil(empty.originY(of: 0))
        XCTAssertTrue(empty.indices(intersecting: band(0, 1_000)).isEmpty)

        let negative = MangaPageLayout(pageCount: -4, width: width, ratios: [0.5])
        XCTAssertEqual(negative.pageCount, 0)
        XCTAssertEqual(negative.totalHeight, 0)
    }

    // MARK: - Width / orientation change

    /// A width change recalculates heights proportionally, so the same page index stays the
    /// anchor rather than the old raw offset.
    func testWidthChangeRecalculatesHeightsAndPreservesPageIndex() {
        let ratios = repeated(tallPageRatio, count: 20)
        let portrait = MangaPageLayout(pageCount: 20, width: 400, ratios: ratios)
        let wider = MangaPageLayout(pageCount: 20, width: 800, ratios: ratios)

        XCTAssertEqual(wider.totalHeight, portrait.totalHeight * 2, accuracy: 0.0001)
        for (before, after) in zip(portrait.slots, wider.slots) {
            XCTAssertEqual(after.originY, before.originY * 2, accuracy: 0.0001)
            XCTAssertEqual(after.height, before.height * 2, accuracy: 0.0001)
        }

        // The page under the viewport top survives the change: the same index is found
        // again at the rescaled offset.
        for index in [0, 5, 14, 19] {
            let offset = portrait.slots[index].originY + 40
            XCTAssertEqual(portrait.index(atOffset: offset), index)
            XCTAssertEqual(wider.index(atOffset: offset * 2), index)
        }
    }

    func testGapIsCountedOnceBetweenPages() {
        let layout = MangaPageLayout(pageCount: 3, width: width, ratios: [0.5, 0.5, 0.5], gap: 8)

        XCTAssertEqual(layout.slots.map(\.originY), [0, 808, 1616])
        // Two gaps for three pages: the trailing gap after the last page is not content.
        XCTAssertEqual(layout.totalHeight, 3 * 800 + 2 * 8, accuracy: 0.0001)
        XCTAssertEqual(layout.slots[2].maxY, layout.totalHeight, accuracy: 0.0001)
    }

    func testNegativeOrNaNGapIsIgnored() {
        for gap in [CGFloat(-5), .nan] {
            let layout = MangaPageLayout(pageCount: 2, width: width, ratios: [0.5, 0.5], gap: gap)
            XCTAssertEqual(layout.totalHeight, 1600, accuracy: 0.0001)
        }
    }

    // MARK: - Bounded render window

    /// Only a viewport-sized band (plus overscan) may materialise page images, so the full
    /// extent is scrollable without starting 20 downloads.
    func testRenderWindowIsBoundedToTheViewport() {
        let layout = MangaPageLayout(
            pageCount: 20,
            width: width,
            ratios: repeated(tallPageRatio, count: 20)
        )
        let viewport: CGFloat = 800

        XCTAssertEqual(layout.indices(intersecting: band(0, viewport * 2)), Set([0, 1]))

        // Scroll to page 15: the window follows without touching page 0 again.
        let origin = layout.slots[14].originY
        let scrolled = layout.indices(
            intersecting: band(origin - viewport, origin + viewport * 2)
        )
        XCTAssertTrue(scrolled.contains(14))
        XCTAssertFalse(scrolled.contains(0))
        XCTAssertLessThanOrEqual(scrolled.count, 4)

        // The window never widens the content extent: it is a subset of reserved pages.
        XCTAssertTrue(scrolled.allSatisfy { layout.slots.indices.contains($0) })
    }

    func testIndexAtOffsetClampsBeyondTheEnds() {
        let layout = MangaPageLayout(
            pageCount: 4,
            width: width,
            ratios: repeated(1.0, count: 4)
        )

        XCTAssertEqual(layout.index(atOffset: -500), 0)
        XCTAssertEqual(layout.index(atOffset: 0), 0)
        XCTAssertEqual(layout.index(atOffset: 10_000), 3)
        XCTAssertEqual(layout.index(atOffset: .nan), 0)
    }
}
