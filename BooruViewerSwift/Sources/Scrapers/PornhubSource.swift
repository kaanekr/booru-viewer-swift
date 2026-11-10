import Foundation

/// Pornhub scraper. Mirrors RN `src/services/pornhub.ts` (Webmasters API + HTML listing, detail
/// `mediaDefinitions` parsing) and `fetchPornhubPosts` (booruApi.ts:1958-2095).
///
/// Listing: the official Webmasters API (`/webmasters/search`) supplies the card metadata, and the
/// plain HTML search page enriches it with a hover preview clip plus timeline thumbs. The listing
/// never carries a playable file: stream URLs are token-limited, so they are resolved fresh from the
/// watch page (or its embed) every time the viewer opens.
struct PornhubSource: BooruSource {
    let id: SourceID = .pornhub
    let displayName = "Pornhub"
    let supportsVideo = true

    /// RN `PORNHUB_BASE` (pornhub.ts:20).
    static let baseURL = "https://www.pornhub.com"
    /// RN `PORNHUB_API_BASE` (pornhub.ts:21).
    static let apiBaseURL = "https://www.pornhub.com/webmasters"
    /// RN `PORNHUB_UA` (pornhub.ts:23-24). An iPhone UA: the desktop variant returns other markup.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    static let acceptLanguage = "en-US,en;q=0.9"
    /// Per-attempt ceiling handed to the challenge solver (RN viewer uses a 20s WebView ceiling).
    static let challengeTimeout: TimeInterval = 20
    /// The age-gate cookies the RN fast path sends (media.ts:499).
    static let ageCookieHeader = "accessAgeDisclaimerPH=1; accessPH=1;"

    /// Optional headless WebKit solver, injected by the app layer. Tests pass a fake.
    var challengeResolver: (any PornhubChallengeSolving)? = nil

    /// RN `PornhubOrdering` (pornhub.ts:26).
    enum Ordering: String {
        case featured, newest, mostviewed, rating
    }

    /// RN `PornhubPeriod` (pornhub.ts:27).
    enum Period: String {
        case daily, weekly, monthly, alltime
    }

    /// Named regex constants for the Pornhub markup (pornhub.ts:283-286, 328-377).
    private enum Pattern {
        /// Listing card start: the element that carries `data-video-vkey` (pornhub.ts:328).
        static let cardStart = #"(?:<li|<div)[^>]*data-video-vkey=["']"#
        /// Viewkey at the start of a card body (pornhub.ts:332-335).
        static let vkeyPrefix = #"^([^"']+)"#
        /// Thumb image class used by the site (pornhub.ts:360-362).
        static let thumbImage = #"<img[^>]*class="[^"]*videoThumb[^"]*"[^>]*src="([^"]+)""#
        /// Any image, the last-resort thumb (pornhub.ts:362).
        static let anyImage = #"<img[^>]*src="([^"]+)""#
        /// Title link (pornhub.ts:370-373).
        static let thumbnailTitle = #"<a[^>]*class="thumbnailTitle"[^>]*>([^<]+)<\/a>"#
        /// Title from the image alt text (pornhub.ts:372).
        static let imageAlt = #"<img[^>]*alt="([^"]+)""#
        /// Title from any title attribute (pornhub.ts:373).
        static let titleAttribute = #"title="([^"]+)""#
        /// Duration badge (pornhub.ts:376).
        static let duration = #"<span[^>]*class="bgEffect time"[^>]*>([^<]+)<\/span>"#
        /// View count (pornhub.ts:377).
        static let views = #"<div[^>]*class="videoViews"[^>]*>[\s\S]*?([\d.,]+[KMB]?)"#
        /// One `mediaDefinitions` stream object (pornhub.ts:283-286). Key order is the site's.
        static let mediaDefinition = #"\{\"group\":\d+,\"height\":(\d+),\"width\":(\d+),\"defaultQuality\":(true|false),\"format\":\"(hls|mp4)\",\"videoUrl\":\"((?:[^\"\\]|\\.)*)\",\"quality\":\"?([^\",}]*)"#
        /// Viewkey in a watch link, used to build the lighter embed URL (media.ts:506-508).
        static let viewkey = #"viewkey=([a-z0-9]+)"#
    }

