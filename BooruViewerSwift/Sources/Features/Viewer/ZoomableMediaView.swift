import SwiftUI
import Foundation
import UIKit

/// One page of the full-screen viewer: an image with pinch / double-tap zoom, a
/// native `AVPlayerViewController` video player, or a multi-page gallery/manga reader.
///
/// Mirrors the per-page behaviour of RN `PostPageItem`
/// (src/components/ImageViewerModal.tsx:800-1990): pinch and double-tap zoom for
/// images, native `AVKit` playback for videos, and a multi-page reader when the
/// post carries gallery pages.
struct ZoomableMediaView: View {
    let post: BooruPost
    let media: ResolvedMedia?
    var isLoading = false
    var isActive = true
    var isMangaMode = false
    var galleryPages: [URL] = []
    /// Safe-area + top-toolbar insets applied only to the native video container so
    /// images and manga stay full-bleed while video never slides under app chrome.
    var videoSafeAreaInsets: UIEdgeInsets = .zero
    /// Single tap on non-video media toggles the viewer controls (RN `handleToggleControls`).
    var onSingleTap: (() -> Void)?
    /// Reports pinch / double-tap zoom so the viewer can stand down its own
    /// dismissal drags while the media pan owns the touch.
    var onZoomChanged: ((Bool) -> Void)?

    var body: some View {
        Group {
            if isMangaMode, galleryPages.count > 1 {
                PrivateMangaReaderView(
                    pages: galleryPages,
                    aspectRatioFallback: post.aspectRatio,
                    onSingleTap: onSingleTap,
                    onZoomChanged: onZoomChanged
                )
            } else if let videoURL = media?.videoURL {
                NativeVideoPlayerView(
                    url: videoURL,
                    isActive: isActive,
                    contentInsets: videoSafeAreaInsets
                )
                .clipped()
            } else {
                imagePage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: zoomScale) { _, scale in
            onZoomChanged?(scale > Self.zoomEpsilon)
        }
        // RN resets the previous page's zoom once it stops being the visible one
        // (ImageViewerModal.tsx:1300-1328).
        .onChange(of: isActive) { _, active in
            if !active { resetZoom() }
        }
    }

    // MARK: Image page (pinch + double-tap zoom)

    private var imagePage: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let nhentaiCover = post.sourceID == .nhentai ? (post.sampleURL ?? post.previewURL) : nil
            let imageChain = [media?.imageURL, media?.placeholderURL, nhentaiCover].compactMap { $0 }

            ZStack {
                Color.black

                if imageChain.isEmpty {
                    unavailable
                } else {
                    PrivateViewerImage(urls: imageChain)
                        .frame(width: size.width, height: size.height)
                }

                if isLoading {
                    ProgressView()
                        .tint(AppTheme.textPrimary)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(zoomScale, anchor: zoomAnchor)
            .offset(zoomOffset)
            .contentShape(Rectangle())
            .gesture(magnificationGesture)
            .simultaneousGesture(panGesture(size: size), including: zoomScale > Self.zoomEpsilon ? .all : .none)
            .gesture(tapGesture(size: size))
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text("Media unavailable")
                .font(.footnote)
        }
        .foregroundStyle(AppTheme.textSecondary)
    }

    // MARK: Zoom state

    @State private var zoomScale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Anchor of the double-tap zoom: the tapped point, in view-unit coordinates
    /// (RN zooms onto the tap location, ImageViewerModal.tsx:1408-1422).
    @State private var zoomAnchor: UnitPoint = .center

    private static let zoomEpsilon: CGFloat = 1.01
    private static let doubleTapScale: CGFloat = 2.5

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomScale = min(max(1, lastScale * value.magnification), 4)
            }
            .onEnded { _ in
                lastScale = zoomScale
                if zoomScale <= Self.zoomEpsilon {
                    resetZoom()
                }
            }
    }

    /// Only pans while zoomed in: the gesture is masked out at 1x so horizontal
    /// drags pass straight through to the paged `TabView`.
    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > Self.zoomEpsilon else { return }
                let moved = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                zoomOffset = clampZoomOffset(moved, scale: zoomScale, anchor: zoomAnchor, size: size)
            }
            .onEnded { _ in
                if zoomScale > Self.zoomEpsilon {
                    lastOffset = zoomOffset
                } else {
                    resetZoom()
                }
            }
    }

    /// Double tap zooms onto the tapped point, a single tap toggles the controls.
    /// `exclusively` keeps the double tap from also firing the single-tap handler.
    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                handleDoubleTap(at: value.location, in: size)
            }
            .exclusively(
                before: TapGesture(count: 1).onEnded { _ in
                    guard let onSingleTap = onSingleTap else { return }
                    onSingleTap()
                }
            )
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoomScale > Self.zoomEpsilon {
                resetZoom()
            } else {
                zoomAnchor = unitPoint(for: location, in: size)
                zoomScale = Self.doubleTapScale
                lastScale = Self.doubleTapScale
                zoomOffset = .zero
                lastOffset = .zero
            }
        }
    }

    /// Tap location → `UnitPoint` anchor, clamped to the view bounds.
    private func unitPoint(for location: CGPoint, in size: CGSize) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(
            x: min(max(location.x / size.width, 0), 1),
            y: min(max(location.y / size.height, 0), 1)
        )
    }

    private func resetZoom() {
        zoomScale = 1
        lastScale = 1
        zoomOffset = .zero
        lastOffset = .zero
        zoomAnchor = .center
    }
}

