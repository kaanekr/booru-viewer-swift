import Foundation
import SwiftUI

/// Tag pill, mirroring RN `TagChip` (src/components/TagChip.tsx).
///
/// The tag text is shown with `_` replaced by a space (TagChip.tsx:22), the count is
/// abbreviated exactly like RN (TagChip.tsx:24-28), and the palette comes from
/// `TagColors` through `AppTheme`.
///
/// Two shapes, one contract:
/// * `onTap != nil` renders a real `Button` with the native iOS 26 Liquid Glass button
///   style (`.buttonStyle(.glass)`), tinted with the category colour. The 44 x 44 pt lane
///   is the button *label*, so the whole target is the button's own content region and
///   nothing is painted outside it. Selection shows as heavier weight plus a checkmark
///   glyph, so the category colour stays the label colour and no `.buttonStyle`
///   conditional has to pick between two different concrete style types.
/// * `onTap == nil` renders inert content (tinted wash + category hairline), never a
///   button, so non-interactive tags are not announced as tappable.
struct TagChipView: View {
    private let text: String
    private let category: TagCategory
    private let count: Int?
    private let isSelected: Bool
    private let onTap: (() -> Void)?

    /// - Parameters:
    ///   - text: raw tag name; underscores are displayed as spaces.
    ///   - category: drives the text/background/border colors.
    ///   - count: optional post count shown in the trailing badge.
    ///   - isSelected: stronger fill and border for an active tag.
    ///   - onTap: when `nil` the chip is not interactive.
    init(
        text: String,
        category: TagCategory = .general,
        count: Int? = nil,
        isSelected: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.text = text
        self.category = category
        self.count = count
        self.isSelected = isSelected
        self.onTap = onTap
    }

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                // The 44 x 44 hit lane belongs to the label, so the whole target is the
                // button's own content region (a frame outside the style would only pad the
                // outer container). Text stays small; only the tap area grows.
                content(interactive: true)
                    .frame(
                        minWidth: AppTheme.Spacing.minimumHitTarget,
                        minHeight: AppTheme.Spacing.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .tint(AppTheme.tagColor(for: category))
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        } else {
            content(interactive: false)
                .background(fill, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.tagBorder(for: category), lineWidth: isSelected ? 1.5 : 1)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    // MARK: Content

    /// Text, optional count badge, and the selection glyph — shared by both variants.
    /// Padding lives here so the glass artwork hugs the copy.
    private func content(interactive: Bool) -> some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(AppTheme.Typography.body)
                .fontWeight(isSelected ? .bold : .semibold)
                .lineLimit(1)
                .truncationMode(.tail)

            if let count {
                countBadge(count, framed: !interactive)
            }

            // Interactive selections get a checkmark: the `.glass` style keeps the label in
            // the tint colour, so weight + glyph carry the selected state. Static chips keep
            // their existing selected look (stronger wash + thicker hairline) unchanged.
            if isSelected, interactive {
                Image(systemName: "checkmark")
                    .font(AppTheme.Typography.caption)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(AppTheme.tagColor(for: category))
        .padding(.horizontal, AppTheme.Spacing.chipHorizontal)
        .padding(.vertical, AppTheme.Spacing.chipVertical)
    }

    private func countBadge(_ value: Int, framed: Bool) -> some View {
        Text(Self.abbreviated(value))
            .font(AppTheme.Typography.caption)
            .monospacedDigit()
            .opacity(0.85)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(framed ? Color.black.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var displayName: String {
        text.replacingOccurrences(of: "_", with: " ")
    }

    /// Spoken text; the count keeps its RN abbreviation so VoiceOver matches the screen.
    private var accessibilityText: String {
        guard let count else { return displayName }
        return "\(displayName), \(Self.abbreviated(count))"
    }

    private var fill: Color {
        isSelected
            ? AppTheme.tagColor(for: category).opacity(0.26)
            : AppTheme.tagBackground(for: category)
    }

    /// RN `formatCount` (TagChip.tsx:24-28): 1.0m above one million, 1.0k above one thousand.
    static func abbreviated(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return String(value)
    }
}
