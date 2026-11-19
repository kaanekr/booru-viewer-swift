import Foundation

/// nhentai adapter (`id` `nhentai`). Official v2 API only, no HTML scraping:
/// `/api/v2/galleries`, `/api/v2/search`, `/api/v2/galleries/{id}`, `/api/v2/tags/search`.
/// RN: `src/services/nhentai.ts` (whole module) and `fetchNHentaiPosts` (booruApi.ts:1738-1808).
struct NHentaiSource: BooruSource {
    let id: SourceID = .nhentai
    let displayName = "nhentai"
    let supportsVideo = false

    /// RN nhentai.ts:23-35. Covers default to t2, page images to i3: t1/i1 are blocked on some
    /// networks while t2/t3 and i3 stay reachable.
    static let baseURL = "https://nhentai.net"
    static let apiBaseURL = "https://nhentai.net/api/v2"
    static let imageBaseURL = "https://i3.nhentai.net"
    static let thumbBaseURL = "https://t2.nhentai.net"
    static let thumbFallbackBaseURL = "https://t3.nhentai.net"
    /// RN nhentai.ts:47-49: a full Safari UA; the API's bot protection stalls a tokenless WKWebView form.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
    /// RN nhentai.ts:658-664 / 676-678: CDN rotation order per host family.
    static let imageHosts = ["https://i3.nhentai.net", "https://i2.nhentai.net", "https://i4.nhentai.net", "https://i1.nhentai.net"]
    static let thumbHosts = ["t2", "t3", "t4", "t1"]

    // MARK: - Requests

