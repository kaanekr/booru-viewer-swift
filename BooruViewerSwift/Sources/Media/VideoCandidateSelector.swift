import Foundation

/// Playable video candidates for the viewer, mirroring RN `getVideoCandidates`
/// (src/utils/media.ts:649-698) with the iOS playability filter from
/// `isUnsupportedOnIOS` (media.ts:364-374).
///
/// Difference from RN, deliberate and required by this module's contract:
/// WebM / AV1 URLs are dropped instead of being returned last, because the iOS
/// player cannot decode them (-11828). RN keeps them and relies on the
/// caller's `selectPrimaryVideoCandidate` guard plus the MP4 upgrade flow
/// (media.ts:700-719); here `MP4Upgrade` takes that role.
///
/// URLs are normalized first (`normalizeBooruMediaUrl`, media.ts:175-204), so an
/// XHamster `.av1.` rendition becomes `.h264.` (media.ts:199-201) and survives the
/// iOS playability filter.
enum VideoCandidateSelector {
    /// iOS-playable video URLs for `post`, RN candidate order preserved
    /// (sample before original, stable priority sort).
    static func videoCandidates(for post: BooruPost) -> [URL] {
        // RN pushes sampleUrl then originalUrl (media.ts:655-656).
        let raw: [URL?] = [post.sampleURL, post.originalURL]
        let normalized = raw.map { MediaURLNormalizer.normalize($0, sourceID: post.sourceID) }

        // RN dedupes the normalized strings, keeping first-seen order (media.ts:658-668).
        var seen = Set<String>()
        var unique: [URL] = []
        for candidate in normalized.compactMap({ $0 }) {
            if seen.insert(candidate.absoluteString).inserted {
                unique.append(candidate)
            }
        }

        // Only video paths survive; image URLs are excluded (media.ts:670-681).
        let videos = unique.filter { isVideoPath(path(of: $0)) }

        // iOS-playable only (media.ts:361-374).
        let playable = videos.filter { !isUnsupportedOnIOS($0) }

        // Priority: mp4/mov/m4v (3) > m3u8 (2) > webm (1) (media.ts:683-697).
        // `sorted(by:)` is not stable in Swift, so ties break on the original index
        // like JavaScript's stable Array.prototype.sort.
        return playable.enumerated()
            .sorted { lhs, rhs in
                let left = priority(lhs.element)
                let right = priority(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map { $0.element }
    }

    /// media.ts:671 — only the query string is stripped before the extension check.
    private static func path(of url: URL) -> String {
        let raw = url.absoluteString.lowercased()
        if let cut = raw.firstIndex(of: "?") {
            return String(raw[..<cut])
        }
        return raw
    }

    /// media.ts:672-679.
    private static func isVideoPath(_ path: String) -> Bool {
        videoExtensions.contains { path.hasSuffix($0) }
    }

    private static let videoExtensions = [".mp4", ".mov", ".m4v", ".webm", ".m3u8"]

    /// media.ts:364-374 (`isUnsupportedOnIOS`). The RN `Platform.OS !== 'ios'` escape
    /// is omitted: this target is iOS-only.
    private static func isUnsupportedOnIOS(_ url: URL) -> Bool {
        let clean = path(of: url)
        return clean.hasSuffix(".webm")
            || clean.contains(".webm")
            || clean.contains(".av1.")
            || clean.hasSuffix(".av1")
    }

    /// media.ts:683-695.
    private static func priority(_ url: URL) -> Int {
        let clean = path(of: url)
        if [".mp4", ".mov", ".m4v"].contains(where: { clean.hasSuffix($0) }) { return 3 }
        if clean.hasSuffix(".m3u8") { return 2 }
        if clean.hasSuffix(".webm") { return 1 }
        return 0
    }
}