// MARK: - Loader-backed viewer image

/// Full-resolution viewer image and manga page loaded through `MediaImageLoader`,
/// so the request carries the per-host `Referer`/`User-Agent` headers and retries
/// through the Cloudflare Worker relay (`ProxyRelay`) for TLS-fragile CDNs — the
/// same route the feed covers get from `AsyncMediaImage`. Plain `AsyncImage` cannot
/// express either, which left the full-screen image and every nhentai page bare.
private struct PrivateViewerImage: View {
    let urls: [URL]
    var failureText = "Media unavailable"
    /// Set by the manga reader for a page URL that already decoded once: the reload is a
    /// cache fast path, so it runs without flashing the spinner (which would otherwise
    /// blink every time a page scrolls back into the reader's rendered window).
    var isKnownLoaded = false
    /// Reported after a successful decode so the reader can mark the URL as loaded.
    var onLoaded: ((URL) -> Void)? = nil

    @State private var image: UIImage?
    @State private var didFail = false
    /// URLs whose image is already applied, so a parent re-render never re-runs
    /// the task (or flashes the spinner) for a decoded page.
    @State private var loadedURLs: [URL]?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(failureText)
                        .font(.footnote)
                }
                .foregroundStyle(AppTheme.textSecondary)
            } else if isKnownLoaded {
                // A page this reader session already decoded once: the URL is in the image
                // cache, so hold the reserved slot empty for the cache hop instead of
                // flashing a spinner every time the page scrolls back into view.
                Color.clear
            } else {
                ProgressView()
                    .tint(AppTheme.textPrimary)
            }
        }
        .task(id: urls) { await load() }
    }

    /// Walks the chain until one URL decodes; a cached image is applied without a
    /// visible placeholder frame. The loader already retried the other route leg.
    /// An already-loaded image is kept across view updates, so re-rendering the
    /// page never flashes the spinner.
    private func load() async {
        guard loadedURLs != urls else { return }
        guard !urls.isEmpty else {
            image = nil
            didFail = true
            return
        }

        // Fast path: check cache for all candidates first without clearing image.
        for url in urls {
            if Task.isCancelled { return }
            if let cached = await MediaImageLoader.shared.cachedImage(for: url) {
                if Task.isCancelled { return }
                image = cached
                loadedURLs = urls
                didFail = false
                onLoaded?(url)
                return
            }
        }

        didFail = false
        for url in urls {
            if Task.isCancelled { return }
            do {
                let loaded = try await MediaImageLoader.shared.image(for: url)
                if Task.isCancelled { return }
                image = loaded
                loadedURLs = urls
                onLoaded?(url)
                return
            } catch {
                continue
            }
        }
        image = nil
        didFail = true
    }
}

// MARK: - Anchored zoom maths

/// Clamps a pan offset so a view scaled with `scaleEffect(_:anchor:)` never shows
/// the frame behind it. Scaling about `anchor` already overhangs the frame by
/// `anchor * size * (scale - 1)` on one side and `(1 - anchor) * size * (scale - 1)`
/// on the other, and the offset may only travel that far.
private func clampZoomOffset(
    _ offset: CGSize,
    scale: CGFloat,
    anchor: UnitPoint,
    size: CGSize
) -> CGSize {
    guard scale > 1, size.width > 0, size.height > 0 else { return .zero }
    let maxX = anchor.x * (scale - 1) * size.width
    let minX = -(1 - anchor.x) * (scale - 1) * size.width
    let maxY = anchor.y * (scale - 1) * size.height
    let minY = -(1 - anchor.y) * (scale - 1) * size.height
    return CGSize(
        width: min(max(offset.width, minX), maxX),
        height: min(max(offset.height, minY), maxY)
    )
}

