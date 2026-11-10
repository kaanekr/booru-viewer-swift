import SwiftUI

/// In-place source picker for the Explore/Search headers, mirroring the RN
/// `SourceSheet` (src/components/SourceSheet.tsx) built on the shared catalog
/// (src/components/SourceCatalog.tsx).
///
/// The sheet stays on the current screen: choosing a row calls `onSelect` and closes,
/// re-choosing the active source only closes (SourceSheet.tsx:54-67). Hidden sources
/// are never listed (SourceCatalog.tsx:46; `sexcom` is `hidden: true` at sources.ts:91).
struct SourceSheetView: View {
    /// One catalog row: brand mark, display name, and the kind/host line.
    struct Entry: Identifiable, Hashable, Sendable {
        /// RN `BooruSource.id` (sources.ts:5-108).
        let id: SourceID
        /// RN `BooruSource.name`.
        let name: String
        /// RN `BooruSource.baseUrl`.
        let baseURL: String
        /// RN `BRANDS[id].initials` (SourceCatalog.tsx:9-23).
        let initials: String
        /// RN `BRANDS[id].color` as 0xRRGGBB.
        let colorHex: UInt32
        /// RN `BRANDS[id].kind`: Images, Videos, or Manga.
        let kind: String
        /// RN `BooruSource.hidden` (sources.ts:91).
        let isHidden: Bool

        /// First word of the name, used by the compact source pill (FeedScreen.tsx:362).
        var shortName: String {
            name.split(separator: " ").first.map { String($0) } ?? name
        }

        /// RN `baseUrl.replace(/^https?:\/\//, '')` (SourceCatalog.tsx:65).
        var host: String {
            var value = baseURL
            if value.hasPrefix("https://") {
                value.removeFirst("https://".count)
            } else if value.hasPrefix("http://") {
                value.removeFirst("http://".count)
            }
            return value
        }
    }

    private let selectedSource: SourceID
    private let onSelect: (SourceID) -> Void

    @Environment(\.dismiss) private var dismiss

    init(selectedSource: SourceID, onSelect: @escaping (SourceID) -> Void) {
        self.selectedSource = selectedSource
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.vertical, 8)

            header

            ScrollView {
                VStack(spacing: AppTheme.Spacing.item) {
                    countRow
                    ForEach(Self.visibleCatalog) { entry in
                        row(for: entry)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.visible)
        }
        .background(AppTheme.background)
    }

    // MARK: Catalog

    /// RN `AVAILABLE_SOURCES` (sources.ts:3-111) in picker order.
    static let catalog: [Entry] = [
        Entry(id: .gelbooru, name: "Gelbooru", baseURL: "https://gelbooru.com", initials: "G", colorHex: 0x6EA8FE, kind: "Images", isHidden: false),
        Entry(id: .yandere, name: "Yande.re", baseURL: "https://yande.re", initials: "Y", colorHex: 0xF194AF, kind: "Images", isHidden: false),
        Entry(id: .danbooru, name: "Danbooru", baseURL: "https://danbooru.donmai.us", initials: "D", colorHex: 0xB1A1FA, kind: "Images", isHidden: false),
        Entry(id: .realbooru, name: "Realbooru", baseURL: "https://realbooru.com", initials: "R", colorHex: 0xD4B48C, kind: "Images", isHidden: false),
        Entry(id: .rule34, name: "Rule34.xxx", baseURL: "https://api.rule34.xxx", initials: "34", colorHex: 0x9BCB88, kind: "Images", isHidden: false),
        Entry(id: .cumst, name: "Cum.st", baseURL: "https://cum.st", initials: "C", colorHex: 0x80CABB, kind: "Images", isHidden: false),
        Entry(id: .redgifs, name: "RedGifs", baseURL: "https://api.redgifs.com", initials: "RG", colorHex: 0xF58F9D, kind: "Videos", isHidden: false),
        Entry(id: .xvideos, name: "XVideos", baseURL: "https://www.xvideos.com", initials: "XV", colorHex: 0xFA9890, kind: "Videos", isHidden: false),
        Entry(id: .xhamster, name: "XHamster", baseURL: "https://xhamster.com", initials: "XH", colorHex: 0xF2B178, kind: "Videos", isHidden: false),
        Entry(id: .pornhub, name: "Pornhub", baseURL: "https://www.pornhub.com", initials: "PH", colorHex: 0xE9B368, kind: "Videos", isHidden: false),
        Entry(id: .sexcom, name: "Sex.com", baseURL: "https://www.sex.com", initials: "SX", colorHex: 0xE49BC3, kind: "Videos", isHidden: true),
        Entry(id: .hentaihaven, name: "HentaiHaven", baseURL: "https://hentaihaven.xxx", initials: "HH", colorHex: 0xAC9BEB, kind: "Videos", isHidden: false),
        Entry(id: .nhentai, name: "nhentai", baseURL: "https://nhentai.net", initials: "nH", colorHex: 0xF08EA6, kind: "Manga", isHidden: false),
    ]

