import Foundation

/// One page of results returned by `BooruSource.fetchPosts`.
struct PostPage: Sendable {
    var posts: [BooruPost]
    /// Next page number to request, or nil when the source does not expose one.
    var nextPage: Int?
    var hasMore: Bool
}
