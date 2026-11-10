import SwiftUI
import Foundation

/// Full-screen paged media viewer, pushed from the Explore / Search / Favorites
/// grids. Mirrors RN `ViewerScreen` + `ImageViewerModal` as a stack screen
/// (src/screens/ViewerScreen.tsx, src/components/ImageViewerModal.tsx).
@MainActor
struct ViewerScreen: View {
    let onSelectTag: (String) -> Void
    let onClose: () -> Void

    /// Search history used by the info sheet's "Save to History" action.
    private let searchHistory: (any SearchHistoryStoring)?
    /// Query modifier used by the info sheet's search actions.
    private let onModifySearch: (@Sendable (TagSearchModification) -> Void)?

    @State private var viewModel: ViewerViewModel
    @State private var showControls = true
    @State private var showInfo = false

    /// Live vertical offset of the media while a swipe is in flight, so the
    /// dismiss / info-sheet drag feels attached to the finger
    /// (ImageViewerModal.tsx:1331-1372).
    @State private var verticalDragOffset: CGFloat = 0
    /// Set once a drag has been classified as clearly vertical; horizontal drags
    /// then stay with the paged `TabView`.
    @State private var isVerticalDrag = false
    /// Latched when a left-edge drag turns out to be decisively horizontal, so the
    /// release handling knows the strip claimed the touch
    /// (ImageViewerModal.tsx:288-324).
    @State private var isEdgeDrag = false
    /// Mirrors the visible page's zoom so the viewer's own drags stand down while
    /// the media pan gesture owns the touch.
    @State private var isMediaZoomed = false

