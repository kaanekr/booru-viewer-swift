import SwiftUI
import AVFoundation
import Foundation
import UIKit

/// One page of the full-screen viewer: an image with pinch / double-tap zoom, a
/// playing video, or a multi-page gallery/manga reader.
///
/// Mirrors the per-page behaviour of RN `PostPageItem`
/// (src/components/ImageViewerModal.tsx:800-1990): pinch and double-tap zoom for
/// images, `AVPlayer` playback with mute + scrubber for videos, and a multi-page
/// reader when the post carries gallery pages.
struct ZoomableMediaView: View {
    struct ImageRequestChain: Equatable {
        let primary: [URL]
        let placeholder: URL?
    }

    static let videoControlsAutoHideDelayNanoseconds: UInt64 = 3_500_000_000

    static func shouldAutoHideVideoControls(
        isActive: Bool,
        showsControls: Bool,
        isPlaying: Bool,
        isScrubbing: Bool,
        isInfoPresented: Bool,
        loadFailed: Bool
    ) -> Bool {
        isActive && showsControls && isPlaying && !isScrubbing && !isInfoPresented && !loadFailed
    }

    static func shouldEarlyReturnFromCache(candidateIndex: Int) -> Bool {
        candidateIndex == 0
    }

    static func imageRequestChain(
        post: BooruPost,
        media: ResolvedMedia?,
        imageQuality: ImageQuality,
        hasUpgradedToOriginal: Bool
    ) -> ImageRequestChain {
        let rawPlaceholder = media?.placeholderURL ?? ImageQualityResolver.placeholderURL(for: post)
        let placeholder = rawPlaceholder.flatMap { isVideoContainerURL($0) ? nil : $0 }

        guard let media else {
            return ImageRequestChain(primary: [], placeholder: placeholder)
        }

        let nhentaiCover = post.sourceID == .nhentai ? (post.sampleURL ?? post.previewURL) : nil
        var candidates: [URL?] = []
        if imageQuality == .auto, hasUpgradedToOriginal {
            candidates.append(ImageQualityResolver.imageURL(for: post, quality: .full))
        }
        candidates.append(media.imageURL)
        candidates.append(nhentaiCover)

        var primary: [URL] = []
        for candidate in candidates {
            guard let url = candidate,
                  !isVideoContainerURL(url),
                  !primary.contains(url) else { continue }
            primary.append(url)
        }
        if primary.isEmpty, let placeholder {
            primary = [placeholder]
        }
        return ImageRequestChain(primary: primary, placeholder: placeholder)
    }

    private static func isVideoContainerURL(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        let path = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? raw
        return [".mp4", ".webm", ".mov", ".m4v", ".m3u8"].contains { path.hasSuffix($0) }
    }

