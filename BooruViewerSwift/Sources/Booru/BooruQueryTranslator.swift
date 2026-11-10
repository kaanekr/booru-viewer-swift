import Foundation

/// Pure translation of `SearchQuery` into the RN booru search syntax and URL query items.
/// Mirrors RN `buildQueryTags` (src/services/booruApi.ts:248-383) for the Gelbooru, Rule34, Danbooru,
/// and Moebooru (yande.re) engines. It also holds the Gelbooru lower-bound walk math (booruApi.ts:82-92, 677-734).
/// No I/O: the walk's network requests live in `GelbooruSource`.
enum BooruQueryTranslator {
    // MARK: Limits (RN booruApi.ts:90-92; SearchScreen.tsx:360, 501; FeedScreen.tsx:160; SearchScreen.tsx:314)

    static let defaultPageLimit = 24
    static let jumpPageLimit = 100
    static let suggestionLimit = 12
    static let boundWalkLimit = 100
    static let boundMaxPages = 15
    static let boundCacheTTL: TimeInterval = 5 * 60

    /// RN fixed page size: 100 for jump searches, otherwise 24 (SearchScreen.tsx:360).
    static func pageLimit(for filter: SearchFilterConfig) -> Int {
        filter.jumpToPage > 1 ? jumpPageLimit : defaultPageLimit
    }

    // MARK: Search text (RN buildQueryTags, booruApi.ts:248-383)

