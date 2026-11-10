import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What a trending-tag context-menu action should do with the Search tab query.
///
/// Mirrors the viewer's tag menu (`TagSearchModification`): a plain tag search,
/// `+tag` appended to the current query, or `-tag` appended to it.
enum FeedTagSearchAction: Sendable {
    /// Replace the query with the tag.
    case replace
    /// Append `+tag` to the current query.
    case include
    /// Append `-tag` to the current query.
    case exclude
}

/// Explore tab: source switcher, source-aware quick filters, trending tags, a two-column
/// masonry grid, pull-to-refresh and infinite pagination.
///
/// Chrome is stock iOS 26: the screen carries its own native navigation title and subtitle,
/// and the source switcher plus the feed-order menu live in the navigation toolbar, so the
/// system draws the collapsing large title, the scroll-edge material, and the Liquid Glass
/// toolbar controls around the content. The quick-filter strip and the trending-tag strip
/// scroll with the grid; nothing is overlaid on the navigation or tab bar.
///
/// Mirrors RN `FeedScreen` (src/screens/FeedScreen.tsx:332-577).
@MainActor
struct FeedScreen: View {
    private let settings: AppSettings
    private let favoriteKeys: Set<String>
    private let onSelectTag: ((String) -> Void)?
    private let onOpenPost: ([BooruPost], Int) -> Void
    /// Request context handed to the model at build time and re-pushed on `contextVersion` changes.
    private let context: SourceContext
    /// Bumped by the app layer whenever the request context (Worker, keys, quality) changes.
    private let contextVersion: Int
    /// Persists a source picked in the sheet so every tab follows the switch.
    private let onSelectSource: ((SourceID) -> Void)?
    /// Long-press action: pin a trending tag to the favorite-tag list.
    private let onPinTag: ((String) -> Void)?
    /// Long-press action: add a trending tag to the blacklist.
    private let onBlacklistTag: ((String) -> Void)?
    /// Long-press action: rewrite the Search tab query with a trending tag.
    private let onSearchAction: ((String, FeedTagSearchAction) -> Void)?

    @State private var model: FeedViewModel
    @State private var isSourceSheetOpen = false
    /// Width measured from the scroll view itself (never a `GeometryReader` wrapper), so the
    /// masonry split follows the container and native scroll-edge/large-title behaviour stays.
    @State private var availableWidth: CGFloat = 0
    /// Memoized masonry split: rebuilt only when the page or the column width changes,
    /// never on plain body evaluation.
    @State private var columns: [[BooruPost]] = [[], []]

    private static let columnSpacing: CGFloat = 12
    /// Bottom breathing room inside the scroll content; the tab-bar clearance is
    /// handled by the host, not here.
    private static let bottomPadding: CGFloat = 12

