import SwiftUI
import UIKit

/// How a `SearchScreen` presents its native navigation chrome.
///
/// `.root` is the Search tab: it owns the native title, the source/filter toolbar controls,
/// and the `.searchable` field. `.pushed` is a `SearchDetailScreen`, which supplies its own
/// title and back button and therefore must not have a second title applied under it.
enum SearchChromeMode: Sendable, Hashable {
    case root
    case pushed
}

private struct SearchChromeModeKey: EnvironmentKey {
    static let defaultValue: SearchChromeMode = .root
}

extension EnvironmentValues {
    /// Chrome ownership for `SearchScreen`; `.pushed` lets the host own the title.
    var searchChromeMode: SearchChromeMode {
        get { self[SearchChromeModeKey.self] }
        set { self[SearchChromeModeKey.self] = newValue }
    }
}

/// Search tab: tag input with debounced server autocomplete, recent-search chips, the filter sheet,
/// and a two-column result grid. Mirrors RN `SearchScreen.tsx`.
///
/// Typing is a real `.searchable` field bound to `SearchViewModel.query`, so the system owns the
/// search bar, its clear/cancel controls, and the suggestion overlay. Autocomplete rows are handed
/// to `.searchSuggestions`, submitting the field runs `SearchViewModel.runSearch()` through
/// `.onSubmit(of: .search)`, and `.searchFocused` binds the field's focus so a chip action can end
/// the interaction. The source picker and the filter sheet are native toolbar buttons.
///
/// The screen owns its `SearchViewModel`; `activeSourceID` is observed so a source change from the
/// app layer resets the search, exactly like `FeedScreen`.
@MainActor
struct SearchScreen: View {
    private let activeSourceID: SourceID
    private let favoriteKeys: Set<String>
    private let imageQuality: ImageQuality
    private let gridPreviewsEnabled: Bool
    /// Request context handed to the model at build time and re-pushed on `contextVersion` changes.
    private let context: SourceContext
    /// Bumped by the app layer whenever the request context (Worker, keys, quality) changes.
    private let contextVersion: Int
    private let onOpenTag: ((String) -> Void)?
    private let onToggleFavorite: ((BooruPost) -> Void)?
    private let onOpenPost: ([BooruPost], Int) -> Void
    /// Optional stores that power the tag-chip context menu (pin/blacklist).
    private let favoriteTagsStore: (any TagListStoring)?
    private let blacklistStore: (any TagListStoring)?

    @State private var model: SearchViewModel
    @State private var isFilterSheetPresented = false
    @State private var isSourceSheetPresented = false
    @State private var pinnedTagKeys: Set<String> = []
    @State private var blacklistedTagKeys: Set<String> = []
    /// Width measured from the results scroll view itself (never a `GeometryReader` wrapper),
    /// so the masonry split follows the container while the native scroll edge stays intact.
    @State private var availableWidth: CGFloat = 0
    /// Bound to the native `.searchable` field via `.searchFocused`; autocomplete runs only
    /// while the field is focused (SearchScreen.tsx:283-326).
    @FocusState private var isSearchFieldFocused: Bool
    /// Set by the host: `.pushed` screens own their navigation title.
    @Environment(\.searchChromeMode) private var chromeMode

    /// RN `POPULAR_TAGS` (SearchScreen.tsx:66-77) plus a wider set of community favourites,
    /// so the popular section fills the viewport instead of leaving the lower half empty.
    private static let popularTags = [
        "original", "1girl", "hatsune_miku", "scenery", "genshin_impact",
        "arknights", "hololive", "frieren", "blue_archive", "cyberpunk",
        "solo", "1boy", "long_hair", "landscape", "cityscape", "chibi",
        "monochrome", "kemonomimi", "cosplay", "cherry_blossoms",
        "night_sky", "aesthetic", "portrait", "wallpaper"
    ]

    /// Grid metrics shared by the masonry split (FeedScreen.tsx:504).
    private static let columnSpacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = AppTheme.Spacing.screenHorizontal

