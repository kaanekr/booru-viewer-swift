import SwiftUI
import UIKit

/// Search tab: tag input with debounced server autocomplete, recent-search chips, the filter sheet,
/// and a two-column result grid. Mirrors RN `SearchScreen.tsx`.
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
    @FocusState private var isSearchFieldFocused: Bool
    /// Measured height of the overlaid header; the lists reserve exactly this much space.
    @State private var headerHeight: CGFloat = 64
    /// Continuous collapse of the header, driven by the list scroll offset.
    @State private var headerState = ScrollAwayHeaderState()

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
    /// Named space the list offset readers measure against.
    private static let listSpace = "searchList"

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

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.background.ignoresSafeArea()

            currentContent

            ScrollAwayHeaderView(
                slideOffset: isHeaderPinned ? 0 : headerState.slide,
                isPinned: isHeaderPinned,
                isHidden: !isHeaderPinned && headerState.isFullyCollapsed
            ) {
                header
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .onPreferenceChange(ScrollAwayHeaderHeightKey.self) { height in
            if height > 0, abs(height - headerHeight) > 0.5 {
                headerHeight = height
            }
        }
        .onChange(of: headerHeight) { _, _ in
            resetHeaderSlide()
        }
        .onChange(of: isHeaderPinned) { _, _ in
            // Editing, autocomplete, and the sheets keep the bar in place; when the pin
            // ends the baseline is dropped too, so the first scroll sample rebases
            // instead of replaying the distance scrolled while editing.
            resetHeaderSlide()
        }
        .onChange(of: model.isSearchActive) { _, _ in
            resetHeaderSlide()
        }
        .onChange(of: model.sourceID) { _, _ in
            // A source switch rebuilds the results and chips; start from a shown header.
            resetHeaderSlide()
        }
        .onChange(of: model.filter) { _, _ in
            // Applying filters re-runs the search, so the header comes back with the new
            // active-tag chips instead of staying mid-slide.
            resetHeaderSlide()
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
            .presentationBackground(AppTheme.background)
        }
    }

    /// The header stays put while the field is being edited (keyboard, live autocomplete)
    /// or a sheet is open, and only follows the list scroll otherwise.
    private var isHeaderPinned: Bool {
        isSearchFieldFocused || isFilterSheetPresented || isSourceSheetPresented
    }

    @ViewBuilder
    private var currentContent: some View {
        if isSearchFieldFocused, !model.suggestions.isEmpty {
            suggestionList
        } else if model.isSearchActive {
            resultsContent
        } else {
            exploreContent
        }
    }

    /// Applies the shared offset tracking to one list: the named space plus the
    /// continuous header update.
    private func tracksHeaderScroll<V: View>(_ list: V) -> some View {
        list
            .coordinateSpace(name: Self.listSpace)
            .onPreferenceChange(ScrollAwayOffsetKey.self) { offset in
                updateHeader(for: offset)
            }
    }

    /// Continuous header collapse: follows the content offset on every sample, so a
    /// short first scroll already starts the slide and any upward move reveals it.
    private func updateHeader(for offset: CGFloat) {
        // Pinned (refresh, sheet, editing): the `.onChange(of: isHeaderPinned)` reset
        // already revealed the bar and dropped the baseline, so ignore scroll samples.
        guard !isHeaderPinned else { return }
        headerState.update(offset: offset, height: headerHeight)
    }

    private func resetHeaderSlide() {
        headerState.syncHeight(headerHeight)
        headerState.reset()
    }

    /// Space reserved at the top of every list for the overlaid header, so the first
    /// row starts below the controls and the inset never changes while it hides.
    private var headerSpacer: some View {
        Color.clear.frame(height: headerHeight)
    }

    private var filterBinding: Binding<SearchFilterConfig> {
        Binding(
            get: { model.filter },
            set: { model.filter = $0 }
        )
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: AppTheme.Spacing.item) {
            HStack(spacing: AppTheme.Spacing.item) {
                sourcePill
                searchField
                filterButton
            }
            if onOpenTag != nil, !model.filter.tags.isEmpty {
                activeTagChips
            }
        }
        .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
        .padding(.top, AppTheme.Spacing.rowVertical)
        .padding(.bottom, AppTheme.Spacing.item)
        .background(AppTheme.background)
    }

    private var sourceEntry: SourceSheetView.Entry {
        SourceSheetView.entry(for: model.sourceID)
    }

    private var sourcePill: some View {
        Button {
            isSearchFieldFocused = false
            isSourceSheetPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryLight)
                Text(sourceEntry.shortName)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, AppTheme.Spacing.chipHorizontal)
            .padding(.vertical, AppTheme.Spacing.chipVertical)
            .background(AppTheme.surface, in: Capsule())
            .overlay {
                Capsule().stroke(AppTheme.border, lineWidth: 1)
            }
            // Compact visual, full-size tap target.
            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current source: \(sourceEntry.name). Change source")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                .foregroundStyle(AppTheme.textMuted)

            TextField("Search tags or creators...", text: queryBinding)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textPrimary)
                .onSubmit {
                    isSearchFieldFocused = false
                    model.runSearch()
                }

            if !model.query.isEmpty {
                Button {
                    model.setQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.Icon.small))
                        .foregroundStyle(AppTheme.textMuted)
                        // 44pt target inside the field, without inflating the bar.
                        .frame(width: AppTheme.Spacing.minimumHitTarget, height: AppTheme.Spacing.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.horizontal, 10)
        // The field surface itself is the 44pt target, so the bar stays compact.
        .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSearchFieldFocused ? AppTheme.primary : AppTheme.border, lineWidth: 1)
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.setQuery($0) }
        )
    }

    private var filterButton: some View {
        Button {
            isSearchFieldFocused = false
            isFilterSheetPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: AppTheme.Icon.standard, weight: .semibold))
                .foregroundStyle(model.hasCustomFilters ? AppTheme.primaryLight : AppTheme.textSecondary)
                .frame(width: AppTheme.Spacing.minimumHitTarget, height: AppTheme.Spacing.minimumHitTarget)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(model.hasCustomFilters ? AppTheme.primary : AppTheme.border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search filters")
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

    // MARK: Autocomplete

    private var suggestionList: some View {
        tracksHeaderScroll(
            ScrollView {
                LazyVStack(spacing: 0) {
                    headerSpacer
                    ForEach(model.suggestions, id: \.name) { suggestion in
                        Button {
                            isSearchFieldFocused = false
                            model.applySuggestion(suggestion, immediateSearch: true)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(AppTheme.tagColor(for: suggestion.category))
                                    .frame(width: 8, height: 8)
                                Text(suggestion.name)
                                    .font(AppTheme.Typography.body)
                                    .lineLimit(1)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer(minLength: 8)
                                Text(TagChipView.abbreviated(suggestion.postCount))
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(AppTheme.textMuted)
                            }
                            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
                            .padding(.vertical, AppTheme.Spacing.rowVertical)
                            // Rows stay comfortably tappable while the text gets smaller.
                            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppTheme.divider)
                    }
                }
                .scrollAwayOffsetReader(space: Self.listSpace)
            }
            .scrollDismissesKeyboard(.immediately)
        )
    }

    // MARK: Results

    private var resultsContent: some View {
        GeometryReader { geometry in
            let columnWidth = Self.columnWidth(for: geometry.size.width)
            tracksHeaderScroll(
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.section) {
                        headerSpacer
                        if model.isLoading {
                            loadingState
                        } else if let message = model.errorMessage {
                            errorState(message)
                        } else {
                            if !model.results.isEmpty {
                                grid(columnWidth: columnWidth)
                            }
                            if model.isLoadingMore {
                                ProgressView()
                                    .tint(AppTheme.primary)
                                    .padding(.vertical, 12)
                            } else if model.blacklistedCount > 0, !model.filter.includeBlacklisted {
                                hiddenPostsButton
                            }
                        }
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.bottom, 12)
                    .scrollAwayOffsetReader(space: Self.listSpace)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            )
        }
    }

    /// Two height-balanced columns (same `MasonryColumns` pass as `FeedScreen`),
    /// so tall cards never leave holes under the shorter column.
    private func grid(columnWidth: CGFloat) -> some View {
        var masonry = MasonryColumns()
        let columns = masonry.layout(model.results) { post in
            MasonryColumns.estimatedHeight(for: post, columnWidth: columnWidth)
        }
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: Self.columnSpacing) {
                    ForEach(columns[index]) { post in
                        card(for: post)
                    }
                }
                .frame(width: columnWidth > 0 ? columnWidth : nil, alignment: .top)
            }
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
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text("Show \(model.blacklistedCount) hidden posts")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(AppTheme.primary)
                .scaleEffect(1.2)
            Text("Searching results...")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(AppTheme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                model.runSearch()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func open(_ post: BooruPost) {
        guard let target = model.openTarget(for: post) else { return }
        onOpenPost(target.posts, target.index)
    }

    // MARK: Explore

    private var exploreContent: some View {
        tracksHeaderScroll(
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                    headerSpacer
                    if !model.history.isEmpty {
                        recentSearches
                    }
                    popularTagsSection
                }
                .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
                .padding(.bottom, AppTheme.Spacing.section)
                .scrollAwayOffsetReader(space: Self.listSpace)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        )
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
