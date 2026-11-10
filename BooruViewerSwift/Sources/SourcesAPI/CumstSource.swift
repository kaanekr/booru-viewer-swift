import Foundation

/// Cum.st adapter (`id` `cumst`). No credentials are used.
/// RN: `fetchCumStPosts` (booruApi.ts:2097-2290) and the Cum.st branch of `buildQueryTags` (booruApi.ts:263-285, 341-378).
///
/// The search text is the RN transport for Cum.st options: `service:` / `type:` carry the
/// `cumstService` / `cumstMediaType` filters, `creator:` the user field, `period:` / `sort:` the sort,
/// and `date:` the snapped leaderboard anchor. `searchTags(for:)` builds that text and
/// `requestURL(tags:page:)` turns it back into one of the two endpoints.
struct CumstSource: BooruSource {
    let id: SourceID = .cumst
    let displayName = "Cum.st"
    let supportsVideo = true

    /// RN sources.ts:45-51.
    static let baseURL = "https://cum.st"
    /// RN booruApi.ts:2099: `o = (page - 1) * 50`, and every request is fixed at 50 items.
    static let pageSize = 50
    /// RN booruApi.ts:2169-2181: one fast retry after a 5xx, pausing 300 ms.
    static let retryDelayNanoseconds: UInt64 = 300_000_000
    /// RN booruApi.ts:2211-2212 attachment hosts.
    static let thumbnailBase = "https://img.cum.st/thumbnail"
    static let mediaBase = "https://e1.cum.st/media"
    /// RN booruApi.ts:2148: periods that may use the keywordless popular endpoint.
    static let leaderboardPeriods = ["day", "week", "month"]

    // MARK: - Search text (RN buildQueryTags, Cum.st branch)

    /// Cum.st branch of RN `buildQueryTags` (booruApi.ts:263-285, 341-378): base tags, minimum score,
    /// `creator:` for the user field, the service and media-type filters, the snapped date anchor, and sort tokens.
    /// The rating filter is omitted: RN has no Cum.st rating syntax (booruApi.ts:298-310).
    static func searchTags(for query: SearchQuery) -> String {
        let filter = query.filter
        var parts: [String] = []

        let base = BooruQueryTranslator.baseTags(for: query)
        if !base.isEmpty {
            parts.append(base)
        }
        // RN :260-263. Cum.st is not in the "no score filter" list, so the threshold is sent.
        if let minScore = filter.minScore, minScore > 0 {
            parts.append("score:>=\(minScore)")
        }
        // RN :265-275. Cum.st uses `creator:` instead of `user:`.
        if let user = filter.user?.booruTrimmed, !user.isEmpty {
            parts.append("creator:\(user)")
        }
        // RN :277-285.
        if let service = filter.cumstService, service != .all {
            parts.append("service:\(service.rawValue)")
        }
        if let mediaType = filter.cumstMediaType, mediaType != .all {
            parts.append("type:\(mediaType.rawValue)")
        }
        // RN :287-296, with the Cum.st anchor snapping.
        if let anchor = filter.leaderboardDate?.booruTrimmed, !anchor.isEmpty {
            parts.append("date:\(snappedAnchor(anchor, timeRange: filter.timeRange))")
        }
        parts += sortTags(filter)
        return parts.joined(separator: " ").booruTrimmed
    }

    /// Sort tokens (booruApi.ts:341-378).
    static func sortTags(_ filter: SearchFilterConfig) -> [String] {
        switch filter.sortBy {
        case .score:
            switch filter.timeRange {
            case .oneDay: return ["period:day", "sort:popular"]
            case .oneWeek: return ["period:week", "sort:popular"]
            case .oneMonth: return ["period:month", "sort:popular"]
            // RN's trailing `else`: 1y and "all" both send the popular sort without a period.
            case .oneYear, .all: return ["sort:popular"]
            }
        case .id: return ["sort:recent"]
        case .height: return ["sort:attachments"]
        case .width: return ["sort:videos"]
        default: return []
        }
    }

    /// RN `snapLeaderboardAnchor` (booruApi.ts:160-190): weekly anchors snap back to Monday, monthly ones to
    /// the 1st, both in UTC. Invalid or overflowing dates pass through unchanged.
    static func snappedAnchor(_ anchor: String, timeRange: TimeRange) -> String {
        let clean = anchor.booruTrimmed
        let parts = clean.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return clean
        }

