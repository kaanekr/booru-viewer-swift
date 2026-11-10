import Foundation

/// Mirrors RN `FeedOrder` (src/services/storage.ts:8-14). Stored under RN key `@booru_feed_order_v2` (storage.ts:24).
/// JSON keys equal the Swift property names. The enums reuse the RN string sets from `SearchFilterConfig.swift`.
struct FeedOrder: Codable, Sendable {
    /// RN `sortBy: SortOption` (storage.ts:10).
    var sortBy: SortOrder
    /// RN `timeRange: TimeRangeOption` (storage.ts:11).
    var timeRange: TimeRange
    /// HentaiHaven Explore section; ignored on other sources (storage.ts:12-13).
    var hentaiHavenSection: HentaiHavenFeedSection? = nil
}
