import SwiftUI
import UIKit

/// Theme tokens for the native iOS 26 UI.
///
/// Surfaces, text, and lines are the *system semantic* colours (`.systemBackground`,
/// `.label`, `.separator`, …) instead of hard-coded hexes, so content follows the
/// platform's appearance and accessibility settings. The app still runs dark-only
/// (`BooruViewerApp` pins `.preferredColorScheme(.dark)`), so these resolve to their dark
/// variants — the same near-black look the previous fixed palette described.
///
/// The brand accents (`primary`, `accent`, `goldAccent`) and the `TagColors` palette keep
/// their exact identity values: the app's accent and the per-category tag colours must stay
/// recognisable across screens.
///
/// This type is data only. It never installs `UINavigationBar` / `UITabBar` appearance
/// proxies, never masks chrome, and never forces a font, size category, or scale: native
/// navigation bars, tab bars, toolbars, sheets, and lists draw their own Liquid Glass.
enum AppTheme {
    // MARK: Surfaces

    /// Page background behind scrolling content.
    static let background = Color(uiColor: .systemBackground)
    /// Post-card / content-card fill.
    static let card = Color(uiColor: .secondarySystemBackground)
    /// Raised control fill: pills, circular buttons, inline fields.
    static let surface = Color(uiColor: .tertiarySystemBackground)
    /// Fill for the picked row of a native picker/list, tinted with the brand accent.
    static let selectedSurface = primary.opacity(0.18)
    /// Inactive chip fill, one step quieter than `surface`.
    static let chip = Color(uiColor: .quaternarySystemFill)
    /// Inactive chip outline.
    static let chipBorder = Color(uiColor: .separator)

    /// Material for *content* surfaces that should read as system-standard (cards over busy
    /// media, floating panels). Never apply it to navigation/tab/toolbar chrome — the system
    /// owns that glass.
    static let contentMaterial: Material = .regularMaterial

    // MARK: Text

    /// Primary copy: titles, row names, values.
    static let textPrimary = Color(uiColor: .label)
    /// Supporting copy: subtitles, source hosts, hints.
    static let textSecondary = Color(uiColor: .secondaryLabel)
    /// Lowest-emphasis copy: metadata, placeholder hints, disabled labels.
    static let textMuted = Color(uiColor: .tertiaryLabel)

    // MARK: Accents

    /// RN `Colors.dark.primary`; the brand accent. Use as `.tint` for interactive chrome.
    static let primary = color(0x6366F1)
    /// Lighter brand accent for glyphs and inline emphasis.
    static let primaryLight = color(0x818CF8)
    /// RN `Colors.dark.accent`; secondary brand accent.
    static let accent = color(0xEC4899)
    /// Caution state.
    static let warning = Color(uiColor: .systemOrange)
    /// Destructive state.
    static let danger = Color(uiColor: .systemRed)
    /// Success/healthy state.
    static let success = Color(uiColor: .systemGreen)
    /// RN `FeedScreen.tsx:39` selected quick-filter accent.
    static let goldAccent = color(0xF5A623)
    /// RN `FeedScreen.tsx:647` text on the selected quick-filter chip.
    static let goldAccentText = color(0x111216)

    // MARK: Lines

    /// Hairline stroke around content cards.
    static let border = Color(uiColor: .separator)
    /// Hairline divider between rows.
    static let divider = Color(uiColor: .separator)

    // MARK: Tag palette

    /// RN `TagColors[category].text` (colors.ts:1-27). Exact values: the tag colour *is*
    /// the category signal, so these stay fixed brand data rather than system colours.
    static func tagColor(for category: TagCategory) -> Color {
        switch category {
        case .artist: return color(0xFF6B6B)
        case .character: return color(0x51CF66)
        case .copyright: return color(0xCC5DE8)
        case .general: return color(0x339AF0)
        case .meta: return color(0xFCC419)
        }
    }

