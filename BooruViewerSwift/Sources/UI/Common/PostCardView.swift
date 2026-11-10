import AVFoundation
import Foundation
import SwiftUI

/// One masonry-grid post card, mirroring RN `PostCard`
/// (src/components/PostCard.tsx:253-372).
///
/// The card keeps RN's presentation rules:
/// - aspect ratio from the stored value, the loader-measured ratio, or a
///   per-source default, clamped to 0.5...1.78 (PostCard.tsx:84);
/// - a cheap static cover (`previewUrl`, then the poster/thumbnail/quality fallbacks);
/// - inline motion only when grid previews are enabled: a muted looping listing clip
///   (`GridPreviewPolicy.videoCandidates`) or the 1200 ms frame slideshow
///   (`GridPreviewPolicy.frameCandidates` + `GridPreviewTiming`);
/// - rating, score, sound, media-type and favorite badges.
struct PostCardView: View {
    /// One corner badge (manga/webm/gif/mp4/zip/video), PostCard.tsx:346-362.
    private struct MediaBadge {
        let text: String
        let symbol: String?
    }

    private let post: BooruPost
    private let imageQuality: ImageQuality
    private let gridPreviewsEnabled: Bool
    private let isFavorite: Bool
    private let onTap: () -> Void
    private let onLongPress: (() -> Void)?

    /// Gates motion so off-screen cards never hold a player or a timer (PostCard.tsx:127-129).
    @State private var isOnScreen = false
    /// Index into the frame slideshow (PostCard.tsx:111, 192-200).
    @State private var frameIndex = 0
    /// Finger-down state of the card. Reported by the `Button`'s
    /// `configuration.isPressed`, which also goes false when the enclosing
    /// `ScrollView` takes the touch over or the press is cancelled.
    @State private var isPressed = false
    /// Held preview: raised once the 350 ms hold succeeds and kept until the press
    /// ends (RN `touchPreviewActive`, PostCard.tsx:110, 261-268).
    @State private var isHoldPreview = false
    /// True once this press has become a long press: keeps `onLongPress` to one call
    /// per hold and suppresses the tap the `Button` would otherwise send on release.
    @State private var didLongPress = false
    /// Aspect ratio updated when AsyncMediaImage loads.
    @State private var dynamicAspectRatio: Double?

