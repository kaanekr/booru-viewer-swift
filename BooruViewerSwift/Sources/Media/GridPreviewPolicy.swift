import Foundation

/// Grid inline-preview policy: which cards may show motion at all, and from which
/// URLs (src/utils/gridPreviews.ts, src/utils/gridPreviewMedia.ts,
/// src/components/PostCard.tsx). Pure: no state, no UI, no network.
enum GridPreviewPolicy {
    /// Mirrors RN's master switch plus the per-card "has a preview" gate
    /// (gridPreviews.ts:4-10, PostCard.tsx:113-114, 125-129): motion (a listing clip
    /// or the frame slideshow) plays only when the Settings switch is on and this post
    /// actually has something to show. `canLoad`, `screenActive` and `onScreen` are
    /// UI state and stay in the view layer (PostCard.tsx:128-129, 154-155).
    static func shouldPlayInlinePreview(post: BooruPost, enabled: Bool, quality: ImageQuality) -> Bool {
        guard enabled else { return false } // gridPreviews.ts:5, PostCard.tsx:113-114
        // PostCard.tsx:125 gates on `manualCandidates` (`allowOriginal = true`), so an
        // originals-only post still counts as having a preview.
        return !videoCandidates(for: post, quality: quality, allowOriginal: true).isEmpty
            || !frameCandidates(for: post).isEmpty // PostCard.tsx:125
    }

    /// Automatic motion candidates, i.e. RN `getGridPreviewVideoCandidates(post, os)` with
    /// `allowOriginal = false` (gridPreviewMedia.ts:33-52). `allowOriginal` mirrors RN's
    /// explicit-hold widening (gridPreviewMedia.ts:32-33, 48-50).
    static func videoCandidates(
        for post: BooruPost,
        quality: ImageQuality,
        allowOriginal: Bool = false
    ) -> [URL] {
        // Quality never widens the automatic set. RN allows full originals only on an
        // explicit long-press hold (`allowOriginal`, gridPreviewMedia.ts:32-33, 50), and the
        // quality setting merely picks the static cover (media.ts:151-159). The switch is
        // exhaustive so the parameter documents that decision instead of being ignored.
        switch quality {
        case .preview, .auto, .full:
            return listingCandidates(for: post, allowOriginal: allowOriginal)
        }
    }

    /// Frame sources for the videoless slideshow, RN `getGridPreviewFrames`
    /// (gridPreviewMedia.ts:54-62).
    static func frameCandidates(for post: BooruPost) -> [URL] {
        var raw: [URL?] = (post.previewThumbs ?? []).map { Optional($0) }
        if let thumb = post.previewThumbURL { raw.append(thumb) } // gridPreviewMedia.ts:57
        // A sample GIF can animate without a native player (gridPreviewMedia.ts:58-59).
        if path(of: post.sampleURL).hasSuffix(".gif"),
           normalized(post.sampleURL) != normalized(post.previewURL) {
            raw.append(post.sampleURL)
        }

        var seen = Set<URL>()
        var result: [URL] = []
        for candidate in raw.compactMap({ $0 }) {
            // Image URLs only; page/archive links are never frames (gridPreviewMedia.ts:61).
            guard let url = normalized(candidate),
                  !isVideoPath(url),
                  !isRejectedPath(url) else { continue }
            if seen.insert(url).inserted { result.append(url) }
        }
        return Array(result.prefix(maxFrameCount)) // slice(0, 32), gridPreviewMedia.ts:61
    }

    private static let maxFrameCount = 32 // gridPreviewMedia.ts:61