    /// RN `TagColors[category].bg` (a low-alpha wash of the tag colour). Lifted from the RN
    /// 0.15 so the wash still reads on the darker system background.
    static func tagBackground(for category: TagCategory) -> Color {
        tagColor(for: category).opacity(0.18)
    }

    /// RN `TagColors[category].border` (a mid-alpha stroke of the tag colour).
    static func tagBorder(for category: TagCategory) -> Color {
        tagColor(for: category).opacity(0.35)
    }

    // MARK: Rating palette

    /// RN `getRatingColor` (PostCard.tsx:38-50): safe/general green, questionable amber,
    /// explicit red, anything else muted.
    static func ratingColor(for rating: PostRating) -> Color {
        switch rating {
        case .safe, .general: return success
        case .questionable: return warning
        case .explicit: return danger
        }
    }

    // MARK: Type ramp

    /// Compact type ramp shared by every screen.
    ///
    /// The screens were asked to get smaller overall ("genel olarak herşey küçülsün
    /// yazılar vb"), so the base sizes are deliberately modest. Each token is a
    /// *semantic* SwiftUI style (`Font.system(_:weight:)`) instead of
    /// `Font.system(size:)`: a fixed point size never follows the user's Dynamic Type
    /// setting, while a semantic style scales with it automatically. Nothing here
    /// forces `\.sizeCategory`, applies `scaleEffect`, or sets `minimumScaleFactor`.
    ///
    /// Nominal target -> resolved default size at the Large content size category:
    /// `screenTitle` 24 -> 22 (`.title2`), `sectionTitle` 14 -> 13 (`.footnote`),
    /// `body` 14 -> 13 (`.footnote`), `secondary` 12 -> 12 (`.caption`),
    /// `caption` 10 -> 11 (`.caption2`, the smallest system style).
    /// Weights ride on the style so callers do not re-declare them.
    enum Typography {
        /// Screen headline, e.g. "Explore" or a viewer title. (24 nominal, `.title2` = 22.)
        static let screenTitle: Font = .system(.title2, weight: .heavy)

        /// Group/section header above a block of rows. (14 nominal, `.footnote` = 13.)
        static let sectionTitle: Font = .system(.footnote, weight: .semibold)

        /// Default readable copy: rows, fields, body text. (14 nominal, `.footnote` = 13.)
        static let body: Font = .system(.footnote)

        /// Supporting copy: subtitles, source hosts, hints. (12 nominal, `.caption` = 12.)
        static let secondary: Font = .system(.caption)

        /// Smallest labels: counts, badges, "ACTIVE". (10 nominal, `.caption2` = 11.)
        static let caption: Font = .system(.caption2, weight: .semibold)
    }

    // MARK: Spacing ramp

    /// Compact spacing ramp; screens keep using it instead of literal paddings so the
    /// density stays consistent across headers, rows, and chips.
    enum Spacing {
        /// Leading/trailing screen gutter (screens used 16 before the compaction pass).
        static let screenHorizontal: CGFloat = 12

        /// Gap between stacked sections inside a screen.
        static let section: CGFloat = 12

        /// Vertical padding inside a row.
        static let rowVertical: CGFloat = 8

        /// Horizontal padding inside a chip/pill.
        static let chipHorizontal: CGFloat = 8

        /// Vertical padding inside a chip/pill.
        static let chipVertical: CGFloat = 4

        /// Gap between adjacent items in a row, stack, or chip strip.
        static let item: CGFloat = 8

        /// Apple's minimum comfortable tap target; keep interactive rows at least this tall.
        static let minimumHitTarget: CGFloat = 44
    }

    // MARK: Icons

    /// Point sizes for SF Symbols so glyphs match the compact type ramp.
    enum Icon {
        /// Symbol size for primary controls.
        static let standard: CGFloat = 18

        /// Symbol size for inline/secondary glyphs.
        static let small: CGFloat = 14
    }

    // MARK: Hex helper

    /// 0xRRGGBB literal, the same notation the RN theme uses. Only for fixed brand data
    /// (accents, brand marks, tag/rating palette) — surfaces and text come from the system.
    static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
