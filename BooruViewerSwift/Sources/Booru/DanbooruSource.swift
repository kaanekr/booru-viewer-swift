import Foundation

/// Danbooru `posts.json` / `tags.json` adapter. No credentials are used (RN sends none, booruApi.ts:882-955).
/// RN: `fetchDanbooruPosts` (booruApi.ts:882-955) and the Danbooru branch of `searchTags` (booruApi.ts:2490-2505).
struct DanbooruSource: BooruSource {
    let id: SourceID = .danbooru
    let displayName = "Danbooru"
    let supportsVideo = true
    /// RN sources.ts:21-23.
    private let baseURL = "https://danbooru.donmai.us"

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let limit = BooruQueryTranslator.pageLimit(for: query.filter)
        let tags = BooruQueryTranslator.tagString(for: query, source: id)
        let data = try await BooruJSONSupport.fetchData(
            baseURL: baseURL,
            path: "posts.json",
            items: BooruQueryTranslator.pagedPostItems(tags: tags, page: page, limit: limit),
            http: context.http
        )
        // RN :910-911. A non-array body yields no posts. Invalid JSON is an error, as in RN.
        let items = try BooruJSONSupport.decode(
            BooruLenientArray<DanbooruPostDTO>.self,
            from: data,
            failure: "Danbooru API did not return valid JSON."
        ).elements
        let posts = items.compactMap { mapPost($0) }
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// RN `mapPost` inside `fetchDanbooruPosts` (booruApi.ts:913-952).
    private func mapPost(_ dto: DanbooruPostDTO) -> BooruPost? {
        // RN :914. Keep only items with a file, large file, or preview URL.
        let hasMedia = [dto.fileURL, dto.largeFileURL, dto.previewFileURL].contains { !($0 ?? "").isEmpty }
        guard hasMedia else { return nil }

        // RN :916-918.
        let preview = BooruJSONSupport.firstNonEmpty(dto.previewFileURL, dto.largeFileURL, dto.fileURL)
        let sample = BooruJSONSupport.firstNonEmpty(dto.largeFileURL, dto.fileURL, dto.previewFileURL)
        let original = BooruJSONSupport.firstNonEmpty(dto.fileURL, dto.largeFileURL, dto.previewFileURL)

        let width = BooruJSONSupport.orDefault(dto.imageWidth, 800)
        let height = BooruJSONSupport.orDefault(dto.imageHeight, 1000)

        // RN :924-930. Category lists are deduplicated individually.
        let artist = BooruJSONSupport.uniqued(dto.tagStringArtist)
        let character = BooruJSONSupport.uniqued(dto.tagStringCharacter)
        let copyright = BooruJSONSupport.uniqued(dto.tagStringCopyright)
        let general = BooruJSONSupport.uniqued(dto.tagStringGeneral)
        let meta = BooruJSONSupport.uniqued(dto.tagStringMeta)
        // RN :930. allTags uses `tag_string` when present, otherwise the categories without meta.
        let allTags = BooruJSONSupport.uniqued(
            dto.tagString.isEmpty ? artist + character + copyright + general : dto.tagString
        )
        // RN :950. `created_at || now`.
        let rawCreatedAt = BooruJSONSupport.firstNonEmpty(dto.createdAt)
        let createdAt = rawCreatedAt.isEmpty ? BooruJSONSupport.isoString(Date()) : rawCreatedAt

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
            favCount: dto.favCount ?? 0,
            tags: BooruTagGroups(artist: artist, character: character, copyright: copyright, general: general, meta: meta),
            allTags: allTags,
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

    /// RN Danbooru branch of `searchTags` (booruApi.ts:2490-2505). Failures return an empty list. Cancellation still propagates.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        guard let query = BooruQueryTranslator.suggestionQuery(prefix) else { return [] }
        let limit = BooruQueryTranslator.suggestionLimit
        let found: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
            let data = try await BooruJSONSupport.fetchData(
                baseURL: baseURL,
                path: "tags.json",
                items: BooruQueryTranslator.danbooruTagItems(query: query, limit: limit),
                http: context.http
            )
            let tags = try BooruJSONSupport.decode(
                BooruLenientArray<DanbooruTagDTO>.self,
                from: data,
                failure: "Danbooru tag list did not return valid JSON."
            ).elements
            return tags.map { tag in
                BooruTagSuggestion(
                    name: tag.name ?? "",
                    category: DanbooruSource.category(for: tag.category),
                    postCount: tag.postCount ?? 0
                )
            }.filter { !$0.name.isEmpty }
        }
        return found ?? []
    }

    /// RN `mapDanbooruCategory` (booruApi.ts:94-107): 1 artist, 3 copyright, 4 character, 5 meta, otherwise general.
    static func category(for raw: Int?) -> TagCategory {
        switch raw ?? 0 {
        case 1: return .artist
        case 3: return .copyright
        case 4: return .character
        case 5: return .meta
        default: return .general
        }
    }

    // MARK: Media

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        BooruJSONSupport.resolvedMedia(for: post, quality: context.imageQuality)
    }
}
