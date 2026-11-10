import Foundation

/// Input to `BooruSource.fetchPosts`. `tags` is the raw search text; `filter` holds the structured options.
struct SearchQuery: Codable, Sendable {
    var tags: String
    var filter: SearchFilterConfig
}
