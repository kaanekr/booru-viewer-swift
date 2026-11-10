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
/// Presentation is stock iOS 26: a `NavigationStack` around a grouped `List` of
/// `Section`s, `LabeledContent` metadata rows, a toolbar Done button and native
/// `Menu` / `contextMenu` tag actions. The view draws no sheet shell of its own —
/// no drag handle, no card backgrounds, no material or background override — so the
/// system sheet chrome, its grabber (added by the presenter) and Liquid Glass stay
/// untouched.
///
/// Tap on a tag searches it (`onSelectTag`); the trailing `•••` menu (and the tag
/// row's context menu) offers all seven RN tag actions: search, add to search,
/// exclude from search, pin/unpin favorite tag, add/remove blacklist, save to
/// history and copy.
@MainActor
struct PostInfoSheetView: View {
    let post: BooruPost
    let viewModel: ViewerViewModel
    /// Search history used by "Save to Search History"; falls back to the view model's.
    private let searchHistory: (any SearchHistoryStoring)?
    /// Applies a search-bar modification; falls back to the view model's.
    private let onModifySearch: (@Sendable (TagSearchModification) -> Void)?
    /// Last played HentaiHaven episode per post id.
    private let hentaiHavenLastEpisodes: [String: Int]
    /// Callback to persist HentaiHaven episode progress.
    private let onSaveHentaiHavenEpisode: (@Sendable (String, Int) -> Void)?
    /// Tap-to-search callback, e.g. `SearchQuery` push in the app layer.
    let onSelectTag: (String) -> Void

    init(
        post: BooruPost,
        viewModel: ViewerViewModel,
        searchHistory: (any SearchHistoryStoring)? = nil,
        onModifySearch: (@Sendable (TagSearchModification) -> Void)? = nil,
        hentaiHavenLastEpisodes: [String: Int] = [:],
        onSaveHentaiHavenEpisode: (@Sendable (String, Int) -> Void)? = nil,
        onSelectTag: @escaping (String) -> Void
    ) {
        self.post = post
        self.viewModel = viewModel
        self.searchHistory = searchHistory
        self.onModifySearch = onModifySearch
        self.hentaiHavenLastEpisodes = hentaiHavenLastEpisodes
        self.onSaveHentaiHavenEpisode = onSaveHentaiHavenEpisode
        self.onSelectTag = onSelectTag
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section("Post") {
                    postRows
                }
                Section("Tags") {
                    tagRows
                }
                if let niches = post.niches, !niches.isEmpty {
                    Section("Niches") {
                        nicheRows(niches)
                    }
                }
                Section("Other") {
                    otherRows
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // A transient status line over the list content; it never takes touches.
            .overlay(alignment: .bottom) { toast }
        }
        .tint(AppTheme.primary)
    }

    // MARK: Sections

