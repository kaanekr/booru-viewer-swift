import Foundation

// MARK: - Lenient decoding helpers for the JSON / API adapters

/// Extra decoders used by the Cum.st, RedGifs, nhentai, and HentaiHaven DTOs on top of the
/// `booruString` / `booruInt` / `booruTagList` helpers in `BooruJSONModels.swift`.
/// One malformed array element is dropped by `BooruLenientArray` / `FailableDecodable`, so a single
/// bad item never fails the whole page.
extension KeyedDecodingContainer {
    /// Decodes one nested object, returning nil when the key is missing or the shape is wrong.
    func sourcesOptional<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            return nil
        }
    }

    /// A lenient array at `key`; a missing key, a null, or a non-array value yields no elements.
    func sourcesArray<T: Decodable>(_ key: Key, _ type: T.Type) -> [T] {
        do {
            return try decode(BooruLenientArray<T>.self, forKey: key).elements
        } catch {
            return []
        }
    }

    /// A lenient array keeping the raw positions, so a caller can derive stable per-item indexes.
    func sourcesRawArray<T: Decodable>(_ key: Key, _ type: T.Type) -> [FailableDecodable<T>] {
        do {
            return try decode([FailableDecodable<T>].self, forKey: key)
        } catch {
            return []
        }
    }

    /// JSON strings only; numbers and other types are dropped (RN `filter(t => typeof t === 'string')`).
    func sourcesStrings(_ key: Key) -> [String] {
        guard let items = try? decode([BooruLossyString].self, forKey: key) else { return [] }
        return items.compactMap { $0.value }
    }

    /// Strings and numeric ids rendered as strings (RN `String(n)`), e.g. RedGifs niches.
    func sourcesScalarStrings(_ key: Key) -> [String] {
        guard let items = try? decode([SourcesAPIScalar].self, forKey: key) else { return [] }
        return items.compactMap { $0.string }
    }

    /// A JSON bool; a wrong type yields nil.
    func sourcesBool(_ key: Key) -> Bool? {
        do {
            return try decodeIfPresent(Bool.self, forKey: key)
        } catch {
            return nil
        }
    }
}

/// One JSON scalar kept only when it is a string or an integer, rendered as a string.
struct SourcesAPIScalar: Decodable {
    let string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            string = text
        } else if let number = try? container.decode(Int.self) {
            string = String(number)
        } else {
            string = nil
        }
    }
}

// MARK: - Cum.st DTOs

/// `/api/v1/posts` and `/api/v1/posts/popular` body: `{"posts": [...]}` (booruApi.ts:2185-2190).
struct CumstPostsResponse: Decodable {
    let posts: [CumstPostDTO]

    enum CodingKeys: String, CodingKey {
        case posts
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            posts = []
            return
        }
        posts = container.sourcesArray(.posts, CumstPostDTO.self)
    }
}

/// One post. Only a missing id makes the element malformed; every other field is tolerated
/// (RN only walks `p.attachments`, booruApi.ts:2196-2200).
struct CumstPostDTO: Decodable {
    let id: String
    let creatorName: String?
    let creatorId: String?
    let service: String?
    let score: Int?
    /// RN falls back to `bookmarked` when `score` is absent; a bool is read as 1 / 0.
    let bookmarked: Int?
    let published: Int?
    let added: Int?
    let tags: [CumstTagDTO]
    /// Kept in raw order, including malformed entries, so ids stay stable.
    let attachments: [FailableDecodable<CumstAttachmentDTO>]

    enum CodingKeys: String, CodingKey {
        case id, creatorName, creatorId, service, score, bookmarked, published, added, tags, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = container.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: container, debugDescription: "Post id is missing.")
        }
        id = decodedID
        creatorName = container.booruString(.creatorName)
        creatorId = container.booruIDString(.creatorId)
        service = container.booruString(.service)
        score = container.booruInt(.score)
        bookmarked = container.booruInt(.bookmarked) ?? container.sourcesBool(.bookmarked).map { $0 ? 1 : 0 }
        published = container.booruInt(.published)
        added = container.booruInt(.added)
        tags = container.sourcesArray(.tags, CumstTagDTO.self)
        attachments = container.sourcesRawArray(.attachments, CumstAttachmentDTO.self)
    }
}