    // MARK: - BooruSource

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let pageNumber = max(1, page)
        // The Webmasters API does not understand '-' exclusions; excluded terms are dropped (booruApi.ts:1988-1996).
        let tokens = HTMLScanner.searchTokens(for: query, extra: HTMLScanner.plainUserTokens(query.filter))
        let keyword = tokens.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        let ordering = Self.ordering(keyword: keyword, filter: query.filter)
        let period = Self.period(keyword: keyword, filter: query.filter)

        // Explore page 1 is the homepage: what the site currently features (booruApi.ts:2020-2043).
        // Only the untouched Discover/Latest feed does this. Any other Explore order (Top · All time,
        // Daily/Weekly/Monthly Top) must reach the search endpoint, otherwise those quick-filter
        // chips look like they do nothing.
        if pageNumber <= 1,
           query.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           query.filter.tags.isEmpty,
           query.filter.sortBy == .default,
           query.filter.timeRange == .all {
            let homePosts = try await Self.homepagePosts(context: context)
            if !homePosts.isEmpty {
                return PostPage(posts: homePosts, nextPage: pageNumber + 1, hasMore: true)
            }
        }

        let apiPosts = try await Self.apiPosts(
            page: pageNumber,
            keyword: keyword,
            ordering: ordering,
            period: period,
            context: context
        )
        let htmlPosts = try await Self.htmlPosts(page: pageNumber, keyword: keyword, context: context)
        let posts = Self.merge(apiPosts: apiPosts, htmlPosts: htmlPosts)
        guard !posts.isEmpty else {
            throw BooruError.network("Could not load Pornhub videos. Please check your internet connection and try again.")
        }
        return PostPage(posts: posts, nextPage: pageNumber + 1, hasMore: true)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        // RN has no suggestion endpoint for Pornhub (booruApi.ts:2405-2407).
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        // The card carries only the hover clip; the stream is token-limited and resolved at viewer open.
        let candidate = VideoCandidateSelector.videoCandidates(for: post).first
        let stream = try await streamURL(for: post, context: context)
        // Both the plain page and the challenge solver can miss the stream, so the card's own
        // hover clip stays playable instead of leaving the post with only a cover.
        let video = stream ?? candidate ?? Self.iosPlayable(MediaURLNormalizer.normalize(post.previewVideoURL, sourceID: .pornhub))
        return ResolvedMedia(
            imageURL: ImageQualityResolver.imageURL(for: post, quality: context.imageQuality),
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }

    // MARK: - Query mapping

    /// RN `fetchPornhubPosts` ordering rules (booruApi.ts:2006-2018). Explore and length/score sorts use views.
    ///
    /// Keywordless Explore used to ignore `sortBy` entirely, so every chip besides Discover
    /// silently reopened the same most-viewed page; honouring `id` gives Latest a real order.
    static func ordering(keyword: String, filter: SearchFilterConfig) -> Ordering {
        switch filter.sortBy {
        case .score, .height, .width: return .mostviewed
        case .rating: return .rating
        case .id: return .newest
        default: return keyword.isEmpty ? .mostviewed : .featured
        }
    }

    /// RN `pornhubPeriodForTimeRange` plus the explore default (pornhub.ts:54-59, booruApi.ts:2002-2005).
    ///
    /// Discover (default sort, no window) keeps the site's daily popular page; every explicit
    /// order maps its window, and All Time asks for `alltime` so the Top chip is all-time.
    static func period(keyword: String, filter: SearchFilterConfig) -> Period {
        if keyword.isEmpty, filter.sortBy == .default, filter.timeRange == .all { return .daily }
        switch filter.timeRange {
        case .oneDay: return .daily
        case .oneWeek: return .weekly
        case .oneMonth: return .monthly
        default: return .alltime
        }
    }

    /// RN `buildPornhubSearchUrl` (pornhub.ts:61-74). `period` is only sent alongside an ordering.
    static func searchURL(page: Int, keyword: String, ordering: Ordering, period: Period) -> String {
        let pairs: [(String, String)] = [
            ("search", HTMLScanner.trim(keyword)),
            ("page", String(max(1, page))),
            ("thumbsize", "medium"),
            ("ordering", ordering.rawValue),
            ("period", period.rawValue),
        ]
        let query = pairs
            .map { HTMLScanner.formEncode($0.0) + "=" + HTMLScanner.formEncode($0.1) }
            .joined(separator: "&")
        return apiBaseURL + "/search?" + query
    }