    /// RN `nhentaiApiHeaders` (nhentai.ts:56-65): Safari headers and, deliberately, no Referer.
    static func request(url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func url(_ path: String) -> URL? {
        URL(string: apiBaseURL + "/" + path)
    }

    static func fetchData(url: URL, http: any HTTPClientProtocol) async throws -> Data {
        let (data, response) = try await BooruJSONSupport.send(request(url: url), http: http)
        guard BooruJSONSupport.isSuccess(response.statusCode) else {
            throw BooruJSONSupport.statusError(response.statusCode)
        }
        return data
    }

    /// RN nhentai.ts:1783-1787: the Cloudflare bot wall arrives as a 2xx HTML body.
    static func isChallenge(body: Data) -> Bool {
        let prefix = String(decoding: body.prefix(4000), as: UTF8.self).lowercased()
        return ["just a moment", "challenge-platform", "cf-challenge", "attention required"].contains { prefix.contains($0) }
    }

    // MARK: - Query (RN nhentai.ts:100-200, booruApi.ts:1745-1750)

    /// RN `fetchNHentaiPosts` builds its text from the base tags plus the plain user word.
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

    /// RN `nhentaiApiSort` (nhentai.ts:100-108).
    static func apiSort(for filter: SearchFilterConfig) -> String {
        guard filter.sortBy == .score else { return "date" }
        switch filter.timeRange {
        case .oneDay: return "popular-today"
        case .oneWeek: return "popular-week"
        case .oneMonth: return "popular-month"
        case .oneYear, .all: return "popular"
        }
    }

    /// RN `buildNHentaiApiCandidates` (nhentai.ts:167-200).
    static func candidateURLs(page: Int, keyword: String, sort: String, minScore: Int?) -> [URL] {
        let pageNumber = max(1, page)
        var query = keyword.booruTrimmed
        // RN :174-177: the server-side favorite threshold rides on the query itself.
        if let minScore, minScore > 0, !query.contains("favorites:") {
            query = query.isEmpty ? "favorites:>=\(minScore)" : "\(query) favorites:>=\(minScore)"
        }

        if query.isEmpty {
            if sort == "popular-today" {
                // RN :180-182: today's popular list is page-1 only.
                return pageNumber <= 1 ? [url("galleries/popular")].compactMap { $0 } : []
            }
            if sort != "date" {
                // RN :183-186: `query=*` pages the whole archive by popularity.
                return [url("search?query=*&sort=\(BooruJSONSupport.encode(sort))&page=\(pageNumber)")].compactMap { $0 }
            }
            return [url("galleries?page=\(pageNumber)&per_page=25")].compactMap { $0 }
        }
        return [url("search?query=\(BooruJSONSupport.encode(query))&sort=\(BooruJSONSupport.encode(sort))&page=\(pageNumber)")].compactMap { $0 }
    }

    // MARK: - BooruSource

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let keyword = NHentaiSource.searchText(for: query)
        let sort = NHentaiSource.apiSort(for: query.filter)
        let candidates = NHentaiSource.candidateURLs(
            page: page,
            keyword: keyword,
            sort: sort,
            minScore: query.filter.minScore
        )
        guard !candidates.isEmpty else {
            return PostPage(posts: [], nextPage: nil, hasMore: false)
        }

        // RN :1756-1804: one attempt per candidate, no retry, 404 means the list ended.
        var lastError: BooruError?
        for url in candidates {
            do {
                let data = try await NHentaiSource.fetchData(url: url, http: context.http)
                guard !NHentaiSource.isChallenge(body: data) else {
                    lastError = .decoding("nhentai returned a challenge page.")
                    continue
                }
                let listing = try BooruJSONSupport.decode(
                    NHentaiListingResponse.self,
                    from: data,
                    failure: "nhentai did not return valid JSON."
                )
                let posts = NHentaiSource.minScoreFiltered(
                    listing.galleries.compactMap { mapGallery($0) },
                    minScore: query.filter.minScore
                )
                if !posts.isEmpty {
                    return BooruJSONSupport.page(posts, requestedPage: page)
                }
            } catch let error as BooruError {
                if case .rateLimited = error {
                    throw error
                }
                if case .http(let status) = error, status == 404 {
                    continue
                }
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return BooruJSONSupport.page([], requestedPage: page)
    }

    /// RN nhentai.ts:594-634 tag search through `POST /api/v2/tags/search`. Failures return an
    /// empty list. The local instant-match pool is a UI concern and lives with the search screen.
    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        let query = prefix.booruTrimmed
        guard !query.isEmpty else { return [] }

        let limit = BooruQueryTranslator.suggestionLimit
        let payload: [String: Any] = ["query": query, "limit": min(50, max(5, limit))]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = NHentaiSource.url("tags/search") else {
            return []
        }

        let found: [BooruTagSuggestion]? = try await BooruJSONSupport.tolerant {
            let (data, response) = try await BooruJSONSupport.send(
                NHentaiSource.request(url: url, method: "POST", body: body),
                http: context.http
            )
            guard BooruJSONSupport.isSuccess(response.statusCode) else { return nil }
            let tags = (try? BooruJSONSupport.decode(
                [FailableDecodable<NHentaiTagDTO>].self,
                from: data,
                failure: "nhentai tags did not return valid JSON."
            )) ?? []
            return tags.compactMap { wrapper -> BooruTagSuggestion? in
                guard let tag = wrapper.value else { return nil }
                let name = NHentaiSource.decodeEntities(tag.name ?? "").booruTrimmed
                guard !name.isEmpty else { return nil }
                return BooruTagSuggestion(
                    name: name,
                    category: NHentaiSource.tagCategory(tag.type),
                    postCount: tag.count ?? 0
                )
            }
        }
        return found ?? []
    }

    /// RN `resolveNHentaiGalleryDetail` (nhentai.ts:373-435): the full gallery is read here and the
    /// first page becomes the display image. A failed lookup degrades to the listing cover.
    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        let placeholder = ImageQualityResolver.placeholderURL(for: post)
        let pages: [URL]
        do {
            pages = try await galleryPages(for: post, context: context)
        } catch let error as CancellationError {
            throw error
        } catch {
            pages = []
        }
        // Never hand the viewer a nil display URL: the first page, the post's own cover chain,
        // and finally the listing thumbnail are all valid targets. A nil imageURL is what rendered
        // the "Media unavailable" state on every nhentai card when the gallery detail call failed.
        let imageURL = pages.first
            ?? ImageQualityResolver.imageURL(for: post, quality: context.imageQuality)
            ?? post.sampleURL
            ?? post.previewURL
        return ResolvedMedia(imageURL: imageURL, videoURL: nil, isVideo: false, placeholderURL: placeholder)
    }

