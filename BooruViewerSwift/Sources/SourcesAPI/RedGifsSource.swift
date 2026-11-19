import Foundation

/// RedGifs adapter (`id` `redgifs`). No user credentials: every call uses the temporary Bearer token
/// the API hands out anonymously.
/// RN: `fetchRedGifsPosts` (booruApi.ts:1294-1425), `mapRedGifsGifs` (:1426-1470), the token flow
/// (:1199-1287), and the suggestion branch (:2385-2407).
struct RedGifsSource: BooruSource {
    let id: SourceID = .redgifs
    let displayName = "RedGifs"
    let supportsVideo = true

    /// RN sources.ts:53-59.
    static let apiBaseURL = "https://api.redgifs.com"
    static let webBaseURL = "https://www.redgifs.com"
    /// RN :1363: `count = Math.min(Math.max(limit, 10), 40)`.
    static let minCount = 10
    static let maxCount = 40
    /// RN :1252: the temporary token is reused for 30 minutes, in memory only.
    static let tokenLifetime: TimeInterval = 30 * 60

    // MARK: - Token cache

    /// Single-flight cache for the temporary RedGifs token (RN booruApi.ts:1199-1271).
    /// Tokens are keyed by connection scope (proxy worker or direct) and never persisted: RN saw a
    /// persisted token reused on another connection fail with a `WrongSender` loop.
    actor RedGifsTokenCache {
        static let shared = RedGifsTokenCache()

        private struct Entry {
            let token: String
            let expiresAt: Date
        }

        private var entries: [String: Entry] = [:]
        private var inFlight: [String: Task<String, Error>] = [:]

        /// Cached token, or the request already in flight, or a fresh token from `acquire`.
        /// `rejected` drops the token the server just refused unless a newer one already replaced it.
        func token(
            scope: String,
            rejected: String? = nil,
            acquire: @escaping @Sendable () async throws -> String
        ) async throws -> String {
            if let rejected, entries[scope]?.token == rejected {
                entries[scope] = nil
            }
            if let entry = entries[scope], Date() < entry.expiresAt {
                return entry.token
            }
            if let task = inFlight[scope] {
                return try await task.value
            }
            let task = Task { try await acquire() }
            inFlight[scope] = task
            defer { inFlight[scope] = nil }
            let value = try await task.value
            entries[scope] = Entry(token: value, expiresAt: Date().addingTimeInterval(RedGifsSource.tokenLifetime))
            return value
        }

        /// Drops every cached token. Used by tests; the app never needs it.
        func clear() {
            entries.removeAll()
            inFlight.removeAll()
        }
    }

    /// RN :1231-1233: the token belongs to the connection that requested it.
    static func scope(for context: SourceContext) -> String {
        context.proxy.enabled ? context.proxy.workerURL : "direct"
    }

    // MARK: - Requests

