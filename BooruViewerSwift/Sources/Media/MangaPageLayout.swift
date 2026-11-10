import CoreGraphics

/// Reserved geometry of the vertical multi-page reader, computed once from ratios the
/// source already knows.
///
/// The reader used to reserve each page with `Color.clear
/// .aspectRatio(ratio, contentMode: .fit).frame(maxWidth: .infinity)` inside a
/// `LazyVStack`: neither dimension was finite before the page image arrived, so the lazy
/// stack only knew the height of the pages it had already created. A fast flick ran out
/// of scroll extent at the last materialised page and behaved as if the gallery had
/// ended; the remaining pages became reachable only once enough images had loaded for the
/// stack to grow. More cache and more prefetch never changed that, because neither
/// changes where the scroll view thinks the content ends.
///
/// This type gives every page a finite width *and* height up front, so the reader's
/// content height is exact on the first layout pass and no image load can change it.
struct MangaPageLayout: Equatable {
    /// One page's reserved slot in the reader's content space.
    struct Slot: Identifiable, Equatable {
        let index: Int
        /// Distance from the top of the gallery content to the top of this page.
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat

        var id: Int { index }
        var maxY: CGFloat { originY + height }
    }

    /// Portrait fallback when neither a measured ratio nor the post ratio is usable:
    /// `1 / sqrt(2) ≈ 0.707`, the ratio of an A-series page.
    static let fallbackRatio: Double = 0.707
    /// Anything at or below this is not a page ratio (`0`, `NaN`, `∞`, a degenerate sliver).
    static let minimumRatio: Double = 0.05
    /// Keeps a tiny-but-valid ratio from reserving an absurdly tall page.
    static let maximumRatio: Double = 20

    /// Number of reserved pages.
    let pageCount: Int
    /// Width every page slot reserves; `0` when the container width is not usable yet.
    let width: CGFloat
    /// Reserved slots, in reading order.
    let slots: [Slot]
    /// Sum of the reserved heights plus the gaps between them: the reader's exact
    /// scrollable content height, known before any page image has loaded.
    let totalHeight: CGFloat

    /// - Parameters:
    ///   - pageCount: Number of gallery pages. Values below zero are treated as zero.
    ///   - width: Reader width every page is laid out into (points).
    ///   - ratios: `width / height` per page, in page order. A missing entry, `nil`,
    ///     `NaN`, `0` or a negative value falls back to ``fallbackRatio``. The array may
    ///     be shorter than `pageCount`.
    ///   - gap: Vertical gap between two pages (points).
    init(pageCount: Int, width: CGFloat, ratios: [Double?], gap: CGFloat = 0) {
        let count = max(pageCount, 0)
        let safeWidth = (width.isFinite && width > 0) ? width : 0
        let safeGap = (gap.isFinite && gap > 0) ? gap : 0

        var slots: [Slot] = []
        slots.reserveCapacity(count)
        var origin: CGFloat = 0
        for index in 0..<count {
            let ratio = Self.resolvedRatio(ratios.indices.contains(index) ? ratios[index] : nil)
            let height = safeWidth > 0 ? safeWidth / CGFloat(ratio) : 0
            slots.append(Slot(index: index, originY: origin, width: safeWidth, height: height))
            origin += height + safeGap
        }

        self.pageCount = count
        self.width = safeWidth
        self.slots = slots
        // The running origin already includes one gap after the last page.
        self.totalHeight = max(origin - (slots.isEmpty ? 0 : safeGap), 0)
    }

    /// Indices of the pages whose reserved slot intersects `range` (a content-space y
    /// band, normally the viewport plus overscan). Empty for a degenerate range.
    func indices(intersecting range: ClosedRange<CGFloat>) -> Set<Int> {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, !slots.isEmpty else { return [] }
        return Set(slots.lazy
            .filter { $0.height > 0 && $0.maxY > range.lowerBound && $0.originY < range.upperBound }
            .map(\.index))
    }

    /// Index of the page under `offset` (a content-space y, normally the top of the
    /// viewport), clamped to the gallery. `nil` only for an empty gallery; a layout whose
    /// width was not usable yet reports the first page instead of a phantom last one.
    func index(atOffset offset: CGFloat) -> Int? {
        guard let first = slots.first else { return nil }
        guard offset.isFinite else { return first.index }
        var lastMeasurable: Int?
        for slot in slots where slot.height > 0 {
            if offset < slot.maxY { return slot.index }
            lastMeasurable = slot.index
        }
        return lastMeasurable ?? first.index
    }

    /// Top of `index`'s reserved slot, or `nil` when the page does not exist.
    func originY(of index: Int) -> CGFloat? {
        slots.indices.contains(index) ? slots[index].originY : nil
    }

    /// `value` when it is a usable page ratio, `nil` otherwise.
    static func validRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > minimumRatio else { return nil }
        return min(value, maximumRatio)
    }

    /// The ratio a page reserves, falling back to a portrait page when unknown.
    static func resolvedRatio(_ value: Double?) -> Double {
        validRatio(value) ?? fallbackRatio
    }
}