/// One attachment (`{sha256, kind, mimeType, originalFilename, width, height, bytes}`).
struct CumstAttachmentDTO: Decodable {
    let sha256: String?
    let kind: String?
    let mimeType: String?
    let originalFilename: String?
    let width: Int?
    let height: Int?
    let bytes: Int?

    enum CodingKeys: String, CodingKey {
        case sha256, kind, mimeType, originalFilename, width, height, bytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = container.booruString(.sha256)
        kind = container.booruString(.kind)
        mimeType = container.booruString(.mimeType)
        originalFilename = container.booruString(.originalFilename)
        width = container.booruInt(.width)
        height = container.booruInt(.height)
        bytes = container.booruInt(.bytes)
    }
}

/// One Cum.st tag: a plain string, or an object carrying `slug` / `label` (booruApi.ts:2223-2227).
struct CumstTagDTO: Decodable {
    let value: String?

    enum CodingKeys: String, CodingKey {
        case slug, label
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            value = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = BooruJSONSupport.firstNonEmpty(container.booruString(.slug), container.booruString(.label))
    }
}

// MARK: - RedGifs DTOs

/// `/v2/auth/temporary` body (booruApi.ts:1249-1262).
struct RedGifsTokenResponse: Decodable {
    let token: String?

    enum CodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            token = nil
            return
        }
        token = container.booruString(.token)
    }
}

/// `/v2/gifs/search`, `/v2/niches/{id}/gifs`, and `/v2/users/{name}/search` bodies.
struct RedGifsGifsResponse: Decodable {
    let gifs: [RedGifsGifDTO]
    let pages: Int?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case gifs, pages, total
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            gifs = []
            pages = nil
            total = nil
            return
        }
        gifs = container.sourcesArray(.gifs, RedGifsGifDTO.self)
        pages = container.booruInt(.pages)
        total = container.booruInt(.total)
    }
}

/// One gif record (booruApi.ts:1428-1470). A missing id makes the element malformed.
struct RedGifsGifDTO: Decodable {
    let id: String
    let width: Int?
    let height: Int?
    let likes: Int?
    let userName: String?
    let hasAudio: Bool?
    let createDate: Int?
    /// Strings only (RN `typeof t === 'string'`).
    let tags: [String]
    /// Niche ids; numbers are stringified (RN `String(n)`).
    let niches: [String]
    let urls: RedGifsURLsDTO?

    enum CodingKeys: String, CodingKey {
        case id, width, height, likes, userName, hasAudio, createDate, tags, niches, urls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = container.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: container, debugDescription: "Gif id is missing.")
        }
        id = decodedID
        width = container.booruInt(.width)
        height = container.booruInt(.height)
        likes = container.booruInt(.likes)
        userName = container.booruString(.userName)
        hasAudio = container.sourcesBool(.hasAudio)
        createDate = container.booruInt(.createDate)
        tags = container.sourcesStrings(.tags)
        niches = container.sourcesScalarStrings(.niches)
        urls = container.sourcesOptional(.urls, RedGifsURLsDTO.self)
    }
}

/// Media URLs of one gif (booruApi.ts:1429-1436).
struct RedGifsURLsDTO: Decodable {
    let hd: String?
    let sd: String?
    let silent: String?
    let thumbnail: String?
    let poster: String?

    enum CodingKeys: String, CodingKey {
        case hd, sd, silent, thumbnail, poster
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            hd = nil
            sd = nil
            silent = nil
            thumbnail = nil
            poster = nil
            return
        }
        hd = container.booruString(.hd)
        sd = container.booruString(.sd)
        silent = container.booruString(.silent)
        thumbnail = container.booruString(.thumbnail)
        poster = container.booruString(.poster)
    }
}

/// `/v2/search/suggest` entry: `{text, gifs}` (booruApi.ts:2388-2403).
struct RedGifsSuggestionDTO: Decodable {
    let text: String?
    let gifs: Int?

    enum CodingKeys: String, CodingKey {
        case text, gifs
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            text = nil
            gifs = nil
            return
        }
        text = container.booruString(.text)
        gifs = container.booruInt(.gifs)
    }
}

