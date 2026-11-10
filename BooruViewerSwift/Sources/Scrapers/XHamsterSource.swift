import Foundation

/// XHamster scraper. Mirrors RN `src/services/xhamster.ts` (URLs and listing parsing) and `fetchXHamsterPosts` (booruApi.ts:1823-1906).
struct XHamsterSource: BooruSource {
    let id: SourceID = .xhamster
    let displayName = "XHamster"
    let supportsVideo = true

    /// RN `XHAMSTER_BASE` (xhamster.ts:21).
    static let baseURL = "https://xhamster.com"
    /// RN `XHAMSTER_UA` (xhamster.ts:23-24).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    static let acceptLanguage = "en-US,en;q=0.9"

    /// Site sort parameter (xhamster.ts:26).
    enum Sort: String {
        case views, newest, best, longest, relevance
    }

    /// Site date window (xhamster.ts:27).
    enum DateRange: String {
        case latest, weekly, monthly, yearly
    }

    /// Named regex constants for the XHamster markup.
    private enum Pattern {
        /// `window.initials` JSON script (xhamster.ts:164).
        static let initialsScript = #"<script id=['"]initials-script['"]>window\.initials=([\s\S]*?)<\/script>"#
        /// Card start: the div that carries `data-video-id` (xhamster.ts:187).
        static let cardStart = #"<div[^>]*data-video-id=""#
        /// Numeric id at the start of a card body (xhamster.ts:190).
        static let videoIDPrefix = #"^(\d+)""#
        /// Thumb link with the href before `data-role` (xhamster.ts:196).
        static let hrefWithRole = #"<a[^>]*href="([^"]+)"[^>]*data-role="thumb-link""#
        /// Any href, the fallback link (xhamster.ts:196).
        static let hrefPlain = #"href="([^"]+)""#
        /// Trailer fallback mp4, used only when it ends in .mp4 (xhamster.ts:209-211).
        static let previewVideoFallback = #"data-previewvideo-fallback="([^"]+)""#
        /// Hover preview mp4 (xhamster.ts:208).
        static let previewVideo = #"data-previewvideo="([^"]+)""#
        /// Image tagged as the preview (xhamster.ts:238).
        static let roleImage = #"<img[^>]*data-role="thumb-preview-img"[^>]*>"#
        /// Plain img src (xhamster.ts:278).
        static let imgSrc = #"<img[^>]*src="([^"]+)""#
        /// Separator between srcset entries (xhamster.ts:260).
        static let srcsetSeparator = #"\s*,\s*(?=[^,]*\s+\d+w|\s*$)"#
        /// Duration block (xhamster.ts:307).
        static let duration = #"data-role="video-duration"[^>]*>([\s\S]*?)<\/div>"#
        /// Uploader name link (xhamster.ts:316).
        static let uploader = #"class="[^"]*video-uploader__name[^"]*"[^>]*>([\s\S]*?)<\/a>"#
        /// View count block (xhamster.ts:321).
        static let views = #"class="[^"]*video-thumb-views[^"]*"[^>]*>([\s\S]*?)<\/div>"#
        /// AV1 codec token between separators, such as `_av1.` (xhamster.ts:224).
        static let av1Token = #"([._-])av1([._-])"#
        /// AV1 codec token as a bare `.av1.` segment (xhamster.ts:225).
        static let av1Extension = #"\.av1\."#
        /// `window.initials` assignment without the id attribute (xhamster.ts:389).
        static let initialsAssignment = #"window\.initials\s*=\s*(\{[\s\S]*?\});\s*(?:window\.|<\/script>)"#
        /// `_TPL_.h264|av1.mp4.m3u8` HLS template (xhamster.ts:454).
        static let tplHLS = #"(https?:[^\s"'<>]*_TPL_\.(?:h264|av1)\.mp4\.m3u8[^\s"'<>]*)"#
        /// Any direct HLS playlist (xhamster.ts:461).
        static let anyHLS = #"((?:https?:)?\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*)"#
        /// Video element source, the no-script player fallback (xhamster.ts:471-474).
        static let videoSource = #"<video[^>]*src="([^"]+)""#
        /// Resolution-tagged H264 mp4 (xhamster.ts:485).
        static let h264MP4 = #"(https?:[^\s"'<>]+\/\d+p\.h264\.mp4[^\s"'<>]*)"#
    }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let pageNumber = max(1, page)
        // XHamster does not understand '-' exclusions; excluded terms are dropped (booruApi.ts:1831-1837).
        let tokens = HTMLScanner.searchTokens(for: query, extra: HTMLScanner.plainUserTokens(query.filter))
        let keyword = tokens.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        let (sort, date) = Self.sortAndDate(for: query.filter)
        let candidates = Self.candidateURLs(page: pageNumber, keyword: keyword, sort: sort, date: date)
        let referer = Self.baseURL + "/"

