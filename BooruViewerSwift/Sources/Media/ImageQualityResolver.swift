import Foundation

/// Image URL selection for one post, mirroring RN `getImageUris`
/// (src/utils/media.ts:133-170). Pure: no network, no UI.
///
/// Every field is normalized through `MediaURLNormalizer.normalize`
/// (`normalizeBooruMediaUrl`, media.ts:175-204) before it is handed to the image loader,
/// matching RN's `getMediaUrl` → `normalizeBooruMediaUrl` path (media.ts:211-215).
enum ImageQualityResolver {
    /// Display URL for the requested quality (media.ts:151-159).
    /// - `.full`: `originalUrl || sampleUrl || previewUrl` (media.ts:149, 152-153)
    /// - `.preview`: `sampleUrl || originalUrl || previewUrl` (media.ts:148, 154-155)
    /// - `.auto`: same sample chain; RN upgrades to the original only on zoom
    ///   (media.ts:157-159), which is a viewer concern, not a URL choice.
    static func imageURL(for post: BooruPost, quality: ImageQuality) -> URL? {
        switch quality {
        case .full:
            return fullURL(for: post)
        case .preview, .auto:
            return sampleURL(for: post)
        }
    }

    /// Placeholder shown while the display image loads.
    /// RN: `placeholder = preview || sample` (media.ts:161), where `sample` already
    /// falls back to the original and then to the preview (media.ts:148).
    static func placeholderURL(for post: BooruPost) -> URL? {
        MediaURLNormalizer.normalize(post.previewURL, sourceID: post.sourceID) ?? sampleURL(for: post)
    }

    /// RN `sample = post.sampleUrl || post.originalUrl || post.previewUrl` (media.ts:148).
    private static func sampleURL(for post: BooruPost) -> URL? {
        MediaURLNormalizer.normalize(post.sampleURL, sourceID: post.sourceID)
            ?? MediaURLNormalizer.normalize(post.originalURL, sourceID: post.sourceID)
            ?? MediaURLNormalizer.normalize(post.previewURL, sourceID: post.sourceID)
    }

    /// RN `full = post.originalUrl || post.sampleUrl || post.previewUrl` (media.ts:149).
    private static func fullURL(for post: BooruPost) -> URL? {
        MediaURLNormalizer.normalize(post.originalURL, sourceID: post.sourceID) ?? sampleURL(for: post)
    }
}
