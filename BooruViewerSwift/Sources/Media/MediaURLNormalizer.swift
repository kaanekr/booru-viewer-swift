import Foundation

/// Booru media-URL normalization, mirroring RN `normalizeBooruMediaUrl`
/// (src/utils/media.ts:175-204): protocol-relative repair, the broken hentaihaven
/// `himg.nl` cover path, deprecated Gelbooru CDN hosts (`img1`/`img2`/`img3`/`cdn`/
/// apex → `img4`), the non-Gelbooru `http://` → `https://` upgrade, and the XHamster
/// AV1 → H.264 rendition rewrite (AVPlayer cannot decode AV1). Pure string rules:
/// no network, no UI.
enum MediaURLNormalizer {
    /// Returns the repaired URL, or `nil` when `url` is `nil` (RN returns `''`).
    ///
    /// `sourceID` is accepted for call sites that already know the source; the RN
    /// function branches on the host string itself (media.ts:190, 199), never on the
    /// source id, so the argument does not change the result.
    static func normalize(_ url: URL?, sourceID: SourceID? = nil) -> URL? {
        guard let url else { return nil }
        let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        var value = raw
        if value.hasPrefix("//") { value = "https:" + value } // media.ts:178

        // HH's API wraps some covers in a broken himg.nl path (404); the embedded
        // filename lives directly under /images/ on the active CDN (media.ts:182-185).
        value = replacing(hiimgCoverPattern, in: value, with: "https://img.hentaihaven.xxx/images/$1$2")

        // Gelbooru: img4 is the only CDN with valid DNS/TLS for images/samples
        // (media.ts:190-196) — but thumbnails often live on img3/assets and 404
        // on img4, so those hosts are preserved for thumbnail paths.
        if value.lowercased().contains("gelbooru.com") {
            let loweredValue = value.lowercased()
            let isThumbnail = loweredValue.contains("/thumbnails/") || loweredValue.contains("thumbnail_")
            if isThumbnail {
                // Do NOT rewrite assets.gelbooru.com or img3.gelbooru.com for thumbnails.
                // Rewrite img1, img2, cdn, video-cdn, and apex gelbooru.com to img4.gelbooru.com.
                value = replacing(
                    #"^https?://(?:(?:img[12]|cdn|video-cdn)\.gelbooru\.com|gelbooru\.com)/"#,
                    in: value,
                    with: "https://img4.gelbooru.com/"
                )
                if value.hasPrefix("http://") {
                    value = "https://" + String(value.dropFirst("http://".count))
                }
            } else {
                value = replacing(
                    #"^https?://[a-z0-9.-]*gelbooru\.com/(images|thumbnails|samples)/"#,
                    in: value,
                    with: "https://img4.gelbooru.com/$1/"
                )
                value = replacing(
                    #"^https?://[a-z0-9-]+\.gelbooru\.com/"#,
                    in: value,
                    with: "https://img4.gelbooru.com/"
                )
                value = replacing(
                    #"^https?://gelbooru\.com/"#,
                    in: value,
                    with: "https://img4.gelbooru.com/"
                )
            }
        } else if value.hasPrefix("http://") {
            value = "https://" + String(value.dropFirst("http://".count)) // media.ts:194-195
        }

        // XHamster CDN: iOS AVPlayer cannot decode AV1; normalize to H.264
        // (media.ts:198-201).
        let lowered = value.lowercased()
        if lowered.contains("xhcdn") || lowered.contains("xhamster") {
            value = replacing(#"([._-])av1([._-])"#, in: value, with: "$1h264$2")
            value = replacing(#"\.av1\."#, in: value, with: ".h264.")
        }

        // A rewrite that no longer parses keeps the original URL rather than dropping media.
        return URL(string: value) ?? url
    }

    /// media.ts:182-183.
    private static let hiimgCoverPattern =
        #"^https?://himg\.nl/images/hh/images/([^?#]+\.(?:jpe?g|png|webp))/s_poster\.jpg([?#].*)?$"#

    /// Applies one case-insensitive pattern substitution; a bad pattern leaves the
    /// value untouched (the patterns are literals, so this is defensive only).
    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}