    /// Rows the picker lists; `source.hidden` rows are filtered out (SourceCatalog.tsx:46).
    static var visibleCatalog: [Entry] {
        catalog.filter { !$0.isHidden }
    }

    /// Catalog data for any source id, including hidden ones (Settings still reaches them).
    static func entry(for id: SourceID) -> Entry {
        catalog.first { $0.id == id } ?? Entry(
            id: id,
            name: id.rawValue,
            baseURL: "",
            initials: String(id.rawValue.prefix(2)).uppercased(),
            colorHex: 0xA6A8BE,
            kind: "Images",
            isHidden: false
        )
    }

    // MARK: Rows

    private var countRow: some View {
        HStack {
            Text("\(Self.visibleCatalog.count) \(Self.visibleCatalog.count == 1 ? "SOURCE" : "SOURCES")")
                .font(AppTheme.Typography.caption)
                .kerning(1.3)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: AppTheme.Spacing.item)
            Text("Tap to switch")
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textMuted)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            circleButton(systemName: "xmark") {
                dismiss()
            }
            .accessibilityLabel("Close source picker")

            VStack(spacing: 1) {
                // Sheet title sits between the compact body and screen-title tokens: it
                // still outranks the 13 pt row names without the old 17 pt bulk.
                Text("Choose source")
                    .font(.system(.subheadline, weight: .heavy))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Stay here, switch instantly")
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.textMuted)
            }
            .frame(maxWidth: .infinity)

            // Matches the leading button so the copy stays centered (SourceSheet.tsx:110-112).
            Color.clear.frame(width: AppTheme.Spacing.minimumHitTarget, height: AppTheme.Spacing.minimumHitTarget)
        }
        .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
        .padding(.bottom, 10)
    }

    private func row(for entry: Entry) -> some View {
        let selected = entry.id == selectedSource
        return Button {
            if !selected {
                onSelect(entry.id)
            }
            dismiss()
        } label: {
            HStack(spacing: AppTheme.Spacing.item) {
                mark(for: entry)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(AppTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                        if selected {
                            Text("ACTIVE")
                                .font(.system(.caption2, weight: .heavy))
                                .kerning(0.7)
                                .foregroundStyle(AppTheme.primaryLight)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    AppTheme.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                    }
                    Text("\(entry.kind) · \(entry.host)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: AppTheme.Spacing.item)

                radio(selected: selected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
            .background(
                selected ? AppTheme.selectedSurface : AppTheme.card,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? AppTheme.primary.opacity(0.47) : AppTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(entry.name), active source" : "Use \(entry.name)")
    }

    private func mark(for entry: Entry) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(AppTheme.color(entry.colorHex, opacity: 0.08))
            .frame(width: 28, height: 28)
            .overlay {
                Text(entry.initials)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(-0.5)
                    .foregroundStyle(AppTheme.color(entry.colorHex))
            }
    }

    private func radio(selected: Bool) -> some View {
        Circle()
            .fill(selected ? AppTheme.primary : Color.clear)
            .frame(width: 15, height: 15)
            .overlay {
                Circle()
                    .stroke(selected ? AppTheme.primary : AppTheme.color(0x3A3F52), lineWidth: 1.5)
            }
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                }
            }
    }

    private func circleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(AppTheme.surface, in: Circle())
                .overlay {
                    Circle().stroke(AppTheme.border, lineWidth: 1)
                }
                // Keep the 44 pt tap lane while the painted button shrinks.
                .frame(minWidth: AppTheme.Spacing.minimumHitTarget, minHeight: AppTheme.Spacing.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