/// `/v2/search/suggest` answers with a bare array; any other shape yields no suggestions.
struct RedGifsSuggestionsResponse: Decodable {
    let suggestions: [RedGifsSuggestionDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let wrapped = (try? container.decode([FailableDecodable<RedGifsSuggestionDTO>].self)) ?? []
        suggestions = wrapped.compactMap { $0.value }
    }
}

// MARK: - nhentai DTOs

/// `/api/v2/galleries` and `/api/v2/search` bodies: either a bare array or `{"result": [...]}`.
struct NHentaiListingResponse: Decodable {
    let galleries: [NHentaiGalleryDTO]

    enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let array = try? single.decode([FailableDecodable<NHentaiGalleryDTO>].self) {
            galleries = array.compactMap { $0.value }
            return
        }
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            galleries = []
            return
        }
        galleries = container.sourcesArray(.result, NHentaiGalleryDTO.self)
    }
}

/// One gallery from a listing (nhentai.ts:207-270). `id` and `media_id` are required.
struct NHentaiGalleryDTO: Decodable {
    let id: String
    let mediaID: String
    let englishTitle: String?
    let japaneseTitle: String?
    let thumbnail: String?
    let thumbnailWidth: Int?
    let thumbnailHeight: Int?
    let numFavorites: Int?
    let numPages: Int?
    let blacklisted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, thumbnail, blacklisted
        case mediaID = "media_id"
        case englishTitle = "english_title"
        case japaneseTitle = "japanese_title"
        case thumbnailWidth = "thumbnail_width"
        case thumbnailHeight = "thumbnail_height"
        case numFavorites = "num_favorites"
        case numPages = "num_pages"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = container.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: container, debugDescription: "Gallery id is missing.")
        }
        guard let decodedMediaID = container.booruIDString(.mediaID), !decodedMediaID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.mediaID, in: container, debugDescription: "Gallery media id is missing.")
        }
        id = decodedID
        mediaID = decodedMediaID
        englishTitle = container.booruString(.englishTitle)
        japaneseTitle = container.booruString(.japaneseTitle)
        thumbnail = container.booruString(.thumbnail)
        thumbnailWidth = container.booruInt(.thumbnailWidth)
        thumbnailHeight = container.booruInt(.thumbnailHeight)
        numFavorites = container.booruInt(.numFavorites)
        numPages = container.booruInt(.numPages)
        blacklisted = container.sourcesBool(.blacklisted)
    }
}

/// `/api/v2/galleries/{id}` body (nhentai.ts:286-410). v2 `pages` is preferred, the v1
/// `images.pages` shape stays supported, and both tolerate individual malformed entries.
struct NHentaiGalleryDetailDTO: Decodable {
    let mediaID: String?
    let numPages: Int?
    let numFavorites: Int?
    let pages: [NHentaiPageDTO]
    let legacyPages: [NHentaiLegacyPageDTO]
    let tags: [NHentaiTagDTO]

    enum CodingKeys: String, CodingKey {
        case pages, tags, images
        case mediaID = "media_id"
        case numPages = "num_pages"
        case numFavorites = "num_favorites"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = container.booruIDString(.mediaID)
        numPages = container.booruInt(.numPages)
        numFavorites = container.booruInt(.numFavorites)
        pages = container.sourcesArray(.pages, NHentaiPageDTO.self)
        tags = container.sourcesArray(.tags, NHentaiTagDTO.self)
        legacyPages = container.sourcesOptional(.images, NHentaiLegacyImagesDTO.self)?.pages ?? []
    }
}

/// v1 `images` object.
struct NHentaiLegacyImagesDTO: Decodable {
    let pages: [NHentaiLegacyPageDTO]

    enum CodingKeys: String, CodingKey {
        case pages
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            pages = []
            return
        }
        pages = container.sourcesArray(.pages, NHentaiLegacyPageDTO.self)
    }
}

/// One v2 page: `{number, path, width, height}`, or a bare path string (nhentai.ts:290-310).
struct NHentaiPageDTO: Decodable {
    let number: Int?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case number, path
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            number = nil
            path = text
            return
        }
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        number = container?.booruInt(.number)
        path = container?.booruString(.path)
    }
}

