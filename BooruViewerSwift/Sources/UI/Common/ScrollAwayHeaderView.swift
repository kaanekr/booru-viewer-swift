import SwiftUI

/// Height of the header content, reported so the grid can reserve exactly that much
/// space under the overlay (the RN header measures itself the same way,
/// src/utils/scrollAwayHeader.ts).
struct ScrollAwayHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Scroll offset of the host scroll content, measured from the top of that content.
///
/// The owner puts `scrollAwayOffsetReader(space:)` on the scroll content and names the
/// same space on the `ScrollView`; the last published sample wins, because only the
/// active list is on screen at a time.
struct ScrollAwayOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Publishes how far the receiver has scrolled past the top of `space`.
    ///
    /// Attach it to the scroll content (not to the `ScrollView`) so the value is the
    /// content offset including any reserved header space, and the header math can use
    /// plain `0...` arithmetic. Negative values are the top rubber band.
    func scrollAwayOffsetReader(space: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollAwayOffsetKey.self,
                    value: -proxy.frame(in: .named(space)).minY
                )
            }
        }
    }
}

/// Opaque Explore/Search header that slides up as the grid scrolls, mirroring RN
/// `ScrollAwayHeader` (src/components/ScrollAwayHeader.tsx).
///
/// The component is an overlay: it keeps its intrinsic height, paints the theme
/// background, and is translated by `slideOffset`. The offset is driven continuously
/// by `ScrollAwayHeaderState`, so the bar follows the finger instead of snapping.
/// `isPinned` freezes it in place for refreshes, editing, and open sheets, and
/// `isHidden` drops hit testing once it is completely out of view so the cards that
/// scrolled underneath stay tappable.
struct ScrollAwayHeaderView<Content: View>: View {
    /// Negative values move the controls (and their surface) up out of view.
    private let slideOffset: CGFloat
    /// When true the header ignores `slideOffset`.
    private let isPinned: Bool
    /// Height of the fixed opaque cover drawn above the controls (status bar area).
    private let topInset: CGFloat
    /// True when the header is fully slid away; it must not swallow taps then.
    private let isHidden: Bool
    private let content: Content

    init(
        slideOffset: CGFloat = 0,
        isPinned: Bool = false,
        topInset: CGFloat = 0,
        isHidden: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.slideOffset = slideOffset
        self.isPinned = isPinned
        self.topInset = topInset
        self.isHidden = isHidden
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.background)
            .offset(y: isPinned ? 0 : slideOffset)
            .allowsHitTesting(isPinned || !isHidden)
            .background(alignment: .top) {
                // RN keeps the safe-area strip opaque while the controls slide away
                // (ScrollAwayHeader.tsx:22-24). Drawn above the layout, so it changes no height.
                if topInset > 0 {
                    AppTheme.background
                        .frame(height: topInset)
                        .offset(y: -topInset)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ScrollAwayHeaderHeightKey.self, value: proxy.size.height)
                }
            }
    }
}