    /// - Parameters:
    ///   - settings: image quality, grid previews, and the starting source/order.
    ///   - context: transport and credentials handed to the source adapters.
    ///   - blacklistedTags: raw blacklist entries applied to every loaded page.
    ///   - favoriteKeys: `postKey` values that draw the favorite badge on a card.
    ///   - sourceProvider: source lookup, injectable for previews and tests.
    ///   - onSelectTag: trending-tag tap; the app layer pushes a search for the tag.
    ///   - onOpenPost: opens the viewer at `index` inside the loaded list
    ///     (RN `pushViewer(posts, idx)`, FeedScreen.tsx:325-330).
    ///   - contextVersion: app-level change counter for the request context; a new value pushes
    ///     the fresh `context` into the view model without rebuilding the screen.
    ///   - onSelectSource: persists a source switch made in the sheet (FeedScreen.tsx:215-226).
    ///   - onPinTag: trending-chip long press; adds the tag to the favorite tags.
    ///   - onBlacklistTag: trending-chip long press; adds the tag to the blacklist.
    ///   - onSearchAction: trending-chip long press; opens the Search tab with the tag.
    init(
        settings: AppSettings,
        context: SourceContext,
        blacklistedTags: [String] = [],
        favoriteKeys: Set<String> = [],
        contextVersion: Int = 0,
        sourceProvider: @escaping FeedViewModel.SourceProvider = { SourceRegistry.source(for: $0) },
        onSelectTag: ((String) -> Void)? = nil,
        onSelectSource: ((SourceID) -> Void)? = nil,
        onPinTag: ((String) -> Void)? = nil,
        onBlacklistTag: ((String) -> Void)? = nil,
        onSearchAction: ((String, FeedTagSearchAction) -> Void)? = nil,
        onOpenPost: @escaping ([BooruPost], Int) -> Void
    ) {
        self.settings = settings
        self.favoriteKeys = favoriteKeys
        self.onSelectTag = onSelectTag
        self.onOpenPost = onOpenPost
        self.context = context
        self.contextVersion = contextVersion
        self.onSelectSource = onSelectSource
        self.onPinTag = onPinTag
        self.onBlacklistTag = onBlacklistTag
        self.onSearchAction = onSearchAction
        _model = State(initialValue: FeedViewModel(
            sourceID: settings.activeSourceID,
            context: context,
            feedOrder: settings.feedOrder,
            blacklistedTags: blacklistedTags,
            sourceProvider: sourceProvider
        ))
    }

    /// Hosts that already built the model (stores, blacklist, source provider) pass it in,
    /// matching how `SearchScreen` receives its view model.
    init(
        viewModel: FeedViewModel,
        settings: AppSettings,
        favoriteKeys: Set<String> = [],
        contextVersion: Int = 0,
        onSelectTag: ((String) -> Void)? = nil,
        onSelectSource: ((SourceID) -> Void)? = nil,
        onPinTag: ((String) -> Void)? = nil,
        onBlacklistTag: ((String) -> Void)? = nil,
        onSearchAction: ((String, FeedTagSearchAction) -> Void)? = nil,
        onOpenPost: @escaping ([BooruPost], Int) -> Void
    ) {
        self.settings = settings
        self.favoriteKeys = favoriteKeys
        self.onSelectTag = onSelectTag
        self.onOpenPost = onOpenPost
        self.context = viewModel.context
        self.contextVersion = contextVersion
        self.onSelectSource = onSelectSource
        self.onPinTag = onPinTag
        self.onBlacklistTag = onBlacklistTag
        self.onSearchAction = onSearchAction
        _model = State(initialValue: viewModel)
    }

    // MARK: Body