/// One v1 page: `{path, t}` where `t` is the CDN extension letter.
struct NHentaiLegacyPageDTO: Decodable {
    let path: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case path
        case type = "t"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        path = container?.booruString(.path)
        type = container?.booruString(.type)
    }
}

/// One tag from a gallery detail or the tag search: `{name, type, count}`.
struct NHentaiTagDTO: Decodable {
    let name: String?
    /// `artist`, `group`, `character`, `parody`, `tag`, `language`, `category`.
    let type: String?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case name, type, count
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            name = nil
            type = nil
            count = nil
            return
        }
        name = container.booruString(.name)
        type = container.booruString(.type)
        count = container.booruInt(.count)
    }
}

// MARK: - HentaiHaven DTOs

/// One selectable series episode surfaced to the viewer. `id` is the API `chapter_id`
/// (or a stable `seriesID_number` fallback), and `streamURL` already carries the direct HLS
/// stream from `chapter_content` or the MP4 `preview` fallback when the detail response had it.
struct HentaiHavenEpisode: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let title: String
    let streamURL: URL?
    let thumbnailURL: URL?
}

/// Every v1 endpoint answers with `{"data": ...}` (hentaihavens.ts:117-127).
struct HentaiHavenEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            data = nil
            return
        }
        data = container.sourcesOptional(.data, Payload.self)
    }
}

/// `/warden` payload: `{"data": {"token": "..."}}`.
struct HentaiHavenWardenDTO: Decodable {
    let token: String?

    enum CodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            token = nil
            return
        }
        token = container.booruString(.token)
    }
}

/// `/hentai/all` and `/genre/{id}` body: `{"data": {"hentais": [...]}}`.
struct HentaiHavenListingDTO: Decodable {
    let hentais: [HentaiHavenItemDTO]

    enum CodingKeys: String, CodingKey {
        case hentais
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            hentais = []
            return
        }
        hentais = container.sourcesArray(.hentais, HentaiHavenItemDTO.self)
    }
}

/// `/search?q=` answers with a bare array of items.
struct HentaiHavenItemList: Decodable {
    let items: [HentaiHavenItemDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let wrapped = (try? container.decode([FailableDecodable<HentaiHavenItemDTO>].self)) ?? []
        items = wrapped.compactMap { $0.value }
    }
}

/// `/genre/all` answers with a bare array of terms.
struct HentaiHavenTermList: Decodable {
    let terms: [HentaiHavenTermDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let wrapped = (try? container.decode([FailableDecodable<HentaiHavenTermDTO>].self)) ?? []
        terms = wrapped.compactMap { $0.value }
    }
}

/// One series card (hentaihavens.ts:739-780).
struct HentaiHavenItemDTO: Decodable {
    let postID: Int?
    let postName: String?
    let postTitle: String?
    let postThumbnail: String?
    let postViews: Int?
    let postDate: String?

    enum CodingKeys: String, CodingKey {
        case postID = "post_ID"
        case postName = "post_name"
        case postTitle = "post_title"
        case postThumbnail = "post_thumbnail"
        case postViews = "post_views"
        case postDate = "post_date"
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            postID = nil
            postName = nil
            postTitle = nil
            postThumbnail = nil
            postViews = nil
            postDate = nil
            return
        }
        postID = container.booruInt(.postID)
        postName = container.booruString(.postName)
        postTitle = container.booruString(.postTitle)
        postThumbnail = container.booruString(.postThumbnail)
        postViews = container.booruInt(.postViews)
        postDate = container.booruString(.postDate)
    }
}

/// One chapter from `last_episodes` or a series detail (hentaihavens.ts:783-830, 1300-1330).
struct HentaiHavenEpisodeDTO: Decodable {
    let chapterID: String?
    let chapterName: String?
    let chapterSlug: String?
    /// Direct HLS stream URL.
    let chapterContent: String?
    let chapterThumbnail: String?
    let chapterDate: String?
    /// Direct MP4 fallback.
    let preview: String?
    let postID: Int?
    let postName: String?
    let postTitle: String?
    let postThumbnail: String?