    // MARK: - Gallery pages

    struct GalleryDetail: Sendable, Equatable {
        let pages: [URL]
        let tags: BooruTagGroups
        let allTags: [String]
    }

    /// Categorized tag groups parsed from `/api/v2/galleries/{id}` (nhentai.ts:340-370).
    static func tagGroups(from detail: NHentaiGalleryDetailDTO) -> (groups: BooruTagGroups, allTags: [String]) {
        var artist: [String] = []
        var character: [String] = []
        var copyright: [String] = []
        var general: [String] = []
        var meta: [String] = ["manga"]

        for tag in detail.tags {
            let clean = decodeEntities(tag.name ?? "").booruTrimmed
            guard !clean.isEmpty else { continue }
            switch tagCategory(tag.type) {
            case .artist: artist.append(clean)
            case .character: character.append(clean)
            case .copyright: copyright.append(clean)
            case .general: general.append(clean)
            case .meta: meta.append(clean)
            }
        }

        let groups = BooruTagGroups(
            artist: BooruJSONSupport.uniqued(artist),
            character: BooruJSONSupport.uniqued(character),
            copyright: BooruJSONSupport.uniqued(copyright),
            general: BooruJSONSupport.uniqued(general),
            meta: BooruJSONSupport.uniqued(meta)
        )
        let allTags = BooruJSONSupport.uniqued(
            groups.copyright + groups.character + groups.artist + groups.general + groups.meta
        )
        return (groups, allTags)
    }

    /// Full gallery detail: pages plus categorized tags (when returned by `/api/v2/galleries/{id}`).
    func galleryDetail(for post: BooruPost, context: SourceContext) async throws -> GalleryDetail {
        let galleryID = NHentaiSource.galleryID(for: post)
        let fallbackPages = NHentaiSource.fallbackPageURLs(for: post)
        let fallbackResult = GalleryDetail(pages: fallbackPages, tags: post.tags, allTags: post.allTags)
        guard !galleryID.isEmpty,
              let url = NHentaiSource.url("galleries/\(BooruJSONSupport.encode(galleryID))") else {
            return fallbackResult
        }

        let data: Data
        do {
            data = try await NHentaiSource.fetchData(url: url, http: context.http)
        } catch let error as CancellationError {
            throw error
        } catch {
            return fallbackResult
        }
        guard !NHentaiSource.isChallenge(body: data) else { return fallbackResult }

        guard let detail = try? BooruJSONSupport.decode(
            NHentaiGalleryDetailDTO.self,
            from: data,
            failure: "nhentai gallery detail did not return valid JSON."
        ) else {
            return fallbackResult
        }

        let parsedTags = detail.tags.isEmpty
            ? (groups: post.tags, allTags: post.allTags)
            : NHentaiSource.tagGroups(from: detail)

        let pages = NHentaiSource.pageURLs(fromDetail: detail)
        if !pages.isEmpty {
            return GalleryDetail(pages: pages, tags: parsedTags.groups, allTags: parsedTags.allTags)
        }
        let synthetic = NHentaiSource.syntheticPageURLs(
            mediaID: detail.mediaID ?? post.mediaId ?? "",
            pageCount: detail.numPages ?? post.pageCount ?? 0,
            fileExt: post.fileExt
        )
        if !synthetic.isEmpty {
            return GalleryDetail(pages: synthetic, tags: parsedTags.groups, allTags: parsedTags.allTags)
        }
        return GalleryDetail(pages: fallbackPages, tags: parsedTags.groups, allTags: parsedTags.allTags)
    }