    var body: some View {
        feedContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Explore")
            // Native iOS 26 subtitle under the large title (FeedScreen.tsx:344-346).
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sourceToolbarButton
                }
                if model.quickFilters.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        feedOrderMenu
                    }
                }
            }
            .sheet(isPresented: $isSourceSheetOpen) {
                SourceSheetView(selectedSource: model.sourceID) { id in
                    isSourceSheetOpen = false
                    // Persist the pick so Explore, Search, and Settings stay in sync.
                    onSelectSource?(id)
                    Task { await model.selectSource(id) }
                }
                .presentationDetents([.medium, .large])
            }
            .task {
                await model.loadInitialIfNeeded()
            }
            .onAppear {
                model.updateContext(context)
            }
            // Observe `model.posts` on the stable `body` ancestor rather than inside `grid`:
            // `grid` unmounts whenever `model.posts.isEmpty` (source switch, empty refresh),
            // so an inner observer misses `sourceA -> [] -> sourceB` at an unchanged width.
            .onChange(of: model.posts, initial: true) { _, _ in
                rebuildColumns(width: availableWidth)
            }
            .onChange(of: contextVersion) { _, _ in
                // A Worker URL, API key, or quality edit pushes a fresh context into the model.
                model.updateContext(context)
            }
            .onChange(of: settings.activeSourceID) { _, newValue in
                guard newValue != model.sourceID else { return }
                Task { await model.selectSource(newValue) }
            }
    }

    @ViewBuilder
    private var feedContent: some View {
        if model.posts.isEmpty {
            if case .failed(let message) = model.phase {
                errorState(message)
            } else if model.phase == .loading || model.phase == .idle {
                loadingState
            } else {
                emptyState
            }
        } else {
            grid
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.item) {
                // A single Discover choice is not a filter (FeedScreen.tsx:369).
                if model.quickFilters.count > 1 {
                    quickFilterBar
                }

                if !model.trendingTags.isEmpty {
                    trendingBar
                }

                VStack(spacing: Self.columnSpacing) {
                    HStack(alignment: .top, spacing: Self.columnSpacing) {
                        ForEach(columns.indices, id: \.self) { index in
                            column(columns[index], width: Self.columnWidth(for: availableWidth))
                        }
                    }

                    footer
                }
                .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
                .padding(.top, AppTheme.Spacing.item)
                .padding(.bottom, Self.bottomPadding)
            }
        }
        .scrollIndicators(.hidden)
        // The grid stays the plain scroll view it has always been: the native navigation
        // stack keeps the scroll edge and the collapsing large title, because no
        // `GeometryReader` wraps it. Only the measured width is reported back.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width.isFinite, width > 0 else { return }
            guard abs(width - availableWidth) > 0.5 else { return }
            availableWidth = width
            rebuildColumns(width: width)
        }
        .refreshable {
            await model.refresh()
        }
    }

    /// Memoized masonry split. Recomputed only when a page lands, the column width
    /// changes, or the grid first appears — never on plain body evaluation.
    private func rebuildColumns(width: CGFloat) {
        let posts = model.posts
        guard !posts.isEmpty else {
            if !columns.allSatisfy(\.isEmpty) {
                columns = [[], []]
            }
            return
        }

        let columnWidth = Self.columnWidth(for: width)
        // A not-yet-measured width (0 at first layout) still produces a usable split: the
        // estimator falls back to its badge allowance, and the columns take an equal share of
        // the container until the measured pass replaces it. No zero/negative column frame
        // and no permanently empty grid.
        var masonry = MasonryColumns()
        let next = masonry.layout(posts) { post in
            MasonryColumns.estimatedHeight(for: post, columnWidth: columnWidth)
        }
        if next != columns {
            columns = next
        }
    }

    /// Equal column width that fits the measured grid exactly; the sub-point
    /// remainder is dropped rather than letterboxing the cards.
    private static func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let usable = totalWidth - AppTheme.Spacing.screenHorizontal * 2 - Self.columnSpacing
        guard usable > 0 else { return 0 }
        return (usable / CGFloat(MasonryColumns.defaultColumnCount)).rounded(.down)
    }

    @ViewBuilder
    private func column(_ posts: [BooruPost], width: CGFloat) -> some View {
        let columnContent = LazyVStack(spacing: Self.columnSpacing) {
            ForEach(posts) { post in
                card(for: post)
            }
            // Skip the sentinel while the memoized split is still empty, so an
            // unbuilt column cannot request page 2 before the cards exist.
            if !posts.isEmpty {
                paginationSentinel
            }
        }
        // Before the first measured width the two columns share the container equally, so the
        // grid is never a zero-width frame; the measured pass pins the exact column width.
        if width > 0 {
            columnContent.frame(width: width, alignment: .top)
        } else {
            columnContent.frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func card(for post: BooruPost) -> some View {
        PostCardView(
            post: post,
            imageQuality: settings.imageQuality,
            gridPreviewsEnabled: settings.gridPreviews,
            isFavorite: favoriteKeys.contains(postKey(post)),
            onTap: { open(post) }
        )
    }

    /// Lazy sentinel: it appears with the last row, which asks for the next page
    /// (FeedScreen.tsx:256-260, 504-506). Duplicate calls are guarded by the model.
    private var paginationSentinel: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                Task { await model.loadMore() }
            }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(AppTheme.primary)
                Text("Loading more...")
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.textMuted)
            }
            .padding(.vertical, 20)
        } else if let message = model.errorMessage {
            Text(message)
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.danger)
                .multilineTextAlignment(.center)
                .padding(.vertical, 16)
        }
    }

    private func open(_ post: BooruPost) {
        guard let target = model.openTarget(for: post) else { return }
        onOpenPost(target.posts, target.index)
    }

    // MARK: Toolbar

    private var sourceEntry: SourceSheetView.Entry {
        SourceSheetView.entry(for: model.sourceID)
    }

    /// Native toolbar source switcher; it opens the system sheet picker. The compact source
    /// name stays visible next to the glyph, matching the old header pill (FeedScreen.tsx:362).
    private var sourceToolbarButton: some View {
        Button {
            isSourceSheetOpen = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.fill")
                Text(sourceEntry.shortName)
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Current source: \(sourceEntry.name). Change source")
        .accessibilityIdentifier("feed.sourceButton")
    }

    /// Native toolbar menu mirroring the quick-filter strip, so the feed order stays
    /// reachable when the strip has scrolled away. Both paths call the same model method.
    private var feedOrderMenu: some View {
        Menu {
            ForEach(model.quickFilters) { option in
                Button {
                    Task { await model.applyQuickFilter(option) }
                } label: {
                    if model.isActive(option) {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label("Feed filters", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Feed filters")
        .accessibilityIdentifier("feed.filterMenu")
    }

    // MARK: Header strips

    /// RN subtitle (FeedScreen.tsx:344-346).
    private var subtitle: String {
        model.sourceID == .redgifs
            ? "Video clips and animations"
            : "Latest anime and illustrations"
    }

    private var quickFilterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.item) {
                ForEach(model.quickFilters) { option in
                    quickFilterChip(option)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
        }
        .scrollIndicators(.hidden)
    }

    /// One quick-filter chip. The active chip is a promoted Liquid Glass button with a
    /// checkmark, so the selected order is carried by the native style, not a hand-drawn fill.
    @ViewBuilder
    private func quickFilterChip(_ option: SourceQuickFilter) -> some View {
        if model.isActive(option) {
            Button {
                Task { await model.applyQuickFilter(option) }
            } label: {
                quickFilterLabel(option, selected: true)
            }
            .buttonStyle(.glassProminent)
            // RN keeps its gold "selected quick filter" accent (FeedScreen.tsx:39).
            .tint(AppTheme.goldAccent)
            .accessibilityLabel(option.label)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                Task { await model.applyQuickFilter(option) }
            } label: {
                quickFilterLabel(option, selected: false)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(option.label)
        }
    }

    /// Chip copy. The 44 x 44 pt lane lives inside the button label, so the whole target is the
    /// control's own content region (never a frame outside the style).
    private func quickFilterLabel(_ option: SourceQuickFilter, selected: Bool) -> some View {
        HStack(spacing: 4) {
            if selected {
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(option.label)
                .font(AppTheme.Typography.secondary)
                .fontWeight(selected ? .bold : .semibold)
                .lineLimit(1)
        }
        // The promoted glass fill is gold, so the copy keeps RN's dark gold label
        // (FeedScreen.tsx:647) instead of the tinted label Liquid Glass would pick.
        .foregroundStyle(selected ? AppTheme.goldAccentText : AppTheme.textPrimary)
        .frame(
            minWidth: AppTheme.Spacing.minimumHitTarget,
            minHeight: AppTheme.Spacing.minimumHitTarget
        )
        .contentShape(Rectangle())
    }

    /// RN rendered RedGifs trending tags here (FeedScreen.tsx:397-423); the cards are the
    /// same `TagChipView` chips, seeded from the loaded posts instead.
    private var trendingBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: AppTheme.Icon.small))
                    .foregroundStyle(AppTheme.goldAccent)
                Text("Trending Tags")
                    .font(AppTheme.Typography.caption)
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.trendingTags) { tag in
                        trendingChip(tag)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// One trending chip: compact shared pill wrapped in a 44pt tap target, so the
    /// strip does not need tall pills. The pill is not interactive itself, so the
    /// button owns the action and the context menu.
    @ViewBuilder
    private func trendingChip(_ tag: FeedViewModel.TrendingTag) -> some View {
        let chip = TagChipView(
            text: tag.name,
            category: tag.category,
            count: tag.count
        )
        .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
        .contentShape(Rectangle())

        if let tap = tagTap(tag.name) {
            Button(action: tap) { chip.accessibilityHidden(true) }
                .buttonStyle(.plain)
                .accessibilityLabel(trendingChipLabel(tag))
                .contextMenu { trendingTagMenu(tag.name) }
        } else {
            chip
                .accessibilityLabel(trendingChipLabel(tag))
                .contextMenu { trendingTagMenu(tag.name) }
        }
    }

    /// Spoken label for a trending chip, including its abbreviated post count.
    private func trendingChipLabel(_ tag: FeedViewModel.TrendingTag) -> String {
        let name = tag.name.replacingOccurrences(of: "_", with: " ")
        return "\(name), \(TagChipView.abbreviated(tag.count)) posts"
    }

    /// Long press on a trending chip: search, include/exclude, pin, blacklist, or copy it.
    @ViewBuilder
    private func trendingTagMenu(_ name: String) -> some View {
        Button {
            runSearchAction(name, .replace)
        } label: {
            Label("Search Tag", systemImage: "magnifyingglass")
        }
        Button {
            runSearchAction(name, .include)
        } label: {
            Label("Add to Search (+\(name))", systemImage: "plus.magnifyingglass")
        }
        Button {
            runSearchAction(name, .exclude)
        } label: {
            Label("Exclude from Search (-\(name))", systemImage: "minus.magnifyingglass")
        }
        Button {
            onPinTag?(name)
        } label: {
            Label("Pin to Favorite Tags", systemImage: "pin")
        }
        Button(role: .destructive) {
            onBlacklistTag?(name)
        } label: {
            Label("Add to Blacklist", systemImage: "eye.slash")
        }
        Button {
            copyTag(name)
        } label: {
            Label("Copy Tag", systemImage: "doc.on.doc")
        }
    }

    /// `.replace` falls back to the existing tap handler when no Search-tab hook is wired.
    private func runSearchAction(_ name: String, _ action: FeedTagSearchAction) {
        if let onSearchAction {
            onSearchAction(name, action)
        } else if action == .replace {
            onSelectTag?(name)
        }
    }

    private func copyTag(_ name: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = name
        #endif
    }

    private func tagTap(_ name: String) -> (() -> Void)? {
        guard let onSelectTag else { return nil }
        return { onSelectTag(name) }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.primary)
            Text("Loading posts...")
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Connection Error", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(friendlyMessage(message))
        } actions: {
            Button("Retry") {
                Task { await model.retry() }
            }
            .buttonStyle(.glassProminent)
            .tint(AppTheme.primary)

            Button("Change Source") {
                isSourceSheetOpen = true
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Change source")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No posts found", systemImage: "tray")
        } description: {
            Text("Pull to refresh or try another source.")
        } actions: {
            Button("Retry") {
                Task { await model.retry() }
            }
            .buttonStyle(.glassProminent)
            .tint(AppTheme.primary)
        }
    }

    /// RN rewrites certificate/timeout failures into an ISP/SSL hint
    /// (FeedScreen.tsx:436-440).
    private func friendlyMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("certificate") || lower.contains("timed out") || lower.contains("ssl") {
            return "Could not reach the \(sourceEntry.name) source due to ISP or SSL blocking."
        }
        return raw
    }
}
