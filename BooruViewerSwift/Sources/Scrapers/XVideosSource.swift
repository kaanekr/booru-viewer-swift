import Foundation

/// Remembers the current `/best` month for six hours (RN `xvideosBestMonth`, booruApi.ts:1548-1576).
actor XVideosBestMonthCache {
    private var month = ""
    private var storedAt: Date?

    /// The cached month while it is younger than six hours, otherwise nil.
    func cachedMonth(now: Date = Date()) -> String? {
        guard !month.isEmpty, let storedAt, now.timeIntervalSince(storedAt) < 6 * 60 * 60 else { return nil }
        return month
    }

    /// The last month seen, regardless of age (RN reads `this.xvideosBestMonth` without an expiry check).
    func lastKnownMonth() -> String {
        month
    }

    func store(_ value: String, now: Date = Date()) {
        month = value
        storedAt = now
    }
}

/// XVideos scraper. Mirrors RN `src/services/xvideos.ts` (URLs and parsing) and `fetchXVideosPosts` (booruApi.ts:1578-1667).
struct XVideosSource: BooruSource {
    let id: SourceID = .xvideos
    let displayName = "XVideos"
    let supportsVideo = true

    /// RN `XVIDEOS_BASE` (xvideos.ts:15).
    static let baseURL = "https://www.xvideos.com"
    /// RN `XVIDEOS_UA` (xvideos.ts:18-19). A mobile UA: the desktop variant returns different markup.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    static let acceptLanguage = "en-US,en;q=0.9"

    /// Site sort parameter (xvideos.ts:21).
    enum Sort: String {
        case relevance, uploaddate, rating, length, views
    }

    /// Site date-window parameter (xvideos.ts:22).
    enum Datef: String {
        case today, week, month, all
    }

    /// Shared `/best` month cache (RN keeps this on the API instance).
    private static let bestMonthCache = XVideosBestMonthCache()

    /// Named regex constants for the XVideos markup.
    private enum Pattern {
        /// Classic card start: each card begins with `id="video_<eid>"` (xvideos.ts:149-150).
        static let classicCardStart = #"id="video_"#
        /// Best-page card start: `id="video-thumb-<enc>"` (xvideos.ts:229).
        static let newCardStart = #"id="video-thumb-"#
        /// Numeric video id on classic cards (xvideos.ts:154).
        static let dataID = #"data-id="(\d+)""#
        /// Watch-page link, `/video.<slug>` (xvideos.ts:155).
        static let videoHref = #"<a[^>]*href="(\/video\.[^"]+)""#
        /// Lazy-load thumbnail template (xvideos.ts:161).
        static let dataSrc = #"data-src="([^"]+)""#
        /// Plain img src, used when there is no lazy-load attribute (xvideos.ts:161).
        static let imgSrc = #"<img[^>]*src="([^"]+)""#
        /// Hover preview mp4 (xvideos.ts:166).
        static let previewVideo = #"data-pvv="([^"]+\.mp4[^"]*)""#
        /// Title, first form: anchor title inside a paragraph (xvideos.ts:172).
        static let titleParagraph = #"<p class="title"><a[^>]*title="([^"]+)""#
        /// Title, second form: div title attribute (xvideos.ts:173).
        static let titleDiv = #"<div class="title" title="([^"]+)""#
        /// Title, last resort: any title attribute (xvideos.ts:174).
        static let titleAttribute = #"title="([^"]+)""#
        /// Uploader name (xvideos.ts:177).
        static let profile = #"<(?:span|a) class="name"[^>]*>([^<]+)<"#
        /// Quality marker such as `>720p<`, used for the height (xvideos.ts:182).
        static let quality = #">(\d{3,4})p<"#
        /// JSON attribute on best-page cards (xvideos.ts:236).
        static let videoJSON = #"data-video='(\{.*?\})'"#
        /// Encoded id at the start of a best-page card, matched case-insensitively as RN's `/i` does (xvideos.ts:250).
        static let encodedIDPrefix = #"^([a-z0-9]+)""#
        /// Numbered thumbnail frame, `_<n>_t.<ext>` (xvideos.ts:144-146).
        static let numberedThumbnail = #"_(\d+)_t\.(jpg|jpeg|webp|avif)"#
        /// Numbered thumbnail suffix replaced per frame (xvideos.ts:146).
        static let numberedThumbnailSuffix = #"_\d+_t\.(jpg|jpeg|webp|avif)"#
        /// Current month in `/best/<YYYY-MM>/<page>` pagination links (xvideos.ts:117).
        static let bestMonth = #"\/best\/(\d{4}-\d{2})\/\d+"#
        /// A whole `YYYY-MM` month value, used to validate the cached month before it enters a URL.
        static let monthValue = #"^\d{4}-\d{2}$"#
        /// Detail-page player call, single quotes (xvideos.ts:343-355). `setVideoHLS` carries no `Url` segment.
        static let playerSingle = #"html5player\.setVideo(?:Url)?(Low|High|HLS)\('([^']+)'"#
        /// Detail-page player call, double quotes (xvideos.ts:343-355).
        static let playerDouble = #"html5player\.setVideo(?:Url)?(Low|High|HLS)\("([^"]+)""#
        /// Detail-page `"videoUrlLow"` / `"videoHLS"` JSON fields (xvideos.ts:343-355).
        static let playerJSON = #""video(?:Url)?(Low|High|HLS)"\s*:\s*"([^"]+)""#
        /// Any absolute or protocol-relative HLS playlist, the last resort of RN's picker (xvideos.ts:357).
        static let anyHLS = #"((?:https?:)?\/\/[^"'<>\s]+\.m3u8[^"'<>\s]*)"#
    }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let pageNumber = max(1, page)
        let tokens = HTMLScanner.searchTokens(for: query, extra: HTMLScanner.plainUserTokens(query.filter))
        // XVideos does not understand '-' exclusions; excluded terms are dropped (booruApi.ts:1586-1592).
        let keyword = tokens.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        let (sort, datef) = Self.sortAndDate(for: query.filter)