    /// - Parameters:
    ///   - activeSourceID: source the search opens on (RN default `gelbooru`).
    ///   - context: transport and credentials handed to the source adapters.
    ///   - historyStore: persisted search history.
    ///   - blacklistedTags: raw blacklist entries applied to every loaded page.
    ///   - favoriteKeys: `postKey` values that draw the favorite badge on a card.
    ///   - initialQuery: search to run on appear (pushed detail searches).
    ///   - initialFilter: filter-sheet style initial search; wins over `initialQuery`.
    ///   - onOpenTag: active-tag chip tap; a pushed search uses it for chained navigation.
    ///   - onToggleFavorite: long-press action for a card.
    ///   - onOpenPost: opens the viewer at `index` inside the result list.
    init(
        activeSourceID: SourceID,
        context: SourceContext,
        historyStore: any SearchHistoryStoring,
        blacklistedTags: [String] = [],
        favoriteKeys: Set<String> = [],
        imageQuality: ImageQuality = .auto,
        gridPreviewsEnabled: Bool = true,
        contextVersion: Int = 0,
        sourceProvider: @escaping SearchViewModel.SourceProvider = { SourceRegistry.source(for: $0) },
        initialQuery: String? = nil,
        initialFilter: SearchFilterConfig? = nil,
        favoriteTagsStore: (any TagListStoring)? = nil,
        blacklistStore: (any TagListStoring)? = nil,
        onOpenTag: ((String) -> Void)? = nil,
        onToggleFavorite: ((BooruPost) -> Void)? = nil,
        onOpenPost: @escaping ([BooruPost], Int) -> Void = { _, _ in }
    ) {
        self.activeSourceID = activeSourceID
        self.favoriteKeys = favoriteKeys
        self.imageQuality = imageQuality
        self.gridPreviewsEnabled = gridPreviewsEnabled
        self.context = context
        self.contextVersion = contextVersion
        self.favoriteTagsStore = favoriteTagsStore ?? TagListStore(directory: JSONFileStore.defaultDirectory(), kind: .favorite)
        self.blacklistStore = blacklistStore ?? TagListStore(directory: JSONFileStore.defaultDirectory(), kind: .blacklisted)
        self.onOpenTag = onOpenTag
        self.onToggleFavorite = onToggleFavorite
        self.onOpenPost = onOpenPost
        _model = State(initialValue: SearchViewModel(
            sourceID: activeSourceID,
            context: context,
            historyStore: historyStore,
            blacklistedTags: blacklistedTags,
            sourceProvider: sourceProvider,
            initialQuery: initialQuery,
            initialFilter: initialFilter
        ))
    }

    @ViewBuilder
    var body: some View {
        if chromeMode == .root {
            // The Search tab owns the title; the pushed detail screens supply their own.
            content.navigationTitle("Search")
        } else {
            content
        }
    }

