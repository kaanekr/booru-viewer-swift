import SwiftUI
import Foundation
import UIKit

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
    /// Live mirror of the visible page's zoom so the viewer's own drags stand down
    /// while the media pan gesture owns the touch.
    @State private var isMediaZoomed = false

    /// True physical device safe-area insets read outside the safe-area crop so
    /// images and manga stay full-bleed while video stays inset below app chrome
    /// and above the home indicator.
    @State private var screenSafeInsets = SafeInsets()
    /// Measured height of the floating top Liquid Glass bar.
    @State private var topChromeHeight: CGFloat = 56

    private struct SafeInsets: Equatable, Sendable {
        var top: CGFloat = 0
        var leading: CGFloat = 0
        var bottom: CGFloat = 0
        var trailing: CGFloat = 0

        init() {}

        init(_ insets: EdgeInsets) {
            top = insets.top
            leading = insets.leading
            bottom = insets.bottom
            trailing = insets.trailing
        }
    }

    private var isCurrentPostVideo: Bool {
        guard let post = viewModel.currentPost else { return false }
        let isManga = viewModel.isMangaMode && viewModel.galleryPages(for: post).count > 1
        return !isManga && viewModel.media(for: post)?.videoURL != nil
    }

    /// Video pages keep the top app bar visible (outside the player bounds) because
    /// single taps on video belong to `AVPlayerViewController`; images and manga
    /// toggle chrome visibility on single tap.
    private var isChromeVisible: Bool {
        isCurrentPostVideo || showControls
    }

    private var videoPlayerInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: screenSafeInsets.top + topChromeHeight,
            left: screenSafeInsets.leading,
            bottom: screenSafeInsets.bottom,
            right: screenSafeInsets.trailing
        )
    }

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
            // Non-interactive full-bleed probe measures the true device safe area
            // while keeping `topBarOverlay` itself constrained inside safe area.
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .onGeometryChange(for: SafeInsets.self) { proxy in
                    SafeInsets(proxy.safeAreaInsets)
                } action: { insets in
                    screenSafeInsets = insets
                }

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
                        videoSafeAreaInsets: videoPlayerInsets,
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
            // paging; disabled on active video via `isEnabled:` (without affecting
            // subview native `AVPlayerViewController` gestures).
            .simultaneousGesture(
                verticalDismissGesture,
                isEnabled: !isCurrentPostVideo
            )

            edgeDismissStrip

            topBarOverlay

            toastOverlay
        }
        .statusBarHidden(!isChromeVisible)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .onChange(of: vm.currentIndex) { _, _ in
            resetPagerGestures()
        }
        .onChange(of: isMediaZoomed) { _, zoomed in
            if zoomed { resetVerticalDrag() }
        }
        .onChange(of: isCurrentPostVideo) { _, isVideo in
            if isVideo {
                resetVerticalDrag()
                isEdgeDrag = false
            }
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
        if viewModel.currentIndex == 0, !isMediaZoomed, !isCurrentPostVideo {
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
    /// the drag), inside the multi-page reader (whose scroll view owns vertical drags),
    /// and on active video pages (`AVPlayerViewController` owns vertical interactions).
    private var isVerticalDismissSuspended: Bool {
        isMediaZoomed || viewModel.isMangaMode || isCurrentPostVideo
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

    // MARK: Native Liquid Glass Top Bar Chrome

    /// All app actions live in a single native iOS 26 Liquid Glass top bar inside
    /// the top safe area. On video pages, `NativeVideoPlayerView` is inset below this
    /// bar so player transport and top AVKit controls are never overlapped; images
    /// and manga remain full-bleed underneath. Exactly one info button exists.
    private var topBarOverlay: some View {
        VStack(spacing: 0) {
            if isChromeVisible {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if height > 0 {
                            topChromeHeight = height
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                glassCircleButton(
                    system: "xmark",
                    tint: AppTheme.textPrimary
                ) {
                    onClose()
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("viewer.closeButton")

                if let post = viewModel.currentPost, !viewModel.episodes(for: post).isEmpty {
                    episodeMenu(for: post)
                } else if viewModel.canShowMangaMode {
                    mangaModeButton
                }

                Spacer(minLength: 4)

                badge

                Spacer(minLength: 4)

                if let post = viewModel.currentPost {
                    let isFavorite = viewModel.isFavorite(post)
                    glassCircleButton(
                        system: isFavorite ? "heart.fill" : "heart",
                        tint: isFavorite ? AppTheme.danger : AppTheme.textPrimary
                    ) {
                        Task { await viewModel.toggleFavorite() }
                    }
                    .disabled(viewModel.savingFavorite)
                    .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")
                    .accessibilityIdentifier("viewer.favoriteButton")
                }

                glassCircleButton(
                    system: "info.circle",
                    tint: showInfo ? AppTheme.primary : AppTheme.textPrimary
                ) {
                    showInfo = true
                }
                .accessibilityLabel("Post info")
                .accessibilityIdentifier("viewer.infoButton")
            }
        }
    }

    private func glassCircleButton(
        system: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: AppTheme.Icon.small + 2, weight: .semibold))
                .foregroundStyle(tint)
                .frame(
                    minWidth: AppTheme.Spacing.minimumHitTarget,
                    minHeight: AppTheme.Spacing.minimumHitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private var badge: some View {
        VStack(spacing: 0) {
            Text(viewModel.currentPost?.sourceName ?? "Booru")
                .font(AppTheme.Typography.secondary.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text("\(viewModel.currentIndex + 1) / \(viewModel.posts.count)")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }

    private var mangaModeButton: some View {
        glassCircleButton(
            system: viewModel.isMangaMode ? "book.fill" : "book",
            tint: viewModel.isMangaMode ? AppTheme.primary : AppTheme.textPrimary
        ) {
            viewModel.isMangaMode.toggle()
        }
        .accessibilityLabel(viewModel.isMangaMode ? "Exit manga mode" : "Manga mode")
        .accessibilityIdentifier("viewer.mangaModeButton")
    }

    // MARK: HentaiHaven episode selector

    /// Native menu for HentaiHaven series episodes, hosted in the top glass bar
    /// outside the video player surface and transport controls.
    private func episodeMenu(for post: BooruPost) -> some View {
        let episodes = viewModel.episodes(for: post)
        let selected = viewModel.selectedEpisode(for: post)
        let labelText = selected.map { "Ep \($0.number)" } ?? "Episodes"

        return Menu {
            ForEach(episodes) { episode in
                Button {
                    viewModel.selectEpisode(episode, for: post)
                } label: {
                    if episode.id == selected?.id {
                        Label("Episode \(episode.number)", systemImage: "checkmark")
                    } else {
                        Text("Episode \(episode.number)")
                    }
                }
                .accessibilityIdentifier("viewer.episodeOption.\(episode.number)")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .font(.system(size: 13, weight: .semibold))
                Text(labelText)
                    .font(AppTheme.Typography.caption)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(
                minWidth: AppTheme.Spacing.minimumHitTarget,
                minHeight: AppTheme.Spacing.minimumHitTarget
            )
            .contentShape(Capsule())
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Episodes")
        .accessibilityIdentifier("viewer.episodeButton")
    }

    private var toastOverlay: some View {
        VStack(spacing: 0) {
            if let message = viewModel.toastMessage {
                Text(message)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(AppTheme.primary), in: Capsule())
                    .padding(.top, topChromeHeight + 8)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
    }
}
