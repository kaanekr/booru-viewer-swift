import SwiftUI

/// In-place source picker for the Explore/Search headers, mirroring the RN
/// `SourceSheet` (src/components/SourceSheet.tsx) built on the shared catalog
/// (src/components/SourceCatalog.tsx).
///
/// The sheet stays on the current screen: choosing a row calls `onSelect` and closes,
/// re-choosing the active source only closes (SourceSheet.tsx:54-67). Hidden sources
/// are never listed (SourceCatalog.tsx:46; `sexcom` is `hidden: true` at sources.ts:91).
///
/// Presentation is stock iOS 26: a `NavigationStack` around a `List` of `Section`s, a
/// native `.searchable` filter, and a toolbar Done button. No custom background, drag
/// handle, or radio artwork is layered over the system sheet chrome / Liquid Glass.
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
    @State private var searchText = ""

    init(selectedSource: SourceID, onSelect: @escaping (SourceID) -> Void) {
        self.selectedSource = selectedSource
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.kind) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            row(for: entry)
                        }
                    } header: {
                        Text(section.kind)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose Source")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search sources")
            .overlay {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   sections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(AppTheme.primary)
        }
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

    // MARK: Sectioning

    /// One native list section: a catalog kind and the visible rows that belong to it.
    private struct KindSection {
        let kind: String
        let entries: [Entry]
    }

    /// `visibleCatalog` grouped by `kind`, keeping catalog order inside each group and
    /// emitting the groups in the order their first row appears. Search narrows the rows.
    private var sections: [KindSection] {
        var order: [String] = []
        var grouped: [String: [Entry]] = [:]

        for entry in Self.visibleCatalog where matches(entry) {
            if grouped[entry.kind] == nil {
                order.append(entry.kind)
            }
            grouped[entry.kind, default: []].append(entry)
        }

        return order.map { KindSection(kind: $0, entries: grouped[$0] ?? []) }
    }

    private func matches(_ entry: Entry) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = "\(entry.name) \(entry.kind) \(entry.host)"
        return haystack.localizedCaseInsensitiveContains(query)
    }

    // MARK: Rows

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

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(AppTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("\(entry.kind) · \(entry.host)")
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: AppTheme.Spacing.item)

                // Native single-selection feedback: a tinted checkmark on the active row,
                // not a hand-drawn radio.
                if selected {
                    Image(systemName: "checkmark")
                        .font(AppTheme.Typography.sectionTitle)
                        .foregroundStyle(AppTheme.primary)
                }
            }
            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
            .contentShape(Rectangle())
        }
        // Plain keeps the row's own label colours (an automatic List button style would
        // tint them with the accent) while the row content keeps the full-width hit area.
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(entry.name), active source" : "Use \(entry.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Brand badge: the catalog initials over a wash of the brand colour. Sized by the
    /// semantic caption font plus padding, so Dynamic Type grows it instead of clipping.
    private func mark(for entry: Entry) -> some View {
        Text(entry.initials)
            .font(AppTheme.Typography.caption)
            .fontWeight(.heavy)
            .foregroundStyle(AppTheme.color(entry.colorHex))
            .padding(.horizontal, 7)
            .frame(minWidth: AppTheme.Spacing.minimumHitTarget - 14, minHeight: AppTheme.Spacing.minimumHitTarget - 14)
            .background(AppTheme.color(entry.colorHex, opacity: 0.16), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}