        let bestMonth: String
        if keyword.isEmpty && pageNumber > 1 && sort != .uploaddate {
            bestMonth = await Self.resolveBestMonth(client: context.http)
        } else {
            bestMonth = await Self.bestMonthCache.lastKnownMonth()
        }

        let candidates = Self.candidateURLs(page: pageNumber, keyword: keyword, sort: sort, datef: datef, bestMonth: bestMonth)
        let referer = Self.baseURL + "/"
        var lastError: Error?
        var reachedSite = false
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            let request = HTMLScanner.htmlRequest(url, userAgent: Self.userAgent, referer: referer, acceptLanguage: Self.acceptLanguage)
            let response: (Data, HTTPURLResponse)
            do {
                response = try await context.http.data(for: request)
            } catch let error as CancellationError {
                throw error
            } catch {
                lastError = error
                continue
            }
            let (data, httpResponse) = response
            let status = httpResponse.statusCode
            // 404 means this URL variant does not exist; try the next one (booruApi.ts:1632-1636).
            if status == 404 {
                lastError = BooruError.http(status: 404)
                continue
            }
            guard (200..<300).contains(status) else {
                throw HTMLScanner.httpError(for: status)
            }
            reachedSite = true
            let html = HTMLScanner.text(from: data)
            let posts = Self.parseListing(html: html)
            if !posts.isEmpty {
                if keyword.isEmpty {
                    let month = Self.extractBestMonth(in: html)
                    if !month.isEmpty {
                        await Self.bestMonthCache.store(month)
                    }
                }
                return PostPage(posts: posts, nextPage: pageNumber + 1, hasMore: true)
            }
            // An empty list may mean the variant is wrong; try the next candidate.
        }
        // Throw only when the site was never reached. Otherwise the list is genuinely empty.
        if !reachedSite, let lastError {
            throw lastError
        }
        return PostPage(posts: [], nextPage: nil, hasMore: false)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        // RN has no suggestion endpoint for XVideos (booruApi.ts:2405-2407).
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        // The card only carries a hover preview; the playable mp4 is token-limited and resolved fresh at viewer open (xvideos.ts:202-204).
        let candidate = VideoCandidateSelector.videoCandidates(for: post).first
        let detail = try await Self.detailVideoURL(for: post, context: context)
        // The hover clip keeps the post playable when the watch page cannot be read.
        let fallback = MediaURLNormalizer.normalize(post.previewVideoURL, sourceID: .xvideos)
        let video = detail ?? candidate ?? fallback
        return ResolvedMedia(
            imageURL: ImageQualityResolver.imageURL(for: post, quality: context.imageQuality),
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }

    // MARK: - Detail page

    /// Playable detail-page files (xvideos.ts:325-362). An empty value means the page did not carry that file.
    static func parseDetailFiles(html: String) -> (high: String, low: String, hls: String) {
        let matched = pickPlayerURLs(html: html)
        var hls = matched["HLS"] ?? ""
        if hls.hasPrefix("//") {
            hls = "https:" + hls
        }
        return (high: matched["High"] ?? "", low: matched["Low"] ?? "", hls: hls)
    }

    /// Maps `Low` / `High` / `HLS` to the first URL RN's picker finds (xvideos.ts:332-358). The HLS key also accepts any playlist.
    private static func pickPlayerURLs(html: String) -> [String: String] {
        var picked: [String: String] = [:]
        for pattern in [Pattern.playerSingle, Pattern.playerDouble, Pattern.playerJSON] {
            for groups in HTMLScanner.allCaptures(pattern, in: html, caseInsensitive: true) where groups.count > 2 {
                let key = groups[1]
                let value = HTMLScanner.decodeScriptValue(groups[2])
                if picked[key] == nil, !value.isEmpty {
                    picked[key] = value
                }
            }
        }
        if picked["HLS"] == nil,
           let direct = HTMLScanner.allFirstCaptures(Pattern.anyHLS, in: html, caseInsensitive: true).first {
            let value = HTMLScanner.decodeScriptValue(direct)
            if !value.isEmpty {
                picked["HLS"] = value
            }
        }
        return picked
    }

    /// Fresh stream from the watch page, priority high, then low, then HLS (RN `resolveXVideosVideoUrls`, media.ts:382-416).
    /// Returns nil when there is no link, the fetch fails, or the page carries no file, so the card's candidate stays.
    static func detailVideoURL(for post: BooruPost, context: SourceContext) async throws -> URL? {
        guard let sourceLink = post.sourceLink else { return nil }
        let request = HTMLScanner.htmlRequest(
            sourceLink,
            userAgent: userAgent,
            referer: baseURL + "/",
            acceptLanguage: acceptLanguage
        )
        let html: String
        do {
            html = try await HTMLScanner.fetchHTML(request, client: context.http)
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
        let files = parseDetailFiles(html: html)
        for value in [files.high, files.low, files.hls] where !value.isEmpty {
            if let url = HTMLScanner.absoluteURL(value, base: baseURL) {
                return MediaURLNormalizer.normalize(url, sourceID: .xvideos)
            }
        }
        return nil
    }

    // MARK: - Order and URLs

    /// RN sort and date mapping (booruApi.ts:1596-1611). The 'user' and default orders map to relevance.
    static func sortAndDate(for filter: SearchFilterConfig) -> (sort: Sort, datef: Datef) {
        switch filter.sortBy {
        case .id: return (.uploaddate, .all)
        case .score: return (.views, datef(for: filter.timeRange))
        case .rating: return (.rating, datef(for: filter.timeRange))
        case .height, .width: return (.length, .all)
        default: return (.relevance, .all)
        }
    }

    /// RN `xvideosDatefForTimeRange` (xvideos.ts:25-30). XVideos has no one-year window, so 1y maps to all.
    static func datef(for timeRange: TimeRange) -> Datef {
        switch timeRange {
        case .oneDay: return .today
        case .oneWeek: return .week
        case .oneMonth: return .month
        default: return .all
        }
    }

    /// Candidate URLs in the order RN tries them (xvideos.ts:53-94). The first non-empty result wins.
    static func candidateURLs(page: Int, keyword: String, sort: Sort, datef: Datef, bestMonth: String) -> [String] {
        let base = baseURL
        let pageNumber = max(1, page)
        let month = isMonth(bestMonth) ? bestMonth : ""
        if keyword.isEmpty {
            // Explicit browse orders must not silently fall back to the homepage (xvideos.ts:65-71).
            if sort == .uploaddate {
                return ["\(base)/new/\(pageNumber)"]
            }
            if sort == .views && datef == .month {
                if pageNumber <= 1 { return ["\(base)/best"] }
                return month.isEmpty ? [] : ["\(base)/best/\(month)/\(pageNumber - 1)"]
            }
            if pageNumber <= 1 {
                return month.isEmpty
                    ? ["\(base)/", "\(base)/best", "\(base)/new", "\(base)/new/1"]
                    : ["\(base)/", "\(base)/best/\(month)", "\(base)/best", "\(base)/new/1"]
            }
            if !month.isEmpty {
                return ["\(base)/best/\(month)/\(pageNumber - 1)", "\(base)/new/\(pageNumber)"]
            }
            return ["\(base)/new/\(pageNumber)"]
        }

        func make(_ page: Int?) -> String {
            var pairs: [(String, String)] = [
                ("k", keyword),
                ("sort", sort.rawValue),
                ("durf", "allduration"),
                ("datef", datef.rawValue),
                ("quality", "all"),
            ]
            if let page {
                // p is zero-based: p=1 is page 2 (xvideos.ts:92).
                pairs.append(("p", String(page)))
            }
            let query = pairs
                .map { HTMLScanner.formEncode($0.0) + "=" + HTMLScanner.formEncode($0.1) }
                .joined(separator: "&")
            return base + "/?" + query
        }
        if pageNumber <= 1 { return [make(nil)] }
        return [make(pageNumber - 1), make(pageNumber)]
    }

    /// Extracts the current month (`YYYY-MM`) from `/best` HTML (xvideos.ts:114-119). Returns "" when absent.
    static func extractBestMonth(in html: String) -> String {
        HTMLScanner.firstCapture(Pattern.bestMonth, in: html) ?? ""
    }

    private static func isMonth(_ value: String) -> Bool {
        HTMLScanner.captures(Pattern.monthValue, in: value) != nil
    }

    /// Fetches `/best` once to learn the current month, and caches it (RN resolveXVideosBestMonth, booruApi.ts:1548-1576).
    private static func resolveBestMonth(client: any HTTPClientProtocol) async -> String {
        if let cached = await bestMonthCache.cachedMonth() {
            return cached
        }
        guard let url = URL(string: baseURL + "/best") else { return "" }
        let request = HTMLScanner.htmlRequest(url, userAgent: userAgent, referer: baseURL + "/", acceptLanguage: acceptLanguage)
        guard let html = try? await HTMLScanner.fetchHTML(request, client: client) else { return "" }
        let month = extractBestMonth(in: html)
        if !month.isEmpty {
            await bestMonthCache.store(month)
        }
        return month
    }

    // MARK: - Parsing

    /// Parses classic and best-page cards (xvideos.ts:130-322). A card without a watch link or a thumbnail is skipped.
    static func parseListing(html: String) -> [BooruPost] {
        let createdAt = HTMLScanner.isoTimestamp()
        var posts: [BooruPost] = []
        var seen = Set<String>()

        for section in HTMLScanner.sections(Pattern.classicCardStart, in: html) {
            let card = section.body
            guard let dataID = HTMLScanner.firstCapture(Pattern.dataID, in: card),
                  !seen.contains(dataID),
                  let href = HTMLScanner.firstCapture(Pattern.videoHref, in: card),
                  let template = thumbnailTemplate(in: card),
                  let post = makePost(
                      key: dataID,
                      card: card,
                      template: template,
                      previewVideo: previewVideoString(in: card, jsonPreview: nil),
                      href: href,
                      createdAt: createdAt
                  )
            else { continue }
            seen.insert(dataID)
            posts.append(post)
        }

        for section in HTMLScanner.sections(Pattern.newCardStart, in: html) {
            let card = section.body
            let json = HTMLScanner.firstCapture(Pattern.videoJSON, in: card).flatMap { parseJSONObject($0) }
            let numericID = (json?["id"] as? Int) ?? 0
            let encoded = (json?["encodedId"] as? String).map { HTMLScanner.trim($0) }
                ?? HTMLScanner.firstCapture(Pattern.encodedIDPrefix, in: card, caseInsensitive: true)
                ?? ""
            guard !encoded.isEmpty else { continue }
            // Numeric id when present, otherwise the encoded id (xvideos.ts:254).
            let key = numericID != 0 ? String(numericID) : encoded
            let jsonPreview = json?["previewVideo"] as? String
            guard !seen.contains(key),
                  let href = HTMLScanner.firstCapture(Pattern.videoHref, in: card),
                  let template = thumbnailTemplate(in: card),
                  !template.contains("blank.gif"),
                  let post = makePost(
                      key: key,
                      card: card,
                      template: template,
                      previewVideo: previewVideoString(in: card, jsonPreview: jsonPreview),
                      href: href,
                      createdAt: createdAt
                  )
            else { continue }
            seen.insert(key)
            posts.append(post)
        }
        return posts
    }

    private static func makePost(
        key: String,
        card: String,
        template: String,
        previewVideo: String?,
        href: String,
        createdAt: String
    ) -> BooruPost? {
        guard let preview = mediaURL(template.replacingOccurrences(of: "THUMBNUM", with: "1")) else {
            return nil
        }
        let title = HTMLScanner.trim(HTMLScanner.decodeEntities(firstMatch(in: card, patterns: [
            Pattern.titleParagraph,
            Pattern.titleDiv,
            Pattern.titleAttribute,
        ]) ?? ""))
        let profile = HTMLScanner.trim(HTMLScanner.decodeEntities(HTMLScanner.firstCapture(Pattern.profile, in: card) ?? ""))
        let height = qualityHeight(card: card)
        let width = Int((Double(height) * 16.0 / 9.0).rounded())
        let artist: [String] = profile.isEmpty ? [] : [profile]
        return BooruPost(
            id: "xv_\(key)",
            sourceID: .xvideos,
            sourceName: "XVideos",
            title: title.isEmpty ? nil : title,
            previewURL: preview,
            previewFallbackURL: nil,
            previewVideoURL: mediaURL(previewVideo),
            previewThumbURL: nil,
            previewThumbs: thumbnailFrames(template),
            sampleURL: preview,
            // The original mp4 is secure-tokenized and time-limited, so it is resolved at viewer open (xvideos.ts:202-204).
            originalURL: nil,
            width: width,
            height: height,
            aspectRatio: Double(width) / Double(height),
            rating: .explicit,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(artist: artist, character: [], copyright: [], general: [], meta: ["video"]),
            allTags: artist,
            sourceLink: URL(string: baseURL + HTMLScanner.decodeEntities(href)),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    /// Thumbnail template from `data-src` or `<img src>`, made absolute (xvideos.ts:160-163).
    private static func thumbnailTemplate(in card: String) -> String? {
        let raw = HTMLScanner.firstCapture(Pattern.dataSrc, in: card) ?? HTMLScanner.firstCapture(Pattern.imgSrc, in: card)
        return raw.flatMap { mediaString($0) }
    }

    /// Best-page JSON preview first, then the hover `data-pvv` attribute (xvideos.ts:242-270).
    private static func previewVideoString(in card: String, jsonPreview: String?) -> String? {
        if let jsonPreview, let url = mediaString(jsonPreview) {
            return url
        }
        return HTMLScanner.firstCapture(Pattern.previewVideo, in: card, caseInsensitive: true).flatMap { mediaString($0) }
    }

    /// RN `mediaUrl` (xvideos.ts:134-139): decodes script escapes, then makes the URL absolute. Other forms return nil.
    private static func mediaString(_ raw: String) -> String? {
        let value = HTMLScanner.decodeScriptValue(raw)
        let lower = value.lowercased()
        guard value.hasPrefix("//") || value.hasPrefix("/") || lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return nil
        }
        return HTMLScanner.absoluteURL(value, base: baseURL)?.absoluteString
    }

    /// Scraped thumbnail, frame, or preview-clip value as a usable URL: made absolute against
    /// the site base, then normalized so a protocol-relative `//host/...` attribute and a
    /// `&amp;` entity can never produce an invalid cover or clip URL
    /// (RN `mediaUrl` + `normalizeBooruMediaUrl`, media.ts:175-204).
    private static func mediaURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let absolute = HTMLScanner.absoluteURL(HTMLScanner.decodeEntities(raw), base: baseURL)
        return MediaURLNormalizer.normalize(absolute, sourceID: .xvideos)
    }

    /// Frames for hover scrubbing (xvideos.ts:140-147). Returns nil when the template has no frame pattern.
    private static func thumbnailFrames(_ template: String) -> [URL]? {
        let frames: [String]
        if template.contains("THUMBNUM") {
            frames = (1...8).map { template.replacingOccurrences(of: "THUMBNUM", with: String($0)) }
        } else if let match = HTMLScanner.captures(Pattern.numberedThumbnail, in: template, caseInsensitive: true),
                  match.count > 2 {
            let ext = match[2]
            frames = [1, 3, 5, 7, 10, 15, 20, 25].map { number in
                HTMLScanner.replace(Pattern.numberedThumbnailSuffix, in: template, with: "_\(number)_t.\(ext)", caseInsensitive: true)
            }
        } else {
            return nil
        }
        let urls = frames.compactMap { mediaURL($0) }
        return urls.isEmpty ? nil : urls
    }

    /// Video height from the quality marker, 720 by default. Accepts 144 to 2160 (xvideos.ts:181-186).
    private static func qualityHeight(card: String) -> Int {
        guard let value = HTMLScanner.firstCapture(Pattern.quality, in: card),
              let height = Int(value),
              (144...2160).contains(height)
        else { return 720 }
        return height
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let value = HTMLScanner.firstCapture(pattern, in: text) {
                return value
            }
        }
        return nil
    }

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
