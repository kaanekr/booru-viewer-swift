import SwiftUI
import UIKit

/// Favorites tab with three segments: saved posts (source filter), favorite tags, and recent views.
/// Mirrors RN `FavoritesScreen.tsx`.
@MainActor
struct FavoritesScreen: View {
    @State private var model: FavoritesViewModel

    private let imageQuality: ImageQuality
    private let gridPreviewsEnabled: Bool
    private let isActive: Bool
    private let onOpenPost: ([BooruPost], Int) -> Void
    private let onSelectTag: (String) -> Void
    /// Optional blacklist store that powers the chip context menu.
    private let blacklistStore: (any TagListStoring)?

    @State private var newTagText = ""
    @State private var isConfirmingClear = false
    @State private var pendingRemoval: BooruPost? = nil
    @State private var blacklistedTagKeys: Set<String> = []

    /// Masonry metrics (same layout as `FeedScreen`).
    private static let columnSpacing: CGFloat = AppTheme.Spacing.item
    private static let horizontalPadding: CGFloat = AppTheme.Spacing.screenHorizontal

    /// - Parameters:
    ///   - favoritesStore: saved posts.
    ///   - tagStore: the favorite-tag list (`TagListStore.Kind.favorite`).
    ///   - recentViewsStore: recently viewed posts.
    ///   - clearRecentViews: persistence hook for the "Clear History" action; the store protocol
    ///     exposes no delete, so the app layer supplies it.
    ///   - isActive: the tab is on screen; turning true reloads all three lists (RN `isActive`).
    ///   - onSelectTag: favorite-tag tap; the app layer pushes a search for the tag.
    ///   - onOpenPost: opens the viewer at `index` inside the tapped list.
    init(
        favoritesStore: any FavoritesStoring,
        tagStore: any TagListStoring,
        recentViewsStore: any RecentViewsStoring,
        clearRecentViews: (() async -> Void)? = nil,
        isActive: Bool = true,
        imageQuality: ImageQuality = .auto,
        gridPreviewsEnabled: Bool = true,
        blacklistStore: (any TagListStoring)? = nil,
        onSelectTag: @escaping (String) -> Void = { _ in },
        onOpenPost: @escaping ([BooruPost], Int) -> Void = { _, _ in }
    ) {
        self.imageQuality = imageQuality
        self.gridPreviewsEnabled = gridPreviewsEnabled
        self.isActive = isActive
        self.blacklistStore = blacklistStore ?? TagListStore(directory: JSONFileStore.defaultDirectory(), kind: .blacklisted)
        self.onSelectTag = onSelectTag
        self.onOpenPost = onOpenPost
        _model = State(initialValue: FavoritesViewModel(
            favoritesStore: favoritesStore,
            tagStore: tagStore,
            recentViewsStore: recentViewsStore,
            clearRecentViews: clearRecentViews
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: segmentBinding) {
                ForEach(FavoritesViewModel.Segment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.top, 6)
            .padding(.bottom, AppTheme.Spacing.item)

            switch model.segment {
            case .savedPosts:
                savedPostsSection
            case .favoriteTags:
                favoriteTagsSection
            case .recentViews:
                recentViewsSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.segment) {
            await model.load()
            await loadBlacklist()
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            Task { await model.load() }
        }
        .confirmationDialog(
            "Clear History",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await model.clearRecentViews() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all recently viewed posts?")
        }
        .confirmationDialog(
            "Remove from favorites?",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let post = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.removeFavorite(post) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    // MARK: Saved posts

    private var savedPostsSection: some View {
        GeometryReader { geometry in
            let columnWidth = Self.columnWidth(for: geometry.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                    sourceFilterBar
                    if model.isLoading {
                        ProgressView()
                            .tint(AppTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if model.visibleFavorites.isEmpty {
                        emptyState(
                            systemImage: "heart",
                            title: model.sourceFilter == nil ? "No saved posts yet" : "Nothing from this source",
                            message: "Posts you save are collected here."
                        )
                    } else {
                        grid(
                            posts: model.visibleFavorites,
                            columnWidth: columnWidth,
                            onLongPress: { pendingRemoval = $0 }
                        )
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.bottom, 16)
            }
            .refreshable { await model.load() }
        }
    }

    private var sourceFilterBar: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            Menu {
                Button {
                    model.sourceFilter = nil
                } label: {
                    if model.sourceFilter == nil {
                        Label("All Sources", systemImage: "checkmark")
                    } else {
                        Text("All Sources")
                    }
                }
                ForEach(model.sourceCounts) { summary in
                    Button {
                        model.sourceFilter = summary.id
                    } label: {
                        if model.sourceFilter == summary.id {
                            Label("\(summary.name) (\(summary.count))", systemImage: "checkmark")
                        } else {
                            Text("\(summary.name) (\(summary.count))")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(model.selectedSourceName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(AppTheme.Typography.body.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.card, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                // The capsule keeps its compact paint (~28 pt) because the background is applied
                // first. The frame below is real layout, so the menu owns an honest 44 pt tap
                // target and nothing extends past its bounds into the first card.
                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Text("\(model.visibleFavorites.count)")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Favorite tags

    private var favoriteTagsSection: some View {
        List {
            Section {
                HStack(spacing: AppTheme.Spacing.item) {
                    TextField("Add a tag", text: $newTagText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(submitNewTag)
                        .foregroundStyle(AppTheme.textPrimary)
                    Button("Add", action: submitNewTag)
                        .font(AppTheme.Typography.body.weight(.semibold))
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Favorite Tags (\(model.favoriteTags.count))") {
                if model.favoriteTags.isEmpty {
                    Text("No favorite tags yet")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(model.favoriteTags, id: \.self) { tag in
                        HStack(spacing: AppTheme.Spacing.item) {
                            TagChipView(text: tag, onTap: { onSelectTag(tag) })
                                .contextMenu { tagContextMenu(for: tag) }
                            Spacer(minLength: 0)
                            Button {
                                Task { await model.removeFavoriteTag(tag) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: AppTheme.Icon.small))
                                    .foregroundStyle(AppTheme.danger)
                                    // A real 44 pt frame, not padding: the tap target is fully
                                    // allocated inside the row.
                                    .frame(
                                        minWidth: AppTheme.Spacing.minimumHitTarget,
                                        minHeight: AppTheme.Spacing.minimumHitTarget
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag)")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .refreshable { await model.load() }
    }

    private func submitNewTag() {
        let tag = newTagText
        guard !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newTagText = ""
        Task { await model.addFavoriteTag(tag) }
    }

    // MARK: Recent views

    private var recentViewsSection: some View {
        GeometryReader { geometry in
            let columnWidth = Self.columnWidth(for: geometry.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                    HStack(spacing: AppTheme.Spacing.item) {
                        Text("\(model.recentViews.count) posts")
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            isConfirmingClear = true
                        } label: {
                            Label("Clear", systemImage: "trash")
                                .font(AppTheme.Typography.body.weight(.semibold))
                                // Real layout height instead of padding handback: the button owns a
                                // 44 pt tap target and nothing bleeds outside the header row.
                                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                                .contentShape(Rectangle())
                        }
                        .disabled(model.recentViews.isEmpty)
                        .accessibilityLabel("Clear recent views")
                    }

                    if model.isLoading {
                        ProgressView()
                            .tint(AppTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if model.recentViews.isEmpty {
                        emptyState(
                            systemImage: "clock.arrow.circlepath",
                            title: "No recent views",
                            message: "Posts you open appear here."
                        )
                    } else {
                        grid(posts: model.recentViews, columnWidth: columnWidth, onLongPress: nil)
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.bottom, 16)
            }
            .refreshable { await model.load() }
        }
    }

    // MARK: Shared pieces

    /// Two height-balanced columns (same `MasonryColumns` pass as `FeedScreen`).
    private func grid(
        posts: [BooruPost],
        columnWidth: CGFloat,
        onLongPress: ((BooruPost) -> Void)?
    ) -> some View {
        var masonry = MasonryColumns()
        let columns = masonry.layout(posts) { post in
            MasonryColumns.estimatedHeight(for: post, columnWidth: columnWidth)
        }
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: Self.columnSpacing) {
                    ForEach(columns[index]) { post in
                        card(for: post, in: posts, onLongPress: onLongPress)
                    }
                }
                .frame(width: columnWidth > 0 ? columnWidth : nil, alignment: .top)
            }
        }
    }

    private func card(
        for post: BooruPost,
        in posts: [BooruPost],
        onLongPress: ((BooruPost) -> Void)?
    ) -> some View {
        let longPress: (() -> Void)? = onLongPress.map { handler in { handler(post) } }
        return PostCardView(
            post: post,
            imageQuality: imageQuality,
            gridPreviewsEnabled: gridPreviewsEnabled,
            isFavorite: model.isFavorite(post),
            onTap: { onOpenPost(posts, posts.firstIndex(of: post) ?? 0) },
            onLongPress: longPress
        )
    }

    /// Equal column width that fits the measured grid exactly.
    private static func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let usable = totalWidth - horizontalPadding * 2 - columnSpacing
        guard usable > 0 else { return 0 }
        return (usable / CGFloat(MasonryColumns.defaultColumnCount)).rounded(.down)
    }

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.top, 40)
    }

    // MARK: Tag context menu

    /// Mirrors `TagListStore.favorite` normalization (trim/collapse/lowercase).
    private static func pinnedKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Mirrors `TagListStore.blacklisted` normalization (whitespace → `_`).
    private static func blacklistKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_").lowercased()
    }

    private func isPinned(_ tag: String) -> Bool {
        let key = Self.pinnedKey(tag)
        return model.favoriteTags.contains { Self.pinnedKey($0) == key }
    }

    private func loadBlacklist() async {
        guard let blacklistStore else { return }
        let tags = (try? await blacklistStore.list()) ?? []
        blacklistedTagKeys = Set(tags.map(Self.blacklistKey))
    }

    private func togglePinnedTag(_ tag: String) async {
        if isPinned(tag) {
            await model.removeFavoriteTag(tag)
        } else {
            await model.addFavoriteTag(tag)
        }
    }

    private func toggleBlacklistedTag(_ tag: String) async {
        guard let blacklistStore else { return }
        let key = Self.blacklistKey(tag)
        if blacklistedTagKeys.contains(key) {
            try? await blacklistStore.remove(key)
        } else {
            try? await blacklistStore.add(key)
        }
        await loadBlacklist()
    }

    /// Tag actions available from any chip: search, add, exclude, pin, blacklist, copy.
    @ViewBuilder
    private func tagContextMenu(for tag: String) -> some View {
        Button {
            onSelectTag(tag)
        } label: {
            Label("Search Tag", systemImage: "magnifyingglass")
        }
        Button {
            onSelectTag("+" + tag)
        } label: {
            Label("Add +\(tag)", systemImage: "plus.circle")
        }
        Button {
            onSelectTag("-" + tag)
        } label: {
            Label("Exclude -\(tag)", systemImage: "minus.circle")
        }
        Button {
            Task { await togglePinnedTag(tag) }
        } label: {
            Label(
                isPinned(tag) ? "Unpin Favorite Tag" : "Pin to Favorite Tags",
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

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
        )
    }

    private var segmentBinding: Binding<FavoritesViewModel.Segment> {
        Binding(
            get: { model.segment },
            set: { model.segment = $0 }
        )
    }
}