    init(
        posts: [BooruPost],
        initialIndex: Int = 0,
        context: SourceContext,
        recentViews: (any RecentViewsStoring)? = nil,
        favorites: (any FavoritesStoring)? = nil,
        favoriteTags: (any TagListStoring)? = nil,
        blacklistedTags: (any TagListStoring)? = nil,
        searchHistory: (any SearchHistoryStoring)? = nil,
        hentaiHavenLastEpisodes: [String: Int] = [:],
        onSaveHentaiHavenEpisode: (@Sendable (String, Int) -> Void)? = nil,
        onModifySearch: (@Sendable (TagSearchModification) -> Void)? = nil,
        onSelectTag: @escaping (String) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.onSelectTag = onSelectTag
        self.onClose = onClose
        self.searchHistory = searchHistory
        self.onModifySearch = onModifySearch
        _viewModel = State(initialValue: ViewerViewModel(
            posts: posts,
            initialIndex: initialIndex,
            context: context,
            recentViews: recentViews,
            favorites: favorites,
            favoriteTags: favoriteTags,
            blacklistedTags: blacklistedTags,
            searchHistory: searchHistory,
            hentaiHavenLastEpisodes: hentaiHavenLastEpisodes,
            onSaveHentaiHavenEpisode: onSaveHentaiHavenEpisode,
            onModifySearch: onModifySearch
        ))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        let vm = viewModel

        ZStack {
            // The backdrop is always the opaque theme background and never moves:
            // the viewer is presented in a `fullScreenCover`, so there is nothing
            // behind it and following the finger would expose a black band
            // (ImageViewerModal.tsx:284-287).
            AppTheme.background.ignoresSafeArea()

            TabView(selection: $viewModel.currentIndex) {
                ForEach(viewModel.posts.indices, id: \.self) { index in
                    let post = viewModel.posts[index]

                    ZoomableMediaView(
                        post: post,
                        media: viewModel.media(for: post),
                        isLoading: viewModel.isLoading(post),
                        isActive: index == viewModel.currentIndex,
                        isMangaMode: viewModel.isMangaMode && index == viewModel.currentIndex,
                        galleryPages: viewModel.galleryPages(for: post),
                        showsControls: showControls,
                        onSingleTap: { toggleControls() },
                        onZoomChanged: { zoomed in isMediaZoomed = zoomed }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            // Only the media content follows the vertical drag; the backdrop above
            // stays put so a pull-down can never reveal an empty (black) band.
            .offset(y: verticalDragOffset)
            .opacity(mediaOpacity)
            // Simultaneous so the `.page` `TabView` keeps its own horizontal
            // paging; the drag only acts after deciding it owns the touch
            // (dominant axis beyond the ratio below).
            .simultaneousGesture(verticalDismissGesture)

            edgeDismissStrip

            overlays
        }
        .statusBarHidden(!showControls)
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onChange(of: vm.currentIndex) { _, _ in
            resetPagerGestures()
        }
        .onChange(of: isMediaZoomed) { _, zoomed in
            if zoomed { resetVerticalDrag() }
        }
        .task(id: vm.currentIndex) { [vm] in
            await vm.prepareCurrentPage()
        }
        .task { [vm] in
            await vm.loadTagLists()
        }
        .onAppear {
            if viewModel.posts.isEmpty {
                onClose()
            }
        }
        .sheet(isPresented: $showInfo) {
            if let post = viewModel.currentPost {
                PostInfoSheetView(
                    post: post,
                    viewModel: viewModel,
                    searchHistory: searchHistory,
                    onModifySearch: onModifySearch,
                    hentaiHavenLastEpisodes: viewModel.hentaiHavenLastEpisodes,
                    onSaveHentaiHavenEpisode: viewModel.onSaveHentaiHavenEpisode
                ) { tag in
                    showInfo = false
                    onSelectTag(tag)
                }
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: Dismiss gestures

    /// Swipe down closes the viewer, swipe up opens the info sheet
    /// (ImageViewerModal.tsx:1331-1372, PostPageItem scroll handler).
    ///
    /// It is attached simultaneously with the paged `TabView` and only claims a
    /// drag that is decisively vertical (`abs(dy) > abs(dx) * 1.5`), so a
    /// diagonal swipe that drops a few points before travelling sideways stays
    /// with the pager. The release re-checks that dominance, so a latched
    /// vertical drag that turns horizontal springs back instead of closing.
    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: Self.verticalMinimumDistance)
            .onChanged { value in
                guard !isVerticalDismissSuspended else { return }
                let translation = value.translation
                if !isVerticalDrag {
                    guard abs(translation.height) > abs(translation.width) * Self.verticalAxisRatio else {
                        return
                    }
                    isVerticalDrag = true
                }
                verticalDragOffset = translation.height
            }
            .onEnded { value in
                guard isVerticalDrag else { return }
                isVerticalDrag = false
                guard !isVerticalDismissSuspended else {
                    resetVerticalDrag()
                    return
                }
                let dy = value.translation.height
                let isDominantlyVertical = abs(dy) > abs(value.translation.width)
                if isDominantlyVertical, dy > Self.swipeDownThreshold {
                    resetVerticalDrag()
                    onClose()
                } else if isDominantlyVertical, dy < -Self.swipeUpThreshold {
                    resetVerticalDrag(animated: true)
                    showInfo = true
                } else {
                    resetVerticalDrag(animated: true)
                }
            }
    }

    /// Claiming left-edge back strip (ImageViewerModal.tsx:432-437, 2512-2521).
    ///
    /// RN uses an overlay that owns the touch instead of a simultaneous gesture,
    /// so the pager never sees the same drag. It is inset past the top bar and
    /// the bottom ~150 pt video timeline area, and only exists on the first page,
    /// where there is nothing to page back to. Nothing follows the finger: the
    /// backdrop cannot move (see `body`), so dismissal is decided on release.
    @ViewBuilder
    private var edgeDismissStrip: some View {
        if viewModel.currentIndex == 0, !isMediaZoomed {
            Color.clear
                .frame(width: Self.edgeStripWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .padding(.top, Self.edgeStripTopInset)
                .padding(.bottom, Self.edgeStripBottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The strip owns the touches it covers (the pager underneath is
                // never hit), so vertical dismissal has to be re-attached here or a
                // pull-down starting in the left strip would be lost.
                .gesture(edgeDismissGesture.simultaneously(with: verticalDismissGesture))
        }
    }

    /// Left-edge pan to dismiss (ImageViewerModal.tsx:288-324). Only a drag that
    /// is decisively horizontal claims the touch — mirroring RN's
    /// `onMoveShouldSetPanResponder` — and only a long, flat release dismisses.
    private var edgeDismissGesture: some Gesture {
        DragGesture(minimumDistance: Self.edgeMoveThreshold)
            .onChanged { value in
                guard !isMediaZoomed else { return }
                guard !isEdgeDrag else { return }
                let translation = value.translation
                guard translation.width > 0,
                      abs(translation.width) > abs(translation.height) else { return }
                isEdgeDrag = true
            }
            .onEnded { value in
                guard isEdgeDrag else { return }
                isEdgeDrag = false
                guard !isMediaZoomed else { return }
                let translation = value.translation
                let shouldDismiss = translation.width > Self.edgeDismissThreshold
                    && abs(translation.height) < Self.edgeMaximumVerticalDrift
                if shouldDismiss {
                    onClose()
                }
            }
    }

    /// Vertical dismissal is suspended while the page is zoomed (the media pan owns
    /// the drag) and inside the multi-page reader, whose scroll view owns vertical
    /// drags (ImageViewerModal.tsx:1345).
    private var isVerticalDismissSuspended: Bool {
        isMediaZoomed || viewModel.isMangaMode
    }

    /// Fades the media as it is pulled off screen, like RN's dismiss transition.
    private var mediaOpacity: Double {
        guard verticalDragOffset > 0 else { return 1 }
        return Double(max(0.4, 1 - verticalDragOffset / 320))
    }

    private static let swipeDownThreshold: CGFloat = 80
    private static let swipeUpThreshold: CGFloat = 70
    /// The vertical drag must clear this distance before it is classified at all.
    private static let verticalMinimumDistance: CGFloat = 24
    /// Vertical dominates only past this factor, so a diagonal swipe that drops a
    /// little before travelling sideways is never latched as a dismissal.
    private static let verticalAxisRatio: CGFloat = 1.5
    private static let edgeStripWidth: CGFloat = 24
    /// RN inset: the top bar area and the bottom video-timeline strip
    /// (ImageViewerModal.tsx:2512-2521).
    private static let edgeStripTopInset: CGFloat = 75
    private static let edgeStripBottomInset: CGFloat = 150
    private static let edgeMoveThreshold: CGFloat = 10
    private static let edgeDismissThreshold: CGFloat = 80
    /// RN requires a flat swipe: `abs(dy) < 35` (ImageViewerModal.tsx:292-293, 300).
    private static let edgeMaximumVerticalDrift: CGFloat = 35
    private static let springBack = Animation.spring(response: 0.32, dampingFraction: 0.86)

    private func resetVerticalDrag(animated: Bool = false) {
        isVerticalDrag = false
        guard animated else {
            verticalDragOffset = 0
            return
        }
        withAnimation(Self.springBack) {
            verticalDragOffset = 0
        }
    }

    private func resetPagerGestures() {
        isMediaZoomed = false
        isVerticalDrag = false
        isEdgeDrag = false
        verticalDragOffset = 0
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack(alignment: .top) {
            VStack {
                if showControls {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    episodeSelectorBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if showControls {
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            toast
        }
    }

    /// The only info control in the viewer chrome: `bottomBar` keeps just the
    /// manga and favorite actions, so exactly one actionable info button is
    /// visible at a time (`showControls` gates the whole chrome).
    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton(system: "xmark") { onClose() }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("viewer.closeButton")

            Spacer(minLength: 0)

            badge

            Spacer(minLength: 0)

            circleButton(
                system: "info.circle",
                tint: showInfo ? AppTheme.primary : AppTheme.textPrimary
            ) {
                showInfo = true
            }
            .accessibilityLabel("Post info")
            .accessibilityIdentifier("viewer.infoButton")
        }
    }

    private var badge: some View {
        VStack(spacing: 1) {
            Text(viewModel.currentPost?.sourceName ?? "Booru")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(viewModel.currentIndex + 1) / \(viewModel.posts.count)")
                .font(.caption2)
        }
        .foregroundStyle(AppTheme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppTheme.surface.opacity(0.9), in: Capsule())
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if viewModel.canShowMangaMode {
                circleButton(
                    system: viewModel.isMangaMode ? "book.fill" : "book",
                    tint: viewModel.isMangaMode ? AppTheme.primary : AppTheme.textPrimary
                ) {
                    viewModel.isMangaMode.toggle()
                }
                .accessibilityLabel(viewModel.isMangaMode ? "Exit manga mode" : "Manga mode")
            }

            Spacer(minLength: 0)

            if let post = viewModel.currentPost {
                let isFavorite = viewModel.isFavorite(post)
                // No info button here: the top bar owns the single info control.
                circleButton(
                    system: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? AppTheme.danger : AppTheme.textPrimary
                ) {
                    Task { await viewModel.toggleFavorite() }
                }
                .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")
                .disabled(viewModel.savingFavorite)
            }
        }
    }

    // MARK: HentaiHaven episode selector

    /// Horizontal episode chips shown under the top bar for HentaiHaven series
    /// posts; tapping one switches the stream immediately.
    @ViewBuilder
    private var episodeSelectorBar: some View {
        if let post = viewModel.currentPost {
            let episodes = viewModel.episodes(for: post)
            if !episodes.isEmpty {
                let selectedID = viewModel.selectedEpisode(for: post)?.id
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(episodes) { episode in
                            let isSelected = episode.id == selectedID
                            Button {
                                viewModel.selectEpisode(episode, for: post)
                            } label: {
                                Text("Ep \(episode.number)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? AppTheme.primary : AppTheme.surface.opacity(0.9),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(
                                            isSelected ? AppTheme.primary : AppTheme.border,
                                            lineWidth: 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toast: some View {
        Group {
            if let message = viewModel.toastMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.primary, lineWidth: 1))
                    .padding(.top, 64)
            }
        }
    }

    // MARK: Controls

    private func circleButton(
        system: String,
        tint: Color = AppTheme.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(AppTheme.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
    }
}