    /// Base search text. RN joins the trimmed `filter.tags` entries (booruApi.ts:252-258).
    /// The raw `query.tags` text wins when it is non-empty; otherwise the structured `filter.tags` list is used. Callers should supply only one of the two.
    static func baseTags(for query: SearchQuery) -> String {
        let raw = query.tags.booruTrimmed
        if !raw.isEmpty {
            return raw
        }
        return query.filter.tags.map { $0.booruTrimmed }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Full RN-style search text for one of the four engines. Order matches RN: base, score, user, leaderboard date, rating, sort/time.
    static func tagString(for query: SearchQuery, source: SourceID, now: Date = Date(), calendar: Calendar = BooruQueryTranslator.gregorianLocal()) -> String {
        let filter = query.filter
        var parts: [String] = []

        let base = baseTags(for: query)
        if !base.isEmpty {
            parts.append(base)
        }
        // RN :260-263. Minimum score is only sent when it is positive.
        if let minScore = filter.minScore, minScore > 0 {
            parts.append("score:>=\(minScore)")
        }
        // RN :265-275. These four engines all use `user:` syntax.
        if let user = filter.user?.booruTrimmed, !user.isEmpty {
            parts.append("user:\(user)")
        }
        // RN :287-296. Raw value is checked for truthiness, then trimmed (non-cumst branch).
        if let leaderboard = filter.leaderboardDate, !leaderboard.isEmpty {
            parts.append("date:\(leaderboard.booruTrimmed)")
        }
        if let rating = ratingTag(filter.rating, source: source) {
            parts.append(rating)
        }
        parts += sortTags(filter, source: source, now: now, calendar: calendar)
        return parts.joined(separator: " ").booruTrimmed
    }

    /// Rating filter syntax per engine (RN :298-310). `.all` sends nothing.
    static func ratingTag(_ rating: RatingFilter, source: SourceID) -> String? {
        let table: [RatingFilter: String]
        switch source {
        case .danbooru:
            table = [.safe: "rating:g", .questionable: "rating:q", .explicit: "rating:e"]
        case .yandere:
            table = [.safe: "rating:s", .questionable: "rating:q", .explicit: "rating:e"]
        case .gelbooru:
            table = [.safe: "rating:general", .questionable: "rating:questionable", .explicit: "rating:explicit"]
        case .rule34:
            table = [.safe: "rating:safe", .questionable: "rating:questionable", .explicit: "rating:explicit"]
        default:
            return nil
        }
        return table[rating]
    }

    /// Sort and time-range syntax per engine (RN :312-380).
    /// Gelbooru-engine time windows are not expressed here. They use the id-bound walk (`gelbooruWindowDays`).
    static func sortTags(_ filter: SearchFilterConfig, source: SourceID, now: Date, calendar: Calendar) -> [String] {
        switch source {
        case .gelbooru, .rule34:
            switch filter.sortBy {
            case .score: return ["sort:score:desc"]
            case .id: return ["sort:id:desc"]
            case .height: return ["sort:height:desc"]
            case .width: return ["sort:width:desc"]
            default: return []
            }
        case .danbooru:
            switch filter.sortBy {
            case .score:
                // RN :321-333. Ranges use `<`; `age:1w` would match only week-old posts (verified live in RN).
                switch filter.timeRange {
                case .oneDay: return ["age:<1day", "order:score"]
                case .oneWeek: return ["age:<1week", "order:score"]
                case .oneMonth: return ["age:<1month", "order:score"]
                case .oneYear: return ["age:<1year", "order:score"]
                case .all: return ["order:score"]
                }
            case .id: return ["order:id"]
            case .height: return ["order:height"]
            case .width: return ["order:width"]
            default: return []
            }
        case .yandere:
            switch filter.sortBy {
            case .score:
                // RN :334-342. `date:START..END` ranges work on Moebooru; keyword dates return nothing.
                let days = timeRangeDays(filter.timeRange)
                guard days > 0 else { return ["order:score"] }
                let start = pastYMD(daysAgo: days, now: now, calendar: calendar)
                return ["order:score", "date:\(start)..\(ymd(now, calendar: calendar))"]
            case .id: return ["order:id_desc"]
            case .height: return ["order:height"]
            case .width: return ["order:width"]
            default: return []
            }
        default:
            return []
        }
    }

    /// RN `timeRangeToDays` (booruApi.ts:143-149). `all` returns 0 (no window).
    static func timeRangeDays(_ range: TimeRange) -> Int {
        switch range {
        case .all: return 0
        case .oneDay: return 1
        case .oneWeek: return 7
        case .oneMonth: return 30
        case .oneYear: return 365
        }
    }

    // MARK: Gelbooru lower-bound walk (RN booruApi.ts:677-734)

    /// Window in days for the id-bound walk. Only score sorting with a time range uses the walk (booruApi.ts:675-676).
    /// `.all` returns 0, so All Time sends `sort:score:desc` alone and the server ranks every post.
    static func gelbooruWindowDays(for filter: SearchFilterConfig) -> Int {
        filter.sortBy == .score ? timeRangeDays(filter.timeRange) : 0
    }

    /// Walk tags: the first `sort:score:desc` becomes `sort:id:desc` (booruApi.ts:681, JS `replace` replaces the first match only).
    static func gelbooruWalkTags(_ tags: String) -> String {
        replacingFirst(in: tags, "sort:score:desc", with: "sort:id:desc")
    }

    /// Final tags that bound the post ids: `<tags> id:>(bound-1)` (booruApi.ts:689).
    /// RN keeps a leading space when tags are empty. This code omits it. The server treats both the same.
    static func gelbooruBoundedTags(_ tags: String, lowerBound: Int) -> String {
        [tags, "id:>\(lowerBound - 1)"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Oldest acceptable post time for the walk: `now - windowDays` (booruApi.ts:708).
    static func gelbooruBoundCutoff(windowDays: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(windowDays) * 86_400)
    }

    /// Zero-based DAPI page index: `max(0, page - 1)` (booruApi.ts:684, 693).
    static func gelbooruPID(page: Int) -> Int {
        max(0, page - 1)
    }

    // MARK: URL query items

    /// DAPI post index parameters (booruApi.ts:745-755). Credentials are appended separately by the source.
    static func gelbooruPostItems(tags: String, pid: Int, limit: Int) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: "dapi"),
            URLQueryItem(name: "s", value: "post"),
            URLQueryItem(name: "q", value: "index"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "pid", value: String(max(0, pid))),
        ]
        if !tags.isEmpty {
            items.append(URLQueryItem(name: "tags", value: tags))
        }
        return items
    }

    /// `page`, `limit`, and `tags` for `posts.json` (Danbooru) and `post.json` (Moebooru), booruApi.ts:890-896, 964-971.
    static func pagedPostItems(tags: String, page: Int, limit: Int) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !tags.isEmpty {
            items.append(URLQueryItem(name: "tags", value: tags))
        }
        return items
    }

    /// `page=autocomplete2&type=tag_query` (booruApi.ts:2297).
    static func gelbooruAutocompleteItems(term: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "page", value: "autocomplete2"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "type", value: "tag_query"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    /// DAPI tag list search, ordered by count (booruApi.ts:2329-2338).
    static func gelbooruTagListItems(name: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "page", value: "dapi"),
            URLQueryItem(name: "s", value: "tag"),
            URLQueryItem(name: "q", value: "index"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "name_pattern", value: "%\(name)%"),
            URLQueryItem(name: "orderby", value: "count"),
            URLQueryItem(name: "order", value: "DESC"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    /// `autocomplete.php?q=` used by Rule34 and Realbooru (booruApi.ts:2413).
    static func gelbooruAutocompletePHPItems(query: String) -> [URLQueryItem] {
        [URLQueryItem(name: "q", value: query)]
    }

    /// Danbooru `tags.json` wildcard name search ordered by count (booruApi.ts:2491).
    static func danbooruTagItems(query: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "search[name_matches]", value: "*\(query)*"),
            URLQueryItem(name: "search[order]", value: "count"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    /// Moebooru `tag.json` exact-name search ordered by count (booruApi.ts:2507).
    static func moebooruTagItems(query: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "order", value: "count"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    // MARK: Suggestion input

    /// RN `searchTags` input rule: the trimmed text must be at least 2 UTF-16 units (booruApi.ts:2291).
    static func suggestionQuery(_ prefix: String) -> String? {
        let trimmed = prefix.booruTrimmed
        return trimmed.utf16.count >= 2 ? trimmed : nil
    }

    // MARK: Date helpers (RN formatYMD / pastYMD, booruApi.ts:130-140)

    /// Gregorian calendar in the device time zone, matching RN local `Date` getters.
    static func gregorianLocal() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// `YYYY-MM-DD` in the given calendar (RN `formatYMD`).
    static func ymd(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(twoDigits(parts.month ?? 0))-\(twoDigits(parts.day ?? 0))"
    }

    /// `YYYY-MM-DD` for `daysAgo` before `now` (RN `pastYMD`).
    static func pastYMD(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        ymd(calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now, calendar: calendar)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Replaces only the first occurrence, like JS `String.prototype.replace` with a string pattern.
    static func replacingFirst(in text: String, _ target: String, with replacement: String) -> String {
        guard let range = text.range(of: target) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
}
