import Foundation

/// Gelbooru DAPI adapter. The same struct serves Rule34.xxx through `GelbooruSource(id: .rule34)`.
/// RN: `fetchGelbooruPosts` / `fetchGelbooruPage` (booruApi.ts:666-880) and `searchTags` (booruApi.ts:2294-2435).
/// Not ported: the HTML scrape fallback that RN runs when anonymous Gelbooru DAPI fails (booruApi.ts:493-496).
struct GelbooruSource: BooruSource {
    let id: SourceID
    let displayName: String
    let supportsVideo = true
    /// RN `baseUrl` (sources.ts:5-7 Gelbooru; sources.ts:37-39 Rule34). RN's DAPI call uses `apiBaseUrl || baseUrl` (booruApi.ts:782), and neither source sets `apiBaseUrl`.
    private let baseURL: String

    /// `.rule34` selects Rule34.xxx. Any other value selects Gelbooru.
    init(id: SourceID = .gelbooru) {
        if id == .rule34 {
            self.id = .rule34
            displayName = "Rule34.xxx"
            baseURL = "https://api.rule34.xxx"
        } else {
            self.id = .gelbooru
            displayName = "Gelbooru"
            baseURL = "https://gelbooru.com"
        }
    }

    /// RN Rule34 auth-failure pattern (booruApi.ts:816).
    private static let rule34AuthPattern = "auth|api.?key|user.?id|access.denied"

    private var apiName: String {
        id == .rule34 ? "Rule34" : "Gelbooru"
    }

    // MARK: Posts

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let limit = BooruQueryTranslator.pageLimit(for: query.filter)
        let tags = BooruQueryTranslator.tagString(for: query, source: id)
        let pid = BooruQueryTranslator.gelbooruPID(page: page)
        let windowDays = BooruQueryTranslator.gelbooruWindowDays(for: query.filter)

        if windowDays > 0 {
            // RN :677-691. Find the period's lower-bound id, then let the server sort the popular posts.
            let walkTags = BooruQueryTranslator.gelbooruWalkTags(tags)
            guard let bound = try await lowerBound(walkTags: walkTags, windowDays: windowDays, context: context) else {
                // RN :683. No posts in the window.
                return BooruJSONSupport.page([], requestedPage: page)
            }
            let bounded = BooruQueryTranslator.gelbooruBoundedTags(tags, lowerBound: bound)
            let posts = try await fetchPage(pid: pid, limit: limit, tags: bounded, context: context)
            return BooruJSONSupport.page(posts, requestedPage: page)
        }

        let posts = try await fetchPage(pid: pid, limit: limit, tags: tags, context: context)
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// One DAPI page (RN `fetchGelbooruPage`, booruApi.ts:736-880).
    private func fetchPage(pid: Int, limit: Int, tags: String, context: SourceContext) async throws -> [BooruPost] {
        var items = BooruQueryTranslator.gelbooruPostItems(tags: tags, pid: pid, limit: limit)

        // Rule34 cannot run without credentials (booruApi.ts:771-780). Gelbooru runs anonymously when they are absent (booruApi.ts:761-769).
        if id == .rule34 {
            guard let credentials = BooruJSONSupport.credentialItems(context.rule34Auth) else {
                throw BooruError.authRequired(.rule34)
            }
            items += credentials
        } else {
            items += BooruJSONSupport.credentialItems(context.gelbooruAuth) ?? []
        }

        guard let requestURL = BooruJSONSupport.url(baseURL: baseURL, path: "index.php", items: items) else {
            throw BooruError.network("Invalid request URL.")
        }
        let (data, response) = try await BooruJSONSupport.send(BooruJSONSupport.request(url: requestURL), http: context.http)
        let status = response.statusCode

        // RN :790-796. 401 means missing or wrong credentials. Rule34 403 is treated the same way (:791-793).
        if status == 401 || (id == .rule34 && status == 403) {
            throw BooruError.authRequired(id)
        }
        // RN :797-803.
        guard BooruJSONSupport.isSuccess(status) else {
            throw BooruJSONSupport.statusError(status)
        }

        let body = try BooruJSONSupport.decode(GelbooruDAPIResponse.self, from: data, failure: "\(apiName) API did not return valid JSON.")

        // RN :812-820. Rule34 reports auth failures as HTTP 200 with a string or `success: false` body.
        if id == .rule34, body.text != nil || body.success == false {
            let message = body.text ?? body.message ?? ""
            if message.range(of: Self.rule34AuthPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                throw BooruError.authRequired(.rule34)
            }
            throw BooruError.decoding("Rule34 API could not complete the request.")
        }

        return body.posts.compactMap { mapPost($0) }
    }