    /// Every page URL of one gallery, for the manga reader (RN nhentai.ts:373-435).
    ///
    /// The v2 detail body is tried first (with the v1 `images.pages` shape decoded from the same
    /// payload). When the call fails, is challenged, or carries no usable pages, the cover chain
    /// supplies a displayable page so the viewer never ends up with nothing to show.
    func galleryPages(for post: BooruPost, context: SourceContext) async throws -> [URL] {
        try await galleryDetail(for: post, context: context).pages
    }

    /// Page URLs assembled from the post itself when the gallery endpoints give nothing back.
    /// `previewThumbs` wins; otherwise a cover that already lives under `/galleries/{mediaId}/`
    /// yields the deterministic page 1 URL, and the bare cover chain is the last resort.
    static func fallbackPageURLs(for post: BooruPost) -> [URL] {
        if let thumbs = post.previewThumbs, !thumbs.isEmpty {
            return thumbs
        }
        let mediaID = (post.mediaId ?? "").booruTrimmed
        if !mediaID.isEmpty {
            let marker = "/galleries/\(mediaID)/"
            let containsMedia = [post.sampleURL, post.previewURL].compactMap { $0 }
                .contains { $0.absoluteString.contains(marker) }
            if containsMedia, let pageOne = URL(string: "\(imageBaseURL)/galleries/\(mediaID)/1.jpg") {
                return [pageOne]
            }
        }
        return [post.sampleURL ?? post.previewURL].compactMap { $0 }
    }

    /// RN :391-397: the gallery id is the post id without the `nh_` / `nhentai_` prefix.
    /// The listing maps ids as `nh_<id>` while other layers persist `nhentai_<id>`, so both
    /// prefixes are stripped (case-insensitively); a bare numeric id is also accepted, and any
    /// leftover wrapper falls back to the first contiguous digit run (`nhentai_123456` -> `123456`).
    static func galleryID(for post: BooruPost) -> String {
        galleryID(from: post.id)
    }