    init(
        post: BooruPost,
        imageQuality: ImageQuality,
        gridPreviewsEnabled: Bool,
        isFavorite: Bool = false,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.post = post
        self.imageQuality = imageQuality
        self.gridPreviewsEnabled = gridPreviewsEnabled
        self.isFavorite = isFavorite
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    // MARK: Geometry

    /// Card fallback ratio per source: video sites render in a landscape player,
    /// nhentai pages are portrait, everything else keeps `PostCard.tsx:84`'s 0.75.
    private static func defaultAspectRatio(for post: BooruPost) -> Double {
        switch post.sourceID {
        case .xvideos, .xhamster, .pornhub: return 16.0 / 9.0
        case .nhentai: return 0.71
        default: return 0.75
        }
    }

    /// Stored ratio first, then the ratio the loader measured for this post's
    /// media, then the per-source default; clamped to `0.5...1.78`.
    private var aspectRatio: Double {
        let postRatio = post.aspectRatio > 0 ? post.aspectRatio : nil
        let rawRatio = dynamicAspectRatio
            ?? postRatio
            ?? MediaAspectRatioCache.aspectRatio(for: post)
            ?? Self.defaultAspectRatio(for: post)
        return min(1.78, max(0.5, rawRatio))
    }

    // MARK: Cover

    /// Cover chain: static images first (poster, thumbnail, requested quality),
    /// video URLs last so `MediaImageLoader` can extract a poster frame when the
    /// card has no still image at all (Cum.st, raw video links).
    private var coverCandidates: [URL] {
        let isMainMediaVideo = MediaImageLoader.isVideoURL(post.sampleURL) || MediaImageLoader.isVideoURL(post.originalURL)
        var staticSources: [URL?] = []
        if isMainMediaVideo, let preview = post.previewURL {
            staticSources.append(preview)
        }
        staticSources.append(contentsOf: [
            post.previewURL,
            post.previewFallbackURL,
            post.previewThumbURL,
            ImageQualityResolver.placeholderURL(for: post),
            ImageQualityResolver.imageURL(for: post, quality: imageQuality)
        ])

        var images: [URL] = []
        for candidate in staticSources {
            guard let candidate,
                  let url = MediaURLNormalizer.normalize(candidate, sourceID: post.sourceID),
                  !MediaImageLoader.isVideoURL(url),
                  !images.contains(url) else { continue }
            images.append(url)
        }

        let videoSources: [URL?] = [
            post.previewVideoURL,
            post.sampleURL,
            post.originalURL
        ]
        var videos: [URL] = []
        for candidate in videoSources {
            guard let candidate,
                  let url = MediaURLNormalizer.normalize(candidate, sourceID: post.sourceID),
                  MediaImageLoader.isVideoURL(url),
                  !videos.contains(url) else { continue }
            videos.append(url)
        }

        return images + videos
    }

    /// Primary cover candidate.
    private var coverURL: URL? {
        coverCandidates.first
    }

    /// Remaining candidates tried after the primary fails.
    private var coverFallbacks: [URL] {
        Array(coverCandidates.dropFirst())
    }

    // MARK: Inline motion

    /// Master switch, on-screen gate, and "has something to show" (PostCard.tsx:125-129).
    private var canPlayInline: Bool {
        isOnScreen && GridPreviewPolicy.shouldPlayInlinePreview(
            post: post,
            enabled: gridPreviewsEnabled,
            quality: imageQuality
        )
    }

    /// RN `hasPreview` (PostCard.tsx:125): a hold-widened clip or a frame source.
    private var hasPreview: Bool {
        !GridPreviewPolicy.videoCandidates(
            for: post,
            quality: imageQuality,
            allowOriginal: true
        ).isEmpty || !GridPreviewPolicy.frameCandidates(for: post).isEmpty
    }

    /// Motion runs for on-screen cards and, additionally, while the card is held
    /// (PostCard.tsx:126-129, 146).
    private var isPreviewActive: Bool {
        canPlayInline || (isHoldPreview && isOnScreen && gridPreviewsEnabled && hasPreview)
    }

    /// Automatic listing clip. A hold widens the candidates to the full original,
    /// which is RN's explicit-hold path (`allowOriginal`, PostCard.tsx:146).
    private var videoURL: URL? {
        guard isPreviewActive else { return nil }
        return GridPreviewPolicy.videoCandidates(
            for: post,
            quality: imageQuality,
            allowOriginal: isHoldPreview
        ).first
    }

    /// Frame slideshow sources for videoless cards (PostCard.tsx:119-124).
    private var frames: [URL] {
        guard isPreviewActive else { return [] }
        return GridPreviewPolicy.frameCandidates(for: post)
    }

    /// Only a multi-frame slideshow needs the timer.
    private var frameLoopKey: Int {
        guard videoURL == nil, frames.count > 1 else { return 0 }
        return frames.count
    }

    private var currentFrame: URL? {
        guard !frames.isEmpty else { return nil }
        return frames[frameIndex % frames.count]
    }

    /// Stable identity of the preview-frame layer: one card's frames reuse the same
    /// view so the previous frame stays on screen while the next one loads. A
    /// different post (or a different cover) gets a fresh layer, so no decoded frame
    /// from the previous card can survive the swap.
    private var frameLayerIdentity: String {
        Self.frameLayerKey(postID: post.id, coverURL: coverURL)
    }

    /// Key for the frame overlay layer. Post id and cover both matter: the cover is
    /// part of the key so a post whose primary cover changes re-seeds the layer
    /// instead of keeping a frame decoded for the old cover.
    static func frameLayerKey(postID: String, coverURL: URL?) -> String {
        "\(postID)|\(coverURL?.absoluteString ?? "")"
    }

    var body: some View {
        // A `Button` (not a gesture recognizer) owns every touch on the card: inside
        // the grid's `ScrollView` it yields the pan as soon as the drag starts, and it
        // reports the whole press lifecycle through `configuration.isPressed`,
        // including cancellation by the scroll view.
        Button(action: handleTap) {
            cardContent
        }
        .buttonStyle(PressableCardStyle(isPressed: $isPressed))
        .onChange(of: isPressed) { _, pressed in
            if pressed {
                beginPress()
            } else {
                endHoldPreview()
            }
        }
        // RN `delayLongPress={350}` measured from the same press state, so the hold
        // needs no recognizer of its own: the sleep is cancelled the moment the press
        // ends or the enclosing scroll view takes the touch over.
        .task(id: isPressed) {
            guard isPressed else { return }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.longPressDelayMilliseconds) * 1_000_000
                )
            } catch {
                return
            }
            beginHoldPreview()
        }
        .onAppear {
            isOnScreen = true
            if dynamicAspectRatio == nil, let cached = MediaAspectRatioCache.aspectRatio(for: post) {
                dynamicAspectRatio = cached
            }
        }
        .onDisappear {
            isOnScreen = false
            isPressed = false
            endHoldPreview()
            didLongPress = false
        }
        // A recycled card that now shows another post (or whose cover changed) starts
        // its slideshow over instead of inheriting the previous card's frame index.
        // The measured ratio is not reset: the next cover load re-reports it, so the
        // masonry column never reflows on the swap.
        .onChange(of: frameLayerIdentity) { _, _ in
            frameIndex = 0
        }
        .task(id: frameLoopKey) {
            guard frameLoopKey > 0 else {
                frameIndex = 0
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(GridPreviewTiming.frameIntervalMilliseconds) * 1_000_000
                    )
                } catch {
                    return
                }
                frameIndex = GridPreviewTiming.nextFrameIndex(
                    current: frameIndex,
                    frameCount: frames.count
                )
            }
        }
    }

    /// Card visuals only; all interaction lives on the enclosing `Button`.
    private var cardContent: some View {
        Color.clear
            .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
            .overlay { mediaFrame }
            .overlay { badgeStack }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Cover plus motion, hard-clamped to the card's aspect-ratio frame. The
    /// inline clip lives here (not in an outer overlay) so a live preview can
    /// never negotiate the layout: the card keeps the geometry the grid measured.
    private var mediaFrame: some View {
        ZStack {
            AsyncMediaImage(
                url: coverURL,
                fallbackURLs: coverFallbacks,
                contentMode: .fill,
                onImageLoaded: { loadedImage in
                    guard loadedImage.size.height > 0 else { return }
                    let ratio = Double(loadedImage.size.width / loadedImage.size.height)
                    if dynamicAspectRatio != ratio {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            dynamicAspectRatio = ratio
                        }
                    }
                }
            )

            if let videoURL {
                MutedLoopingVideo(url: videoURL)
                    .id(videoURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(false)
            } else if let currentFrame {
                AsyncMediaImage(
                    url: currentFrame,
                    contentMode: .fill,
                    // Transparent while loading and a kept previous frame: a pending
                    // or failed timeline frame must never paint over the still-valid
                    // base cover underneath (and never blank it).
                    placeholder: AsyncMediaImage.overlayConfiguration.placeholder,
                    keepsPreviousImageWhileLoading:
                        AsyncMediaImage.overlayConfiguration.keepsPreviousImageWhileLoading
                )
                // Keyed by post+cover, not by frame URL: advancing the slideshow
                // updates this same layer instead of tearing down a new one, so the
                // last decoded frame holds while the next decodes.
                .id(frameLayerIdentity)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.02), Color.black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .clipped()
    }

    /// Badges pinned to the card geometry: the explicit `maxWidth`/`maxHeight`
    /// frame keeps each stack anchored to its corner of the image instead of
    /// stretching with whatever the video layer reports.
    private var badgeStack: some View {
        ZStack {
            topBadges
            bottomBadges
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: Press / long press

    /// RN `delayLongPress={350}` (PostCard.tsx:260).
    private static let longPressDelayMilliseconds: Double = 350

    /// Tap: RN suppresses `onPress` once a long press has fired (PostCard.tsx:256-267),
    /// so a hold that opened the favorites action must not also open the viewer.
    private func handleTap() {
        let wasHold = didLongPress
        endHoldPreview()
        guard !wasHold else { return }
        onTap()
    }

    /// Fresh touch-down: re-arm the hold so `didLongPress` can never stay stuck and a
    /// second long press on the same card always works.
    private func beginPress() {
        isHoldPreview = false
        didLongPress = false
    }

    /// The hold reached 0.35 s: raise the inline preview and notify once
    /// (PostCard.tsx:261-267).
    private func beginHoldPreview() {
        guard !didLongPress else { return }
        didLongPress = true
        if isOnScreen && gridPreviewsEnabled && hasPreview {
            isHoldPreview = true
        }
        onLongPress?()
    }

    /// Press end, press cancellation, or the card leaving the grid: stop the held
    /// preview (RN `onPressOut`, PostCard.tsx:268). `didLongPress` survives until the
    /// next touch-down so a late `Button` action cannot open the viewer as well.
    private func endHoldPreview() {
        isHoldPreview = false
    }

    // MARK: Badges

    private var topBadges: some View {
        HStack(alignment: .top, spacing: 6) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            if let mediaBadge {
                mediaBadgeView(mediaBadge)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var bottomBadges: some View {
        HStack(spacing: 6) {
            Text(post.rating.rawValue.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.ratingColor(for: post.rating), in: RoundedRectangle(cornerRadius: 6))

            if hasSoundTag {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer(minLength: 0)

            if post.score != 0 {
                Text("★ \(post.score)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.goldAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    /// RedGifs carries audio support as the `sound` meta tag; grid clips play muted
    /// (PostCard.tsx:337-343).
    private var hasSoundTag: Bool {
        post.tags.meta.contains("sound")
    }

    /// Manga page count first, then WEBM, then gif/mp4/zip, then a generic video mark
    /// (PostCard.tsx:346-362).
    private var mediaBadge: MediaBadge? {
        if post.sourceID == .nhentai || (post.pageCount ?? 0) > 0 {
            let text = post.pageCount.map { "\($0)P" } ?? "MANGA"
            return MediaBadge(text: text, symbol: "book.fill")
        }
        if isWebm {
            return MediaBadge(text: "WEBM", symbol: nil)
        }
        if let ext = post.fileExt?.lowercased(), ["gif", "mp4", "zip", "webp"].contains(ext) {
            return MediaBadge(text: ext.uppercased(), symbol: nil)
        }
        if post.previewVideoURL != nil {
            return MediaBadge(text: "VIDEO", symbol: "play.fill")
        }
        return nil
    }

    /// RN `isWebm` (PostCard.tsx:87-93).
    private var isWebm: Bool {
        if post.fileExt?.lowercased() == "webm" { return true }
        return endsWith(post.originalURL, ".webm") || endsWith(post.sampleURL, ".webm")
    }

    private func mediaBadgeView(_ badge: MediaBadge) -> some View {
        HStack(spacing: 3) {
            if let symbol = badge.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            Text(badge.text)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badgeFill(badge), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Manga red, WEBM orange (AVPlayer cannot decode it), other types near-black
    /// (PostCard.tsx:548-573).
    private func badgeFill(_ badge: MediaBadge) -> Color {
        if badge.symbol == "book.fill" { return AppTheme.color(0xED2553, opacity: 0.85) }
        if badge.text == "WEBM" { return AppTheme.color(0xE65100, opacity: 0.9) }
        return Color.black.opacity(0.7)
    }

    /// RN `pathOf(...).endsWith(...)`; query strings and fragments are ignored.
    private func endsWith(_ url: URL?, _ suffix: String) -> Bool {
        guard let raw = url?.absoluteString.lowercased() else { return false }
        let path = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map { String($0) } ?? raw
        return path.hasSuffix(suffix)
    }
}

/// Forwards the card's press lifecycle out of the `Button` without a gesture
/// recognizer, so the card never competes with the grid's scroll pan: the button
/// is cancelled (and `isPressed` goes back to false) as soon as the enclosing
/// `ScrollView` takes the touch over.
private struct PressableCardStyle: ButtonStyle {
    /// `true` while the finger is down on the card.
    let isPressed: Binding<Bool>

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if isPressed.wrappedValue != pressed {
                    isPressed.wrappedValue = pressed
                }
            }
    }
}

/// Muted, looping inline clip.
///
/// `AVPlayerLooper` owns the loop so no end-of-item notification has to be wired up,
/// and the player is paused as soon as the card leaves the grid (RN releases the
/// native player for the same reason, PostCard.tsx:397-408). Rendering goes through
/// `AVPlayerSurfaceView` so the clip carries no native `AVKit` controls and no
/// `AVPlayerViewController` layout of its own.
private struct MutedLoopingVideo: View {
    let url: URL

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        AVPlayerSurfaceView(player: player, videoGravity: .resizeAspectFill)
            .allowsHitTesting(false)
            .disabled(true)
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        if let player {
            player.play()
            return
        }
        // Same routed, header-carrying item the viewer uses: relays TLS-fragile
        // CDNs and sends the Referer/User-Agent AVPlayer omits by default.
        let item = MediaRequestConfiguration.makePlayerItem(for: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        queuePlayer.play()
    }

    private func stop() {
        player?.pause()
    }
}
