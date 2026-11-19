import Foundation

/// HentaiHaven adapter (`id` `hentaihaven`). Official v1 API only, no HTML scraping:
/// `/warden` token, `/hentai/all`, `/hentai/home`, `/search`, `/genre/all`, `/genre/{id}`, `/hentai/{id}`.
/// RN: `src/services/hentaihavens.ts` (whole module) and `fetchHentaiHavenPosts` (booruApi.ts:2410-2412).
///
/// The HTML safety net in RN (`parseHentaiHavenListing` and the episode-page parser) belongs to the
/// Scrapers layer; this adapter degrades to the API result instead of switching transports.
struct HentaiHavenSource: BooruSource {
    let id: SourceID = .hentaihaven
    let displayName = "HentaiHaven"
    let supportsVideo = true

    /// RN hentaihavens.ts:23-28.
    static let baseURL = "https://hentaihaven.xxx"
    static let apiBaseURL = "https://api.hentaihaven.app/v1"
    static let appUserAgent = "HH_xxx_APP"

    /// RN hentaihavens.ts:30-31: the warden request carries the app's generic Android device
    /// profile as a form body. It is a shared emulator fingerprint, never a personal identifier.
    static let wardenRequestBody =
        "sdkInt=33&board=goldfish_x86_64&brand=google&display=sdk_gphone_x86_64-userdebug+13+TE1A.220922.028+10190541+dev-keys"
        + "&fingerprint=google%2Fsdk_gphone_x86_64%2Femu64xa%3A13%2FTE1A.220922.028%2F10190541%3Auserdebug%2Fdev-keys"
        + "&manufacturer=Google&model=sdk_gphone_x86_64"

    /// RN hentaihavens.ts:392-398: Explore sections mapped to official genre term ids.
    static func genreID(for section: HentaiHavenFeedSection) -> Int? {
        switch section {
        case .yuri: return 102
        case .ecchi: return 2594
        case .incest: return 64
        case .tentacle: return 244
        case .uncensored: return 107
        case .latest, .trending, .episodes: return nil
        }
    }

    /// RN hentaihavens.ts:400-415: core genres missing from the `genre/all` response.
    /// The static studios/authors pool (`HENTAIHAVEN_KNOWN_AUTHORS`) is not ported; the pool learns
    /// terms from `genre/all` and the detail responses instead.
    static let knownGenres: [HentaiHavenTermDTO] = [
        HentaiHavenTermDTO(termID: 102, name: "Yuri", slug: "yuri", count: 194),
        HentaiHavenTermDTO(termID: 244, name: "Tentacle", slug: "tentacle", count: 88),
        HentaiHavenTermDTO(termID: 107, name: "Uncensored Hentai", slug: "uncensored", count: 186),
        HentaiHavenTermDTO(termID: 106, name: "Tsundere", slug: "tsundere", count: 234),
        HentaiHavenTermDTO(termID: 66, name: "Teen Hentai", slug: "teen-hentai", count: 142),
        HentaiHavenTermDTO(termID: 67, name: "Young Hentai", slug: "young", count: 141),
        HentaiHavenTermDTO(termID: 104, name: "Yaoi", slug: "yaoi", count: 32),
        HentaiHavenTermDTO(termID: 2627, name: "Softcore", slug: "softcore", count: 48),
        HentaiHavenTermDTO(termID: 2605, name: "Umemaro 3D", slug: "umemaro-3d", count: 12),
    ]

    // MARK: - Warden token cache

    /// Single-flight cache for the warden token (RN hentaihavens.ts:34-73). The token stays valid for
    /// months, so it is dropped only when the API answers 401/502.
    actor HentaiHavenWardenCache {
        static let shared = HentaiHavenWardenCache()

        private var token: String?
        private var inFlight: Task<String, Error>?

        /// Cached token, the request already in flight, or a fresh one from `acquire`.
        func token(
            forceRefresh: Bool = false,
            acquire: @escaping @Sendable () async throws -> String
        ) async throws -> String {
            if forceRefresh {
                token = nil
            }
            if let token {
                return token
            }
            if let task = inFlight {
                return try await task.value
            }
            let task = Task { try await acquire() }
            inFlight = task
            defer { inFlight = nil }
            let value = try await task.value
            token = value
            return value
        }

        /// Drops the cached token. Used by tests; the app never needs it.
        func clear() {
            token = nil
            inFlight = nil
        }
    }

    // MARK: - Genre pool cache