// MARK: - Multi-page gallery / manga reader

/// Vertical reader for multi-page posts (nhentai / manga), with a page indicator
/// (RN `mangaPages` reader, ImageViewerModal.tsx:804-1620). Double tap zooms 2.2x
/// onto the tapped point and a second double tap returns to 1x without losing the
/// current page (RN `handleMangaDoubleTap`, ImageViewerModal.tsx:1439-1490).
///
/// Geometry strategy — fixed slots, independent of image state:
/// 1. `MangaPageLayout` turns the page list plus a frozen per-page ratio snapshot into
///    one finite `width` *and* `height` per page, plus that page's content `originY` and
///    the gallery's exact `totalHeight`. This runs on the first layout pass, from source
///    metadata only, so the content extent exists before any page image does.
/// 2. Each slot renders at exactly that size (a lightweight empty shell until its image
///    is wanted), so no child ever contributes an intrinsic height the scroll view could
///    discover later; the container also states the total explicitly. An image loading
///    therefore cannot change the content extent or shift the current page.
/// 3. Downloads stay bounded: `PrivateViewerImage` is mounted only for the window around
///    the tracked page (one viewport of overscan above, two below), and at most a few
///    pages past that window are prefetched. A fling can still reach every page, because
///    reachability comes from the reserved extent rather than from mounted views.
/// 4. A width / orientation change re-derives the slots (legitimately) and re-anchors on
///    the tracked page index, so the reader keeps its place instead of its raw offset.
private struct PrivateMangaReaderView: View {
    let pages: [URL]
    /// Post-level aspect ratio used when a page has no cached/source ratio.
    var aspectRatioFallback: Double?
    var onSingleTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    /// Snapshot of the ratio each page reserves, taken once when the reader first lays
    /// out (and again only when the page list itself changes). Reading
    /// `MediaAspectRatioCache` in the body instead would resize a page the moment its
    /// image decoded, which shifts the current page and changes the total extent.
    @State private var reservedRatios: [Double?]
    /// Page whose reserved slot sits under the top of the viewport. It drives both the
    /// `n / total` indicator and the bounded render window, so the reader re-renders only
    /// when the page changes — never once per scroll frame — and the window never feeds
    /// back into the reserved geometry.
    @State private var trackedPageIndex = 0
    /// Page URLs already decoded in this reader session, so a page that scrolls back
    /// into the window resolves from cache without flashing a spinner.
    @State private var decodedURLs: Set<URL> = []

    @State private var zoomScale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var zoomAnchor: UnitPoint = .center

    private static let zoomEpsilon: CGFloat = 1.01
    /// RN `tapZoom` for the manga reader (ImageViewerModal.tsx:1469).
    private static let doubleTapScale: CGFloat = 2.2
    /// Vertical gap between two reserved page slots. Pages are contiguous, like the RN
    /// manga reader.
    private static let pageGap: CGFloat = 0
    /// Extra viewport heights rendered above / below the visible band. The window is
    /// biased forward because a fling travels downward, so the next pages are usually
    /// already mounted when they arrive on screen.
    private static let overscanScreensBefore: CGFloat = 1
    private static let overscanScreensAfter: CGFloat = 2
    /// Pages prefetched after the furthest mounted one, so the next image is already
    /// decoding when it scrolls in. Together with the bounded mount window this keeps only
    /// a handful of page requests in flight for a 24+ page gallery.
    private static let prefetchAhead = 3
    private static let scrollSpace = "viewer.manga.scroll"

    init(
        pages: [URL],
        aspectRatioFallback: Double? = nil,
        onSingleTap: (() -> Void)? = nil,
        onZoomChanged: ((Bool) -> Void)? = nil
    ) {
        self.pages = pages
        self.aspectRatioFallback = aspectRatioFallback
        self.onSingleTap = onSingleTap
        self.onZoomChanged = onZoomChanged
        _reservedRatios = State(initialValue: Self.ratios(for: pages, fallback: aspectRatioFallback))
    }