    /// Finds the smallest post id inside the time window, using the cache when it is fresh (RN `resolveGelbooruLowerBound`, booruApi.ts:698-734).
    private func lowerBound(walkTags: String, windowDays: Int, context: SourceContext) async throws -> Int? {
        let now = Date()
        let key = "\(id.rawValue)|\(walkTags)|\(windowDays)"
        if let cached = await GelbooruBoundCache.shared.fresh(key, now: now, ttl: BooruQueryTranslator.boundCacheTTL) {
            return cached.bound
        }

        let cutoff = BooruQueryTranslator.gelbooruBoundCutoff(windowDays: windowDays, now: now)
        var bound: Int?
        for pid in 0..<BooruQueryTranslator.boundMaxPages {
            let batch = try await fetchPage(pid: pid, limit: BooruQueryTranslator.boundWalkLimit, tags: walkTags, context: context)
            if batch.isEmpty { break }
            for post in batch {
                guard let postID = Int(post.id),
                      let created = BooruJSONSupport.date(fromISO: post.createdAt),
                      created >= cutoff else { continue }
                bound = min(bound ?? postID, postID)
            }
            if batch.count < BooruQueryTranslator.boundWalkLimit { break }
            // RN :729-730. Stop walking once the oldest post on this page is already older than the cutoff.
            if let last = batch.last, let lastCreated = BooruJSONSupport.date(fromISO: last.createdAt), lastCreated < cutoff {
                break
            }
        }

        await GelbooruBoundCache.shared.store(key, GelbooruBoundEntry(bound: bound, at: now))
        return bound
    }

    /// RN `mapPost` inside `fetchGelbooruPage` (booruApi.ts:834-877). Returns nil for items with no media URL (booruApi.ts:835).
    private func mapPost(_ dto: GelbooruPostDTO) -> BooruPost? {
        let hasMedia = [dto.previewURL, dto.sampleURL, dto.fileURL, dto.image].contains { !($0 ?? "").isEmpty }
        guard hasMedia else { return nil }

        // RN :837-838. Directory-based fallbacks apply only when the direct URL is empty.
        var originalRaw = dto.fileURL ?? ""
        if originalRaw.isEmpty, let directory = dto.directory, let image = dto.image, !image.isEmpty {
            originalRaw = "\(baseURL)/images/\(directory)/\(image)"
        }
        var previewRaw = dto.previewURL ?? ""
        if previewRaw.isEmpty, let directory = dto.directory, let image = dto.image, !image.isEmpty {
            previewRaw = "\(baseURL)/thumbnails/\(directory)/thumbnail_\(image)"
        }
        // RN :839-841. sample = sample || original || preview. A missing original or preview falls back to the sample.
        let sampleRaw = BooruJSONSupport.firstNonEmpty(dto.sampleURL, originalRaw, previewRaw)
        let original = BooruJSONSupport.firstNonEmpty(originalRaw, sampleRaw)
        let preview = BooruJSONSupport.firstNonEmpty(previewRaw, sampleRaw)

        let width = BooruJSONSupport.orDefault(dto.width, 800)
        let height = BooruJSONSupport.orDefault(dto.height, 1000)
        let tags = BooruJSONSupport.uniqued(dto.tags)

        // RN :864 and :875. favCount comes from `change`, and createdAt is `change` as ISO time (now when missing or zero).
        let createdAt: String
        if let change = dto.change, change != 0 {
            createdAt = BooruJSONSupport.isoString(unixSeconds: change)
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
            sampleURL: BooruJSONSupport.absoluteURL(sampleRaw, baseURL: baseURL),
            originalURL: BooruJSONSupport.absoluteURL(original, baseURL: baseURL),
            width: width,
            height: height,
            aspectRatio: BooruJSONSupport.aspectRatio(width: width, height: height),
            rating: BooruJSONSupport.rating(dto.rating),
            score: dto.score ?? 0,
            favCount: dto.change ?? 0,
            tags: BooruTagGroups(general: tags),
            allTags: tags,
            sourceLink: BooruJSONSupport.optionalURL(dto.source),
            fileExt: dto.image.map { $0.components(separatedBy: ".").last ?? "" },
            fileSize: nil,
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: Tag suggestions

    /// RN `searchTags` for this engine (booruApi.ts:2290-2527). Failures return an empty list, as in RN. Cancellation still propagates.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        guard let query = BooruQueryTranslator.suggestionQuery(prefix) else { return [] }

        if id == .gelbooru {
            // RN :2295-2325. Preferred step: autocomplete2. A non-empty raw response is final, even when it maps to nothing.
            let autocomplete: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
                try await self.autocomplete2Suggestions(query, context: context)
            }
            if let autocomplete {
                return autocomplete
            }
            // RN :2327-2382. Fallback step: the official DAPI tag list, with credentials when they are set.
            let dapi: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
                try await self.dapiTagSuggestions(query, context: context)
            }
            return dapi ?? []
        }