    /// Genre/studio pool cache (RN hentaihavens.ts:478-520).
    actor HentaiHavenGenreCache {
        static let shared = HentaiHavenGenreCache()

        private var cached: [HentaiHavenTermDTO]?
        private var inFlight: Task<[HentaiHavenTermDTO], Error>?

        func genres(http: any HTTPClientProtocol) async throws -> [HentaiHavenTermDTO] {
            if let cached {
                return cached
            }
            if let task = inFlight {
                return try await task.value
            }
            let task = Task { try await HentaiHavenSource.fetchGenres(http: http) }
            inFlight = task
            defer { inFlight = nil }
            let merged = try await task.value
            cached = merged
            return merged
        }

        /// Resets the pool. Used by tests; the app never needs it.
        func clear() {
            cached = nil
            inFlight = nil
        }
    }

    // MARK: - Episode cache

    /// Series episodes keyed by slug (RN `resolveHentaiHavenGalleryDetail` list reuse). The viewer
    /// asks for the episode list and then, per selection, for one stream URL; caching the parsed
    /// list per series keeps episode switching from refetching the detail every time.
    actor HentaiHavenEpisodeCache {
        static let shared = HentaiHavenEpisodeCache()

        private var cached: [String: [HentaiHavenEpisode]] = [:]

        func episodes(for slug: String) -> [HentaiHavenEpisode]? {
            cached[slug]
        }

        func store(_ episodes: [HentaiHavenEpisode], for slug: String) {
            cached[slug] = episodes
        }

        /// Resets the cache. Used by tests; the app never needs it.
        func clear() {
            cached.removeAll()
        }
    }

    // MARK: - Requests

    static func apiRequest(path: String, token: String) -> URLRequest? {
        guard let url = URL(string: apiBaseURL + "/" + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(token, forHTTPHeaderField: "warden")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `POST /warden` (hentaihavens.ts:40-73).
    static func acquireToken(http: any HTTPClientProtocol) async throws -> String {
        guard let url = URL(string: apiBaseURL + "/warden") else {
            throw BooruError.network("Invalid HentaiHaven warden URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(wardenRequestBody.utf8)

        let (data, response) = try await BooruJSONSupport.send(request, http: http)
        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        let envelope = try BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenWardenDTO>.self,
            from: data,
            failure: "HentaiHaven warden did not return valid JSON."
        )
        guard let token = envelope.data?.token?.booruTrimmed, !token.isEmpty else {
            throw BooruError.decoding("HentaiHaven warden returned no token.")
        }
        return token
    }

    /// `fetchHentaiHavenApi` (hentaihavens.ts:79-127): one refresh on 401/502, 429 surfaces as
    /// `BooruError.rateLimited` through the shared status mapping.
    static func apiData(path: String, http: any HTTPClientProtocol) async throws -> Data {
        let token = try await HentaiHavenWardenCache.shared.token(acquire: {
            try await HentaiHavenSource.acquireToken(http: http)
        })
        guard var request = apiRequest(path: path, token: token) else {
            throw BooruError.network("Invalid HentaiHaven API URL.")
        }
        var (data, response) = try await BooruJSONSupport.send(request, http: http)

        if response.statusCode == 401 || response.statusCode == 502 {
            let refreshed = try await HentaiHavenWardenCache.shared.token(forceRefresh: true, acquire: {
                try await HentaiHavenSource.acquireToken(http: http)
            })
            guard let retry = apiRequest(path: path, token: refreshed) else {
                throw BooruError.network("Invalid HentaiHaven API URL.")
            }
            request = retry
            (data, response) = try await BooruJSONSupport.send(request, http: http)
        }

        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        return data
    }

    // MARK: - Query text

    /// RN `buildQueryTags` for HentaiHaven (booruApi.ts:263-285): base tags plus the plain user word.
    static func searchText(for query: SearchQuery) -> String {
        var parts: [String] = []
        let base = BooruQueryTranslator.baseTags(for: query)
        if !base.isEmpty {
            parts.append(base)
        }
        if let user = query.filter.user?.booruTrimmed, !user.isEmpty {
            parts.append(user)
        }
        return parts.joined(separator: " ")
    }

    /// RN `parseHentaiHavenQuery` (hentaihavens.ts:654-700): quoted groups stay one token, a `-`
    /// prefix becomes an exclusion, booru prefixes are stripped, and at most 12 tokens are kept.
    struct ParsedQuery: Equatable {
        var include: [String] = []
        var exclude: [String] = []
    }

    static func parseQuery(_ raw: String?) -> ParsedQuery {
        var include: [String] = []
        var exclude: [String] = []
        var seenInclude = Set<String>()
        var seenExclude = Set<String>()

        func push(_ token: String, negated: Bool) {
            var text = token.booruTrimmed
            guard !text.isEmpty else { return }
            var isExcluded = negated
            if !isExcluded, text.hasPrefix("-") {
                isExcluded = true
                text = String(text.drop(while: { $0 == "-" })).booruTrimmed
            }
            for prefix in ["tag:", "genre:", "artist:", "character:", "parody:", "group:", "language:", "category:"] {
                if text.lowercased().hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count)).booruTrimmed
                    break
                }
            }
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                text = String(text.dropFirst().dropLast()).booruTrimmed
            }
            guard !text.isEmpty else { return }
            let key = text.lowercased()
            if isExcluded {
                if seenExclude.insert(key).inserted {
                    exclude.append(text)
                }
            } else if seenInclude.insert(key).inserted {
                include.append(text)
            }
        }

