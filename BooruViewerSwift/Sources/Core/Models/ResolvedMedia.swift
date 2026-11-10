import Foundation

/// Playable or displayable media for one post, produced by `BooruSource.resolveMedia`.
struct ResolvedMedia: Sendable {
    var imageURL: URL?
    var videoURL: URL?
    var isVideo: Bool
    var placeholderURL: URL?
}