    /// HTML fallback page RN fetches next to the API (booruApi.ts:2075-2079).
    static func htmlListURL(page: Int, keyword: String) -> String {
        let pageNumber = max(1, page)
        guard !keyword.isEmpty else { return baseURL + "/video?o=mv&page=\(pageNumber)" }
        return baseURL + "/video/search?search=" + HTMLScanner.componentEncode(keyword) + "&page=\(pageNumber)"
    }

    // MARK: - Fetching

    /// Homepage cards, used for explore page 1. Cancellation propagates; other failures yield no posts.
    private static func homepagePosts(context: SourceContext) async throws -> [BooruPost] {
        guard let url = URL(string: baseURL + "/") else { return [] }
        let request = HTMLScanner.htmlRequest(
            url,
            userAgent: userAgent,
            referer: baseURL + "/",
            acceptLanguage: acceptLanguage
        )
        do {
            let html = try await HTMLScanner.fetchHTML(request, client: context.http)
            return parseListing(html: html)
        } catch let error as CancellationError {
            throw error
        } catch {
            return []
        }
    }

    /// Webmasters API cards. A non-2xx answer throws; an unreadable body yields no posts so the
    /// HTML fallback still runs (booruApi.ts:2055-2074).
    private static func apiPosts(
        page: Int,
        keyword: String,
        ordering: Ordering,
        period: Period,
        context: SourceContext
    ) async throws -> [BooruPost] {
        guard let url = URL(string: searchURL(page: page, keyword: keyword, ordering: ordering, period: period)) else {
            throw BooruError.network("Invalid Pornhub API URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await context.http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTMLScanner.httpError(for: response.statusCode)
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let videos = root?["videos"] as? [[String: Any]] else { return [] }
        return videos.compactMap { mapVideo($0) }
    }

    /// HTML listing beside the API. Failures are tolerated; the API cards still stand.
    private static func htmlPosts(page: Int, keyword: String, context: SourceContext) async throws -> [BooruPost] {
        guard let url = URL(string: htmlListURL(page: page, keyword: keyword)) else { return [] }
        let request = HTMLScanner.htmlRequest(
            url,
            userAgent: userAgent,
            referer: baseURL + "/",
            acceptLanguage: acceptLanguage
        )
        do {
            let html = try await HTMLScanner.fetchHTML(request, client: context.http)
            return parseListing(html: html)
        } catch let error as CancellationError {
            throw error
        } catch {
            return []
        }
    }

    /// RN merges the HTML hover clip and timeline thumbs into the API cards (booruApi.ts:2082-2098).
    static func merge(apiPosts: [BooruPost], htmlPosts: [BooruPost]) -> [BooruPost] {
        guard !htmlPosts.isEmpty else { return apiPosts }
        guard !apiPosts.isEmpty else { return htmlPosts }
        var byKey: [String: BooruPost] = [:]
        for post in htmlPosts {
            byKey[post.id.hasPrefix("ph_") ? String(post.id.dropFirst(3)) : post.id] = post
        }
        return apiPosts.map { post in
            var merged = post
            let key = post.id.hasPrefix("ph_") ? String(post.id.dropFirst(3)) : post.id
            if let card = byKey[key] {
                if let preview = card.previewVideoURL {
                    merged.previewVideoURL = preview
                }
                if (merged.previewThumbs?.count ?? 0) <= 1, let thumbs = card.previewThumbs, thumbs.count > 1 {
                    merged.previewThumbs = thumbs
                    merged.previewThumbURL = card.previewThumbURL
                }
            }
            return merged
        }
    }

    // MARK: - Detail page

    /// Playable detail-page files, mirroring `parsePornhubDetail` (pornhub.ts:272-312).
    /// An empty value means the page did not carry that file.
    static func parseDetailFiles(html: String) -> (high: String, low: String, hls: String) {
        let empty = (high: "", low: "", hls: "")
        guard html.contains("mediaDefinitions") else { return empty }

        // The detail page embeds mediaDefinitions inside a double-escaped JS string (pornhub.ts:278-281).
        let source = html.contains("mediaDefinitions\\\":")
            ? HTMLScanner.replace(#"\\""#, in: html, with: "\"")
            : html

        var streams: [(url: String, quality: Int, isDefault: Bool, format: String)] = []
        for groups in HTMLScanner.allCaptures(Pattern.mediaDefinition, in: source) where groups.count > 6 {
            let url = HTMLScanner.decodeScriptValue(groups[5])
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            streams.append((
                url: url,
                quality: leadingInt(groups[6]),
                isDefault: groups[3] == "true",
                format: groups[4].lowercased()
            ))
        }
        guard !streams.isEmpty else { return empty }

        let hls = streams.filter { $0.format == "hls" }
        let targets = hls.isEmpty ? streams : hls
        // Highest quality first; ties keep page order, like JavaScript's stable sort (pornhub.ts:301-307).
        let sorted = targets.enumerated()
            .sorted { lhs, rhs in
                lhs.element.quality == rhs.element.quality
                    ? lhs.offset < rhs.offset
                    : lhs.element.quality > rhs.element.quality
            }
            .map { $0.element }
        guard let top = sorted.first, let bottom = sorted.last else { return empty }

        var files = (high: top.url, low: bottom.url, hls: "")
        if !hls.isEmpty {
            files.hls = sorted.first(where: { $0.isDefault })?.url ?? top.url
        }
        return files
    }

    /// Best playable stream of a page: high, then HLS, then low (ImageViewerModal.tsx:957-959).
    static func playableURL(html: String) -> URL? {
        let files = parseDetailFiles(html: html)
        for value in [files.high, files.hls, files.low] where !value.isEmpty {
            if let url = HTMLScanner.absoluteURL(value, base: baseURL) {
                return url
            }
        }
        return nil
    }

    /// RN tries the light embed page first, then the watch page (media.ts:501-508).
    static func pageURLs(for sourceLink: URL) -> [URL] {
        var urls: [URL] = []
        if let key = HTMLScanner.firstCapture(Pattern.viewkey, in: sourceLink.absoluteString, caseInsensitive: true),
           !key.isEmpty,
           let embed = URL(string: baseURL + "/embed/" + key) {
            urls.append(embed)
        }
        urls.append(sourceLink)
        return urls
    }

    /// Browser-like watch-page request with the age-gate cookies (media.ts:489-499).
    static func watchRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue(ageCookieHeader, forHTTPHeaderField: "Cookie")
        return request
    }

    /// Fresh stream for `post`, or nil so the card's hover clip stays (RN `resolvePornhubVideoUrls`, media.ts:478-528).
    /// A page that answers with the JS wall is re-read through `challengeResolver` when one is injected.
    private func streamURL(for post: BooruPost, context: SourceContext) async throws -> URL? {
        guard let sourceLink = post.sourceLink else { return nil }
        for pageURL in Self.pageURLs(for: sourceLink) {
            var needsSolver = true
            do {
                let html = try await HTMLScanner.fetchHTML(Self.watchRequest(pageURL), client: context.http)
                if let url = Self.playableURL(html: html) { return url }
                needsSolver = PornhubChallengeMarkers.looksLikeChallenge(html)
            } catch let error as CancellationError {
                throw error
            } catch {
                // A plain fetch that dies on a tokened page is the bot wall in practice (RN opens the WebView).
                needsSolver = true
            }
            guard needsSolver, let solver = challengeResolver else { continue }
            let solved: String
            do {
                solved = try await solver.resolvePageHTML(url: pageURL, timeout: Self.challengeTimeout)
            } catch let error as CancellationError {
                throw error
            } catch {
                continue
            }
            if let url = Self.playableURL(html: solved) { return url }
        }
        return nil
    }

    // MARK: - Webmasters JSON mapping

    /// Converts one Webmasters video into a post, mirroring `mapPornhubVideoToPost` (pornhub.ts:161-251).
    static func mapVideo(_ video: [String: Any]) -> BooruPost? {
        guard let rawID = text(video["video_id"]), !rawID.isEmpty else { return nil }
        let thumbRaw = text(video["thumb"]) ?? text(video["default_thumb"]) ?? ""
        let thumb = HTMLScanner.trim(thumbRaw)
        guard !thumb.isEmpty else { return nil }

        var width = 640
        var height = 360
        let thumbs = (video["thumbs"] as? [[String: Any]]) ?? []
        if let first = thumbs.first {
            let w = leadingInt(text(first["width"]) ?? "")
            let h = leadingInt(text(first["height"]) ?? "")
            if w > 0, h > 0, w < 8000, h < 8000 {
                width = w
                height = h
            }
        }

        let tagNames = normalizedNames(video["tags"], key: "tag_name")
        let categories = normalizedNames(video["categories"], key: "category")
        let artists = normalizedNames(video["pornstars"], key: "pornstar_name")
        let rating = double(video["rating"]) ?? 0
        let views = integer(video["views"]) ?? 0
        let ratings = integer(video["ratings"])
        let createdAt = publishDate(video["publish_date"]) ?? HTMLScanner.isoTimestamp()

        var previewThumbs = sequentialThumbs(thumb) ?? []
        if previewThumbs.count <= 1 {
            let sources = thumbs.compactMap { text($0["src"]).map(HTMLScanner.trim) }.filter { !$0.isEmpty }
            for source in sources {
                if let sequence = sequentialThumbs(source), sequence.count > 1 {
                    previewThumbs = sequence
                    break
                }
            }
            if previewThumbs.count <= 1 {
                let filenames = Set(sources.map { source -> String in
                    let path = source.components(separatedBy: "?").first ?? source
                    return path.components(separatedBy: "/").last ?? path
                })
                if filenames.count > 1 {
                    previewThumbs = HTMLScanner.uniqued(sources)
                }
            }
        }

        let title = HTMLScanner.trim(text(video["title"]) ?? "")
        let link = HTMLScanner.trim(text(video["url"]) ?? "")
        let sourceLink = link.isEmpty ? baseURL + "/view_video.php?viewkey=" + rawID : link
        return BooruPost(
            id: "ph_" + rawID,
            sourceID: .pornhub,
            sourceName: "Pornhub",
            title: title.isEmpty ? nil : title,
            previewURL: mediaURL(thumb),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: mediaURL(previewThumbs.last),
            previewThumbs: previewThumbs.count > 1 ? previewThumbs.compactMap { mediaURL($0) } : nil,
            sampleURL: mediaURL(thumb),
            // The playable stream is token-limited and resolved at viewer open.
            originalURL: nil,
            width: width,
            height: height,
            aspectRatio: width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9.0,
            rating: .explicit,
            score: Int((rating * 100).rounded()),
            favCount: ratings ?? views,
            tags: BooruTagGroups(
                artist: artists,
                character: [],
                copyright: categories,
                general: tagNames,
                meta: ["video", "duration:\(durationSeconds(video["duration"]))s"]
            ),
            allTags: artists + categories + tagNames,
            sourceLink: MediaURLNormalizer.normalize(
                HTMLScanner.absoluteURL(sourceLink, base: baseURL),
                sourceID: .pornhub
            ),
            fileExt: "mp4",
            fileSize: nil,
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: - HTML listing

    /// Card fields from a search or browse page, mirroring `parsePornhubHtmlListing` (pornhub.ts:324-421).
    /// A card without a thumbnail is skipped.
    static func parseListing(html: String) -> [BooruPost] {
        guard !html.isEmpty else { return [] }
        let createdAt = HTMLScanner.isoTimestamp()
        var posts: [BooruPost] = []
        var seen = Set<String>()

        for section in HTMLScanner.sections(Pattern.cardStart, in: html, caseInsensitive: true) {
            let card = section.body
            guard let rawKey = HTMLScanner.firstCapture(Pattern.vkeyPrefix, in: card) else { continue }
            let vkey = HTMLScanner.trim(rawKey)
            guard !vkey.isEmpty, !seen.contains(vkey) else { continue }

            // New `data-webm` flipbook first, then the older attributes (pornhub.ts:338-343).
            let previewVideo = HTMLScanner.trim(
                attributeValue(["data-webm", "data-previewvideo", "data-mediabook"], in: card)
            )
            let poster = attributeValue(["data-poster", "data-thumb_url", "data-mediumthumb"], in: card)
            var thumb = attributeValue(["data-path", "data-image", "data-src"], in: card)
            if thumb.isEmpty { thumb = poster }
            if thumb.isEmpty, let raw = firstCapture(in: card, patterns: [Pattern.thumbImage, Pattern.anyImage]) {
                let candidate = HTMLScanner.trim(raw.replacingOccurrences(of: "&amp;", with: "&"))
                if !candidate.isEmpty, !candidate.contains("blank.gif") { thumb = candidate }
            }
            guard !thumb.isEmpty else { continue }

            let title = HTMLScanner.trim(
                HTMLScanner.decodeEntities(
                    firstCapture(in: card, patterns: [Pattern.thumbnailTitle, Pattern.imageAlt, Pattern.titleAttribute]) ?? ""
                )
            )
            var generalTags: [String] = []
            if let duration = HTMLScanner.firstCapture(Pattern.duration, in: card, caseInsensitive: true) {
                generalTags.append("duration:" + HTMLScanner.trim(duration))
            }
            if let views = HTMLScanner.firstCapture(Pattern.views, in: card, caseInsensitive: true) {
                generalTags.append("views:" + HTMLScanner.trim(views))
            }
            let previewThumbs = sequentialThumbs(poster)
                ?? sequentialThumbs(thumb)
                ?? sequentialThumbs(attributeValue(["data-thumb_url", "data-mediumthumb", "data-src", "data-path", "data-image"], in: card))
                ?? []

            seen.insert(vkey)
            let previewVideoURL = mediaURL(previewVideo)
            // The `.webm` flipbook (`data-mediabook`) is a hover clip, not a cover: an image
            // view cannot render it and iOS drops WebM, so `sampleURL` keeps the high-res thumb.
            let thumbURL = mediaURL(thumb)
            posts.append(BooruPost(
                id: "ph_" + vkey,
                sourceID: .pornhub,
                sourceName: "Pornhub",
                title: title.isEmpty ? nil : title,
                previewURL: thumbURL,
                previewFallbackURL: nil,
                previewVideoURL: previewVideoURL,
                previewThumbURL: mediaURL(previewThumbs.last) ?? mediaURL(poster),
                previewThumbs: previewThumbs.count > 1 ? previewThumbs.compactMap { mediaURL($0) } : nil,
                sampleURL: thumbURL,
                originalURL: nil,
                width: 640,
                height: 360,
                aspectRatio: 16.0 / 9.0,
                rating: .explicit,
                score: 0,
                favCount: 0,
                tags: BooruTagGroups(artist: [], character: [], copyright: [], general: generalTags, meta: ["video"]),
                allTags: generalTags,
                sourceLink: URL(string: baseURL + "/view_video.php?viewkey=" + vkey),
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

    /// Eight timeline frames (1, 3, … 15) from a cover URL, mirroring `generatePornhubSequentialThumbs`
    /// (pornhub.ts:96-154). Nil when the URL has no usable image name.
    static func sequentialThumbs(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        let clean = HTMLScanner.trim(raw.replacingOccurrences(of: "&amp;", with: "&"))
        guard !clean.isEmpty, !clean.contains("blank.gif") else { return nil }

        let parts = clean.components(separatedBy: "?")
        let path = parts[0]
        let suffix = parts.count > 1 ? "?" + parts.dropFirst().joined(separator: "?") : ""
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let directory = String(path[...slash])
        let file = String(path[path.index(after: slash)...])

        guard let extMatch = HTMLScanner.captures(#"\.(jpg|jpeg|webp)$"#, in: file, caseInsensitive: true),
              extMatch.count > 1 else { return nil }
        let ext = extMatch[1]
        let fileBase = String(file.dropLast(extMatch[0].count))

        // 1. Size suffix at the end of the file: `_small`, `_medium`, `_large` (pornhub.ts:116-135).
        var sizeSuffix = ""
        var base = fileBase
        if let match = HTMLScanner.captures(#"^(.*?)(_small|_medium|_large)$"#, in: fileBase, caseInsensitive: true),
           match.count > 2 {
            base = match[1]
            sizeSuffix = match[2]
        } else if let match = HTMLScanner.captures(#"^(.*?)(small|medium|large)$"#, in: fileBase, caseInsensitive: true),
                  match.count > 2,
                  match[1].isEmpty || match[1].hasSuffix(")") || match[1].hasSuffix("/") || match[1].hasSuffix("_") {
            base = match[1]
            sizeSuffix = "_" + match[2]
        }

        // 2. A frame number, or the `default` / `original` name (pornhub.ts:137-149).
        var prefix = base
        if let match = HTMLScanner.captures(#"^(.*?)(\d+)$"#, in: base), match.count > 2 {
            prefix = match[1]
        } else if let match = HTMLScanner.captures(#"^(.*?)(default|original)$"#, in: base, caseInsensitive: true),
                  match.count > 2 {
            prefix = match[1]
        }

        // The CDN produces 16 sequential frames; frames 1, 3, … 15 are the timeline (pornhub.ts:151-153).
        return [1, 3, 5, 7, 9, 11, 13, 15].map { number in
            directory + prefix + String(number) + sizeSuffix + "." + ext + suffix
        }
    }

    // MARK: - Private helpers

    /// Scraped cover or clip value as a usable URL: made absolute against the site base, then
    /// normalized (`MediaURLNormalizer`) so protocol-relative values and `&amp;` entities never
    /// become an invalid cover (media.ts:175-204).
    private static func mediaURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return MediaURLNormalizer.normalize(HTMLScanner.absoluteURL(raw, base: baseURL), sourceID: .pornhub)
    }

    /// The hover clip when AVPlayer can decode it: WebM containers and AV1 renditions cannot
    /// (media.ts:364-374), so they never become the viewer's stream.
    private static func iosPlayable(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let raw = url.absoluteString.lowercased()
        let path = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if path.contains(".webm") || path.hasSuffix(".av1") || path.contains(".av1.") { return nil }
        return url
    }

    /// First capture group of the first pattern that matches.
    private static func firstCapture(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let value = HTMLScanner.firstCapture(pattern, in: text, caseInsensitive: true) {
                return value
            }
        }
        return nil
    }

    /// Entity-decoded value of the first attribute present, skipping empty and placeholder values
    /// (RN `pickAttr`, pornhub.ts:345-354).
    private static func attributeValue(_ names: [String], in card: String) -> String {
        for name in names {
            guard let value = HTMLScanner.attribute(name, in: card), !value.isEmpty, !value.contains("blank.gif") else {
                continue
            }
            return value
        }
        return ""
    }

    /// RN `normalizeTag` (pornhub.ts:76-78): trimmed lowercase with whitespace runs as underscores.
    static func normalizeTag(_ raw: String) -> String {
        HTMLScanner.replace(#"\s+"#, in: HTMLScanner.trim(raw).lowercased(), with: "_")
    }

    /// Tag names from an API array such as `[{"tag_name": "Red Hair"}]`.
    private static func normalizedNames(_ value: Any?, key: String) -> [String] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let raw = text(entry[key]) else { return nil }
            let name = normalizeTag(raw)
            return name.isEmpty ? nil : name
        }
    }

    /// RN `parseDurationToSeconds` (pornhub.ts:80-87). Malformed values count as zero.
    static func durationSeconds(_ value: Any?) -> Int {
        guard let raw = text(value) else { return 0 }
        let parts = raw.components(separatedBy: ":").map { Int(HTMLScanner.trim($0)) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }

    /// `"2025-11-10 20:09:26"` to the ISO form the app stores (pornhub.ts:192-198).
    private static func publishDate(_ value: Any?) -> String? {
        guard let raw = text(value) else { return nil }
        let trimmed = HTMLScanner.trim(raw)
        guard !trimmed.isEmpty else { return nil }
        let iso = trimmed.replacingOccurrences(of: " ", with: "T") + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return nil }
        return HTMLScanner.isoTimestamp(date)
    }

    /// Leading decimal digits of a JSON value, like JavaScript `parseInt` (pornhub.ts:172-176, 291).
    private static func leadingInt(_ raw: String) -> Int {
        guard let match = HTMLScanner.captures(#"^\s*(\d+)"#, in: raw) else { return 0 }
        return Int(match[1]) ?? 0
    }

    /// String form of a JSON scalar. Numbers keep their plain decimal form.
    private static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.stringValue
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