        // RN :2412-2435. Rule34 has type `gelbooru` but is not `gelbooru`, so it takes this branch.
        let php: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
            try await self.autocompletePHPSuggestions(query, context: context)
        }
        return php ?? []
    }

    private func autocomplete2Suggestions(_ query: String, context: SourceContext) async throws -> [BooruTagSuggestion]? {
        let limit = BooruQueryTranslator.suggestionLimit
        let data = try await BooruJSONSupport.fetchData(
            baseURL: baseURL,
            path: "index.php",
            items: BooruQueryTranslator.gelbooruAutocompleteItems(term: query, limit: limit),
            referer: "\(baseURL)/",
            http: context.http
        )
        let entries = try BooruJSONSupport.decode(
            BooruLenientArray<GelbooruAutocompleteDTO>.self,
            from: data,
            failure: "Gelbooru autocomplete did not return valid JSON."
        ).elements
        guard !entries.isEmpty else { return nil }
        return entries.prefix(limit).map { entry in
            BooruTagSuggestion(
                name: entry.value ?? entry.label ?? "",
                category: GelbooruSource.autocompleteCategory(entry.category),
                postCount: entry.postCount ?? 0
            )
        }.filter { !$0.name.isEmpty }
    }

    private func dapiTagSuggestions(_ query: String, context: SourceContext) async throws -> [BooruTagSuggestion]? {
        let limit = BooruQueryTranslator.suggestionLimit
        var items = BooruQueryTranslator.gelbooruTagListItems(name: query, limit: limit)
        items += BooruJSONSupport.credentialItems(context.gelbooruAuth) ?? []
        let data = try await BooruJSONSupport.fetchData(baseURL: baseURL, path: "index.php", items: items, http: context.http)
        let tags = try BooruJSONSupport.decode(
            GelbooruTagListResponse.self,
            from: data,
            failure: "Gelbooru tag list did not return valid JSON."
        ).tags
        guard !tags.isEmpty else { return nil }
        return tags.prefix(limit).map { tag in
            BooruTagSuggestion(
                name: tag.name ?? "",
                category: GelbooruSource.tagListCategory(tag.type),
                postCount: tag.count ?? 0
            )
        }.filter { !$0.name.isEmpty }
    }

    private func autocompletePHPSuggestions(_ query: String, context: SourceContext) async throws -> [BooruTagSuggestion]? {
        let limit = BooruQueryTranslator.suggestionLimit
        let data = try await BooruJSONSupport.fetchData(
            baseURL: baseURL,
            path: "autocomplete.php",
            items: BooruQueryTranslator.gelbooruAutocompletePHPItems(query: query),
            http: context.http
        )
        let entries = try BooruJSONSupport.decode(
            BooruLenientArray<GelbooruAutocompletePHPDTO>.self,
            from: data,
            failure: "\(apiName) autocomplete did not return valid JSON."
        ).elements
        return entries.prefix(limit).map { entry in
            BooruTagSuggestion(
                name: entry.value ?? entry.label ?? "",
                category: .general,
                postCount: GelbooruSource.postCount(inLabel: entry.label)
            )
        }.filter { !$0.name.isEmpty }
    }

    /// RN `autocomplete2` category mapping (booruApi.ts:2307-2312).
    static func autocompleteCategory(_ raw: String?) -> TagCategory {
        switch raw ?? "" {
        case "artist": return .artist
        case "character": return .character
        case "copyright": return .copyright
        case "metadata": return .meta
        default: return .general
        }
    }

    /// RN DAPI tag `type` mapping (booruApi.ts:2366-2371).
    static func tagListCategory(_ type: Int?) -> TagCategory {
        switch type ?? 0 {
        case 1: return .artist
        case 3: return .copyright
        case 4: return .character
        case 5: return .meta
        default: return .general
        }
    }

    /// RN `label.match(/\((\d+)\)/)` count (booruApi.ts:2424-2428). Returns 0 when there is no count.
    static func postCount(inLabel label: String?) -> Int {
        guard let label,
              let regex = try? NSRegularExpression(pattern: "\\(([0-9]+)\\)"),
              let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(match.range(at: 1), in: label) else {
            return 0
        }
        return Int(label[range]) ?? 0
    }

    // MARK: Media

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        BooruJSONSupport.resolvedMedia(for: post, quality: context.imageQuality)
    }
}

// MARK: - Lower-bound cache

/// One cached walk result. `bound` is nil when the window had no posts (RN `GelbooruBoundEntry`, booruApi.ts:85-88).
struct GelbooruBoundEntry: Sendable {
    let bound: Int?
    let at: Date
}

/// Process-wide 5-minute cache shared by every Gelbooru-engine instance (RN `gelbooruBoundCache`, booruApi.ts:89-90).
///
/// Internal rather than file-private: pull-to-refresh clears it so a timed top re-walks
/// instead of reusing a bound from before the user's last refresh.
actor GelbooruBoundCache {
    static let shared = GelbooruBoundCache()

    private var entries: [String: GelbooruBoundEntry] = [:]

    func fresh(_ key: String, now: Date, ttl: TimeInterval) -> GelbooruBoundEntry? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) < ttl else { return nil }
        return entry
    }

    func store(_ key: String, _ entry: GelbooruBoundEntry) {
        entries[key] = entry
    }

    /// Drops every cached lower bound so the next timed top walks the window again.
    func clear() {
        entries.removeAll()
    }
}
