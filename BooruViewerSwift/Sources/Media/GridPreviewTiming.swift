import Foundation

/// Pure timing constants and frame stepping for the grid preview loop, mirroring
/// RN `PostCard.tsx` (src/components/PostCard.tsx).
enum GridPreviewTiming {
    /// The frame slideshow advances every 1200 ms (PostCard.tsx:196-198).
    static let frameIntervalMilliseconds: Int = 1200

    /// A stalled native player keeps the cover and advances after 15 s
    /// (PostCard.tsx:158-164).
    static let stallTimeoutMilliseconds: Int = 15_000

    /// Next slide index. RN: `(prev + 1) % previewThumbs.length`, and the timer is
    /// torn down (index reset to 0) when fewer than two frames exist
    /// (PostCard.tsx:192-199).
    static func nextFrameIndex(current: Int, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let wrapped = (current % frameCount + frameCount) % frameCount
        return (wrapped + 1) % frameCount
    }
}
