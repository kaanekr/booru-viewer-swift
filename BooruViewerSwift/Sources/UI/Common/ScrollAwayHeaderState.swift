import CoreGraphics

/// Continuous collapse state for the Explore and Search headers.
///
/// The bar tracks the finger instead of snapping between two positions: every
/// downward scroll delta grows the collapsed distance and every upward delta
/// shrinks it, clamped to `0...height`. The bar therefore starts sliding on the
/// first scrolled point (it no longer waits for a full header height), an upward
/// drag anywhere in the list brings it back, and the top of the list always shows
/// it fully.
///
/// The view feeds it the clamped content offset, so the rubber band at the top is
/// handled by rebasing at `offset <= 0`: pull-to-refresh never flickers and never
/// counts as travel. Sub-point jitter is buffered instead of applied, and a small
/// opposite-direction threshold keeps a stray pixel from reversing the bar.
///
/// The type is pure and free of SwiftUI so the scroll rules are unit-testable.
struct ScrollAwayHeaderState: Sendable {
    /// Movement below this is buffered, not applied, so touch jitter cannot
    /// wobble the header.
    static let jitterThreshold: CGFloat = 0.5

    /// Opposite-direction travel needed before the header reverses; keeps a
    /// micro-bounce at a resting point from flipping the bar.
    static let reversalThreshold: CGFloat = 4

    /// Starts revealed with no measured height and no scroll baseline.
    init() {}

    private enum Direction: Equatable, Sendable {
        case none
        case collapsing
        case revealing
    }

    /// Measured header height in points, refreshed by the view on layout.
    private(set) var height: CGFloat = 0

    /// How much of the header is currently slid out of view, `0...height`.
    private(set) var collapse: CGFloat = 0

    /// Previous content offset; `nil` until the next sample re-establishes a
    /// baseline (right after an explicit reset).
    private var lastOffset: CGFloat?
    /// Sub-threshold movement carried to the next sample so nothing is lost.
    private var bufferedDelta: CGFloat = 0
    /// Opposite-direction movement accumulated until it is deliberate.
    private var bufferedReversal: CGFloat = 0
    private var direction: Direction = .none

    /// Translation to apply to the header view (`-height` is fully hidden).
    var slide: CGFloat { -collapse }

    /// `0` fully visible, `1` fully slid away.
    var progress: CGFloat {
        guard height > 0 else { return 0 }
        return min(1, max(0, collapse / height))
    }

    /// True only once the whole header is out of view, so it can drop hit testing.
    var isFullyCollapsed: Bool { height > 0 && collapse >= height - 0.5 }

    /// Feeds one scroll sample and returns the header translation.
    ///
    /// - Parameters:
    ///   - rawOffset: content offset measured from the top of the list (negative
    ///     while the user pulls the list down past its top).
    ///   - newHeight: current measured header height.
    @discardableResult
    mutating func update(offset rawOffset: CGFloat, height newHeight: CGFloat) -> CGFloat {
        syncHeight(newHeight)
        guard rawOffset.isFinite, height > 0 else {
            collapse = 0
            return slide
        }
        guard rawOffset > 0 else {
            // Top of the list or the pull-to-refresh rubber band: keep the bar open
            // at the true zero baseline, so the pull never counts as travel and the
            // first real scrolled point already collapses the header.
            collapse = 0
            lastOffset = 0
            bufferedDelta = 0
            bufferedReversal = 0
            direction = .none
            return slide
        }
        guard let previous = lastOffset else {
            // First sample after an explicit reset: rebase instead of applying the
            // whole distance the list was already scrolled by.
            lastOffset = rawOffset
            return slide
        }
        lastOffset = rawOffset

        var delta = (rawOffset - previous) + bufferedDelta
        bufferedDelta = 0
        guard abs(delta) >= Self.jitterThreshold else {
            bufferedDelta = delta
            return slide
        }

        let incoming: Direction = delta > 0 ? .collapsing : .revealing
        if direction == .none {
            direction = incoming
        } else if direction == incoming {
            bufferedReversal = 0
        } else {
            bufferedReversal += delta
            guard abs(bufferedReversal) >= Self.reversalThreshold else {
                return slide
            }
            // Apply the whole withheld reversal, not just the last event.
            delta = bufferedReversal
            bufferedReversal = 0
            direction = incoming
        }

        collapse = min(height, max(0, collapse + delta))
        return slide
    }

    /// Stores a fresh measured height. A bar that grew or shrank while fully hidden
    /// stays fully hidden; a partly hidden bar keeps its raw slide distance, clamped
    /// to the new size, so nothing pops in.
    mutating func syncHeight(_ newHeight: CGFloat) {
        let clamped = max(0, newHeight)
        guard abs(clamped - height) >= 0.5 else { return }
        let wasFullyCollapsed = isFullyCollapsed
        height = clamped
        collapse = wasFullyCollapsed ? height : min(collapse, height)
    }

    /// Fully reveals the header and forgets the scroll baseline, so the next
    /// sample rebases instead of applying a stale jump. Used by refresh, sheet
    /// presentation, remeasurement, editing entry, and source/filter resets.
    mutating func reset() {
        collapse = 0
        lastOffset = nil
        bufferedDelta = 0
        bufferedReversal = 0
        direction = .none
    }
}
