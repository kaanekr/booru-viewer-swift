import Foundation

/// Mirrors RN `SortOption` (src/types/booru.ts:82). Raw values equal the RN strings.
enum SortOrder: String, Codable, CaseIterable, Sendable {
    case `default` = "default"
    case id = "id"
    case score = "score"
    case rating = "rating"
    case user = "user"
    case height = "height"
    case width = "width"
}

/// Mirrors RN `TimeRangeOption` (src/types/booru.ts:83).
enum TimeRange: String, Codable, CaseIterable, Sendable {
    case all = "all"
    case oneDay = "1d"
    case oneWeek = "1w"
    case oneMonth = "1m"
    case oneYear = "1y"
}

/// Mirrors RN `RatingFilterOption` (src/types/booru.ts:84).
enum RatingFilter: String, Codable, CaseIterable, Sendable {
    case all = "all"
    case safe = "safe"
    case questionable = "questionable"
    case explicit = "explicit"
}

/// Mirrors RN `CumstMediaTypeOption` (src/types/booru.ts:86). Field name `cumstMediaType`.
enum MediaTypeFilter: String, Codable, CaseIterable, Sendable {
    case all = "all"
    case photos = "photos"
    case videos = "videos"
    case audio = "audio"
}

/// Mirrors RN `CumstServiceOption` (src/types/booru.ts:85). Field name `cumstService`.
enum PlatformFilter: String, Codable, CaseIterable, Sendable {
    case all = "all"
    case onlyfans = "onlyfans"
    case fansly = "fansly"
}

/// Mirrors RN `HentaiHavenFeedSection` (src/types/booru.ts:94-102).
enum HentaiHavenFeedSection: String, Codable, CaseIterable, Sendable {
    case latest = "latest"
    case trending = "trending"
    case episodes = "episodes"
    case yuri = "yuri"
    case ecchi = "ecchi"
    case incest = "incest"
    case tentacle = "tentacle"
    case uncensored = "uncensored"
}

/// Mirrors RN `SearchFilterConfig` (src/types/booru.ts:104-119).
/// Default values mirror RN `DEFAULT_FILTER_CONFIG` (src/types/booru.ts:121-134).
struct SearchFilterConfig: Codable, Equatable, Sendable {
    var tags: [String] = []
    var sortBy: SortOrder = .default
    var timeRange: TimeRange = .all
    var rating: RatingFilter = .all
    /// RN `minScore` (booru.ts:109).
    var minScore: Int? = nil
    /// RN `user` (booru.ts:110).
    var user: String? = nil
    /// RN `cumstService` (booru.ts:111).
    var cumstService: PlatformFilter? = .all
    /// RN `cumstMediaType` (booru.ts:112).
    var cumstMediaType: MediaTypeFilter? = .all
    /// RN `leaderboardDate` (booru.ts:113).
    var leaderboardDate: String? = nil
    var jumpToPage: Int = 1
    var includeBlacklisted: Bool = false
    var autocompleteFromServer: Bool = true
    /// Backs the HentaiHaven Explore feed; ignored by other sources (booru.ts:117-118).
    var hentaiHavenSection: HentaiHavenFeedSection? = nil

    /// JSON keys equal the property names; encoded output is unchanged.
    enum CodingKeys: String, CodingKey {
        case tags, sortBy, timeRange, rating, minScore, user, cumstService, cumstMediaType
        case leaderboardDate, jumpToPage, includeBlacklisted, autocompleteFromServer, hentaiHavenSection
    }
}

extension SearchFilterConfig {
    /// Missing keys take the same defaults as the property defaults, so a partial stored object still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sortBy = try c.decodeIfPresent(SortOrder.self, forKey: .sortBy) ?? SortOrder.default
        timeRange = try c.decodeIfPresent(TimeRange.self, forKey: .timeRange) ?? TimeRange.all
        rating = try c.decodeIfPresent(RatingFilter.self, forKey: .rating) ?? RatingFilter.all
        minScore = try c.decodeIfPresent(Int.self, forKey: .minScore)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        cumstService = try c.decodeIfPresent(PlatformFilter.self, forKey: .cumstService) ?? PlatformFilter.all
        cumstMediaType = try c.decodeIfPresent(MediaTypeFilter.self, forKey: .cumstMediaType) ?? MediaTypeFilter.all
        leaderboardDate = try c.decodeIfPresent(String.self, forKey: .leaderboardDate)
        jumpToPage = try c.decodeIfPresent(Int.self, forKey: .jumpToPage) ?? 1
        includeBlacklisted = try c.decodeIfPresent(Bool.self, forKey: .includeBlacklisted) ?? false
        autocompleteFromServer = try c.decodeIfPresent(Bool.self, forKey: .autocompleteFromServer) ?? true
        hentaiHavenSection = try c.decodeIfPresent(HentaiHavenFeedSection.self, forKey: .hentaiHavenSection)
    }
}