    @ViewBuilder
    private var postRows: some View {
        if let title = post.title, !title.isEmpty {
            row(label: "Title", value: title) { copyToPasteboard(title, label: "Title") }
        }
        row(
            label: "Normal (\(sampleExtension))",
            value: "\(sampleWidth)px X \(sampleHeight)px"
        ) {
            copyToPasteboard((post.sampleURL ?? post.previewURL)?.absoluteString ?? "", label: "Normal Image URL")
        }
        row(
            label: "Original (\(originalExtension))",
            value: originalDetail
        ) {
            copyToPasteboard((post.originalURL ?? post.sampleURL)?.absoluteString ?? "", label: "Image URL")
        }
        row(
            label: "Source",
            value: post.sourceLink?.absoluteString ?? "Unknown / None",
            icon: "arrow.up.right.square",
            hint: post.sourceLink == nil ? "Source link not available" : "Opens the source page"
        ) {
            if let link = post.sourceLink {
                openURL(link)
            } else {
                showToast("Source link not available")
            }
        }
        row(
            label: "URL",
            value: (post.originalURL ?? post.sampleURL)?.absoluteString ?? "Unknown / None"
        ) {
            copyToPasteboard((post.originalURL ?? post.sampleURL)?.absoluteString ?? "", label: "Image URL")
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

        // RN order: copyright, character, artist, general, meta (PostInfoModal.tsx:212-216).
        append(post.tags.copyright, .copyright)
        append(post.tags.character, .character)
        append(post.tags.artist, .artist)
        append(post.tags.general, .general)
        append(post.tags.meta, .meta)

        // Fallback for uncategorized posts (PostInfoModal.tsx:219-227).
        if items.isEmpty {
            append(post.allTags, .general)
        }
        return items
    }

    @ViewBuilder
    private var tagRows: some View {
        ForEach(tagItems, id: \.name) { item in
            tagRow(for: item)
        }
    }

    /// One native list row per tag: the tag name is its own button (tap searches it)
    /// and the trailing `•••` is a separate `Menu`, so opening the menu never also
    /// runs the search. Both controls are siblings inside the row — no nested buttons —
    /// both reserve Apple's 44 pt tap target, and the name keeps its category colour
    /// as the leading accessory of a stock `List` row.
    private func tagRow(
        for item: PostInfoTagItem,
        displayText: String? = nil,
        displayCategory: TagCategory? = nil
    ) -> some View {
        let text = displayText ?? item.name
        let shown = text.replacingOccurrences(of: "_", with: " ")
        let category = displayCategory ?? item.category
        let isPinned = viewModel.isPinnedTag(item.name)

        return HStack(spacing: AppTheme.Spacing.item) {
            Button {
                selectTag(item.name)
            } label: {
                HStack(spacing: 6) {
                    Text(shown)
                        .font(AppTheme.Typography.body)
                        .fontWeight(isPinned ? .bold : .semibold)
                        .foregroundStyle(AppTheme.tagColor(for: category))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Pinned tags are also marked with the system pin glyph, so the
                    // state does not rest on weight alone.
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.tagColor(for: category))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Borderless keeps this button's own hit area instead of letting the row
            // swallow every touch, which would hide the menu beside it.
            .buttonStyle(.borderless)
            .accessibilityLabel(shown)
            // Long-pressing the tag name still opens the same seven-action menu.
            .contextMenu { tagMenu(for: item) }

            Menu {
                tagMenu(for: item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(
                        width: AppTheme.Spacing.minimumHitTarget,
                        height: AppTheme.Spacing.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            // Borderless keeps the trailing control's own hit area inside the row and
            // leaves the label as the plain system ellipsis: no detached pill, no
            // second card style to drift away from the tag name beside it.
            .buttonStyle(.borderless)
            .accessibilityLabel("Tag actions for \(shown)")
            .accessibilityHint("Opens the seven tag actions")
            .accessibilityIdentifier("info.tagMenu")
        }
    }

    /// The seven tag actions of RN `PostInfoModal` (PostInfoModal.tsx:806-880).
    ///
    /// The pin/blacklist titles read the live tag lists when the menu is built, so a
    /// toggle shows its new state the next time the menu opens.
    @ViewBuilder
    private func tagMenu(for item: PostInfoTagItem) -> some View {
        let token = formattedSearchToken(for: item.name, category: item.category, sourceID: post.sourceID)
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

    private func nicheRows(_ niches: [String]) -> some View {
        ForEach(niches, id: \.self) { niche in
            // Same row + inline menu treatment as the Tags section, so the two
            // lists cannot drift apart visually.
            tagRow(
                for: PostInfoTagItem(name: "niche:\(niche)", category: .general),
                displayText: niche.replacingOccurrences(of: "-", with: " "),
                displayCategory: .meta
            )
        }
    }

    @ViewBuilder
    private var otherRows: some View {
        row(label: "ID", value: post.id) { copyToPasteboard(post.id, label: "Post ID") }
        row(label: "Posted", value: Self.formatPostedDate(post.createdAt))
        row(label: "Score", value: String(post.score))
        row(label: "Rating", value: Self.ratingLabel(post.rating))
    }

    // MARK: Building blocks

    /// One metadata line. A row with an action becomes a native `List` button, so the
    /// whole row is the tap target; a plain value stays inert content.
    @ViewBuilder
    private func row(
        label: String,
        value: String,
        icon: String = "doc.on.doc",
        hint: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        if let action {
            Button {
                action()
            } label: {
                rowContent(label: label, value: value, icon: icon)
            }
            // Borderless is the `List` idiom for a row-sized control: the full label
            // area is hit-testable and the system still shows its pressed state.
            .buttonStyle(.borderless)
            .accessibilityHint(hint ?? "Copies \(label)")
        } else {
            rowContent(label: label, value: value, icon: nil)
        }
    }

    /// `LabeledContent` gives the standard two-column metadata layout: label leading,
    /// value trailing, with the system's own spacing and Dynamic Type behaviour.
    private func rowContent(label: String, value: String, icon: String?) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value)
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)

                if let icon {
                    Image(systemName: icon)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityHidden(true)
                }
            }
        } label: {
            Text(label)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textPrimary)
        }
        // Full row width keeps the copy target row-sized rather than text-sized.
        .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.minimumHitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var toast: some View {
        Group {
            if let toastMessage {
                Text(toastMessage)
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.contentMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
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
    private func formattedSearchToken(for tag: String, category: TagCategory, sourceID: SourceID) -> String {
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
        withAnimation(.easeInOut(duration: 0.15)) {
            toastMessage = message
        }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                toastMessage = nil
            }
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

/// One categorized post tag rendered as a native info-sheet row.
private struct PostInfoTagItem: Hashable {
    let name: String
    let category: TagCategory
}