        var lastError: Error?
        var lastWasNotFound = false
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
                lastWasNotFound = false
                continue
            }
            let (data, httpResponse) = response
            let status = httpResponse.statusCode
            // 404 means this URL variant does not exist; try the next one (booruApi.ts:1876-1879).
            if status == 404 {
                lastError = BooruError.http(status: 404)
                lastWasNotFound = true
                continue
            }
            guard (200..<300).contains(status) else {
                throw HTMLScanner.httpError(for: status)
            }
            reachedSite = true
            let posts = Self.parseListing(html: HTMLScanner.text(from: data))
            if !posts.isEmpty {
                return PostPage(posts: posts, nextPage: pageNumber + 1, hasMore: true)
            }
            // An empty list may mean the variant is wrong; try the next candidate.
        }
        // A site that only answered 404 means no results (booruApi.ts:1899-1902).
        if !reachedSite, let lastError {
            if lastWasNotFound {
                return PostPage(posts: [], nextPage: nil, hasMore: false)
            }
            throw lastError
        }
        return PostPage(posts: [], nextPage: nil, hasMore: false)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        // RN has no suggestion endpoint for XHamster (booruApi.ts:2405-2407).
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        // The card carries only a trailer; the full file is resolved fresh at viewer open (xhamster.ts:336-338).
        let candidate = VideoCandidateSelector.videoCandidates(for: post).first
        let detail = try await Self.detailVideoURL(for: post, context: context)
        let video = detail ?? candidate
        return ResolvedMedia(
            imageURL: ImageQualityResolver.imageURL(for: post, quality: context.imageQuality),
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }

    // MARK: - Detail page

    /// Playable detail-page files (xhamster.ts:377-508). An empty value means the page did not carry that file.
    static func parseDetailFiles(html: String) -> (high: String, low: String, hls: String) {
        var high = ""
        var low = ""
        var hls = ""

        let settings = object(initialsRoot(html: html), key: "xplayerSettings")
        if let sources = object(settings, key: "sources") {
            // H264 HLS first: the AV1 variant is not decodable by AVPlayer (xhamster.ts:430-436).
            let hlsObject = object(sources, key: "hls")
            let h264HLS = sourceURL(hlsObject?["h264"])
            let av1HLS = sourceURL(hlsObject?["av1"])
            if isHTTP(h264HLS) {
                hls = h264HLS
            } else if isHTTP(av1HLS) {
                hls = av1HLS
            }
            // `standard.h264` entries carry a quality; 720 and above is the high file (xhamster.ts:438-446).
            let standard = object(sources, key: "standard")
            for case let entry as [String: Any] in array(standard, key: "h264") {
                let url = sourceURL(entry)
                guard isHTTP(url) else { continue }
                let quality = Int(idString(entry["quality"]) ?? "") ?? 0
                if quality >= 720 {
                    if high.isEmpty { high = url }
                } else if low.isEmpty {
                    low = url
                }
            }
        }

        if hls.isEmpty {
            if let template = HTMLScanner.firstCapture(Pattern.tplHLS, in: html, caseInsensitive: true) {
                hls = h264(HTMLScanner.decodeScriptValue(template))
            } else if let direct = HTMLScanner.firstCapture(Pattern.anyHLS, in: html, caseInsensitive: true) {
                let value = HTMLScanner.decodeScriptValue(direct)
                hls = value.hasPrefix("//") ? "https:" + value : value
            }
        }

        // The no-script player, then the resolution-tagged mp4 links (xhamster.ts:470-495).
        if high.isEmpty || low.isEmpty,
           let raw = HTMLScanner.firstCapture(Pattern.videoSource, in: html, caseInsensitive: true) {
            let value = HTMLScanner.decodeScriptValue(raw)
            if high.isEmpty { high = value } else if low.isEmpty { low = value }
        }
        if high.isEmpty || low.isEmpty {
            for raw in HTMLScanner.allFirstCaptures(Pattern.h264MP4, in: html, caseInsensitive: true) {
                let value = HTMLScanner.decodeScriptValue(raw)
                if value.contains("720p") || value.contains("1080p") || value.contains("480p") {
                    if high.isEmpty { high = value }
                } else if low.isEmpty {
                    low = value
                }
            }
        }

        if high.isEmpty && !low.isEmpty { high = low }
        if low.isEmpty && !high.isEmpty { low = high }
        // AVPlayer cannot decode AV1, so every AV1 token is rewritten to H.264 (xhamster.ts:457-459).
        return (high: h264(high), low: h264(low), hls: h264(hls))
    }

    /// Root `window.initials` object of a page (xhamster.ts:387-397). The id-tagged script wins, then the plain assignment.
    static func initialsRoot(html: String) -> [String: Any]? {
        let candidates = [
            HTMLScanner.firstCapture(Pattern.initialsScript, in: html),
            HTMLScanner.firstCapture(Pattern.initialsAssignment, in: html, caseInsensitive: true),
        ]
        for case let raw? in candidates {
            var text = HTMLScanner.trim(raw)
            if !text.hasPrefix("{"), let inner = HTMLScanner.firstCapture(Pattern.initialsAssignment, in: text, caseInsensitive: true) {
                text = HTMLScanner.trim(inner)
            }
            if text.hasSuffix(";") {
                text.removeLast()
            }
            guard text.hasPrefix("{"), let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let root = parsed as? [String: Any]
            else { continue }
            return root
        }
        return nil
    }

    /// Fresh stream from the video page, priority high, then low, then HLS (RN `resolveXHamsterVideoUrls`, media.ts:436-470).
    /// Returns nil when there is no link, the fetch fails, or the page carries no file, so the card's trailer stays.
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
                return MediaURLNormalizer.normalize(url, sourceID: .xhamster)
            }
        }
        return nil
    }

    /// `{ url, fallback }` source object from `xplayerSettings` (xhamster.ts:430-446).
    private static func sourceURL(_ value: Any?) -> String {
        guard let entry = value as? [String: Any] else { return "" }
        if let url = entry["url"] as? String, !url.isEmpty { return url }
        if let fallback = entry["fallback"] as? String, !fallback.isEmpty { return fallback }
        return ""
    }

    /// Nested JSON object, or nil when the level is missing or not an object.
    private static func object(_ root: [String: Any]?, key: String) -> [String: Any]? {
        guard let value = root?[key] else { return nil }
        return value as? [String: Any]
    }

    /// JSON array under `key`, or an empty array.
    private static func array(_ root: [String: Any]?, key: String) -> [Any] {
        guard let value = root?[key] else { return [] }
        return value as? [Any] ?? []
    }

    private static func isHTTP(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// AV1 is rewritten to H.264 because AVPlayer cannot decode AV1 (xhamster.ts:200-226, 457-459).
    private static func h264(_ value: String) -> String {
        let first = HTMLScanner.replace(Pattern.av1Token, in: value, with: "$1h264$2", caseInsensitive: true)
        return HTMLScanner.replace(Pattern.av1Extension, in: first, with: ".h264.", caseInsensitive: true)
    }

    /// Scraped cover or trailer value as a usable URL: made absolute against the site base,
    /// then normalized (`MediaURLNormalizer`) so `http://` becomes `https://` and an
    /// `xhcdn` `.av1.` rendition becomes the `.h264.` one AVPlayer can decode
    /// (media.ts:175-204).
    private static func normalizedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return MediaURLNormalizer.normalize(HTMLScanner.absoluteURL(raw, base: baseURL), sourceID: .xhamster)
    }

    // MARK: - Order and URLs

    /// RN sort mapping (booruApi.ts:1840-1855): score uses views plus a date window, rating uses best, width and height use longest, id uses newest.
    static func sortAndDate(for filter: SearchFilterConfig) -> (sort: Sort, date: DateRange?) {
        switch filter.sortBy {
        case .score: return (.views, dateRange(for: filter.timeRange))
        case .rating: return (.best, nil)
        case .height, .width: return (.longest, nil)
        case .id: return (.newest, nil)
        default: return (.relevance, nil)
        }
    }

    /// RN `xhamsterDateForTimeRange` (xhamster.ts:33-39). All maps to no window.
    static func dateRange(for timeRange: TimeRange) -> DateRange? {
        switch timeRange {
        case .oneDay: return .latest
        case .oneWeek: return .weekly
        case .oneMonth: return .monthly
        case .oneYear: return .yearly
        case .all: return nil
        }
    }

    /// Candidate URLs in the order RN tries them (xhamster.ts:55-120). The first non-empty result wins.
    static func candidateURLs(page: Int, keyword: String, sort: Sort?, date: DateRange?) -> [String] {
        let base = baseURL
        let pageNumber = max(1, page)
        if keyword.isEmpty {
            if sort == .best {
                if pageNumber <= 1 { return ["\(base)/best", "\(base)/best/1"] }
                return ["\(base)/best/\(pageNumber)", "\(base)/best?page=\(pageNumber)"]
            }
            if sort == .views {
                if let window = dateWindowSegment(date) {
                    if pageNumber <= 1 { return ["\(base)/best/\(window)", "\(base)/best/\(window)/1"] }
                    return ["\(base)/best/\(window)/\(pageNumber)", "\(base)/best/\(window)?page=\(pageNumber)"]
                }
                if pageNumber <= 1 { return ["\(base)/best", "\(base)/newest", base] }
                return ["\(base)/best/\(pageNumber)", "\(base)/newest/\(pageNumber)", "\(base)/\(pageNumber)"]
            }
            if sort == .longest {
                if pageNumber <= 1 { return ["\(base)/newest", base] }
                return ["\(base)/newest/\(pageNumber)", "\(base)/\(pageNumber)"]
            }
            // Default and newest: the homepage (daily picks) comes first on page 1 (xhamster.ts:92-94).
            if pageNumber <= 1 { return [base, "\(base)/newest", "\(base)/newest/1"] }
            return ["\(base)/newest/\(pageNumber)", "\(base)/newest?page=\(pageNumber)", "\(base)/\(pageNumber)"]
        }

        // Search URLs: `/search/<slug>` first, then `/search?q=`, then the same without sort/date as a fallback.
        var parameters: [String] = []
        if let sort, sort != .relevance {
            parameters.append("sort=\(sort.rawValue)")
        }
        if let date {
            parameters.append("date=\(date.rawValue)")
        }
        if pageNumber > 1 {
            parameters.append("page=\(pageNumber)")
        }
        let slug = HTMLScanner.componentEncode(keyword)
        let query = parameters.joined(separator: "&")
        var candidates = [
            "\(base)/search/\(slug)" + (query.isEmpty ? "" : "?" + query),
            "\(base)/search?q=\(slug)" + (query.isEmpty ? "" : "&" + query),
        ]
        if sort != nil || date != nil {
            var fallback: [String] = []
            if pageNumber > 1 {
                fallback.append("page=\(pageNumber)")
            }
            let fallbackQuery = fallback.joined(separator: "&")
            candidates.append("\(base)/search/\(slug)" + (fallbackQuery.isEmpty ? "" : "?" + fallbackQuery))
            candidates.append("\(base)/search?q=\(slug)" + (fallbackQuery.isEmpty ? "" : "&" + fallbackQuery))
        }
        return candidates
    }

    /// Path segment for a browse date window. Yearly has no keyword-less browse path, so it returns nil (xhamster.ts:72-86).
    private static func dateWindowSegment(_ date: DateRange?) -> String? {
        switch date {
        case .latest: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly, .none: return nil
        }
    }

    // MARK: - Parsing

    /// Parses cards from one page (xhamster.ts:158-360). A card without a numeric id is skipped.
    /// A card with neither a preview nor a thumbnail is skipped too, since it has nothing to show.
    static func parseListing(html: String) -> [BooruPost] {
        let createdAt = HTMLScanner.isoTimestamp()
        let initials = initialsVideoMap(html: html)
        var posts: [BooruPost] = []
        var seen = Set<String>()

        for section in HTMLScanner.sections(Pattern.cardStart, in: html) {
            let card = section.body
            guard let videoID = HTMLScanner.firstCapture(Pattern.videoIDPrefix, in: card), !seen.contains(videoID) else {
                continue
            }
            let initData = initials[videoID]
            let videoString = previewVideoValue(card: card, initData: initData)
            let thumbString = thumbnailValue(card: card, initData: initData)
            let thumbURL = normalizedURL(thumbString)
            let videoURL = videoString.flatMap { normalizedURL($0) }
            guard let previewURL = thumbURL ?? videoURL else { continue }

            let title = titleValue(card: card, initData: initData)
            let duration = HTMLScanner.firstCapture(Pattern.duration, in: card, caseInsensitive: true)
                .map { HTMLScanner.stripTags($0) } ?? ""
            let uploader = HTMLScanner.firstCapture(Pattern.uploader, in: card, caseInsensitive: true)
                .map { HTMLScanner.decodeEntities(HTMLScanner.stripTags($0)) } ?? ""
            let viewsText = HTMLScanner.firstCapture(Pattern.views, in: card, caseInsensitive: true)
                .map { HTMLScanner.stripTags($0) } ?? ""
            let score = HTMLScanner.parseCount(viewsText)
            let sourceLink = hrefValue(card: card).flatMap { normalizedURL($0) }

            let artist: [String] = uploader.isEmpty ? [] : [uploader]
            let durationTags: [String] = duration.isEmpty ? [] : ["duration:\(duration)"]
            seen.insert(videoID)
            posts.append(BooruPost(
                id: "xh_\(videoID)",
                sourceID: .xhamster,
                sourceName: "XHamster",
                title: title.isEmpty ? nil : title,
                previewURL: previewURL,
                previewFallbackURL: nil,
                previewVideoURL: videoURL,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: videoURL ?? thumbURL,
                // The per-card trailer mp4 is the instant original fallback; the full file is resolved at viewer open (xhamster.ts:336-338).
                originalURL: videoURL,
                width: 1280,
                height: 720,
                aspectRatio: 16.0 / 9.0,
                rating: .explicit,
                score: score,
                favCount: score,
                tags: BooruTagGroups(artist: artist, character: [], copyright: [], general: durationTags, meta: ["video"]),
                allTags: artist + durationTags + ["video"],
                sourceLink: sourceLink,
                fileExt: "mp4",
                fileSize: nil,
                createdAt: createdAt,
                niches: nil,
                isPremium: nil,
                pageCount: nil,
                mediaId: nil
            ))
        }
        return posts
    }

    /// Maps video id to its `window.initials` object. Only objects with an id and a thumbnail or image URL are kept (xhamster.ts:163-183).
    static func initialsVideoMap(html: String) -> [String: [String: Any]] {
        guard let raw = HTMLScanner.firstCapture(Pattern.initialsScript, in: html) else { return [:] }
        var json = HTMLScanner.trim(raw)
        if json.hasSuffix(";") {
            json.removeLast()
        }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        var map: [String: [String: Any]] = [:]
        collectVideoEntries(root, into: &map)
        return map
    }

    private static func collectVideoEntries(_ value: Any, into map: inout [String: [String: Any]]) {
        if let array = value as? [Any] {
            for case let item as [String: Any] in array {
                guard let key = idString(item["id"]), hasThumbnailURL(item) else { continue }
                map[key] = item
            }
            for item in array {
                collectVideoEntries(item, into: &map)
            }
        } else if let object = value as? [String: Any] {
            for child in object.values {
                collectVideoEntries(child, into: &map)
            }
        }
    }

    private static func idString(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func hasThumbnailURL(_ item: [String: Any]) -> Bool {
        let thumb = (item["thumbURL"] as? String) ?? ""
        let image = (item["imageURL"] as? String) ?? ""
        return !thumb.isEmpty || !image.isEmpty
    }

    /// Preview mp4 from the initials JSON, then the card attributes. AV1 is rewritten to H.264 because AVPlayer cannot decode AV1 (xhamster.ts:200-226).
    private static func previewVideoValue(card: String, initData: [String: Any]?) -> String? {
        var value = ""
        if let trailer = initData?["trailerFallbackUrl"] as? String, !trailer.isEmpty {
            value = trailer.replacingOccurrences(of: "\\", with: "")
        } else if let trailer = initData?["trailerURL"] as? String, !trailer.isEmpty {
            value = trailer.replacingOccurrences(of: "\\", with: "")
        } else if let fallback = HTMLScanner.firstCapture(Pattern.previewVideoFallback, in: card, caseInsensitive: true),
                  fallback.hasSuffix(".mp4") {
            value = fallback
        } else if let primary = HTMLScanner.firstCapture(Pattern.previewVideo, in: card, caseInsensitive: true) {
            value = primary
        }
        guard !value.isEmpty else { return nil }
        var url = HTMLScanner.decodeEntities(HTMLScanner.decodeScriptValue(value))
        if url.hasPrefix("//") {
            url = "https:" + url
        }
        return h264(url)
    }

    /// Thumbnail from the initials JSON, then the preview image. Placeholder `data:image/` values are skipped (xhamster.ts:228-287).
    private static func thumbnailValue(card: String, initData: [String: Any]?) -> String {
        var thumb = ""
        if let value = initData?["thumbURL"] as? String, !value.isEmpty {
            thumb = value.replacingOccurrences(of: "\\/", with: "/")
        } else if let value = initData?["imageURL"] as? String, !value.isEmpty {
            thumb = value.replacingOccurrences(of: "\\/", with: "/")
        }
        if thumb.isEmpty {
            let roleTag = HTMLScanner.captures(Pattern.roleImage, in: card, caseInsensitive: true)?[0]
            if let tag = roleTag ?? HTMLScanner.firstTag("img", in: card) {
                thumb = imageThumbnail(tag: tag)
            }
        }
        if thumb.isEmpty, let raw = HTMLScanner.firstCapture(Pattern.imgSrc, in: card, caseInsensitive: true) {
            thumb = HTMLScanner.decodeEntities(raw)
        }
        if !thumb.isEmpty {
            thumb = HTMLScanner.decodeEntities(HTMLScanner.decodeScriptValue(thumb))
            if thumb.hasPrefix("//") {
                thumb = "https:" + thumb
            }
        }
        return thumb
    }

    /// Lazy-load attribute first, then the largest srcset entry (500 px or wider), then src.
    private static func imageThumbnail(tag: String) -> String {
        var thumb = ""
        let lazy = HTMLScanner.attribute("data-thumb-url", in: tag)
            ?? HTMLScanner.attribute("data-src", in: tag)
            ?? HTMLScanner.attribute("data-original", in: tag)
            ?? ""
        if !lazy.isEmpty && !lazy.hasPrefix("data:image/") {
            thumb = lazy
        }
        if thumb.isEmpty, let srcset = HTMLScanner.attribute("srcset", in: tag) {
            thumb = bestSrcsetURL(srcset)
        }
        if thumb.isEmpty || thumb.hasPrefix("data:image/") {
            thumb = ""
            if let src = HTMLScanner.attribute("src", in: tag), !src.hasPrefix("data:image/") {
                thumb = src
            }
        }
        return thumb
    }

    /// Picks the first srcset entry at 500 w or wider, else the last entry (xhamster.ts:258-266).
    private static func bestSrcsetURL(_ srcset: String) -> String {
        let pieces = HTMLScanner.split(HTMLScanner.trim(srcset), by: Pattern.srcsetSeparator)
        let candidates: [(url: String, width: Int)] = pieces.map { (piece: String) -> (url: String, width: Int) in
            let parts = HTMLScanner.tokens(piece)
            let width = parts.count > 1 ? (Int(parts[1].replacingOccurrences(of: "w", with: "")) ?? 0) : 0
            return (url: parts.first ?? "", width: width)
        }
        let good = candidates.first(where: { $0.width >= 500 }) ?? candidates.last
        var url = good?.url ?? ""
        if url.isEmpty, let first = pieces.first {
            url = HTMLScanner.tokens(first).first ?? ""
        }
        if url.hasSuffix(",") {
            url.removeLast()
        }
        return url
    }

    /// Title from the initials JSON when it is non-empty, otherwise aria-label, title, or alt (xhamster.ts:289-304).
    private static func titleValue(card: String, initData: [String: Any]?) -> String {
        if let title = initData?["title"] as? String, !title.isEmpty {
            return HTMLScanner.trim(title)
        }
        let raw = HTMLScanner.attribute("aria-label", in: card)
            ?? HTMLScanner.attribute("title", in: card)
            ?? HTMLScanner.attribute("alt", in: card)
            ?? ""
        return HTMLScanner.trim(raw)
    }

    /// Link to the video page: the thumb link first, then any href (xhamster.ts:195-198).
    private static func hrefValue(card: String) -> String? {
        let raw = HTMLScanner.firstCapture(Pattern.hrefWithRole, in: card, caseInsensitive: true)
            ?? HTMLScanner.firstCapture(Pattern.hrefPlain, in: card)
        return raw.map { HTMLScanner.decodeEntities($0) }
    }
}
