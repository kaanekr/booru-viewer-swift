import CoreGraphics
import XCTest
@testable import BooruViewer

/// Greedy masonry split behind the Explore grid (Sources/UI/Common/MasonryColumns.swift).
/// The reference behaviour is RN src/screens/FeedScreen.tsx:270-294 and the card clamp
/// in src/components/PostCard.tsx:84.
final class MasonryColumnsTests: XCTestCase {
    // MARK: - Fixtures

    private func makePost(_ id: String, aspectRatio: Double = 1) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: .gelbooru,
            sourceName: "Example",
            title: nil,
            previewURL: nil,
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: nil,
            originalURL: nil,
            width: 1000,
            height: 1000,
            aspectRatio: aspectRatio,
            rating: .general,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(artist: [], character: [], copyright: [], general: [], meta: []),
            allTags: [],
            sourceLink: nil,
            fileExt: nil,
            fileSize: nil,
            createdAt: "2026-01-01T00:00:00Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    /// One full pass over `posts`, using `heights` as the per-post estimated height.
    private func layout(_ posts: [BooruPost], heights: [CGFloat]) -> [[BooruPost]] {
        let table = Dictionary(uniqueKeysWithValues: zip(posts.map(\.id), heights))
        var masonry = MasonryColumns()
        return masonry.layout(posts) { table[$0.id] ?? 0 }
    }

    private func totalHeight(_ column: [BooruPost], heights: [CGFloat]) -> CGFloat {
        column.reduce(CGFloat.zero) { $0 + (heights[Int($1.id) ?? 0]) }
    }

    // MARK: - Balance

    /// The reported bug: short/long cards left holes under the shorter column.
    /// The greedy pass bounds the imbalance by the tallest single card.
    func testHeightBalancedColumnsFillGaps() {
        let posts = (0..<4).map { makePost("\($0)") }
        let heights: [CGFloat] = [300, 120, 120, 300]
        let columns = layout(posts, heights: heights)

        XCTAssertEqual(columns.count, 2)
        let left = totalHeight(columns[0], heights: heights)
        let right = totalHeight(columns[1], heights: heights)
        XCTAssertLessThanOrEqual(abs(left - right), heights.max() ?? 0)
        // Every card is placed exactly once.
        XCTAssertEqual(columns.flatMap { $0.map(\.id) }.sorted(), posts.map(\.id).sorted())
    }

    /// After a 200pt card the two columns are tied, so the next cards alternate:
    /// 0 -> left, 1 -> right, 2 -> left (tie goes leftmost), 3 -> right.
    func testEqualHeightsAlternateColumns() {
        let posts = (0..<4).map { makePost("\($0)") }
        let columns = layout(posts, heights: [100, 100, 100, 100])

        XCTAssertEqual(columns[0].map(\.id), ["0", "2"])
        XCTAssertEqual(columns[1].map(\.id), ["1", "3"])
    }

    /// The short column keeps receiving cards until it catches up.
    func testNextItemFillsShorterColumn() {
        let posts = (0..<3).map { makePost("\($0)") }
        let columns = layout(posts, heights: [200, 100, 100])

        XCTAssertEqual(columns[0].map(\.id), ["0"])
        XCTAssertEqual(columns[1].map(\.id), ["1", "2"])
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsEmptyColumns() {
        let columns = layout([], heights: [])

        XCTAssertEqual(columns.count, 2)
        XCTAssertTrue(columns[0].isEmpty)
        XCTAssertTrue(columns[1].isEmpty)
    }

    func testSingleItemLandsInFirstColumn() {
        let columns = layout([makePost("solo")], heights: [300])

        XCTAssertEqual(columns[0].map(\.id), ["solo"])
        XCTAssertTrue(columns[1].isEmpty)
    }

    // MARK: - Height estimation

    /// Mirrors `PostCardView`: clamp 0.5...1.78 with a 0.75 fallback plus the
    /// badge/footer allowance.
    func testEstimatedHeightClampsAspectRatioPlusBadgeAllowance() {
        let columnWidth: CGFloat = 200

        XCTAssertEqual(
            MasonryColumns.estimatedHeight(
                for: makePost("square", aspectRatio: 1),
                columnWidth: columnWidth
            ),
            columnWidth + MasonryColumns.badgeFooterAllowance,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MasonryColumns.estimatedHeight(
                for: makePost("tall", aspectRatio: 0.2),
                columnWidth: columnWidth
            ),
            columnWidth / 0.5 + MasonryColumns.badgeFooterAllowance,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MasonryColumns.estimatedHeight(
                for: makePost("wide", aspectRatio: 3),
                columnWidth: columnWidth
            ),
            columnWidth / 1.78 + MasonryColumns.badgeFooterAllowance,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MasonryColumns.estimatedHeight(
                for: makePost("unknown", aspectRatio: 0),
                columnWidth: columnWidth
            ),
            columnWidth / 0.75 + MasonryColumns.badgeFooterAllowance,
            accuracy: 0.001
        )
    }
}
