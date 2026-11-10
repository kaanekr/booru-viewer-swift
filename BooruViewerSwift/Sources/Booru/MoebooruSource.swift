import Foundation

/// Moebooru adapter for Yande.re (`id` `yandere`). No credentials are used.
/// RN: `fetchMoebooruPosts` (booruApi.ts:957-1030) and the generic `tag.json` branch of `searchTags` (booruApi.ts:2506-2521).
struct MoebooruSource: BooruSource {
    let id: SourceID = .yandere
    let displayName = "Yande.re"
    let supportsVideo = true
    /// RN sources.ts:13-15.
    private let baseURL = "https://yande.re"

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let limit = BooruQueryTranslator.pageLimit(for: query.filter)
        let tags = BooruQueryTranslator.tagString(for: query, source: id)
        let data = try await BooruJSONSupport.fetchData(
            baseURL: baseURL,
            path: "post.json",
            items: BooruQueryTranslator.pagedPostItems(tags: tags, page: page, limit: limit),
            http: context.http
        )
        // RN :985-986. A non-array body yields no posts. Invalid JSON is an error, as in RN.
        let items = try BooruJSONSupport.decode(
            BooruLenientArray<MoebooruPostDTO>.self,
            from: data,
            failure: "Moebooru API did not return valid JSON."
        ).elements
        let posts = items.compactMap { mapPost($0) }
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// RN `mapPost` inside `fetchMoebooruPosts` (booruApi.ts:988-1027).
    private func mapPost(_ dto: MoebooruPostDTO) -> BooruPost? {
        // RN :989. Keep only items with a preview, sample, or file URL.
        let hasMedia = [dto.previewURL, dto.sampleURL, dto.fileURL].contains { !($0 ?? "").isEmpty }
        guard hasMedia else { return nil }

        // RN :991-993.
        let preview = BooruJSONSupport.firstNonEmpty(dto.previewURL, dto.sampleURL, dto.fileURL)
        let sample = BooruJSONSupport.firstNonEmpty(dto.sampleURL, dto.fileURL, dto.previewURL)
        let original = BooruJSONSupport.firstNonEmpty(dto.fileURL, dto.sampleURL, dto.previewURL)

        let width = BooruJSONSupport.orDefault(dto.width, 800)
        let height = BooruJSONSupport.orDefault(dto.height, 1000)
        let tags = BooruJSONSupport.uniqued(dto.tags)

        // RN :1025. `created_at` is unix seconds. Missing or zero means now.
        let createdAt: String
        if let created = dto.createdAt, created != 0 {
            createdAt = BooruJSONSupport.isoString(unixSeconds: created)
        } else {
            createdAt = BooruJSONSupport.isoString(Date())
        }

        return BooruPost(
            id: dto.id,
            sourceID: id,
            sourceName: displayName,
            title: nil,
            previewURL: BooruJSONSupport.absoluteURL(preview, baseURL: baseURL),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: BooruJSONSupport.absoluteURL(sample, baseURL: baseURL),
            originalURL: BooruJSONSupport.absoluteURL(original, baseURL: baseURL),
            width: width,
            height: height,
            aspectRatio: BooruJSONSupport.aspectRatio(width: width, height: height),
            rating: BooruJSONSupport.rating(dto.rating),
            score: dto.score ?? 0,
            favCount: 0,
            tags: BooruTagGroups(general: tags),
            allTags: tags,
            sourceLink: BooruJSONSupport.optionalURL(dto.source),
            fileExt: dto.fileExt,
            fileSize: dto.fileSize,
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: Tag suggestions

    /// RN generic branch of `searchTags` (booruApi.ts:2506-2521), which handles Moebooru. Failures return an empty list. Cancellation still propagates.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        guard let query = BooruQueryTranslator.suggestionQuery(prefix) else { return [] }
        let limit = BooruQueryTranslator.suggestionLimit
        let found: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
            let data = try await BooruJSONSupport.fetchData(
                baseURL: baseURL,
                path: "tag.json",
                items: BooruQueryTranslator.moebooruTagItems(query: query, limit: limit),
                http: context.http
            )
            let tags = try BooruJSONSupport.decode(
                BooruLenientArray<MoebooruTagDTO>.self,
                from: data,
                failure: "Moebooru tag list did not return valid JSON."
            ).elements
            return tags.map { tag in
                BooruTagSuggestion(name: tag.name ?? "", category: .general, postCount: tag.count ?? 0)
            }.filter { !$0.name.isEmpty }
        }
        return found ?? []
    }

    // MARK: Media

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        BooruJSONSupport.resolvedMedia(for: post, quality: context.imageQuality)
    }
}