    enum CodingKeys: String, CodingKey {
        case preview
        case chapterID = "chapter_id"
        case chapterName = "chapter_name"
        case chapterSlug = "chapter_slug"
        case chapterContent = "chapter_content"
        case chapterThumbnail = "chapter_thumbnail"
        case chapterDate = "chapter_date"
        case postID = "post_ID"
        case postName = "post_name"
        case postTitle = "post_title"
        case postThumbnail = "post_thumbnail"
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            chapterID = nil
            chapterName = nil
            chapterSlug = nil
            chapterContent = nil
            chapterThumbnail = nil
            chapterDate = nil
            preview = nil
            postID = nil
            postName = nil
            postTitle = nil
            postThumbnail = nil
            return
        }
        chapterID = container.booruIDString(.chapterID)
        chapterName = container.booruString(.chapterName)
        chapterSlug = container.booruString(.chapterSlug)
        chapterContent = container.booruString(.chapterContent)
        chapterThumbnail = container.booruString(.chapterThumbnail)
        chapterDate = container.booruString(.chapterDate)
        preview = container.booruString(.preview)
        postID = container.booruInt(.postID)
        postName = container.booruString(.postName)
        postTitle = container.booruString(.postTitle)
        postThumbnail = container.booruString(.postThumbnail)
    }
}

/// `/hentai/home` sections (hentaihavens.ts:832-842). Only the two streams this layer reads are kept.
struct HentaiHavenHomeDTO: Decodable {
    let trendingMonth: [HentaiHavenItemDTO]
    let lastEpisodes: [HentaiHavenEpisodeDTO]

    enum CodingKeys: String, CodingKey {
        case trendingMonth = "trending_month"
        case lastEpisodes = "last_episodes"
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            trendingMonth = []
            lastEpisodes = []
            return
        }
        trendingMonth = container.sourcesArray(.trendingMonth, HentaiHavenItemDTO.self)
        lastEpisodes = container.sourcesArray(.lastEpisodes, HentaiHavenEpisodeDTO.self)
    }
}

/// `/hentai/{id}` body (hentaihavens.ts:1290-1360).
struct HentaiHavenDetailDTO: Decodable {
    let postID: Int?
    let postName: String?
    let postTitle: String?
    let postViews: Int?
    let postContent: String?
    let genres: [HentaiHavenTermDTO]
    let tags: [HentaiHavenTermDTO]
    let authors: [HentaiHavenTermDTO]
    let episodes: [HentaiHavenEpisodeDTO]

    enum CodingKeys: String, CodingKey {
        case postID = "post_ID"
        case postName = "post_name"
        case postTitle = "post_title"
        case postViews = "post_views"
        case postContent = "post_content"
        case genres = "post_genres"
        case tags = "post_tags"
        case authors = "post_authors"
        case episodes = "post_episodes"
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            postID = nil
            postName = nil
            postTitle = nil
            postViews = nil
            postContent = nil
            genres = []
            tags = []
            authors = []
            episodes = []
            return
        }
        postID = container.booruInt(.postID)
        postName = container.booruString(.postName)
        postTitle = container.booruString(.postTitle)
        postViews = container.booruInt(.postViews)
        postContent = container.booruString(.postContent)
        genres = container.sourcesArray(.genres, HentaiHavenTermDTO.self)
        tags = container.sourcesArray(.tags, HentaiHavenTermDTO.self)
        authors = container.sourcesArray(.authors, HentaiHavenTermDTO.self)
        episodes = container.sourcesArray(.episodes, HentaiHavenEpisodeDTO.self)
    }
}

/// One genre / studio / tag term: `{term_id, name, slug, count}`.
struct HentaiHavenTermDTO: Decodable {
    let termID: Int?
    let name: String?
    let slug: String?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case name, slug, count
        case termID = "term_id"
    }

    /// Used by the static genre pool that fills in terms missing from `genre/all`.
    init(termID: Int, name: String, slug: String, count: Int) {
        self.termID = termID
        self.name = name
        self.slug = slug
        self.count = count
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            termID = nil
            name = nil
            slug = nil
            count = nil
            return
        }
        termID = container.booruInt(.termID)
        name = container.booruString(.name)
        slug = container.booruString(.slug)
        count = container.booruInt(.count)
    }
}
