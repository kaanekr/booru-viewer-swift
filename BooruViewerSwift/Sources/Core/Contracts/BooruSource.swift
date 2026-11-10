import Foundation

/// One booru or video platform. Implementations are provided per source in later integration work.
protocol BooruSource: Sendable {
    var id: SourceID { get }
    var displayName: String { get }
    var supportsVideo: Bool { get }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion]
    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia
}
