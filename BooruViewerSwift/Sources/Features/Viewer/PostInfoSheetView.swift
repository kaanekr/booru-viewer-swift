import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// How an info-sheet tag action modifies the active search query
/// (RN `handleTagSearch` / `handleTagAddToSearch` / `handleTagExcludeFromSearch`,
/// PostInfoModal.tsx:312-377). The app layer applies it to the search bar.
enum TagSearchModification: Sendable, Equatable {
    case replace(String)
    case include(String)
    case exclude(String)
}

/// Bottom sheet with the visible post's metadata, copy actions and categorized
/// tags. Mirrors RN `PostInfoModal` (src/components/PostInfoModal.tsx).
///
/// Tap on a tag searches it (`onSelectTag`); the `•••` menu (and the chip's
/// context menu) offers all seven RN tag actions: search, add to search, exclude
/// from search, pin/unpin favorite tag, add/remove blacklist, save to history and
/// copy.
@MainActor
struct PostInfoSheetView: View {
    let post: BooruPost
    let viewModel: ViewerViewModel
    /// Search history used by "Save to Search History"; falls back to the view model's.
    private let searchHistory: (any SearchHistoryStoring)?
    /// Applies a search-bar modification; falls back to the view model's.
    private let onModifySearch: (@Sendable (TagSearchModification) -> Void)?
    /// Tap-to-search callback, e.g. `SearchQuery` push in the app layer.
    let onSelectTag: (String) -> Void

