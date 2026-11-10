import Foundation

/// Mirrors RN `BooruPost` (src/types/booru.ts:27-60).
/// URL-typed fields are `URL?`. Empty or invalid URL strings decode as nil (see the decoder extension),
/// so one bad URL does not fail a whole backup import.
struct BooruPost: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// RN `sourceId` (booru.ts:29). Unknown legacy source strings fail to decode here;
    /// `BackupSchema` drops such posts individually instead of failing the whole backup.
    var sourceID: SourceID
    /// RN `sourceName` (booru.ts:30).
    var sourceName: String
    /// Content title on video sources (booru.ts:31-32).
    var title: String?
    /// RN `previewUrl` (booru.ts:33). An empty or invalid RN string decodes as nil; UI must nil-check.
    var previewURL: URL?
    /// Static cover tried if `previewURL` fails, e.g. RedGifs poster (booru.ts:34-35).
    var previewFallbackURL: URL?
    /// RN `previewVideoUrl` (booru.ts:36).
    var previewVideoURL: URL?
    /// RN `previewThumbUrl` (booru.ts:37).
    var previewThumbURL: URL?
    /// RN `previewThumbs` (booru.ts:38).
    var previewThumbs: [URL]?
    /// RN `sampleUrl` (booru.ts:39). An empty or invalid RN string decodes as nil; UI must nil-check.
    var sampleURL: URL?
    /// RN `originalUrl` (booru.ts:40). An empty or invalid RN string decodes as nil; UI must nil-check.
    var originalURL: URL?
    /// RN `width` (booru.ts:41).
    var width: Int
    /// RN `height` (booru.ts:42).
    var height: Int
    /// RN `aspectRatio` (booru.ts:43).
    var aspectRatio: Double
    /// RN `rating` codes 's' | 'q' | 'e' | 'g' (booru.ts:44).
    var rating: PostRating
    /// RN `score` (booru.ts:45).
    var score: Int
    /// RN `favCount` (booru.ts:46).
    var favCount: Int
    /// RN `tags` (booru.ts:47).
    var tags: BooruTagGroups
    /// RN `allTags` (booru.ts:48).
    var allTags: [String]
    /// RN `sourceLink` (booru.ts:49).
    var sourceLink: URL?
    /// RN `fileExt` (booru.ts:50).
    var fileExt: String?
    /// RN `fileSize` (booru.ts:51).
    var fileSize: Int?
    /// Raw RN string. The date format varies by source (booru.ts:52).
    var createdAt: String
    /// RedGifs niche ids, e.g. "3-somes" (booru.ts:53-54).
    var niches: [String]?
    /// Premium-locked content: filtered from lists, the preview plays in the viewer (booru.ts:55-56).
    var isPremium: Bool?
    /// Manga / doujinshi page count (booru.ts:57-58).
    var pageCount: Int?
    /// Media id, e.g. nhentai (booru.ts:57-59).
    var mediaId: String?

    /// JSON keys are the exact RN field names.
    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "sourceId"
        case sourceName
        case title
        case previewURL = "previewUrl"
        case previewFallbackURL = "previewFallbackUrl"
        case previewVideoURL = "previewVideoUrl"
        case previewThumbURL = "previewThumbUrl"
        case previewThumbs
        case sampleURL = "sampleUrl"
        case originalURL = "originalUrl"
        case width, height, aspectRatio, rating, score, favCount, tags, allTags
        case sourceLink, fileExt, fileSize, createdAt, niches, isPremium, pageCount, mediaId
    }
}

extension BooruPost {
    /// Tolerant URL decoding: missing, null, empty, or unparseable strings become nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceID = try c.decode(SourceID.self, forKey: .sourceID)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        previewURL = BooruPost.lenientURL(c, .previewURL)
        previewFallbackURL = BooruPost.lenientURL(c, .previewFallbackURL)
        previewVideoURL = BooruPost.lenientURL(c, .previewVideoURL)
        previewThumbURL = BooruPost.lenientURL(c, .previewThumbURL)
        previewThumbs = try c.decodeIfPresent([String].self, forKey: .previewThumbs)?.compactMap { URL(string: $0) }
        sampleURL = BooruPost.lenientURL(c, .sampleURL)
        originalURL = BooruPost.lenientURL(c, .originalURL)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        aspectRatio = try c.decode(Double.self, forKey: .aspectRatio)
        rating = try c.decode(PostRating.self, forKey: .rating)
        score = try c.decode(Int.self, forKey: .score)
        favCount = try c.decode(Int.self, forKey: .favCount)
        tags = try c.decode(BooruTagGroups.self, forKey: .tags)
        allTags = try c.decode([String].self, forKey: .allTags)
        sourceLink = BooruPost.lenientURL(c, .sourceLink)
        fileExt = try c.decodeIfPresent(String.self, forKey: .fileExt)
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        niches = try c.decodeIfPresent([String].self, forKey: .niches)
        isPremium = try c.decodeIfPresent(Bool.self, forKey: .isPremium)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        mediaId = try c.decodeIfPresent(String.self, forKey: .mediaId)
    }

    private static func lenientURL(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let raw = try? c.decodeIfPresent(String.self, forKey: key), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