        switch timeRange {
        case .oneWeek:
            guard (1...12).contains(month), (1...31).contains(day) else { return clean }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return clean }
            // Overflowing days such as Feb 30 are passed through instead of being rounded.
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            guard check.year == year, check.month == month, check.day == day else { return clean }
            // JS getUTCDay is Sunday=0; Calendar.weekday is Sunday=1. Monday backs up 0 days.
            let weekday = calendar.component(.weekday, from: date)
            let daysBack = (weekday + 5) % 7
            guard let monday = calendar.date(byAdding: .day, value: -daysBack, to: date) else { return clean }
            return BooruQueryTranslator.ymd(monday, calendar: calendar)
        case .oneMonth:
            guard (1...12).contains(month), (1...31).contains(day) else { return clean }
            return "\(parts[0])-\(parts[1])-01"
        case .oneDay, .oneYear, .all:
            return clean
        }
    }

    // MARK: - Request building

    /// RN token split of the search text (booruApi.ts:2107-2147).
    struct ParsedTags: Equatable {
        var period: String?
        var date: String?
        var sort: String?
        var service: String?
        var mediaType: String?
        var gender: String?
        var tagSlug: String?
        var keywords: [String] = []
    }

    static func parseTags(_ tags: String) -> ParsedTags {
        var parsed = ParsedTags()
        for token in tags.split(whereSeparator: { $0.isWhitespace }) {
            let text = String(token)
            let lower = text.lowercased()
            if lower.hasPrefix("period:") {
                parsed.period = String(text.dropFirst(7)).booruTrimmed
            } else if lower.hasPrefix("date:") {
                parsed.date = String(text.dropFirst(5)).booruTrimmed
            } else if lower.hasPrefix("sort:") {
                parsed.sort = String(text.dropFirst(5)).booruTrimmed
            } else if lower.hasPrefix("service:") {
                parsed.service = String(text.dropFirst(8)).booruTrimmed
            } else if lower.hasPrefix("type:") {
                parsed.mediaType = String(text.dropFirst(5)).booruTrimmed
            } else if lower.hasPrefix("gender:") {
                parsed.gender = String(text.dropFirst(7)).booruTrimmed
            } else if lower.hasPrefix("tag:") {
                parsed.tagSlug = String(text.dropFirst(4)).booruTrimmed
            } else if lower.hasPrefix("creator:") || lower.hasPrefix("user:") {
                let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = parts.count > 1 ? String(parts[1]) : text
                parsed.keywords.append(name.replacingOccurrences(of: "_", with: " "))
            } else {
                parsed.keywords.append(text.replacingOccurrences(of: "_", with: " "))
            }
        }
        return parsed
    }

    /// RN endpoint choice (booruApi.ts:2150-2180). `/api/v1/posts/popular` is keywordless-only;
    /// a word search always uses `/api/v1/posts`.
    static func requestURL(tags: String, page: Int) -> URL? {
        let parsed = parseTags(tags)
        let offset = max(0, (page - 1) * pageSize)
        let period = (parsed.period?.isEmpty == false) ? parsed.period?.lowercased() : nil
        let dateAnchor = parsed.date ?? ""
        let hasLeaderboardPeriod = period.map { leaderboardPeriods.contains($0) } ?? false

        if parsed.keywords.isEmpty && (hasLeaderboardPeriod || !dateAnchor.isEmpty) {
            var items = [
                URLQueryItem(name: "period", value: period ?? "day"),
                URLQueryItem(name: "o", value: String(offset)),
                URLQueryItem(name: "n", value: String(pageSize)),
            ]
            if !dateAnchor.isEmpty {
                items.append(URLQueryItem(name: "date", value: dateAnchor))
            }
            return BooruJSONSupport.url(baseURL: baseURL, path: "api/v1/posts/popular", items: items)
        }

        var items = [
            URLQueryItem(name: "o", value: String(offset)),
            URLQueryItem(name: "n", value: String(pageSize)),
        ]
        if let sort = parsed.sort, !sort.isEmpty {
            items.append(URLQueryItem(name: "sort", value: sort))
        }
        if let service = parsed.service, !service.isEmpty, service != "all" {
            items.append(URLQueryItem(name: "service", value: service))
        }
        if let mediaType = parsed.mediaType, !mediaType.isEmpty, mediaType != "all" {
            items.append(URLQueryItem(name: "type", value: mediaType))
        }
        if let gender = parsed.gender, !gender.isEmpty, gender != "all" {
            items.append(URLQueryItem(name: "gender", value: gender))
        }
        if let tagSlug = parsed.tagSlug, !tagSlug.isEmpty {
            items.append(URLQueryItem(name: "tag", value: tagSlug))
        }
        if !parsed.keywords.isEmpty {
            items.append(URLQueryItem(name: "q", value: parsed.keywords.joined(separator: " ")))
        }
        return BooruJSONSupport.url(baseURL: baseURL, path: "api/v1/posts", items: items)
    }

    /// Sends the list request. RN repeats it once on a 5xx after 300 ms (booruApi.ts:2169-2181);
    /// other failures surface through `HTTPStatusMapping`.
    static func fetchData(url: URL, http: any HTTPClientProtocol) async throws -> Data {
        let referer = CumstSource.baseURL + "/"
        var (data, response) = try await BooruJSONSupport.send(BooruJSONSupport.request(url: url, referer: referer), http: http)
        if response.statusCode >= 500 {
            try await Task.sleep(nanoseconds: CumstSource.retryDelayNanoseconds)
            (data, response) = try await BooruJSONSupport.send(BooruJSONSupport.request(url: url, referer: referer), http: http)
        }
        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        return data
    }

    // MARK: - BooruSource

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let tags = CumstSource.searchTags(for: query)
        guard let url = CumstSource.requestURL(tags: tags, page: page) else {
            throw BooruError.network("Invalid Cum.st list URL.")
        }
        let data = try await CumstSource.fetchData(url: url, http: context.http)
        let response = try BooruJSONSupport.decode(
            CumstPostsResponse.self,
            from: data,
            failure: "Cum.st did not return valid JSON."
        )
        let posts = response.posts.flatMap { mapPost($0) }
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// RN has no Cum.st suggestion branch, so `searchTags` yields nothing (booruApi.ts:2290-2527).
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        BooruJSONSupport.resolvedMedia(for: post, quality: context.imageQuality)
    }

    // MARK: - Mapping (RN booruApi.ts:2196-2280)

    /// One BooruPost per attachment; a post without usable attachments contributes nothing.
    private func mapPost(_ dto: CumstPostDTO) -> [BooruPost] {
        let attachments = dto.attachments
        guard !attachments.isEmpty else { return [] }

        // RN :2175: `Number(p.score !== undefined ? p.score : p.bookmarked) || 0`.
        let score = dto.score ?? dto.bookmarked ?? 0

        var posts: [BooruPost] = []
        for (index, wrapper) in attachments.enumerated() {
            guard let attachment = wrapper.value,
                  let sha = attachment.sha256?.booruTrimmed, !sha.isEmpty else { continue }

            // RN :2201.
            let isVideo = attachment.kind == "video" || (attachment.mimeType?.hasPrefix("video/") ?? false)
            let ext = CumstSource.fileExtension(attachment, isVideo: isVideo)
            let thumbnail = "\(CumstSource.thumbnailBase)/\(sha)/preview.webp"
            let media = "\(CumstSource.mediaBase)/\(sha)/original.\(ext)"
            let width = BooruJSONSupport.orDefault(attachment.width, 800)
            let height = BooruJSONSupport.orDefault(attachment.height, 1000)

            // RN :2217-2238.
            let creatorName = dto.creatorName ?? ""
            let service = dto.service ?? ""
            let artist: [String] = creatorName.isEmpty ? [] : [creatorName]
            let copyright: [String] = service.isEmpty ? [] : [service]
            let general = BooruJSONSupport.uniqued(dto.tags.compactMap { $0.value }.filter { !$0.isEmpty })
            let meta = BooruJSONSupport.uniqued(
                [attachment.kind ?? "", attachment.mimeType ?? "", service, isVideo ? "video" : "photo"]
                    .filter { !$0.isEmpty }
            )
            let allTags = BooruJSONSupport.uniqued(artist + copyright + general + meta)

            // RN :2242-2243: the attachment index is only appended when there is more than one.
            let idSuffix = attachments.count > 1 ? "_\(index + 1)" : ""

            // RN :2266-2269.
            let creatorID = dto.creatorId ?? ""
            let sourceLink: URL? = (service.isEmpty || creatorID.isEmpty)
                ? nil
                : URL(string: "\(CumstSource.baseURL)/creators/\(service)/\(creatorID)/post/\(dto.id)")

            // RN :2270-2274: `published || added || now`.
            let createdAt: String
            if let published = dto.published, published != 0 {
                createdAt = BooruJSONSupport.isoString(unixSeconds: published)
            } else if let added = dto.added, added != 0 {
                createdAt = BooruJSONSupport.isoString(unixSeconds: added)
            } else {
                createdAt = BooruJSONSupport.isoString(Date())
            }

            posts.append(BooruPost(
                id: "cumst_\(dto.id)\(idSuffix)",
                sourceID: id,
                sourceName: displayName,
                title: nil,
                previewURL: URL(string: thumbnail),
                previewFallbackURL: nil,
                previewVideoURL: nil,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: URL(string: media),
                originalURL: URL(string: media),
                width: width,
                height: height,
                aspectRatio: BooruJSONSupport.aspectRatio(width: width, height: height),
                rating: .explicit,
                score: score,
                favCount: score,
                tags: BooruTagGroups(artist: artist, character: [], copyright: copyright, general: general, meta: meta),
                allTags: allTags,
                sourceLink: sourceLink,
                fileExt: ext,
                fileSize: attachment.bytes,
                createdAt: createdAt,
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ))
        }
        return posts
    }

    /// RN `att.originalFilename.split('.').pop() || (video ? 'mp4' : kind === 'gif' ? 'gif' : 'jpg')` (booruApi.ts:2206-2208).
    static func fileExtension(_ attachment: CumstAttachmentDTO, isVideo: Bool) -> String {
        let name = attachment.originalFilename ?? ""
        let last = name.components(separatedBy: ".").last ?? ""
        if !last.isEmpty {
            return last
        }
        if isVideo {
            return "mp4"
        }
        return attachment.kind == "gif" ? "gif" : "jpg"
    }
}