    init(
        post: BooruPost,
        viewModel: ViewerViewModel,
        searchHistory: (any SearchHistoryStoring)? = nil,
        onModifySearch: (@Sendable (TagSearchModification) -> Void)? = nil,
        onSelectTag: @escaping (String) -> Void
    ) {
        self.post = post
        self.viewModel = viewModel
        self.searchHistory = searchHistory
        self.onModifySearch = onModifySearch
        self.onSelectTag = onSelectTag
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    postSection
                    tagsSection
                    if let niches = post.niches, !niches.isEmpty {
                        nichesSection(niches)
                    }
                    otherSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.visible)
        }
        .background(AppTheme.background)
        .overlay(alignment: .top) { toast }
    }

    // MARK: Chrome

    private var dragHandle: some View {
        Capsule()
            .fill(AppTheme.border)
            .frame(width: 36, height: 4.5)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private var header: some View {
        HStack {
            circleButton(system: "xmark") { dismiss() }
            Spacer()
            Text("Info")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func circleButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 38, height: 38)
                .background(AppTheme.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sections

    private var postSection: some View {
        section("Post") {
            VStack(spacing: 0) {
                if let title = post.title, !title.isEmpty {
                    row(label: "Title", value: title) { copyToPasteboard(title, label: "Title") }
                    divider
                }
                row(
                    label: "Normal (\(sampleExtension))",
                    value: "\(sampleWidth)px X \(sampleHeight)px"
                ) {
                    copyToPasteboard((post.sampleURL ?? post.previewURL)?.absoluteString ?? "", label: "Normal Image URL")
                }
                divider
                row(
                    label: "Original (\(originalExtension))",
                    value: originalDetail
                ) {
                    copyToPasteboard((post.originalURL ?? post.sampleURL)?.absoluteString ?? "", label: "Image URL")
                }
                divider
                row(
                    label: "Source",
                    value: post.sourceLink?.absoluteString ?? "Unknown / None",
                    icon: "arrow.up.right.square"
                ) {
                    if let link = post.sourceLink {
                        openURL(link)
                    } else {
                        showToast("Source link not available")
                    }
                }
                divider
                row(
                    label: "URL",
                    value: (post.originalURL ?? post.sampleURL)?.absoluteString ?? "Unknown / None"
                ) {
                    copyToPasteboard((post.originalURL ?? post.sampleURL)?.absoluteString ?? "", label: "Image URL")
                }
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var tagItems: [PostInfoTagItem] {
        var seen = Set<String>()
        var items: [PostInfoTagItem] = []

        func append(_ tags: [String], _ category: TagCategory) {
            for tag in tags {
                let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
                items.append(PostInfoTagItem(name: clean, category: category))
            }
        }

        let resolved = viewModel.resolvedTags(for: post)
        // RN order: copyright, character, artist, general, meta (PostInfoModal.tsx:212-216).
        append(resolved.groups.copyright, .copyright)
        append(resolved.groups.character, .character)
        append(resolved.groups.artist, .artist)
        append(resolved.groups.general, .general)
        append(resolved.groups.meta, .meta)

        // Fallback for uncategorized posts (PostInfoModal.tsx:219-227).
        if items.isEmpty {
            append(resolved.allTags, .general)
        }
        return items
    }

    private var tagsSection: some View {
        section("Tags") {
            // Each row reserves a 44 pt hit target around a 28 pt pill. `lineSpacing`
            // stays 0 (not negative) so neighbouring 44 pt targets never overlap and
            // the drawn pills stay the same size as every other chip.
            TagFlowLayout(spacing: 8, lineSpacing: 0) {
                ForEach(tagItems, id: \.name) { item in
                    tagChipWithMenu(for: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One tag chip with its `•••` menu folded into the same category-coloured
    /// pill (RN `tagRowItem` + `yellowDotsBadge`, PostInfoModal.tsx:644-676).
    ///
    /// The text and the menu are sibling buttons inside a shared pill, so tapping
    /// the ellipsis never also runs the chip's search action. The pill row reserves
    /// a 44 pt tall hit target while the drawn pill stays the same compact height
    /// as every other chip, so small tags do not grow visually.
    private func tagChipWithMenu(
        for item: PostInfoTagItem,
        displayText: String? = nil,
        displayCategory: TagCategory? = nil
    ) -> some View {
        let text = displayText ?? item.name
        let shown = text.replacingOccurrences(of: "_", with: " ")
        let category = displayCategory ?? item.category
        let isPinned = viewModel.isPinnedTag(item.name)

        return HStack(spacing: 0) {
            Button {
                let token = Self.formattedSearchToken(for: item.name, category: item.category, sourceID: post.sourceID)
                selectTag(token.isEmpty ? item.name : token)
            } label: {
                Text(shown)
                    .font(.system(size: 13, weight: isPinned ? .bold : .semibold))
                    .foregroundStyle(AppTheme.tagColor(for: category))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    // Same 44 pt target as the menu; the pill drawn behind it stays
                    // 28 pt tall, so the chip does not look bigger.
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shown)
            // Long-press on the tag text keeps opening the same seven-action menu
            // it did before the ellipsis moved inside the pill.
            .contextMenu { tagMenu(for: item) }

            Rectangle()
                .fill(AppTheme.tagBorder(for: category))
                .frame(width: 1, height: 14)

            Menu {
                tagMenu(for: item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.tagColor(for: category))
                    // Full 44 pt target inside the pill; the drawn pill stays compact
                    // because only this row's height grows, not the chip fill.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tag actions for \(shown)")
            .accessibilityIdentifier("info.tagMenu")
        }
        .frame(height: 44)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isPinned
                        ? AppTheme.tagColor(for: category).opacity(0.26)
                        : AppTheme.tagBackground(for: category)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.tagBorder(for: category), lineWidth: isPinned ? 1.5 : 1)
                )
                .frame(height: 28)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The seven tag actions of RN `PostInfoModal` (PostInfoModal.tsx:806-880).
    @ViewBuilder
    private func tagMenu(for item: PostInfoTagItem) -> some View {
        let token = Self.formattedSearchToken(for: item.name, category: item.category, sourceID: post.sourceID)
        let isPinned = viewModel.favoriteTagSet.contains(ViewerViewModel.favoriteTagKey(item.name)) || viewModel.isPinnedTag(item.name)
        let isBlacklisted = viewModel.blacklistedTagSet.contains(ViewerViewModel.blacklistTagKey(item.name)) || viewModel.isBlacklistedTag(item.name)

        // 1. Search Tag
        Button {
            modifySearch(.replace(token), fallbackTag: token)
        } label: {
            Label("Search Tag", systemImage: "magnifyingglass")
        }

        // 2. Add to Search (+tag)
        Button {
            modifySearch(.include(token), fallbackTag: token)
        } label: {
            Label("Add to Search (+tag)", systemImage: "plus.circle")
        }

        // 3. Exclude from Search (-tag)
        Button {
            modifySearch(.exclude(token), fallbackTag: "-\(token)")
        } label: {
            Label("Exclude from Search (-tag)", systemImage: "minus.circle")
        }

        Divider()

        // 4. Pin to Favorite Tags / Unpin Favorite Tag
        Button {
            Task { await viewModel.togglePinnedTag(item.name) }
        } label: {
            Label(
                isPinned ? "Unpin Favorite Tag" : "Pin to Favorite Tags",
                systemImage: isPinned ? "pin.slash" : "pin"
            )
        }

        // 5. Add to Blacklist / Remove from Blacklist
        Button {
            Task { await viewModel.toggleBlacklistedTag(item.name) }
        } label: {
            Label(
                isBlacklisted ? "Remove from Blacklist" : "Add to Blacklist",
                systemImage: isBlacklisted ? "eye" : "eye.slash"
            )
        }

        Divider()

        // 6. Save to Search History
        Button {
            saveToSearchHistory(token.isEmpty ? item.name : token)
        } label: {
            Label("Save to Search History", systemImage: "clock")
        }

        // 7. Copy Tag
        Button {
            copyToPasteboard(item.name, label: "Tag")
        } label: {
            Label("Copy Tag", systemImage: "doc.on.doc")
        }
    }

    private func nichesSection(_ niches: [String]) -> some View {
        section("Niches") {
            TagFlowLayout(spacing: 8, lineSpacing: 0) {
                ForEach(niches, id: \.self) { niche in
                    // Same chip + inline ellipsis treatment as the Tags section, so
                    // the two lists cannot drift apart visually.
                    tagChipWithMenu(
                        for: PostInfoTagItem(name: "niche:\(niche)", category: .general),
                        displayText: niche.replacingOccurrences(of: "-", with: " "),
                        displayCategory: .meta
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var otherSection: some View {
        section("Other") {
            VStack(spacing: 0) {
                row(label: "ID", value: post.id) { copyToPasteboard(post.id, label: "Post ID") }
                divider
                row(label: "Posted", value: Self.formatPostedDate(post.createdAt))
                divider
                row(label: "Score", value: String(post.score))
                divider
                row(label: "Rating", value: Self.ratingLabel(post.rating))
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            content()
        }
    }

    private func row(
        label: String,
        value: String,
        icon: String = "doc.on.doc",
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private var toast: some View {
        Group {
            if let toastMessage {
                Text(toastMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.primary, lineWidth: 1))
                    .padding(.top, 56)
            }
        }
    }

    // MARK: Actions

    private func selectTag(_ tag: String) {
        dismiss()
        onSelectTag(tag)
    }

    /// Applies a search modification through `onModifySearch`, else falls back to
    /// the plain tag search (RN falls back to `onSearchTag` when no modifier prop
    /// is provided, PostInfoModal.tsx:347-353).
    private func modifySearch(_ modification: TagSearchModification, fallbackTag: String) {
        dismiss()
        if let modify = onModifySearch ?? viewModel.onModifySearch {
            modify(modification)
        } else {
            onSelectTag(fallbackTag)
        }
    }

    private func saveToSearchHistory(_ query: String) {
        guard let store = searchHistory ?? viewModel.searchHistory else {
            showToast("Search history is unavailable.")
            return
        }
        Task {
            try? await store.record(query)
            showToast("🕒 \"\(query)\" saved to search history!")
        }
    }

    /// Source-specific search token for a tag (RN `nhentaiTagQuery`,
    /// `hentaiHavenTagQuery`, and the RedGifs `user:` rule).
    static func formattedSearchToken(for tag: String, category: TagCategory, sourceID: SourceID) -> String {
        let clean = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        switch sourceID {
        case .redgifs:
            guard category == .artist, !clean.lowercased().hasPrefix("user:") else { return clean }
            return "user:\(clean)"
        case .nhentai:
            return Self.nhentaiTagQuery(clean, category: category)
        case .hentaihaven:
            return Self.hentaiHavenTagQuery(clean, category: category)
        default:
            return clean
        }
    }

    /// RN `nhentaiTagQuery` (nhentai.ts:132-162): a prefixed tag is normalized to
    /// `prefix:"value"` when it has spaces, otherwise every category gets its
    /// `artist:` / `character:` / `parody:` / `tag:` prefix.
    private static func nhentaiTagQuery(_ name: String, category: TagCategory) -> String {
        if let colon = name.firstIndex(of: ":"),
           name[..<colon].range(of: #"^[a-z][a-z-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let prefix = name[..<colon].lowercased()
            let value = name[name.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return name }
            return value.contains(where: { $0.isWhitespace })
                ? "\(prefix):\"\(value)\""
                : "\(prefix):\(value)"
        }
        let quoted = "\"\(name.replacingOccurrences(of: "\"", with: ""))\""
        switch category {
        case .artist:
            return "artist:\(quoted)"
        case .character:
            return "character:\(quoted)"
        case .copyright:
            return "parody:\(quoted)"
        case .general:
            return "tag:\(quoted)"
        case .meta:
            return name
        }
    }

    /// RN `hentaiHavenTagQuery` (hentaihavens.ts:533-540): already-prefixed tags are
    /// untouched; otherwise `artist:"name"` for artists and `tag:"name"` for the rest.
    private static func hentaiHavenTagQuery(_ name: String, category: TagCategory) -> String {
        if name.range(of: #"^[a-z][a-z-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return name
        }
        let lower = name.lowercased()
        let prefix = category == .artist ? "artist" : "tag"
        return lower.contains(where: { $0.isWhitespace }) ? "\(prefix):\"\(lower)\"" : "\(prefix):\(lower)"
    }

    private func copyToPasteboard(_ text: String, label: String) {
        guard !text.isEmpty else {
            showToast("Nothing to copy")
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        showToast("📋 \(label) copied!")
        #endif
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    // MARK: Metadata helpers

    private var sampleExtension: String {
        let ext = (post.sampleURL ?? post.previewURL)?.pathExtension ?? ""
        return ext.isEmpty ? "jpg" : ext
    }

    private var originalExtension: String {
        if let ext = post.fileExt, !ext.isEmpty { return ext }
        let ext = post.originalURL?.pathExtension ?? ""
        return ext.isEmpty ? "png" : ext
    }

    /// RN halves overly large sample dimensions (PostInfoModal.tsx:415-416).
    private var sampleWidth: Int {
        post.width > 1200 ? Int((Double(post.width) * 0.5).rounded()) : post.width
    }

    private var sampleHeight: Int {
        post.height > 1200 ? Int((Double(post.height) * 0.5).rounded()) : post.height
    }

    private var originalDetail: String {
        var detail = "\(post.width)px X \(post.height)px"
        if let size = Self.formatBytes(post.fileSize) {
            detail += " • \(size)"
        }
        return detail
    }

    private static func formatBytes(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }

    private static func ratingLabel(_ rating: PostRating) -> String {
        switch rating {
        case .safe, .general:
            return "general"
        case .questionable:
            return "questionable"
        case .explicit:
            return "explicit"
        }
    }

    /// RN `formatPostedDate` (PostInfoModal.tsx:253-268): numeric values are epoch
    /// seconds, everything else is parsed as a date string; unparseable input is shown raw.
    private static func formatPostedDate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "Unknown" }

        let date: Date?
        if let seconds = Double(raw) {
            date = Date(timeIntervalSince1970: seconds)
        } else {
            let iso = ISO8601DateFormatter()
            date = iso.date(from: raw)
                ?? {
                    let fractional = ISO8601DateFormatter()
                    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return fractional.date(from: raw)
                }()
        }

        guard let date else { return raw }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Tag item

/// One categorized post tag rendered as a `TagChipView` in the sheet.
private struct PostInfoTagItem: Hashable {
    let name: String
    let category: TagCategory
}

// MARK: - Tag flow layout
/// Wraps `TagChipView`s like RN's tag list: chip-by-chip, new line when the width
/// is exhausted (PostInfoModal.tsx:640-678).
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