    static func galleryID(from rawID: String) -> String {
        var raw = rawID.booruTrimmed
        guard !raw.isEmpty else { return "" }
        let lowered = raw.lowercased()
        for prefix in ["nhentai_", "nh_"] where lowered.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count)).booruTrimmed
            break
        }
        if !raw.isEmpty, raw.allSatisfy({ $0.isNumber }) {
            return raw
        }
        if let digits = raw.range(of: #"\d+"#, options: .regularExpression) {
            return String(raw[digits])
        }
        return raw
    }

    /// RN `parseNHentaiGalleryPages` (nhentai.ts:286-336) plus the synthetic safety net (:437-465).
    static func pageURLs(fromDetail detail: NHentaiGalleryDetailDTO) -> [URL] {
        // v2: `pages: [{number, path}]`; a missing `number` falls back to the array index (RN :293-307).
        let v2 = detail.pages.enumerated().compactMap { index, page -> (number: Int, order: Int, path: String)? in
            guard let path = page.path, !path.isEmpty else { return nil }
            let number = (page.number ?? 0) > 0 ? (page.number ?? index + 1) : index + 1
            return (number: number, order: index, path: path)
        }
        .sorted { $0.number == $1.number ? $0.order < $1.order : $0.number < $1.number }
        .compactMap { URL(string: absolutePageURL($0.path)) }
        if !v2.isEmpty {
            return v2
        }

        // v1 (and nested v2 payloads): `images.pages` with a media_id (RN :311-330).
        if let mediaID = detail.mediaID, !mediaID.isEmpty, !detail.legacyPages.isEmpty {
            let legacy = detail.legacyPages.enumerated().compactMap { index, page -> URL? in
                if let path = page.path, !path.isEmpty {
                    return URL(string: absolutePageURL(path))
                }
                let ext = legacyExtension(page.type)
                return URL(string: "\(imageBaseURL)/galleries/\(mediaID)/\(index + 1).\(ext)")
            }
            if !legacy.isEmpty {
                return legacy
            }
        }

        // Metadata-only safety net (RN :437-465).
        guard let mediaID = detail.mediaID, !mediaID.isEmpty else { return [] }
        let count = (detail.numPages ?? 0) > 0 ? (detail.numPages ?? 0) : detail.pages.count
        let ext = detail.pages.first.flatMap { $0.path }.map { pageExtension($0) } ?? "webp"
        return syntheticPageURLs(mediaID: mediaID, pageCount: count, fileExt: ext)
    }

    /// Page URLs built from listing metadata alone (RN `syntheticNHentaiPages`, nhentai.ts:437-465).
    static func syntheticPageURLs(mediaID: String, pageCount: Int, fileExt: String?) -> [URL] {
        let cleanMediaID = mediaID.booruTrimmed
        guard !cleanMediaID.isEmpty, pageCount > 0 else { return [] }
        var ext = (fileExt ?? "").booruTrimmed.lowercased().replacingOccurrences(of: "jpeg", with: "jpg")
        if ext.isEmpty {
            ext = "webp"
        }
        return (1...pageCount).compactMap { URL(string: "\(imageBaseURL)/galleries/\(cleanMediaID)/\($0).\(ext)") }
    }

    /// RN `extFromType` (nhentai.ts:67-76).
    static func legacyExtension(_ type: String?) -> String {
        switch (type ?? "").booruTrimmed.lowercased() {
        case "j": return "jpg"
        case "p": return "png"
        case "w": return "webp"
        case "g": return "gif"
        case let clean where !clean.isEmpty && clean.count <= 4: return clean
        default: return "jpg"
        }
    }

    /// Extension of a CDN page path, `webp` when it cannot be read.
    static func pageExtension(_ path: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\.([a-z0-9]{2,4})(?:\?|$)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else {
            return "webp"
        }
        return String(path[range]).lowercased().replacingOccurrences(of: "jpeg", with: "jpg")
    }

    /// RN nhentai.ts:228-232: the CDN extension is preserved; `jpeg` normalizes to `jpg`.
    static func thumbnailExtension(_ url: String) -> String {
        pageExtension(url)
    }

    static func absolutePageURL(_ path: String) -> String {
        if path.hasPrefix("http") {
            return path
        }
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "\(imageBaseURL)/\(clean)"
    }

    /// RN :237-239: the cover swaps `thumb.` for `cover.` on the fallback host.
    static func coverURL(_ thumbnail: String) -> String {
        thumbnail
            .replacingOccurrences(of: "/thumb.", with: "/cover.", options: [.caseInsensitive])
            .replacingOccurrences(of: thumbBaseURL, with: thumbFallbackBaseURL, options: [.caseInsensitive])
    }

    /// RN `rotateNhentaiThumbHost` (nhentai.ts:676-688): t2 -> t3 -> t4 -> t1, nil past the end.
    static func rotateThumbHost(_ url: String?) -> String? {
        rotateCDNHost(url, pattern: #"^(https?://)(t\d)\.nhentai\.net(/.*)$"#, hosts: thumbHosts)
    }

    /// RN `rotateNhentaiImageHost` (nhentai.ts:658-671): i3 -> i2 -> i4 -> i1, nil past the end.
    static func rotateImageHost(_ url: String?) -> String? {
        rotateCDNHost(url, pattern: #"^(https?://)(i\d)\.nhentai\.net(/.*)$"#, hosts: imageHosts.map { host in
            String(host.dropFirst("https://".count).prefix(2))
        })
    }

    private static func rotateCDNHost(_ url: String?, pattern: String, hosts: [String]) -> String? {
        guard let url,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let schemeRange = Range(match.range(at: 1), in: url),
              let hostRange = Range(match.range(at: 2), in: url),
              let pathRange = Range(match.range(at: 3), in: url) else {
            return nil
        }
        let host = String(url[hostRange]).lowercased()
        guard let index = hosts.firstIndex(of: host), index + 1 < hosts.count else { return nil }
        return String(url[schemeRange]) + hosts[index + 1] + ".nhentai.net" + String(url[pathRange])
    }

    /// RN nhentai.ts:75-83 entity decoding, in the same order.
    static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// RN `nhentaiTagCategory` (nhentai.ts:573-585).
    static func tagCategory(_ type: String?) -> TagCategory {
        switch (type ?? "").lowercased() {
        case "artist", "group": return .artist
        case "character": return .character
        case "parody": return .copyright
        case "language", "category": return .meta
        default: return .general
        }
    }

    /// RN `filterNHentaiMinScore` (booruApi.ts:1813-1821): only filters when the page reports favorites.
    static func minScoreFiltered(_ posts: [BooruPost], minScore: Int?) -> [BooruPost] {
        guard let minScore, minScore > 0, !posts.isEmpty else { return posts }
        guard posts.contains(where: { $0.score > 0 }) else { return posts }
        return posts.filter { $0.score >= minScore }
    }

    // MARK: - Mapping (RN nhentai.ts:207-270)

    private func mapGallery(_ dto: NHentaiGalleryDTO) -> BooruPost? {
        // RN :214-215: blacklisted galleries never surface.
        guard dto.blacklisted != true else { return nil }

        let title = NHentaiSource.decodeEntities(
            BooruJSONSupport.firstNonEmpty(dto.englishTitle, dto.japaneseTitle, "Gallery #\(dto.id)")
        ).booruTrimmed

        // RN :216-232: relative thumb paths hang off the t2 host, the extension is kept.
        let rawThumb = dto.thumbnail ?? ""
        let thumbnail = rawThumb.hasPrefix("http")
            ? rawThumb
            : NHentaiSource.thumbBaseURL + "/" + (rawThumb.hasPrefix("/") ? String(rawThumb.dropFirst()) : rawThumb)
        let ext = NHentaiSource.thumbnailExtension(thumbnail)
        let cover = NHentaiSource.coverURL(thumbnail)
        let previewFallback = NHentaiSource.rotateThumbHost(thumbnail)

        // nhentai covers are tall book pages; a missing/zero thumbnail size previously
        // produced a 250:350 card. The 1280x1810 default keeps the masonry column proportions
        // of real doujin thumbnails instead of squashing them toward landscape.
        let rawWidth = dto.thumbnailWidth ?? 0
        let rawHeight = dto.thumbnailHeight ?? 0
        let width = rawWidth > 0 ? rawWidth : 1280
        let height = rawHeight > 0 ? rawHeight : 1810
        let aspectRatio = Double(width) / Double(height)
        let favorites = dto.numFavorites ?? 0
        let pageCount = dto.numPages ?? 0

        return BooruPost(
            id: "nh_\(dto.id)",
            sourceID: id,
            sourceName: displayName,
            title: title.isEmpty ? nil : title,
            previewURL: URL(string: thumbnail),
            previewFallbackURL: previewFallback.flatMap { URL(string: $0) },
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: URL(string: cover),
            originalURL: URL(string: "\(NHentaiSource.imageBaseURL)/galleries/\(dto.mediaID)/1.\(ext)"),
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            rating: .explicit,
            score: favorites,
            favCount: favorites,
            tags: BooruTagGroups(meta: ["manga"]),
            allTags: [],
            sourceLink: URL(string: "\(NHentaiSource.baseURL)/g/\(dto.id)/"),
            fileExt: ext,
            fileSize: nil,
            createdAt: BooruJSONSupport.isoString(Date()),
            niches: nil,
            isPremium: nil,
            pageCount: pageCount > 0 ? pageCount : nil,
            mediaId: dto.mediaID
        )
    }
}