    /// RN `fetchRedGifsApi` headers (booruApi.ts:1201-1216). RN sends a single Authorization header on purpose.
    static func request(url: URL, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(BooruJSONSupport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webBaseURL, forHTTPHeaderField: "Origin")
        request.setValue(webBaseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func url(path: String, items: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: apiBaseURL + "/" + path)
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url
    }

    /// `/v2/auth/temporary` (booruApi.ts:1249-1262).
    static func acquireToken(http: any HTTPClientProtocol) async throws -> String {
        guard let url = URL(string: apiBaseURL + "/v2/auth/temporary") else {
            throw BooruError.network("Invalid RedGifs auth URL.")
        }
        let (data, response) = try await BooruJSONSupport.send(request(url: url), http: http)
        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        let body = try BooruJSONSupport.decode(
            RedGifsTokenResponse.self,
            from: data,
            failure: "RedGifs auth did not return valid JSON."
        )
        guard let token = body.token, !token.isEmpty else {
            throw BooruError.decoding("RedGifs returned an empty token.")
        }
        return token
    }

    /// Authenticated GET with the single 401 refresh RN allows (booruApi.ts:1273-1287).
    static func fetchData(url: URL, context: SourceContext) async throws -> Data {
        let scope = RedGifsSource.scope(for: context)
        let token = try await RedGifsTokenCache.shared.token(scope: scope, acquire: {
            try await RedGifsSource.acquireToken(http: context.http)
        })
        var (data, response) = try await BooruJSONSupport.send(
            RedGifsSource.request(url: url, token: token),
            http: context.http
        )
        if response.statusCode == 401 {
            let refreshed = try await RedGifsTokenCache.shared.token(scope: scope, rejected: token, acquire: {
                try await RedGifsSource.acquireToken(http: context.http)
            })
            (data, response) = try await BooruJSONSupport.send(
                RedGifsSource.request(url: url, token: refreshed),
                http: context.http
            )
        }
        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        return data
    }

    // MARK: - Search text

    /// RN `redGifsSearchText` (booruApi.ts:62-64): underscores and whitespace runs become single spaces.
    static func searchText(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in value {
            if character == "_" || character.isWhitespace {
                pendingSeparator = true
            } else {
                if pendingSeparator && !result.isEmpty {
                    result.append(" ")
                }
                pendingSeparator = false
                result.append(character)
            }
        }
        return result
    }

    /// RN `normTag` (booruApi.ts:1312): lowercase, whitespace runs become underscores.
    static func normalizedTag(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
    }

    /// RN `t.toLowerCase().replace(/\s+/g, '_')` for a display tag (booruApi.ts:1443).
    static func generalTag(_ value: String) -> String {
        normalizedTag(value)
    }

    /// RN token handling of the search text (booruApi.ts:1308-1343).
    struct ParsedSearch: Equatable {
        var excludeTags: [String] = []
        var nicheExcludes: [String] = []
        var userExcludes: [String] = []
        var includeTokens: [String] = []
        var tokenUsername: String = ""
        var includeTags: String = ""
        var nicheId: String = ""
        var remainingTokens: [String] = []
        var searchUsername: String = ""
    }

    static func parseSearch(tags: String, filter: SearchFilterConfig) -> ParsedSearch {
        let tokens = tags.split(whereSeparator: { $0.isWhitespace }).map { String($0) }

        // RN :1312-1325: exclusions are kept locally, RedGifs has no `-tag` syntax.
        let excludeTags = tokens
            .filter { $0.hasPrefix("-") }
            .map { normalizedTag(String($0.drop(while: { $0 == "-" }))) }
            .filter { !$0.isEmpty }
        let nicheExcludes = excludeTags
            .filter { $0.hasPrefix("niche:") }
            .map { String($0.dropFirst(6)).booruTrimmed }
            .filter { !$0.isEmpty }
        let userExcludes = excludeTags
            .filter { $0.hasPrefix("user:") }
            .map { String($0.dropFirst(5)).booruTrimmed.lowercased() }
            .filter { !$0.isEmpty }

        // RN :1326-1333.
        let includeTokens = tokens
            .filter { !$0.hasPrefix("-") }
            .filter { !$0.lowercased().hasPrefix("user:") }
        let userToken = tokens.first { !$0.hasPrefix("-") && $0.lowercased().hasPrefix("user:") }
        let tokenUsername = userToken.map { String($0.dropFirst(5)).booruTrimmed } ?? ""
        let includeTags = searchText(includeTokens.joined(separator: " "))

        // RN :1365-1372.
        let nicheToken = includeTokens.first { $0.lowercased().hasPrefix("niche:") }
        let nicheId = nicheToken.map { String($0.dropFirst(6)).booruTrimmed } ?? ""
        let remainingTokens: [String]
        if let nicheToken, !nicheId.isEmpty {
            remainingTokens = includeTokens.filter { $0 != nicheToken }
        } else {
            remainingTokens = includeTokens
        }

        // RN :1370-1373: the User field wins over a `user:` token.
        let filterUser = (filter.user ?? "").booruTrimmed
        let searchUsername = filterUser.isEmpty ? tokenUsername : filterUser

        return ParsedSearch(
            excludeTags: excludeTags,
            nicheExcludes: nicheExcludes,
            userExcludes: userExcludes,
            includeTokens: includeTokens,
            tokenUsername: tokenUsername,
            includeTags: includeTags,
            nicheId: nicheId,
            remainingTokens: remainingTokens,
            searchUsername: searchUsername
        )
    }

    /// RN order mapping (booruApi.ts:1345-1362).
    static func order(for filter: SearchFilterConfig) -> String {
        switch filter.sortBy {
        case .id:
            return "latest"
        case .score:
            switch filter.timeRange {
            case .oneDay: return "trending"
            case .oneWeek: return "top7"
            case .oneMonth: return "top28"
            case .oneYear, .all: return "top"
            }
        default:
            // rating, user, default, height, and width all keep the trending stream (RN :1360-1362).
            return "trending"
        }
    }

    /// RN :1363: the page size the API accepts is clamped to 10...40.
    static func count(for filter: SearchFilterConfig) -> Int {
        min(max(BooruQueryTranslator.pageLimit(for: filter), minCount), maxCount)
    }

    /// RN URL choice (booruApi.ts:1374-1382): user search, then niche, then tag search.
    static func searchURL(_ parsed: ParsedSearch, filter: SearchFilterConfig, page: Int) -> URL? {
        let pageSize = RedGifsSource.count(for: filter)
        let pageNumber = max(1, page)

        if !parsed.searchUsername.isEmpty {
            let items = [
                URLQueryItem(name: "page", value: String(pageNumber)),
                URLQueryItem(name: "count", value: String(pageSize)),
                URLQueryItem(name: "order", value: "latest"),
                URLQueryItem(name: "type", value: "g"),
            ]
            return url(path: "v2/users/\(BooruJSONSupport.encode(parsed.searchUsername))/search", items: items)
        }
        if !parsed.nicheId.isEmpty {
            let items = [
                URLQueryItem(name: "count", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(pageNumber)),
            ]
            return url(path: "v2/niches/\(BooruJSONSupport.encode(parsed.nicheId))/gifs", items: items)
        }

        var items = [
            URLQueryItem(name: "type", value: "g"),
            URLQueryItem(name: "order", value: order(for: filter)),
            URLQueryItem(name: "count", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(pageNumber)),
        ]
        if !parsed.includeTags.isEmpty {
            items.append(URLQueryItem(name: "tags", value: parsed.includeTags))
        }
        return url(path: "v2/gifs/search", items: items)
    }

    /// RN client-side filtering (booruApi.ts:1396-1424): the server ignores `-tag`, and combined
    /// user/niche + tag queries are not filtered server-side.
    static func clientFiltered(_ posts: [BooruPost], parsed: ParsedSearch) -> [BooruPost] {
        let filterTokens = parsed.nicheId.isEmpty ? parsed.includeTokens : parsed.remainingTokens
        let needsFilter = !parsed.excludeTags.isEmpty
            || ((!parsed.searchUsername.isEmpty || !parsed.nicheId.isEmpty) && !filterTokens.isEmpty)
        guard needsFilter else { return posts }

        let includeNorm = filterTokens.map { normalizedTag($0) }.filter { !$0.isEmpty }
        return posts.filter { post in
            let hay = post.allTags.map { normalizedTag($0) }
            if parsed.excludeTags.contains(where: { hay.contains($0) }) {
                return false
            }
            if (!parsed.searchUsername.isEmpty || !parsed.nicheId.isEmpty),
               includeNorm.contains(where: { !hay.contains($0) }) {
                return false
            }
            if !parsed.nicheExcludes.isEmpty,
               (post.niches ?? []).map({ normalizedTag($0) }).contains(where: { parsed.nicheExcludes.contains($0) }) {
                return false
            }
            if !parsed.userExcludes.isEmpty,
               post.tags.artist.contains(where: { parsed.userExcludes.contains($0.booruTrimmed.lowercased()) }) {
                return false
            }
            return true
        }
    }

    // MARK: - BooruSource

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        // RN buildQueryTags sends only the base tags for RedGifs (:263-313).
        let tags = BooruQueryTranslator.baseTags(for: query)
        let parsed = RedGifsSource.parseSearch(tags: tags, filter: query.filter)
        guard let url = RedGifsSource.searchURL(parsed, filter: query.filter, page: page) else {
            throw BooruError.network("Invalid RedGifs list URL.")
        }
        let data = try await RedGifsSource.fetchData(url: url, context: context)
        let body = try BooruJSONSupport.decode(
            RedGifsGifsResponse.self,
            from: data,
            failure: "RedGifs did not return valid JSON."
        )
        let posts = RedGifsSource.clientFiltered(body.gifs.map { mapGif($0) }, parsed: parsed)
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// RN RedGifs branch of `searchTags` (booruApi.ts:2385-2407). Failures return an empty list.
    /// Cancellation still propagates.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        guard let query = BooruQueryTranslator.suggestionQuery(prefix) else { return [] }
        let text = RedGifsSource.searchText(query)
        guard let url = RedGifsSource.url(path: "v2/search/suggest", items: [URLQueryItem(name: "query", value: text)]) else {
            return []
        }
        let limit = BooruQueryTranslator.suggestionLimit
        let found: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
            let data = try await RedGifsSource.fetchData(url: url, context: context)
            let suggestions = try BooruJSONSupport.decode(
                RedGifsSuggestionsResponse.self,
                from: data,
                failure: "RedGifs suggestions did not return valid JSON."
            ).suggestions
            return suggestions.compactMap { entry -> BooruTagSuggestion? in
                guard let raw = entry.text?.booruTrimmed, !raw.isEmpty else { return nil }
                return BooruTagSuggestion(
                    name: RedGifsSource.generalTag(raw),
                    category: .general,
                    postCount: entry.gifs ?? 0
                )
            }.prefix(limit).map { $0 }
        }
        return found ?? []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        let placeholder = ImageQualityResolver.placeholderURL(for: post)
        let hd = MediaURLNormalizer.normalize(post.originalURL, sourceID: .redgifs)
        let sd = MediaURLNormalizer.normalize(post.sampleURL, sourceID: .redgifs)
        let fallback = VideoCandidateSelector.videoCandidates(for: post).first
        let video: URL? = switch context.imageQuality {
        case .preview:
            sd ?? hd ?? fallback
        case .auto, .full:
            hd ?? sd ?? fallback
        }
        return ResolvedMedia(
            imageURL: placeholder ?? post.previewURL,
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: placeholder
        )
    }

    // MARK: - Mapping (RN booruApi.ts:1428-1470)

    private func mapGif(_ dto: RedGifsGifDTO) -> BooruPost {
        let urls = dto.urls
        let hd = urls?.hd ?? ""
        let sd = urls?.sd ?? ""
        let silent = urls?.silent ?? ""
        let fullVideo = BooruJSONSupport.firstNonEmpty(hd, sd, silent)

        // RN :1434-1441: the first cover is the preview, the other one becomes the fallback.
        let covers = [urls?.thumbnail, urls?.poster]
            .compactMap { $0?.booruTrimmed }
            .filter { !$0.isEmpty }
        let previewThumb = covers.first ?? ""
        let previewFallback = covers.first { $0 != previewThumb }
        let sampleMedia = BooruJSONSupport.firstNonEmpty(sd, silent, fullVideo)

        // RN :1443-1454.
        let general = BooruJSONSupport.uniqued(dto.tags.map { RedGifsSource.generalTag($0) })
        let userName = dto.userName ?? ""
        let artist: [String] = userName.isEmpty ? [] : [userName]
        var meta = ["video"]
        if dto.hasAudio == true {
            meta.append("sound")
        }
        let allTags = BooruJSONSupport.uniqued(artist + general + meta)
        let niches = BooruJSONSupport.uniqued(
            dto.niches.map { $0.booruTrimmed.lowercased() }.filter { !$0.isEmpty }
        )

        let width = BooruJSONSupport.orDefault(dto.width, 720)
        let height = BooruJSONSupport.orDefault(dto.height, 1280)
        let aspectRatio = width > 0 && height > 0 ? Double(width) / Double(height) : 9.0 / 16.0

        // RN :1463-1466.
        let createdAt: String
        if let created = dto.createDate, created != 0 {
            createdAt = BooruJSONSupport.isoString(unixSeconds: created)
        } else {
            createdAt = BooruJSONSupport.isoString(Date())
        }

        let previewVideoURL = silent.isEmpty
            ? BooruJSONSupport.absoluteURL(sd, baseURL: RedGifsSource.apiBaseURL)
            : BooruJSONSupport.absoluteURL(silent, baseURL: RedGifsSource.apiBaseURL)

        return BooruPost(
            id: "rg_\(dto.id)",
            sourceID: id,
            sourceName: displayName,
            title: nil,
            previewURL: BooruJSONSupport.absoluteURL(previewThumb, baseURL: RedGifsSource.apiBaseURL),
            previewFallbackURL: BooruJSONSupport.absoluteURL(previewFallback, baseURL: RedGifsSource.apiBaseURL),
            previewVideoURL: previewVideoURL,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: BooruJSONSupport.absoluteURL(sampleMedia, baseURL: RedGifsSource.apiBaseURL),
            originalURL: BooruJSONSupport.absoluteURL(fullVideo, baseURL: RedGifsSource.apiBaseURL),
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            rating: .explicit,
            score: dto.likes ?? 0,
            favCount: dto.likes ?? 0,
            tags: BooruTagGroups(artist: artist, character: [], copyright: [], general: general, meta: meta),
            allTags: allTags,
            sourceLink: URL(string: "\(RedGifsSource.webBaseURL)/watch/\(dto.id)"),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: createdAt,
            niches: niches.isEmpty ? nil : niches,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }
}
