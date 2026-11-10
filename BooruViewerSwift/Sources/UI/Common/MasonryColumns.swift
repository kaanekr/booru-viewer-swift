import CoreGraphics
import Foundation

/// Height-balanced column split for the Explore grid.
///
/// RN runs the same greedy pass over the loaded posts in points
/// (src/screens/FeedScreen.tsx:270-294): every card joins the column with the
/// smallest accumulated height, so both columns end level and no dead space is
/// left under the shorter one. The pass is deterministic and append-only, so
/// paging in another page never reshuffles the cards already on screen.
///
/// Heights are estimated from the card's presentation rules instead of measured:
/// the stored `aspectRatio`, then the ratio `MediaAspectRatioCache` measured for
/// the post, then a per-source default, clamped to `0.5...1.78` (the same clamp
/// `PostCardView` applies), plus one fixed badge/footer allowance.
struct MasonryColumns {
    /// Columns the Explore grid renders (FeedScreen.tsx:504).
    static let defaultColumnCount = 2

    /// Fixed badge/footer allowance added to every estimated card height.
    static let badgeFooterAllowance: CGFloat = 44

    /// Number of columns to fill; always at least one.
    let columnCount: Int

    init(columnCount: Int = MasonryColumns.defaultColumnCount) {
        self.columnCount = max(1, columnCount)
    }

    // MARK: Layout

    /// Greedy masonry pass, `O(items * columnCount)`.
    ///
    /// Items keep their input order inside each column and ties go to the
    /// leftmost column, so the result only depends on the input sequence.
    /// Nothing is stored between passes; the only allocation is the returned
    /// column array.
    mutating func layout(
        _ items: [BooruPost],
        estimatedHeight: (BooruPost) -> CGFloat
    ) -> [[BooruPost]] {
        var columns = [[BooruPost]](repeating: [], count: columnCount)
        var heights = [CGFloat](repeating: 0, count: columnCount)
        let perColumn = items.count / columnCount + 1
        for index in columns.indices {
            columns[index].reserveCapacity(perColumn)
        }

        for item in items {
            var target = 0
            var index = 1
            while index < columnCount {
                if heights[index] < heights[target] {
                    target = index
                }
                index += 1
            }
            columns[target].append(item)
            heights[target] += max(estimatedHeight(item), 0)
        }
        return columns
    }

    // MARK: Estimation

    /// Estimated rendered height of one card at `columnWidth` points.
    static func estimatedHeight(for post: BooruPost, columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return badgeFooterAllowance }
        return columnWidth / CGFloat(clampedAspectRatio(post)) + badgeFooterAllowance
    }

    /// Aspect ratio used for the estimate: the stored value, then the ratio the
    /// image loader measured for the post, then the per-source default, clamped
    /// to `0.5...1.78` (same clamp as `PostCardView`).
    static func clampedAspectRatio(_ post: BooruPost) -> Double {
        let postRatio = post.aspectRatio > 0 ? post.aspectRatio : nil
        let rawRatio = postRatio ?? MediaAspectRatioCache.aspectRatio(for: post) ?? defaultAspectRatio(for: post)
        return min(1.78, max(0.5, rawRatio))
    }

    /// Video sources render in a landscape player, nhentai pages are portrait,
    /// every other source keeps the 0.75 card fallback (PostCard.tsx:84).
    static func defaultAspectRatio(for post: BooruPost) -> Double {
        switch post.sourceID {
        case .xvideos, .xhamster, .pornhub: return 16.0 / 9.0
        case .nhentai: return 0.71
        default: return 0.75
        }
    }
}