    let post: BooruPost
    let media: ResolvedMedia?
    var isLoading = false
    var isActive = true
    var isMangaMode = false
    var galleryPages: [URL] = []
    var imageQuality: ImageQuality = .auto
    var isInfoPresented = false
    var controlsInteractionToken = 0
    /// Mirrors the viewer's controls visibility so the video transport card hides
    /// together with `ViewerScreen`'s top/bottom bars.
    var showsControls = true
    /// Explicit visibility setter used by the video auto-hide timer.
    var onSetControlsVisible: ((Bool) -> Void)? = nil
    /// Single tap on the media toggles the viewer controls (RN `handleToggleControls`).
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
                PrivateVideoPlaybackView(
                    url: videoURL,
                    isActive: isActive,
                    showsControls: showsControls,
                    isInfoPresented: isInfoPresented,
                    controlsInteractionToken: controlsInteractionToken,
                    onSetControlsVisible: onSetControlsVisible,
                    onSingleTap: onSingleTap
                )
                .id(videoURL)
            } else {
                imagePage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: zoomScale) { _, scale in
            let zoomed = scale > Self.zoomEpsilon
            onZoomChanged?(zoomed)
            if zoomed, imageQuality == .auto, !hasUpgradedToOriginal {
                hasUpgradedToOriginal = true
            }
        }
        .onChange(of: post.uniqueKey) { _, _ in
            hasUpgradedToOriginal = false
            resetZoom()
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
            let chain = Self.imageRequestChain(
                post: post,
                media: media,
                imageQuality: imageQuality,
                hasUpgradedToOriginal: hasUpgradedToOriginal
            )
            let showUnavailable = media != nil && !isLoading && chain.primary.isEmpty && chain.placeholder == nil

            ZStack {
                Color.black

                if showUnavailable {
                    unavailable
                } else {
                    PrivateViewerImage(
                        urls: chain.primary,
                        placeholderURL: chain.placeholder,
                        isAwaitingURLs: media == nil,
                        showsSpinner: !isLoading
                    )
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
    @State private var hasUpgradedToOriginal = false
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
    var placeholderURL: URL? = nil
    var isAwaitingURLs = false
    var showsSpinner = true
    var failureText = "Media unavailable"
    /// Set by the manga reader for a page URL that already decoded once: the reload is a
    /// cache fast path, so it runs without flashing the spinner (which would otherwise
    /// blink every time a page scrolls back into the reader's rendered window).
    var isKnownLoaded = false
    /// Reported after a successful decode so the reader can mark the URL as loaded.
    var onLoaded: ((URL) -> Void)? = nil

    private struct LoadKey: Equatable {
        let urls: [URL]
        let placeholderURL: URL?
        let isAwaitingURLs: Bool
    }

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
            } else if isKnownLoaded || !showsSpinner {
                // A page this reader session already decoded once: the URL is in the image
                // cache, so hold the reserved slot empty for the cache hop instead of
                // flashing a spinner every time the page scrolls back into view.
                Color.clear
            } else {
                ProgressView()
                    .tint(AppTheme.textPrimary)
            }
        }
        .task(id: LoadKey(urls: urls, placeholderURL: placeholderURL, isAwaitingURLs: isAwaitingURLs)) {
            await load()
        }
    }

    /// Walks the primary chain first. A cached fallback/placeholder renders immediately
    /// as a progressive preview without short-circuiting the primary high-res download.
    private func load() async {
        var uniqueURLs: [URL] = []
        for url in urls where !uniqueURLs.contains(url) {
            uniqueURLs.append(url)
        }

        if uniqueURLs.isEmpty {
            didFail = false
            if isAwaitingURLs {
                if image == nil, let placeholderURL,
                   let cached = await MediaImageLoader.shared.cachedImage(for: placeholderURL) {
                    if Task.isCancelled { return }
                    image = cached
                }
                return
            }
            if let placeholderURL {
                if let cached = await MediaImageLoader.shared.cachedImage(for: placeholderURL) {
                    if Task.isCancelled { return }
                    image = cached
                    loadedURLs = []
                    onLoaded?(placeholderURL)
                    return
                }
                do {
                    let loaded = try await MediaImageLoader.shared.image(for: placeholderURL)
                    if Task.isCancelled { return }
                    image = loaded
                    loadedURLs = []
                    onLoaded?(placeholderURL)
                    return
                } catch {}
            }
            if image == nil {
                didFail = true
            }
            return
        }

        guard loadedURLs != uniqueURLs else { return }

        // Only early-return from cache if the primary desired URL (index 0) is already cached.
        if ZoomableMediaView.shouldEarlyReturnFromCache(candidateIndex: 0),
           let cachedPrimary = await MediaImageLoader.shared.cachedImage(for: uniqueURLs[0]) {
            if Task.isCancelled { return }
            image = cachedPrimary
            loadedURLs = uniqueURLs
            didFail = false
            onLoaded?(uniqueURLs[0])
            return
        }

        // Progressive preview: display a cached fallback/placeholder immediately while still
        // fetching `uniqueURLs[0]` (do NOT early-return or mark `loadedURLs`).
        if image == nil {
            let progressiveCandidates = Array(uniqueURLs.dropFirst())
                + ([placeholderURL].compactMap { $0 }.filter { !uniqueURLs.contains($0) })
            for fallback in progressiveCandidates {
                if Task.isCancelled { return }
                if let cachedFallback = await MediaImageLoader.shared.cachedImage(for: fallback) {
                    if Task.isCancelled { return }
                    image = cachedFallback
                    didFail = false
                    break
                }
            }
        }

        didFail = false
        for url in uniqueURLs {
            if Task.isCancelled { return }
            if let cached = await MediaImageLoader.shared.cachedImage(for: url) {
                if Task.isCancelled { return }
                image = cached
                loadedURLs = uniqueURLs
                onLoaded?(url)
                return
            }
            do {
                let loaded = try await MediaImageLoader.shared.image(for: url)
                if Task.isCancelled { return }
                image = loaded
                loadedURLs = uniqueURLs
                onLoaded?(url)
                return
            } catch {
                continue
            }
        }

        if let placeholderURL, !uniqueURLs.contains(placeholderURL) {
            if let cached = await MediaImageLoader.shared.cachedImage(for: placeholderURL) {
                if Task.isCancelled { return }
                image = cached
                loadedURLs = uniqueURLs
                didFail = false
                onLoaded?(placeholderURL)
                return
            }
            if let loaded = try? await MediaImageLoader.shared.image(for: placeholderURL) {
                if Task.isCancelled { return }
                image = loaded
                loadedURLs = uniqueURLs
                didFail = false
                onLoaded?(placeholderURL)
                return
            }
        }

        if image != nil {
            loadedURLs = uniqueURLs
            didFail = false
            return
        }
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

// MARK: - Video playback

/// Shared mute state kept across clips during the app session (RN `sessionVideoMuted`).
@MainActor
private enum VideoPlaybackSession {
    static var isMuted = false
}

/// `AVPlayer`-backed video page with play/pause, a scrubber and a mute toggle
/// (RN video controls, ImageViewerModal.tsx:1993-2500).
///
/// The surface is a bare `AVPlayerLayer` (`AVPlayerSurfaceView`), so the native
/// `AVPlayerViewController` transport bar never appears alongside these controls.
/// Items are built through `MediaRequestConfiguration`, which means the request
/// carries the per-host `Referer`/`User-Agent` and routes TLS-fragile CDNs through
/// the worker; a failed playback retries once on the alternate leg.
private struct PrivateVideoPlaybackView: View {
    private struct AutoHideKey: Equatable {
        let isActive: Bool
        let showsControls: Bool
        let isPlaying: Bool
        let isScrubbing: Bool
        let isInfoPresented: Bool
        let loadFailed: Bool
        let localToken: Int
        let externalToken: Int
    }

    let url: URL
    var isActive: Bool
    /// Only show the transport card while the viewer's controls are visible.
    var showsControls = true
    var isInfoPresented = false
    var controlsInteractionToken = 0
    var onSetControlsVisible: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isMuted = VideoPlaybackSession.isMuted
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var loadFailed = false
    @State private var localInteractionToken = 0
    @State private var timeObserver: Any?
    @State private var itemStatusObservation: NSKeyValueObservation?
    /// End-of-item observer, bound to the *object* of the current item so a
    /// replaced item can never drive a stale loop.
    @State private var endObserver: NSObjectProtocol?
    /// Set once the alternate route leg has been tried, so a dead URL cannot loop.
    @State private var didRetryAlternate = false
    /// Set by `tearDown` so an in-flight seek completion never restarts a player
    /// whose page has gone away.
    @State private var isDisposed = false
    /// Live mirror of `isActive`. The seek / notification completions capture this
    /// view value, so reading the immutable `isActive` prop there could be stale;
    /// `@State` storage stays current and tells the loop whether the page still
    /// wants playback.
    @State private var isPageActive = true

    private var autoHideKey: AutoHideKey {
        AutoHideKey(
            isActive: isActive,
            showsControls: showsControls,
            isPlaying: isPlaying,
            isScrubbing: isScrubbing,
            isInfoPresented: isInfoPresented,
            loadFailed: loadFailed,
            localToken: localInteractionToken,
            externalToken: controlsInteractionToken
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loadFailed {
                videoFailureOverlay
            } else if let player {
                // `.resizeAspect` keeps the whole frame visible (never cropped) and the
                // surface fills the page, so the video is centred in the viewport.
                AVPlayerSurfaceView(player: player, videoGravity: .resizeAspect)
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)

                // Dedicated tap catcher above `AVPlayerSurfaceView` (which has
                // `isUserInteractionEnabled = false`) so single taps reliably toggle controls.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        localInteractionToken &+= 1
                        onSingleTap?()
                    }
            } else {
                ProgressView()
                    .tint(AppTheme.textPrimary)
            }
        }
        .overlay(alignment: .bottom) {
            if !loadFailed, let player, isActive, showsControls {
                playbackControls(player)
                    .padding(.horizontal, 16)
                    // Clears `ViewerScreen.bottomBar` (manga / favorite
                    // buttons) so the card never hides under it.
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: setUp)
        .onDisappear(perform: tearDown)
        .onChange(of: url) { _, _ in
            tearDown()
            setUp()
        }
        .onChange(of: isActive) { _, active in
            isPageActive = active
            guard let player else { return }
            if active {
                if loadFailed {
                    onSetControlsVisible?(true)
                } else {
                    // Coming back to a clip that already ran to the end must replay
                    // from the start instead of resuming at the final frame.
                    resumeFromStartIfEnded(player)
                }
            } else {
                player.pause()
                isPlaying = false
            }
        }
        .task(id: autoHideKey) {
            guard ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: isActive,
                showsControls: showsControls,
                isPlaying: isPlaying,
                isScrubbing: isScrubbing,
                isInfoPresented: isInfoPresented,
                loadFailed: loadFailed
            ) else { return }
            try? await Task.sleep(nanoseconds: ZoomableMediaView.videoControlsAutoHideDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: isPageActive,
                showsControls: showsControls,
                isPlaying: isPlaying,
                isScrubbing: isScrubbing,
                isInfoPresented: isInfoPresented,
                loadFailed: loadFailed
            ) else { return }
            onSetControlsVisible?(false)
        }
    }

    private var videoFailureOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(AppTheme.danger)
            Text("Video failed to load")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Button {
                localInteractionToken &+= 1
                loadFailed = false
                tearDown()
                setUp()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppTheme.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(AppTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Classic transport card: scrubber row (time / slider / duration) plus a
    /// button row (-10s / play-pause / +10s / mute), on a translucent surface.
    ///
    /// The transport group is centred on the card's own axis: the reserved side
    /// slot is the same width on both edges, so `play` sits at
    /// `viewport.midX` whether or not the trailing mute button is there, and the
    /// flexible spacers keep the mute from colliding with `+10s` on a narrow
    /// iPhone.
    private func playbackControls(_ player: AVPlayer) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(Self.timeLabel(currentTime))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 38, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { currentTime = $0 }
                    ),
                    in: 0...max(duration, 0.1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        localInteractionToken &+= 1
                        if !editing {
                            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                        }
                    }
                )
                .tint(AppTheme.primary)

                Text(Self.timeLabel(duration))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 0) {
                // Symmetric reservation: equal on both sides, so the play button's
                // midX is the card's midX. The trailing slot only hosts mute.
                Color.clear
                    .frame(width: Self.transportSideSlot, height: 1)

                Spacer(minLength: 0)

                HStack(spacing: 18) {
                    circleControl(system: "gobackward.10") { seek(player, by: -10) }
                        .accessibilityLabel("Rewind 10 seconds")

                    Button {
                        togglePlayback(player)
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 48, height: 48)
                            .background(AppTheme.primary.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("viewer.playButton")

                    circleControl(system: "goforward.10") { seek(player, by: 10) }
                        .accessibilityLabel("Forward 10 seconds")
                }
                // Keeps the three transport buttons individually hittable while the
                // group itself carries an identifier for UI tests.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("viewer.transportControls")

                Spacer(minLength: 0)

                circleControl(system: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    toggleMute(player)
                }
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
                .accessibilityIdentifier("viewer.muteButton")
                .frame(width: Self.transportSideSlot, alignment: .trailing)
            }
            .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
    }

    private func circleControl(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Width reserved on both ends of the transport row so the play button lands on
    /// the card's midX. Matches a `circleControl` target.
    private static let transportSideSlot: CGFloat = 36

    // MARK: Player lifecycle

    private func setUp() {
        guard player == nil else { return }
        didRetryAlternate = false
        loadFailed = false
        isDisposed = false
        isPageActive = isActive
        isMuted = VideoPlaybackSession.isMuted
        let item = MediaRequestConfiguration.makePlayerItem(for: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        player = newPlayer
        currentTime = 0
        duration = 0
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            // A relayed leg can fail mid-load; the alternate leg is tried once.
            if newPlayer.currentItem?.status == .failed {
                retryAlternateLeg()
                return
            }
            guard !isScrubbing else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                currentTime = seconds
            }
            if let total = newPlayer.currentItem?.duration.seconds, total.isFinite, total > 0 {
                duration = total
            }
        }
        observeItemStatus(of: item)
        observeEndOfCurrentItem(of: newPlayer)
        if isActive {
            newPlayer.play()
            isPlaying = true
        }
    }

    private func observeItemStatus(of item: AVPlayerItem?) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        guard let item else { return }
        let observedID = ObjectIdentifier(item)
        itemStatusObservation = item.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor in
                guard !isDisposed,
                      let livePlayer = self.player,
                      livePlayer.currentItem.map(ObjectIdentifier.init) == observedID else { return }
                retryAlternateLeg()
            }
        }
    }

    /// Swaps in the other route leg (direct ⇄ relay) after a playback failure so
    /// a TLS-fragile or relay-blocked source still plays. Runs at most once; if no
    /// alternate leg works, surfaces the retryable failure overlay.
    private func retryAlternateLeg() {
        guard !isDisposed, !loadFailed, let player else { return }
        if !didRetryAlternate {
            didRetryAlternate = true
            let attempts = MediaRequestConfiguration.routeAttempts(for: url)
            if attempts.count > 1 {
                let alternate = attempts[1]
                let nextItem = MediaRequestConfiguration.makePlayerItem(for: alternate)
                player.replaceCurrentItem(with: nextItem)
                currentTime = 0
                duration = 0
                // The replaced item is a different object: re-bind observers to it.
                observeItemStatus(of: nextItem)
                observeEndOfCurrentItem(of: player)
                if isPageActive {
                    player.play()
                    isPlaying = true
                }
                return
            }
        }
        player.pause()
        isPlaying = false
        loadFailed = true
        onSetControlsVisible?(true)
    }

    /// Loops a finished finite clip: observe `didPlayToEndTimeNotification` bound to
    /// the current item object, seek back to zero, and resume only when the seek
    /// really finished and nothing invalidated it meanwhile.
    ///
    /// The notification can be posted from a non-main thread, so every mutation in
    /// the handler hops to the main actor. The previous observer is always removed
    /// first, so a replaced item (URL change, episode switch, alternate-leg retry)
    /// can never leave a stale loop behind and observers never multiply.
    private func observeEndOfCurrentItem(of player: AVPlayer) {
        removeEndObserver()
        guard let item = player.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            // Apple's docs note the notification may be posted from another thread;
            // hop to the main actor before touching any UI state.
            Task { @MainActor in
                handlePlaybackReachedEnd()
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    /// Runs on the main actor after the current item played to its end. Restarts
    /// from zero only if the clip is still the live one and the page still wants
    /// playback; a paused, scrubbed, backgrounded or dismissed player stays put.
    private func handlePlaybackReachedEnd() {
        guard !isDisposed, let player, isPageActive, isPlaying, !isScrubbing else { return }
        guard let item = player.currentItem else { return }
        guard endObserver != nil else { return }

        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            // The completion can arrive on a background thread and after the player,
            // its item, the active page or the user's intent changed; the seek is
            // cancelled (`finished == false`) when another seek interrupted it.
            Task { @MainActor in
                guard finished, !isDisposed, isPageActive, isPlaying, !isScrubbing else { return }
                guard let livePlayer = self.player, livePlayer === player,
                      let liveItem = livePlayer.currentItem, liveItem === item else { return }
                currentTime = 0
                livePlayer.play()
            }
        }
    }

    /// Replays a clip that already ran to its end instead of leaving the page on
    /// the final frame when the viewer pages back to it.
    private func resumeFromStartIfEnded(_ player: AVPlayer) {
        let current = player.currentTime().seconds
        let total = player.currentItem?.duration.seconds ?? .nan
        let reachedEnd = total.isFinite && total > 0 && current.isFinite && current >= total - 0.15
        guard reachedEnd else {
            player.play()
            isPlaying = true
            return
        }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard finished, !isDisposed, isPageActive, let livePlayer = self.player else { return }
                livePlayer.play()
                isPlaying = true
            }
        }
    }

    private func tearDown() {
        isDisposed = true
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        removeEndObserver()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func togglePlayback(_ player: AVPlayer) {
        localInteractionToken &+= 1
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func toggleMute(_ player: AVPlayer) {
        localInteractionToken &+= 1
        isMuted.toggle()
        VideoPlaybackSession.isMuted = isMuted
        player.isMuted = isMuted
    }

    /// Relative seek (-10s / +10s), clamped to the clip bounds.
    private func seek(_ player: AVPlayer, by delta: Double) {
        localInteractionToken &+= 1
        let upperBound = duration > 0 ? duration : max(currentTime + delta, 0)
        let target = min(max(currentTime + delta, 0), upperBound)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
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