    /// RN `getGridPreviewVideoCandidates` body (gridPreviewMedia.ts:34-51).
    private static func listingCandidates(for post: BooruPost, allowOriginal: Bool) -> [URL] {
        // A GIF is never a motion preview: Realbooru lists no extension and the guessed
        // `.mp4` 404s, so the card keeps its thumbnail cover (gridPreviewMedia.ts:34-36).
        if isGifMediaPost(post) { return [] }

        var result: [URL] = []
        func add(_ value: URL?, explicit: Bool = false) {
            guard let url = normalized(value) else { return } // gridPreviewMedia.ts:39
            guard isIOSSupported(url) else { return } // gridPreviewMedia.ts:27-30, 40
            guard !isImagePath(url) else { return } // gridPreviewMedia.ts:40
            // Non-video links are usable only when explicit and not a watch/JSON/zip page
            // (gridPreviewMedia.ts:41).
            if !isVideoPath(url) && (!explicit || isRejectedPath(url)) { return }
            if !result.contains(url) { result.append(url) } // gridPreviewMedia.ts:42
        }

        add(post.previewVideoURL, explicit: true) // gridPreviewMedia.ts:44
        let original = normalized(post.originalURL) // gridPreviewMedia.ts:45
        // Several adapters alias sampleUrl/previewUrl to the full attachment; that is not a
        // lightweight listing preview (gridPreviewMedia.ts:46-49).
        if allowOriginal || normalized(post.previewURL) != original { add(post.previewURL) }
        if allowOriginal || normalized(post.sampleURL) != original { add(post.sampleURL) }
        if allowOriginal { add(post.originalURL) } // gridPreviewMedia.ts:50
        return result
    }

    /// RN `isGifMediaPost` (src/utils/gifMedia.ts:21-40). The detail-resolved original
    /// (`resolvedOriginalUrl`) is not stored on `BooruPost`, so only the metadata branches
    /// (gifMedia.ts:32-39) apply.
    private static func isGifMediaPost(_ post: BooruPost) -> Bool {
        if (post.fileExt ?? "").lowercased() == "gif" { return true } // gifMedia.ts:32
        if post.sourceID == .realbooru { // gifMedia.ts:34-38
            let general = post.tags.general.map { $0.lowercased() }
            let hasVideoTag = general.contains { $0 == "video" || $0 == "webm" || $0 == "mp4" }
            if general.contains("gif") && !hasVideoTag { return true }
        }
        // `(originalUrl || sampleUrl).endsWith('.gif')` (gifMedia.ts:39): one fallback,
        // not an OR of both fields, so an mp4 original with a gif sample is not a GIF.
        return path(of: post.originalURL ?? post.sampleURL).hasSuffix(".gif")
    }

    /// RN `normalizePreviewUrl` (gridPreviewMedia.ts:16-21) plus the shared booru media
    /// normalization (`normalizeBooruMediaUrl`, media.ts:175-204). Only absolute http(s)
    /// URLs survive, so relative paths and watch-page links never become streams.
    private static func normalized(_ value: URL?) -> URL? {
        guard let value = MediaURLNormalizer.normalize(value) else { return nil }
        guard let scheme = value.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return value
    }

    /// RN `pathOf` (gridPreviewMedia.ts:23) splits on `[?#&]`.
    private static func path(of url: URL?) -> String {
        guard let raw = url?.absoluteString.lowercased() else { return "" }
        if let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "&" }) {
            return String(raw[..<cut])
        }
        return raw
    }

    /// gridPreviewMedia.ts:24.
    private static func isVideoPath(_ url: URL) -> Bool {
        let clean = path(of: url)
        return videoExtensions.contains { clean.hasSuffix($0) }
    }

    private static let videoExtensions = [".mp4", ".webm", ".mov", ".m4v", ".m3u8"]

    /// gridPreviewMedia.ts:25.
    private static func isImagePath(_ url: URL) -> Bool {
        let clean = path(of: url)
        return imageExtensions.contains { clean.hasSuffix($0) }
    }

    private static let imageExtensions = [
        ".jpeg", ".jpg", ".png", ".webp", ".avif", ".gif", ".svg", ".bmp",
    ]

    /// RN `/\.(html?|php|json|zip)$/` (gridPreviewMedia.ts:41, 61).
    private static func isRejectedPath(_ url: URL) -> Bool {
        let clean = path(of: url)
        return rejectedExtensions.contains { clean.hasSuffix($0) }
    }

    private static let rejectedExtensions = [".htm", ".html", ".php", ".json", ".zip"]

    /// RN `supported(url, 'ios')` (gridPreviewMedia.ts:27-30): WebM containers and AV1
    /// renditions are not playable, so they never enter the candidate list.
    private static func isIOSSupported(_ url: URL) -> Bool {
        let clean = path(of: url)
        if clean.hasSuffix(".webm") { return false }
        if clean.contains(".av1.") || clean.hasSuffix(".av1") { return false }
        return true
    }
}