        // RN :686-691: quoted groups are taken first, the rest is whitespace-split.
        var rest = ""
        var groups: [(text: String, negated: Bool)] = []
        let characters = Array(raw ?? "")
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                var inner = ""
                var cursor = index + 1
                while cursor < characters.count, characters[cursor] != "\"" {
                    inner.append(characters[cursor])
                    cursor += 1
                }
                let negated = rest.hasSuffix("-")
                if negated {
                    rest.removeLast()
                }
                groups.append((text: inner, negated: negated))
                index = cursor < characters.count ? cursor + 1 : cursor
                continue
            }
            rest.append(character)
            index += 1
        }

        for group in groups {
            push((group.negated ? "-" : "") + group.text, negated: false)
        }
        for part in rest.split(whereSeparator: { $0.isWhitespace }) {
            push(String(part), negated: false)
            if include.count + exclude.count >= 12 {
                break
            }
        }
        return ParsedQuery(include: include, exclude: exclude)
    }

    /// RN `normHentaiHavenToken` (hentaihavens.ts:592-598).
    static func normalizedToken(_ value: String?) -> String {
        (value ?? "").lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// RN `stripHentaiAffix` (hentaihavens.ts:602-608).
    static func stripAffix(_ value: String) -> String {
        var text = value
        if text.hasPrefix("hentai ") {
            text = String(text.dropFirst("hentai ".count))
        }
        if text.hasSuffix(" hentai") {
            text = String(text.dropLast(" hentai".count))
        }
        return text.booruTrimmed
    }

    /// RN `findHentaiHavenGenre` (hentaihavens.ts:615-641): separators are ignored, the ` Hentai`
    /// affix may drop, and the exact match beats a higher-count fuzzy one.
    static func findGenre(_ genres: [HentaiHavenTermDTO], _ token: String?) -> HentaiHavenTermDTO? {
        let needle = normalizedToken(token)
        guard !needle.isEmpty else { return nil }
        let compact = needle.replacingOccurrences(of: " ", with: "")
        var best: (genre: HentaiHavenTermDTO, rank: Int)?

        for genre in genres {
            let name = normalizedToken(genre.name)
            let slug = normalizedToken(genre.slug)
            let nameCompact = name.replacingOccurrences(of: " ", with: "")
            let slugCompact = slug.replacingOccurrences(of: " ", with: "")
            var rank: Int?
            if needle == name || needle == slug || compact == nameCompact || compact == slugCompact {
                rank = 0
            } else {
                let base = stripAffix(name)
                if !base.isEmpty, needle == base || compact == base.replacingOccurrences(of: " ", with: "") {
                    rank = 1
                }
            }
            guard let rank else { continue }
            if let current = best {
                let better = rank < current.rank
                    || (rank == current.rank && (genre.count ?? 0) > (current.genre.count ?? 0))
                if better {
                    best = (genre: genre, rank: rank)
                }
            } else {
                best = (genre: genre, rank: rank)
            }
        }
        return best?.genre
    }

    /// RN hentaihavens.ts:1028-1034: the phrase form of the query, without a leading prefix or quotes.
    static func rawPhrase(_ tags: String) -> String {
        var text = tags.booruTrimmed
        for prefix in ["tag:", "genre:", "artist:", "character:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).booruTrimmed
            if text.hasPrefix("\"") {
                text = String(text.dropFirst())
            }
            break
        }
        if text.hasSuffix("\"") {
            text = String(text.dropLast())
        }
        return text.booruTrimmed
    }

    // MARK: - Genre pool

    /// RN `getAllGenres` (hentaihavens.ts:478-517): `genre/all` plus the static terms it omits.
    /// A failed call falls back to the static pool alone.
    static func fetchGenres(http: any HTTPClientProtocol) async throws -> [HentaiHavenTermDTO] {
        var merged: [HentaiHavenTermDTO] = []
        do {
            let data = try await apiData(path: "genre/all", http: http)
            let envelope = try BooruJSONSupport.decode(
                HentaiHavenEnvelope<HentaiHavenTermList>.self,
                from: data,
                failure: "HentaiHaven genres did not return valid JSON."
            )
            merged = envelope.data?.terms ?? []
        } catch let error as CancellationError {
            throw error
        } catch {
            merged = []
        }

        var seen = Set(merged.compactMap { $0.termID })
        for known in knownGenres {
            guard let termID = known.termID, !seen.contains(termID) else { continue }
            seen.insert(termID)
            merged.append(known)
        }
        return merged
    }

    // MARK: - Item fetches

    /// `/genre/{id}?p=` (hentaihavens.ts:852-860).
    static func genreItems(termID: Int, page: Int, http: any HTTPClientProtocol) async throws -> [HentaiHavenItemDTO] {
        let data = try await apiData(path: "genre/\(termID)?p=\(max(1, page))", http: http)
        let listing = try BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenListingDTO>.self,
            from: data,
            failure: "HentaiHaven genre did not return valid JSON."
        )
        return listing.data?.hentais ?? []
    }

    /// `search?q=` (hentaihavens.ts:867-876): single page only, the API ignores `&p`.
    static func searchItems(token: String, page: Int, http: any HTTPClientProtocol) async throws -> [HentaiHavenItemDTO] {
        guard page <= 1 else { return [] }
        let data = try await apiData(path: "search?q=\(BooruJSONSupport.encode(token))", http: http)
        let list = try BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenItemList>.self,
            from: data,
            failure: "HentaiHaven search did not return valid JSON."
        )
        return list.data?.items ?? []
    }

    /// RN `fetchMultiTokenItems` (hentaihavens.ts:902-952): per-token genre or title lookup,
    /// intersected over post ids, with the union as the fallback.
    static func multiTokenItems(
        tokens: [String],
        genres: [HentaiHavenTermDTO],
        page: Int,
        http: any HTTPClientProtocol
    ) async throws -> [HentaiHavenItemDTO] {
        var lists: [[HentaiHavenItemDTO]] = []
        var hasSearchToken = false
        for token in tokens.prefix(5) {
            if let genre = findGenre(genres, token), let termID = genre.termID {
                lists.append(try await genreItems(termID: termID, page: page, http: http))
            } else {
                hasSearchToken = true
                if page > 1 {
                    lists.append([])
                } else {
                    lists.append(try await searchItems(token: token, page: page, http: http))
                }
            }
        }
        guard lists.contains(where: { !$0.isEmpty }) else { return [] }
        // RN :941-943: on page > 1 the title search is empty, so the intersection is meaningless.
        if page > 1 && hasSearchToken {
            return []
        }

        var hits: [Int: (item: HentaiHavenItemDTO, count: Int, firstSeen: Int)] = [:]
        var order = 0
        for list in lists {
            var seen = Set<Int>()
            for item in list {
                guard let postID = item.postID, !seen.contains(postID) else { continue }
                seen.insert(postID)
                if var existing = hits[postID] {
                    existing.count += 1
                    hits[postID] = existing
                } else {
                    hits[postID] = (item: item, count: 1, firstSeen: order)
                    order += 1
                }
            }
        }

        let all = hits.values.sorted { $0.firstSeen < $1.firstSeen }
        let intersection = all.filter { $0.count == lists.count }
        if !intersection.isEmpty {
            return intersection.map { $0.item }
        }
        // RN :947-951: the union lists the most token matches first.
        return all.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.firstSeen < rhs.firstSeen : lhs.count > rhs.count
        }.map { $0.item }
    }

    /// RN `applyHentaiHavenExcludes` (hentaihavens.ts:954-966): list items carry no tags, so the
    /// exclusion is a best-effort title match.
    static func excluding(_ posts: [BooruPost], _ exclude: [String]) -> [BooruPost] {
        let norms = exclude
            .map { normalizedToken($0).replacingOccurrences(of: " ", with: "") }
            .filter { !$0.isEmpty }
        guard !norms.isEmpty else { return posts }
        return posts.filter { post in
            let hay = normalizedToken(post.title ?? "").replacingOccurrences(of: " ", with: "")
            if hay.isEmpty {
                return true
            }
            return !norms.contains { hay.contains($0) }
        }
    }

    // MARK: - BooruSource

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let tags = HentaiHavenSource.searchText(for: query)
        let parsed = HentaiHavenSource.parseQuery(tags)
        let posts: [BooruPost]

        if parsed.include.isEmpty {
            // RN hentaihavens.ts:1019-1023: no section means trend for score sorting, newest otherwise.
            let section: HentaiHavenFeedSection = query.filter.hentaiHavenSection
                ?? (query.filter.sortBy == .score ? .trending : .latest)
            posts = try await fetchSection(section, page: page, context: context)
        } else {
            posts = try await searchPosts(parsed: parsed, tags: tags, page: page, context: context)
        }
        return BooruJSONSupport.page(posts, requestedPage: page)
    }

    /// RN `searchHentaiHavenTags` (hentaihavens.ts:703-735): the genre pool is matched by name and slug.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        let query = HentaiHavenSource.normalizedToken(prefix)
        guard !query.isEmpty else { return [] }
        let compact = query.replacingOccurrences(of: " ", with: "")

        let pool: [HentaiHavenTermDTO]? = try await BooruJSONSupport.tolerant {
            try await HentaiHavenGenreCache.shared.genres(http: context.http)
        }
        guard let pool else { return [] }

        let matched = pool.filter { genre in
            let name = HentaiHavenSource.normalizedToken(genre.name)
            let slug = HentaiHavenSource.normalizedToken(genre.slug)
            return name.contains(query) || slug.contains(query)
                || name.replacingOccurrences(of: " ", with: "").contains(compact)
                || slug.replacingOccurrences(of: " ", with: "").contains(compact)
        }
        .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
        .prefix(BooruQueryTranslator.suggestionLimit)

        return matched.compactMap { genre -> BooruTagSuggestion? in
            guard let name = genre.name?.booruTrimmed, !name.isEmpty else { return nil }
            return BooruTagSuggestion(name: name, category: .general, postCount: genre.count ?? 0)
        }
    }

    static func isPlayableVideoURL(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        let path = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? raw
        return [".m3u8", ".mp4", ".mov", ".m4v", ".webm"].contains { path.hasSuffix($0) }
    }

    /// RN `resolveHentaiHavenEpisodeUrls` (hentaihavens.ts:1417-1447): the series episode list is
    /// read here, then the default (newest) episode's HLS stream or its MP4 fallback is returned.
    /// Every failure path still exposes the cover and any listing-level video, never treating a
    /// `.jpg` cover image as a video stream.
    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        let placeholder = ImageQualityResolver.placeholderURL(for: post)
        let fallbackVideo = [post.previewVideoURL, post.sampleURL]
            .compactMap { $0 }
            .first(where: Self.isPlayableVideoURL)
        let episodes: [HentaiHavenEpisode]
        do {
            episodes = try await fetchEpisodes(for: post, context: context)
        } catch let error as CancellationError {
            throw error
        } catch {
            episodes = []
        }

        // `fetchEpisodes` is ordered ascending for the selector; the newest episode is the default.
        guard let target = episodes.last ?? episodes.first else {
            return ResolvedMedia(
                imageURL: post.previewURL,
                videoURL: fallbackVideo,
                isVideo: fallbackVideo != nil,
                placeholderURL: placeholder
            )
        }

        let stream: URL?
        do {
            stream = try await resolveEpisodeStream(episode: target, post: post, context: context)
        } catch let error as CancellationError {
            throw error
        } catch {
            stream = nil
        }
        let video = stream ?? fallbackVideo
        return ResolvedMedia(
            imageURL: target.thumbnailURL ?? post.previewURL,
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: placeholder
        )
    }

    // MARK: - Episodes

    /// All playable episodes of one series, ordered ascending by episode number.
    /// Numeric ids go straight to `/v1/hentai/{id}` (the `hentaihaven_` / `hh_` prefixes are
    /// stripped the same way `resolveMedia` resolves its target); slug-only cards reuse the title
    /// search path. The parsed list is cached per series slug.
    func fetchEpisodes(for post: BooruPost, context: SourceContext) async throws -> [HentaiHavenEpisode] {
        guard let slug = HentaiHavenSource.seriesSlug(for: post) else { return [] }
        if let cached = await HentaiHavenEpisodeCache.shared.episodes(for: slug) {
            return cached
        }

        let detail: HentaiHavenDetailDTO?
        do {
            detail = try await HentaiHavenSource.seriesDetail(for: post, http: context.http)
        } catch let error as CancellationError {
            throw error
        } catch {
            detail = nil
        }
        guard let detail else { return [] }

        let episodes = HentaiHavenSource.episodeModels(from: detail)
        if !episodes.isEmpty {
            await HentaiHavenEpisodeCache.shared.store(episodes, for: slug)
        }
        return episodes
    }

    /// Direct playable URL for one episode. The detail payload usually carries it already; when it
    /// does not, the series detail is fetched again and the matching episode is used. The post's
    /// own video/cover chain is the final fallback.
    func resolveEpisodeStream(
        episode: HentaiHavenEpisode,
        post: BooruPost,
        context: SourceContext
    ) async throws -> URL? {
        if let stream = episode.streamURL {
            return stream
        }

        let detail: HentaiHavenDetailDTO?
        do {
            detail = try await HentaiHavenSource.seriesDetail(for: post, http: context.http)
        } catch let error as CancellationError {
            throw error
        } catch {
            detail = nil
        }
        if let detail {
            let match = HentaiHavenSource.episodeModels(from: detail)
                .first { $0.id == episode.id || $0.number == episode.number }
            if let stream = match?.streamURL {
                return stream
            }
            let models = HentaiHavenSource.episodeModels(from: detail)
            if !models.isEmpty, let slug = HentaiHavenSource.seriesSlug(for: post) {
                await HentaiHavenEpisodeCache.shared.store(models, for: slug)
            }
        }
        return [post.previewVideoURL, post.sampleURL]
            .compactMap { $0 }
            .first(where: Self.isPlayableVideoURL)
    }

    // MARK: - Detail resolution

    /// RN `resolveHentaiHavenGalleryDetail` (hentaihavens.ts:1250-1368), API path only.
    static func detail(for post: BooruPost, http: any HTTPClientProtocol) async throws -> HentaiHavenDetailDTO? {
        guard let targetID = try await resolvePostID(for: post, http: http) else { return nil }
        let data = try await apiData(path: "hentai/\(targetID)", http: http)
        let envelope = try? BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenDetailDTO>.self,
            from: data,
            failure: "HentaiHaven detail did not return valid JSON."
        )
        return envelope?.data
    }

    /// RN :1256-1287: a numeric media id first, then the slug through a title search.
    static func resolvePostID(for post: BooruPost, http: any HTTPClientProtocol) async throws -> Int? {
        if let mediaID = post.mediaId?.booruTrimmed, let numericID = Int(mediaID) {
            return numericID
        }
        var rawID = post.id.booruTrimmed
        let lowered = rawID.lowercased()
        for prefix in ["hentaihaven_", "hh_"] where lowered.hasPrefix(prefix) {
            rawID = String(rawID.dropFirst(prefix.count)).booruTrimmed
            break
        }
        if let numericID = Int(rawID) {
            return numericID
        }
        guard let link = post.sourceLink?.absoluteString, let slug = watchSlug(link) else { return nil }

        let genres: [HentaiHavenTermDTO]
        do {
            genres = try await HentaiHavenGenreCache.shared.genres(http: http)
        } catch let error as CancellationError {
            throw error
        } catch {
            genres = []
        }
        let tokens = slug.split(separator: "-").map { String($0) }.filter { !$0.isEmpty }
        let items = try await multiTokenItems(tokens: tokens, genres: genres, page: 1, http: http)
        return items.first { item in
            item.postName == slug || item.postID.map { String($0) } == slug
        }?.postID
    }

    /// RN :1271-1272: `/watch/{slug}/`.
    static func watchSlug(_ link: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/watch/([a-z0-9-]+)/"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let range = Range(match.range(at: 1), in: link) else {
            return nil
        }
        return String(link[range])
    }

    /// Series id/slug used by the episode layer. `mediaId` wins; otherwise the `hentaihaven_` /
    /// `hh_` prefix is stripped from `post.id` (case-insensitively, matching `resolveMedia`) and a
    /// non-numeric leftover such as `hh_ep_11` falls back to the `/watch/{slug}/` source link.
    static func seriesSlug(for post: BooruPost) -> String? {
        if let mediaID = post.mediaId?.booruTrimmed, !mediaID.isEmpty {
            return mediaID
        }
        var raw = post.id.booruTrimmed
        let lowered = raw.lowercased()
        for prefix in ["hentaihaven_", "hh_"] where lowered.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count)).booruTrimmed
            break
        }
        if !raw.isEmpty, Int(raw) != nil {
            return raw
        }
        if let slug = watchSlug(post.sourceLink?.absoluteString ?? "") {
            return slug
        }
        return raw.isEmpty ? nil : raw
    }

    /// Series detail for the episode layer. Numeric ids hit `/v1/hentai/{id}` directly; slug-only
    /// cards go through the same title-search resolution `resolveMedia` uses.
    static func seriesDetail(
        for post: BooruPost,
        http: any HTTPClientProtocol
    ) async throws -> HentaiHavenDetailDTO? {
        guard let slug = seriesSlug(for: post) else { return nil }
        guard Int(slug) != nil else {
            return try await detail(for: post, http: http)
        }
        let data = try await apiData(path: "hentai/\(slug)", http: http)
        let envelope = try? BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenDetailDTO>.self,
            from: data,
            failure: "HentaiHaven detail did not return valid JSON."
        )
        return envelope?.data
    }

    /// One playable episode of a series (RN hentaihavens.ts:1300-1330).
    struct ResolvedEpisode: Equatable, Sendable {
        let number: Int
        let name: String
        let chapterID: String?
        /// Direct HLS URL from `chapter_content`.
        let streamURL: String
        /// Direct MP4 fallback from `preview`.
        let previewURL: String
        let thumbnail: String
    }

    /// RN :1301-1330: episodes are ordered newest first.
    static func episodes(from detail: HentaiHavenDetailDTO) -> [ResolvedEpisode] {
        let mapped = detail.episodes.enumerated().map { index, dto -> ResolvedEpisode in
            let rawName = BooruJSONSupport.firstNonEmpty(dto.chapterName, dto.chapterSlug)
            let number = firstNumber(in: rawName) ?? (index + 1)
            let name = (dto.chapterName ?? "").booruTrimmed
            return ResolvedEpisode(
                number: number,
                name: name.isEmpty ? "Episode \(number)" : name,
                chapterID: dto.chapterID,
                streamURL: (dto.chapterContent ?? "").booruTrimmed,
                previewURL: (dto.preview ?? "").booruTrimmed,
                thumbnail: BooruJSONSupport.firstNonEmpty(dto.chapterThumbnail, dto.postThumbnail)
            )
        }
        return mapped.sorted { $0.number > $1.number }
    }

    static func firstNumber(in value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return nil
        }
        return Int(value[range])
    }

    /// Maps `post_episodes` into the viewer-facing model, ascending by episode number.
    /// `chapter_content` is the direct HLS stream; when it is missing the MP4 `preview` becomes the
    /// playable URL so an episode is never dropped just because the HLS field is empty.
    static func episodeModels(from detail: HentaiHavenDetailDTO) -> [HentaiHavenEpisode] {
        let mapped = detail.episodes.enumerated().map { index, dto -> HentaiHavenEpisode in
            let rawName = BooruJSONSupport.firstNonEmpty(dto.chapterName, dto.chapterSlug)
            let number = firstNumber(in: rawName) ?? (index + 1)
            let name = (dto.chapterName ?? "").booruTrimmed
            let title = name.isEmpty ? "Episode \(number)" : name
            let identifier = dto.chapterID ?? "\(detail.postID ?? 0)_\(number)"
            let hls = BooruJSONSupport.absoluteURL(dto.chapterContent, baseURL: baseURL)
            let mp4 = BooruJSONSupport.absoluteURL(dto.preview, baseURL: baseURL)
            let thumbnail = BooruJSONSupport.firstNonEmpty(dto.chapterThumbnail, dto.postThumbnail)
            return HentaiHavenEpisode(
                id: identifier,
                number: number,
                title: title,
                streamURL: hls ?? mp4,
                thumbnailURL: BooruJSONSupport.absoluteURL(thumbnail, baseURL: baseURL)
            )
        }
        return mapped.sorted { lhs, rhs in
            lhs.number == rhs.number ? lhs.id < rhs.id : lhs.number < rhs.number
        }
    }

    // MARK: - Section fetches

    private func fetchSection(
        _ section: HentaiHavenFeedSection,
        page: Int,
        context: SourceContext
    ) async throws -> [BooruPost] {
        switch section {
        case .trending, .episodes:
            // RN :976-990: home streams carry 20 items and have no pagination.
            guard page <= 1 else { return [] }
            let data = try await HentaiHavenSource.apiData(path: "hentai/home", http: context.http)
            let home = try BooruJSONSupport.decode(
                HentaiHavenEnvelope<HentaiHavenHomeDTO>.self,
                from: data,
                failure: "HentaiHaven home did not return valid JSON."
            ).data
            guard let home else { return [] }
            if section == .trending {
                return home.trendingMonth.compactMap { mapItem($0) }
            }
            return home.lastEpisodes.compactMap { mapEpisode($0) }
        case .latest:
            return try await listingPosts(path: "hentai/all?p=\(max(1, page))", context: context)
        default:
            guard let termID = HentaiHavenSource.genreID(for: section) else {
                return try await listingPosts(path: "hentai/all?p=\(max(1, page))", context: context)
            }
            return try await listingPosts(path: "genre/\(termID)?p=\(max(1, page))", context: context)
        }
    }

    /// `/hentai/all?p=` (hentaihavens.ts:982-987) and the upcoming genre page.
    private func listingPosts(path: String, context: SourceContext) async throws -> [BooruPost] {
        let data = try await HentaiHavenSource.apiData(path: path, http: context.http)
        let listing = try BooruJSONSupport.decode(
            HentaiHavenEnvelope<HentaiHavenListingDTO>.self,
            from: data,
            failure: "HentaiHaven list did not return valid JSON."
        ).data
        return (listing?.hentais ?? []).compactMap { mapItem($0) }
    }

    /// RN `fetchHentaiHavenPosts` query path (hentaihavens.ts:1036-1070).
    private func searchPosts(
        parsed: ParsedQuery,
        tags: String,
        page: Int,
        context: SourceContext
    ) async throws -> [BooruPost] {
        let genres: [HentaiHavenTermDTO]
        do {
            genres = try await HentaiHavenGenreCache.shared.genres(http: context.http)
        } catch let error as CancellationError {
            throw error
        } catch {
            genres = []
        }
        let pageNumber = max(1, page)
        let includes = parsed.include
        var items: [HentaiHavenItemDTO]

        if includes.count > 1, !tags.contains("\"") {
            // RN :1028-1042: a multi-word phrase that names a genre or studio stays whole.
            let phrase = HentaiHavenSource.rawPhrase(tags)
            if let genre = HentaiHavenSource.findGenre(genres, phrase), let termID = genre.termID {
                items = try await HentaiHavenSource.genreItems(termID: termID, page: pageNumber, http: context.http)
            } else {
                items = try await HentaiHavenSource.multiTokenItems(tokens: includes, genres: genres, page: pageNumber, http: context.http)
            }
        } else if includes.count == 1 {
            if let genre = HentaiHavenSource.findGenre(genres, includes[0]), let termID = genre.termID {
                items = try await HentaiHavenSource.genreItems(termID: termID, page: pageNumber, http: context.http)
            } else {
                items = try await HentaiHavenSource.searchItems(token: includes[0], page: pageNumber, http: context.http)
            }
        } else {
            items = try await HentaiHavenSource.multiTokenItems(tokens: includes, genres: genres, page: pageNumber, http: context.http)
        }

        let posts = items.compactMap { mapItem($0) }
        return HentaiHavenSource.excluding(posts, parsed.exclude)
    }

    // MARK: - Mapping (RN hentaihavens.ts:739-830)

    private func mapItem(_ dto: HentaiHavenItemDTO) -> BooruPost? {
        guard let numericID = dto.postID else { return nil }
        let slug = BooruJSONSupport.firstNonEmpty(dto.postName, String(numericID))
        let poster = (dto.postThumbnail ?? "").booruTrimmed
        let views = dto.postViews ?? 0
        let title = (dto.postTitle ?? "").booruTrimmed

        return BooruPost(
            id: "hh_\(numericID)",
            sourceID: id,
            sourceName: displayName,
            title: title.isEmpty ? nil : title,
            previewURL: BooruJSONSupport.absoluteURL(poster, baseURL: HentaiHavenSource.baseURL),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: BooruJSONSupport.absoluteURL(poster, baseURL: HentaiHavenSource.baseURL),
            originalURL: nil,
            width: 600,
            height: 900,
            aspectRatio: 2.0 / 3.0,
            rating: .explicit,
            score: views,
            favCount: views,
            tags: BooruTagGroups(meta: ["video"]),
            allTags: [],
            sourceLink: URL(string: "\(HentaiHavenSource.baseURL)/watch/\(slug)/"),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: BooruJSONSupport.firstNonEmpty(dto.postDate, BooruJSONSupport.isoString(Date())),
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: String(numericID)
        )
    }

    /// RN `mapApiEpisodeItemToPost` (hentaihavens.ts:783-830).
    private func mapEpisode(_ dto: HentaiHavenEpisodeDTO) -> BooruPost? {
        guard let numericID = dto.postID else { return nil }
        let slug = BooruJSONSupport.firstNonEmpty(dto.postName, String(numericID))
        let poster = BooruJSONSupport.firstNonEmpty(dto.chapterThumbnail, dto.postThumbnail)
        guard !poster.isEmpty else { return nil }

        let episodeName = BooruJSONSupport.firstNonEmpty(dto.chapterName, "Episode")
        let postTitle = (dto.postTitle ?? "").booruTrimmed
        let title = postTitle.isEmpty ? episodeName : "\(postTitle) - \(episodeName)"
        let identifier = dto.chapterID ?? "\(numericID)_\(episodeName)"

        return BooruPost(
            id: "hh_ep_\(identifier)",
            sourceID: id,
            sourceName: displayName,
            title: title,
            previewURL: BooruJSONSupport.absoluteURL(poster, baseURL: HentaiHavenSource.baseURL),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: BooruJSONSupport.absoluteURL(poster, baseURL: HentaiHavenSource.baseURL),
            originalURL: nil,
            width: 600,
            height: 900,
            aspectRatio: 2.0 / 3.0,
            rating: .explicit,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(meta: ["video"]),
            allTags: [],
            sourceLink: URL(string: "\(HentaiHavenSource.baseURL)/watch/\(slug)/"),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: BooruJSONSupport.firstNonEmpty(dto.chapterDate, BooruJSONSupport.isoString(Date())),
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: String(numericID)
        )
    }
}