    /// Shared chrome: the native search field, its suggestion overlay, the toolbar controls,
    /// the sheets, and the model lifecycle. Only the title differs between root and pushed.
    private var content: some View {
        currentContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(
                text: queryBinding,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search tags or creators..."
            )
            .searchFocused($isSearchFieldFocused)
            .searchSuggestions { suggestionRows }
            // Environment-level input traits, the same ones the old inline field carried.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                // Same entry point as the old field's search key (SearchScreen.tsx:330-350).
                isSearchFieldFocused = false
                model.runSearch()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sourceToolbarButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    filterToolbarButton
                }
            }
            .task {
                await model.start()
                await reloadTagLists()
            }
            .onAppear { model.updateContext(context) }
            .onChange(of: contextVersion) { _, _ in
                // A Worker URL, API key, or quality edit pushes a fresh context into the model.
                model.updateContext(context)
            }
            .onChange(of: isSearchFieldFocused) { _, focused in
                // Autocomplete stays tied to the field being active, as before.
                model.inputFocusChanged(focused)
            }
            .onChange(of: activeSourceID) { _, newValue in
                model.selectSource(newValue)
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                SearchFilterSheetView(config: filterBinding, sourceID: model.sourceID) { config in
                    model.applyFilter(config)
                }
            }
            .sheet(isPresented: $isSourceSheetPresented) {
                SourceSheetView(selectedSource: model.sourceID) { id in
                    isSourceSheetPresented = false
                    model.selectSource(id)
                }
                .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var currentContent: some View {
        if model.isSearchActive {
            resultsContent
        } else {
            exploreContent
        }
    }

    private var filterBinding: Binding<SearchFilterConfig> {
        Binding(
            get: { model.filter },
            set: { model.filter = $0 }
        )
    }

    /// The native field's text. Writing goes through `setQuery` so the debounced server
    /// autocomplete reschedules on every keystroke (SearchScreen.tsx:283-326).
    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.setQuery($0) }
        )
    }

    // MARK: Toolbar

    private var sourceEntry: SourceSheetView.Entry {
        SourceSheetView.entry(for: model.sourceID)
    }

    /// Native toolbar source switcher; it opens the system sheet picker. The compact source
    /// name stays visible next to the glyph, matching the old header pill.
    private var sourceToolbarButton: some View {
        Button {
            isSearchFieldFocused = false
            isSourceSheetPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.fill")
                Text(sourceEntry.shortName)
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Current source: \(sourceEntry.name). Change source")
        .accessibilityIdentifier("search.sourceButton")
    }

    /// Native toolbar filter control; the filled glyph marks active structured options.
    private var filterToolbarButton: some View {
        Button {
            isSearchFieldFocused = false
            isFilterSheetPresented = true
        } label: {
            Label(
                "Search filters",
                systemImage: model.hasCustomFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("Search filters")
        .accessibilityIdentifier("search.filterButton")
    }

    // MARK: Autocomplete

    /// Autocomplete rows for the system suggestion overlay. Selecting one keeps the
    /// token-aware rewrite and runs the search, exactly like the old inline list.
    ///
    /// Empty results produce no rows at all, so a focused field with nothing to suggest
    /// never shows an empty overlay; the model still cancels tasks on source change.
    @ViewBuilder
    private var suggestionRows: some View {
        if !model.suggestions.isEmpty {
            ForEach(model.suggestions, id: \.name) { suggestion in
                Button {
                    isSearchFieldFocused = false
                    model.applySuggestion(suggestion, immediateSearch: true)
                } label: {
                    HStack(spacing: AppTheme.Spacing.item) {
                        Circle()
                            .fill(AppTheme.tagColor(for: suggestion.category))
                            .frame(width: 8, height: 8)
                        Text(suggestion.name)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer(minLength: AppTheme.Spacing.item)
                        Text(TagChipView.abbreviated(suggestion.postCount))
                            .font(AppTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.textMuted)
                    }
                    .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    "\(suggestion.name.replacingOccurrences(of: "_", with: " ")), "
                        + "\(TagChipView.abbreviated(suggestion.postCount)) posts"
                )
            }
        }
    }

    // MARK: Results

    private var resultsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                if onOpenTag != nil, !model.filter.tags.isEmpty {
                    activeTagChips
                }
                if model.isLoading {
                    loadingState
                } else if let message = model.errorMessage {
                    errorState(message)
                } else {
                    if !model.results.isEmpty {
                        grid(columnWidth: Self.columnWidth(for: availableWidth))
                    }
                    if model.isLoadingMore {
                        ProgressView()
                            .tint(AppTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else if model.blacklistedCount > 0, !model.filter.includeBlacklisted {
                        hiddenPostsButton
                    }
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // Width comes from the scroll view itself, so no `GeometryReader` wraps it and the
        // native navigation stack keeps the scroll edge and collapsing title.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width.isFinite, width > 0 else { return }
            guard abs(width - availableWidth) > 0.5 else { return }
            availableWidth = width
        }
    }

    private var activeTagChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.filter.tags, id: \.self) { tag in
                    // Wrapping button: compact chip, full 44pt target, no nested buttons.
                    Button {
                        onOpenTag?(tag)
                    } label: {
                        TagChipView(text: tag, isSelected: true)
                            .accessibilityHidden(true)
                            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tag.replacingOccurrences(of: "_", with: " "))
                    .contextMenu { tagContextMenu(for: tag) }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Two height-balanced columns (same `MasonryColumns` pass as `FeedScreen`),
    /// so tall cards never leave holes under the shorter column.
    private func grid(columnWidth: CGFloat) -> some View {
        let columns = Self.masonrySplit(model.results, columnWidth: columnWidth)
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(columns.indices, id: \.self) { index in
                columnFrame(
                    LazyVStack(spacing: Self.columnSpacing) {
                        ForEach(columns[index]) { post in
                            card(for: post)
                        }
                    },
                    width: columnWidth
                )
            }
        }
    }

    /// Before the first width sample there is no measured column, so the columns take an equal
    /// share of the container instead of collapsing to a zero frame; the measured pass
    /// replaces it as soon as `onGeometryChange` reports a real width.
    @ViewBuilder
    private func columnFrame<V: View>(_ content: V, width: CGFloat) -> some View {
        if width > 0 {
            content.frame(width: width, alignment: .top)
        } else {
            content.frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// Greedy height-balanced split (pure, so the render pass never mutates state).
    private static func masonrySplit(_ posts: [BooruPost], columnWidth: CGFloat) -> [[BooruPost]] {
        var masonry = MasonryColumns()
        return masonry.layout(posts) { post in
            MasonryColumns.estimatedHeight(for: post, columnWidth: columnWidth)
        }
    }

    private func card(for post: BooruPost) -> some View {
        let longPress: (() -> Void)? = onToggleFavorite.map { handler in { handler(post) } }
        return PostCardView(
            post: post,
            imageQuality: imageQuality,
            gridPreviewsEnabled: gridPreviewsEnabled,
            isFavorite: favoriteKeys.contains(postKey(post)),
            onTap: { open(post) },
            onLongPress: longPress
        )
        .onAppear {
            // Prefetch the next page when the last card appears (RN `onEndReached`).
            if post.id == model.results.last?.id {
                model.loadMore()
            }
        }
    }

    /// Equal column width that fits the measured grid exactly.
    private static func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let usable = totalWidth - AppTheme.Spacing.screenHorizontal * 2 - Self.columnSpacing
        guard usable > 0 else { return 0 }
        return (usable / CGFloat(MasonryColumns.defaultColumnCount)).rounded(.down)
    }

    private var hiddenPostsButton: some View {
        Button {
            model.showBlacklistedPosts()
        } label: {
            Label("Show \(model.blacklistedCount) hidden posts", systemImage: "eye.slash")
                .font(AppTheme.Typography.secondary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.minimumHitTarget)
        }
        .buttonStyle(.glass)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(AppTheme.primary)
            Text("Searching results...")
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Result errors and the "no results" page share one native state view; the model reports an
    /// empty page as the message "No results found" (SearchViewModel `apply(_:isFirstPage:)`).
    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        if message == "No results found" {
            ContentUnavailableView {
                Label("No results found", systemImage: "magnifyingglass")
            } description: {
                Text("Try different tags or adjust the filters.")
            } actions: {
                retryButton
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
        } else {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(message)
            } actions: {
                retryButton
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
        }
    }

    private var retryButton: some View {
        Button("Retry") {
            model.runSearch()
        }
        .buttonStyle(.glassProminent)
        .tint(AppTheme.primary)
    }

    private func open(_ post: BooruPost) {
        guard let target = model.openTarget(for: post) else { return }
        onOpenPost(target.posts, target.index)
    }

    // MARK: Explore

    private var exploreContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                if !model.history.isEmpty {
                    recentSearches
                }
                popularTagsSection
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.bottom, AppTheme.Spacing.section)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: AppTheme.Icon.small))
                    .foregroundStyle(AppTheme.textSecondary)
                Text("Recent Searches")
                    .font(AppTheme.Typography.caption)
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.history, id: \.self) { entry in
                        // Compact chip inside a full-height button target.
                        Button {
                            isSearchFieldFocused = false
                            model.search(text: entry)
                        } label: {
                            TagChipView(text: entry)
                                .accessibilityHidden(true)
                                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.replacingOccurrences(of: "_", with: " "))
                        .contextMenu { tagContextMenu(for: entry) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var popularTagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: AppTheme.Icon.small))
                    .foregroundStyle(AppTheme.goldAccent)
                Text("Popular Tags")
                    .font(AppTheme.Typography.caption)
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            PopularTagFlowLayout(spacing: AppTheme.Spacing.item, lineSpacing: AppTheme.Spacing.item) {
                ForEach(Self.popularTags, id: \.self) { tag in
                    // Compact chip inside a full-height button target.
                    Button {
                        isSearchFieldFocused = false
                        model.search(text: tag)
                    } label: {
                        TagChipView(text: tag)
                            .accessibilityHidden(true)
                            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tag.replacingOccurrences(of: "_", with: " "))
                    .contextMenu { tagContextMenu(for: tag) }
                }
            }
        }
    }

    // MARK: Tag context menu

    /// Mirrors `TagListStore.favorite` normalization: trimmed, whitespace
    /// collapsed, lowercased.
    private static func pinnedKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Mirrors `TagListStore.blacklisted` normalization: whitespace becomes `_`.
    private static func blacklistKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_").lowercased()
    }

    /// Refreshes the pin/blacklist state shown by the chip menus.
    private func reloadTagLists() async {
        if let favoriteTagsStore, let tags = try? await favoriteTagsStore.list() {
            pinnedTagKeys = Set(tags.map(Self.pinnedKey))
        }
        if let blacklistStore, let tags = try? await blacklistStore.list() {
            blacklistedTagKeys = Set(tags.map(Self.blacklistKey))
            model.updateBlacklist(tags)
        }
    }

    private func togglePinnedTag(_ tag: String) async {
        guard let favoriteTagsStore else { return }
        let key = Self.pinnedKey(tag)
        if pinnedTagKeys.contains(key) {
            try? await favoriteTagsStore.remove(key)
        } else {
            try? await favoriteTagsStore.add(key)
        }
        await reloadTagLists()
    }

    private func toggleBlacklistedTag(_ tag: String) async {
        guard let blacklistStore else { return }
        let key = Self.blacklistKey(tag)
        if blacklistedTagKeys.contains(key) {
            try? await blacklistStore.remove(key)
        } else {
            try? await blacklistStore.add(key)
        }
        await reloadTagLists()
    }

    /// Tag actions available from any chip: search, add, exclude, pin, blacklist, copy.
    @ViewBuilder
    private func tagContextMenu(for tag: String) -> some View {
        Button {
            isSearchFieldFocused = false
            model.search(text: tag, mode: .replace)
        } label: {
            Label("Search Tag", systemImage: "magnifyingglass")
        }
        Button {
            isSearchFieldFocused = false
            model.search(text: "+" + tag, mode: .add)
        } label: {
            Label("Add +\(tag)", systemImage: "plus.circle")
        }
        Button {
            isSearchFieldFocused = false
            model.search(text: "-" + tag, mode: .exclude)
        } label: {
            Label("Exclude -\(tag)", systemImage: "minus.circle")
        }
        Button {
            Task { await togglePinnedTag(tag) }
        } label: {
            Label(
                pinnedTagKeys.contains(Self.pinnedKey(tag)) ? "Unpin Favorite Tag" : "Pin to Favorite Tags",
                systemImage: "pin"
            )
        }
        Button(role: .destructive) {
            Task { await toggleBlacklistedTag(tag) }
        } label: {
            Label(
                blacklistedTagKeys.contains(Self.blacklistKey(tag)) ? "Remove from Blacklist" : "Add to Blacklist",
                systemImage: "eye.slash"
            )
        }
        Button {
            UIPasteboard.general.string = tag
        } label: {
            Label("Copy Tag", systemImage: "doc.on.doc")
        }
    }
}

// MARK: - Popular tag flow

/// Left-aligned wrapping row of chips.
///
/// A `LazyVGrid` with `.adaptive` columns stretches every cell to the same width, which left
/// wide irregular gaps between short tags; this layout lets each chip keep its intrinsic size
/// and wraps to the next line only when the width is exhausted (same behaviour as
/// `TagFlowLayout` in `PostInfoSheetView`).
private struct PopularTagFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(
            width: maxWidth.isFinite ? maxWidth : contentWidth,
            height: y + lineHeight
        )
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