    /// Reserved ratio per page, taken from the measured cache and otherwise from the
    /// post-level ratio. `nil` lets `MangaPageLayout` apply the portrait fallback.
    private static func ratios(for pages: [URL], fallback: Double?) -> [Double?] {
        let postRatio = MangaPageLayout.validRatio(fallback)
        return pages.map { url in
            MangaPageLayout.validRatio(MediaAspectRatioCache.aspectRatio(for: url)) ?? postRatio
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Pure geometry: the same width and ratio snapshot always produce the same
            // slots, so an image arriving can never change the content extent.
            let layout = MangaPageLayout(
                pageCount: pages.count,
                width: size.width,
                ratios: reservedRatios,
                gap: Self.pageGap
            )
            let window = renderWindow(layout: layout, viewportHeight: size.height)
            // Nil until the reader has a real width, so an unmeasured pass never pins the
            // content to a zero-height frame.
            let contentWidth: CGFloat? = layout.width > 0 ? layout.width : nil
            let contentHeight: CGFloat? = layout.totalHeight > 0 ? layout.totalHeight : nil

            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        // A plain `VStack` (not a lazy one): every child carries an explicit
                        // finite width *and* height, so the stack's content size is exact on
                        // the first pass and there is no ideal-size estimate left to clamp a
                        // fling. The container frame below states the total independently.
                        // Image materialisation is bounded separately by the render window,
                        // so a long gallery still holds only a few live page views.
                        VStack(spacing: Self.pageGap) {
                            ForEach(layout.slots) { slot in
                                pageSlot(slot, isRendered: window.contains(slot.index))
                                    // Stable per-page identity: the width-change
                                    // re-anchor uses it, and a slot switching between
                                    // shell and image keeps the same identity.
                                    .id(slot.index)
                            }
                        }
                        // The scroll content extent is the precomputed total, not whatever
                        // the mounted children happen to add up to: this is what keeps a
                        // long fling from stopping at the last page that has an image.
                        .frame(
                            width: contentWidth,
                            height: contentHeight,
                            alignment: .top
                        )
                        .background {
                            GeometryReader { contentProxy in
                                Color.clear.preference(
                                    key: MangaContentOffsetKey.self,
                                    value: -contentProxy.frame(in: .named(Self.scrollSpace)).minY
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .scrollIndicators(.visible)
                    .accessibilityIdentifier("viewer.mangaReader")
                    // The zoom pan owns the touch while zoomed; scrolling returns at 1x.
                    .scrollDisabled(zoomScale > Self.zoomEpsilon)
                    .contentShape(Rectangle())
                    .scaleEffect(zoomScale, anchor: zoomAnchor)
                    .offset(zoomOffset)
                    .simultaneousGesture(
                        panGesture(size: size),
                        including: zoomScale > Self.zoomEpsilon ? .all : .none
                    )
                    .gesture(tapGesture(size: size))
                    .onPreferenceChange(MangaContentOffsetKey.self) { offset in
                        track(offset: offset, layout: layout)
                    }
                    // A width / orientation change legitimately re-derives every slot;
                    // the page that was on top stays on top instead of jumping to
                    // whatever content y it used to occupy.
                    .onChange(of: size.width) { oldWidth, newWidth in
                        guard oldWidth > 0, newWidth > 0, oldWidth != newWidth else { return }
                        scrollProxy.scrollTo(trackedPageIndex, anchor: .top)
                    }
                    .task(id: window) { await prefetchAfter(window: window) }
                }

                indicator(layout: layout)
                    .padding(16)
            }
            .clipped()
            .onChange(of: zoomScale) { _, scale in
                onZoomChanged?(scale > Self.zoomEpsilon)
            }
            .onChange(of: pages) { _, newPages in
                // A different gallery legitimately re-derives its reserved ratios.
                reservedRatios = Self.ratios(for: newPages, fallback: aspectRatioFallback)
                decodedURLs.formIntersection(newPages)
                trackedPageIndex = 0
            }
            .onDisappear {
                onZoomChanged?(false)
            }
        }
    }

    private func indicator(layout: MangaPageLayout) -> some View {
        Text("\(visiblePageIndex(in: layout) + 1) / \(pages.count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("viewer.mangaPageIndicator")
    }

    /// One reserved slot: the page image while the slot is inside the render window, a
    /// lightweight empty shell otherwise. Both reserve the identical finite size, so the
    /// scroll extent never depends on which pages are mounted.
    @ViewBuilder
    private func pageSlot(_ slot: MangaPageLayout.Slot, isRendered: Bool) -> some View {
        let slotWidth: CGFloat? = slot.width > 0 ? slot.width : nil
        let slotHeight: CGFloat? = slot.height > 0 ? slot.height : nil

        Group {
            if isRendered, pages.indices.contains(slot.index) {
                let url = pages[slot.index]
                PrivateViewerImage(
                    urls: [url],
                    failureText: "Page \(slot.index + 1) unavailable",
                    isKnownLoaded: decodedURLs.contains(url),
                    onLoaded: { loaded in
                        // Remember the decode so scrolling back to this page does not
                        // flash the spinner again.
                        self.decodedURLs.formUnion([loaded])
                    }
                )
            } else {
                Color.clear
            }
        }
        .frame(width: slotWidth, height: slotHeight)
        .clipped()
    }

    /// Pages whose reserved slot intersects the viewport plus a bounded overscan. This
    /// bounds the number of live image requests to what is on (or near) screen: the
    /// content extent comes from `MangaPageLayout`, never from mounted children.
    private func renderWindow(layout: MangaPageLayout, viewportHeight: CGFloat) -> Set<Int> {
        guard viewportHeight.isFinite, viewportHeight > 0, layout.pageCount > 0 else { return [] }
        let top = max(layout.originY(of: trackedPageIndex) ?? 0, 0)
        let lower = max(top - viewportHeight * Self.overscanScreensBefore, 0)
        let upper = top + viewportHeight * (1 + Self.overscanScreensAfter)
        return layout.indices(intersecting: lower...max(upper, lower))
    }

    /// Page under the top of the viewport, for the `n / total` indicator.
    private func visiblePageIndex(in layout: MangaPageLayout) -> Int {
        layout.slots.isEmpty ? 0 : min(max(trackedPageIndex, 0), layout.pageCount - 1)
    }

    /// Records the page under the viewport top. Only a page change mutates state, so a
    /// long scroll does not re-evaluate the reader once per frame; the width-change
    /// re-anchor, the indicator and the render window all read the same tracked page.
    private func track(offset: CGFloat, layout: MangaPageLayout) {
        guard offset.isFinite else { return }
        let index = layout.index(atOffset: max(offset, 0)) ?? 0
        guard index != trackedPageIndex else { return }
        trackedPageIndex = index
    }

    /// Warms the few pages after the furthest mounted one. Bounded so a gallery never
    /// starts downloading itself; the loader also caps concurrent prefetches.
    private func prefetchAfter(window: Set<Int>) async {
        guard let furthest = window.max() else { return }
        let first = furthest + 1
        let last = min(furthest + Self.prefetchAhead, pages.count - 1)
        guard first <= last else { return }
        let upcoming = (first...last).map { pages[$0] }
        await MediaImageLoader.shared.prefetch(urls: upcoming)
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > Self.zoomEpsilon else { return }
                let moved = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                zoomOffset = clampZoomOffset(moved, scale: zoomScale, anchor: zoomAnchor, size: size)
            }
            .onEnded { _ in
                if zoomScale > Self.zoomEpsilon {
                    lastOffset = zoomOffset
                } else {
                    resetZoom()
                }
            }
    }

    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                handleDoubleTap(at: value.location, in: size)
            }
            .exclusively(
                before: TapGesture(count: 1).onEnded { _ in
                    onSingleTap?()
                }
            )
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoomScale > Self.zoomEpsilon {
                resetZoom()
            } else {
                guard size.width > 0, size.height > 0 else { return }
                zoomAnchor = UnitPoint(
                    x: min(max(location.x / size.width, 0), 1),
                    y: min(max(location.y / size.height, 0), 1)
                )
                zoomScale = Self.doubleTapScale
                lastScale = Self.doubleTapScale
                zoomOffset = .zero
                lastOffset = .zero
            }
        }
    }

    private func resetZoom() {
        zoomScale = 1
        lastScale = 1
        zoomOffset = .zero
        lastOffset = .zero
        zoomAnchor = .center
    }
}

/// Vertical scroll offset of the manga reader's reserved content, measured from the top
/// of its content space. It only decides which page is *tracked* (indicator + bounded
/// render window); it never feeds back into the reserved geometry.
private struct MangaContentOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
