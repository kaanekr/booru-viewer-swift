import Foundation

/// Sex.com scraper. Mirrors RN `src/services/sexcom.ts` (URLs and listing parsing), `excludePremiumPosts` (sexcom.ts:212-215),
/// and `fetchSexComPosts` (booruApi.ts:1669-1712).
/// The RN source is `hidden: true` in the picker (sources.ts:91; SourceCatalog.tsx:46). The adapter exists for a saved selection.
struct SexComSource: BooruSource {
    let id: SourceID = .sexcom
    let displayName = "Sex.com"
    let supportsVideo = true

    /// RN `SEXCOM_BASE` (sexcom.ts:14).
    static let baseURL = "https://www.sex.com"
    /// RN `SEXCOM_UA` (sexcom.ts:17-18). An iPhone UA: the mobile variant returns the same markup.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    static let acceptLanguage = "en-US,en;q=0.9"

    /// Named regex constants for the Sex.com markup.
    private enum Pattern {
        /// Card start: `data-testid="video-card"` (sexcom.ts:65).
        static let cardStart = #"data-testid="video-card""#
        /// Numeric video id on the card (sexcom.ts:69).
        static let videoID = #"data-analytics-video_id="(\d+)""#
        /// Watch-page link `/en/videos/<id>...` (sexcom.ts:74).
        static let videoHref = #"href="(\/en\/videos\/\d+[^"]*)""#
        /// Title from a data attribute (sexcom.ts:78).
        static let dataTitle = #"data-title="([^"]+)""#
        /// Title from the image alt text (sexcom.ts:79).
        static let imageAlt = #"<img[^>]*alt="([^"]+)""#
        /// Title from any title attribute (sexcom.ts:80).
        static let titleAttribute = #"title="([^"]+)""#
        /// Static cover on the image CDN, `thumbnail.N.jpg.webp` or `poster.webp` (sexcom.ts:83).
        static let thumbnail = #"src="(https:\/\/images\.sxccdn\.com\/videos\/\d+\/\d+\/(?:thumbnail\.[^"]+|poster\.webp))""#
        /// Hover preview video source (sexcom.ts:85).
        static let videoSource = #"<video[^>]*src="([^"]+)""#
        /// Duration text (sexcom.ts:89).
        static let duration = #"<time>([^<]*)<\/time>"#
        /// Source channel name (sexcom.ts:91).
        static let channel = #"data-testid="video-link-to-source-channel"[^>]*>([^<]+)<"#
        /// View count, located within 800 characters of its test id (sexcom.ts:93).
        static let views = #"data-testid="view-count"[\s\S]{0,800}?<span>([^<]*)<\/span>"#
        /// Rating percentage, such as `98%` (sexcom.ts:95).
        static let ratingPercent = #">([0-9]{1,3})%<\/span>"#
        /// Premium flag on the card (sexcom.ts:98).
        static let premium = #"data-premium="([01])""#
        /// JSON-LD block on the detail page (sexcom.ts:171).
        static let jsonLD = #"<script type="application\/ld\+json">([\s\S]*?)<\/script>"#
        /// `contentUrl` inside the JSON-LD block (sexcom.ts:174).
        static let contentURL = #""contentUrl"\s*:\s*"([^"]+)""#
        /// Detail-page mp4 in a video tag, used when the JSON-LD video is missing (sexcom.ts:202).
        static let detailVideoSource = #"<video[^>]*src="([^"]+\.mp4[^"]*)""#
    }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let pageNumber = max(1, page)
        // The site has no sort parameter; keywords are plain text and '-' is not special (booruApi.ts:1676-1681).
        let tokens = HTMLScanner.searchTokens(for: query, extra: HTMLScanner.plainUserTokens(query.filter))
        let keyword = tokens.joined(separator: " ")
        guard let url = URL(string: Self.searchURL(page: pageNumber, keyword: keyword)) else {
            throw BooruError.network("Invalid Sex.com list URL.")
        }
        let request = HTMLScanner.htmlRequest(
            url,
            userAgent: Self.userAgent,
            referer: Self.baseURL + "/",
            acceptLanguage: Self.acceptLanguage
        )
        let html = try await HTMLScanner.fetchHTML(request, client: context.http)
        let parsed = Self.parseListing(html: html)
        let filtered = Self.excludingPremium(parsed)
        // RN returns the premium-filtered list, so paging follows the posts that can actually be shown (booruApi.ts:1708-1712).
        return PostPage(
            posts: filtered,
            nextPage: parsed.isEmpty ? nil : pageNumber + 1,
            hasMore: !filtered.isEmpty
        )
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        // RN has no suggestion endpoint for Sex.com (booruApi.ts:2405-2407).
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        // The card carries only a short preview clip; the full file is time-limited and resolved at viewer open (sexcom.ts:119-120).
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

    /// Playable files from a video detail page, mirroring RN `SexComFiles` (sexcom.ts:168-205).
    struct DetailFiles: Sendable {
        var hls: String = ""
        var mp4: String = ""
        /// A premium-host HLS stream, which the anonymous player cannot open (sexcom.ts:180-181).
        var premium: Bool = false
    }

    /// JSON-LD `contentUrl` first, then the page's own video tag (sexcom.ts:168-205).
    static func parseDetailFiles(html: String) -> DetailFiles {
        var files = DetailFiles()
        guard !html.isEmpty else { return files }
        let scope: String
        if let groups = HTMLScanner.captures(Pattern.jsonLD, in: html, caseInsensitive: true), groups.count > 1 {
            scope = groups[1]
        } else {
            scope = html
        }

        if let raw = HTMLScanner.firstCapture(Pattern.contentURL, in: scope, caseInsensitive: true) {
            let content = HTMLScanner.trim(raw)
            let path = content.components(separatedBy: "?")[0].lowercased()
            if path.hasSuffix(".m3u8") {
                files.hls = content
                files.premium = isPremiumHost(content)
            } else if path.hasSuffix(".mp4") {
                files.mp4 = content
            }
        }
        if files.mp4.isEmpty,
           let raw = HTMLScanner.firstCapture(Pattern.detailVideoSource, in: html, caseInsensitive: true) {
            files.mp4 = HTMLScanner.trim(HTMLScanner.decodeEntities(raw))
        }
        return files
    }

    /// Playable URL from detail files (RN `selectSexComPlayable`, sexcom.ts:222-226):
    /// a premium-locked HLS stream is skipped in favour of the preview mp4.
    static func playableURL(from files: DetailFiles) -> String? {
        if files.premium {
            return files.mp4.isEmpty ? nil : files.mp4
        }
        if !files.hls.isEmpty { return files.hls }
        return files.mp4.isEmpty ? nil : files.mp4
    }

    /// Fresh stream from the video page (RN `resolveSexComVideoUrls`, sexcom.ts:233-271).
    /// Returns nil when there is no link, the fetch fails, or the page carries no file, so the card's preview stays.
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
        guard let playable = playableURL(from: parseDetailFiles(html: html)) else { return nil }
        return normalizedURL(playable)
    }

    /// Scraped cover or preview-clip value as a usable URL: made absolute against the site
    /// base, then normalized (`MediaURLNormalizer`) so an `http://` cover becomes `https://`
    /// (media.ts:175-204).
    private static func normalizedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return MediaURLNormalizer.normalize(HTMLScanner.absoluteURL(raw, base: baseURL), sourceID: .sexcom)
    }

    /// `premium-` CDN hosts serve streams that need an account (sexcom.ts:180-181).
    private static func isPremiumHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return host.lowercased().hasPrefix("premium-")
    }

    // MARK: - URLs

    /// RN `buildSexComSearchCandidates(...)[0]` (sexcom.ts:20-30). The keyword is URI-encoded.
    static func searchURL(page: Int, keyword: String) -> String {
        let pageNumber = max(1, page)
        if keyword.isEmpty {
            return pageNumber <= 1 ? "\(baseURL)/en/videos" : "\(baseURL)/en/videos?page=\(pageNumber)"
        }
        let encoded = HTMLScanner.componentEncode(keyword)
        if pageNumber <= 1 {
            return "\(baseURL)/en/videos?search=\(encoded)"
        }
        return "\(baseURL)/en/videos?page=\(pageNumber)&search=\(encoded)"
    }

    // MARK: - Filtering

    /// Drops premium-locked cards from the grid (sexcom.ts:212-215). A card without the flag stays.
    static func excludingPremium(_ posts: [BooruPost]) -> [BooruPost] {
        posts.filter { $0.isPremium != true }
    }

    // MARK: - Parsing

    /// Parses list or search HTML (sexcom.ts:59-143). A card without an id or a link is skipped,
    /// and so is a card with neither a cover nor a preview clip.
    static func parseListing(html: String) -> [BooruPost] {
        let createdAt = HTMLScanner.isoTimestamp()
        var posts: [BooruPost] = []
        var seen = Set<String>()

        for section in HTMLScanner.sections(Pattern.cardStart, in: html) {
            let card = section.body
            guard let videoID = HTMLScanner.firstCapture(Pattern.videoID, in: card),
                  !seen.contains(videoID),
                  let href = HTMLScanner.firstCapture(Pattern.videoHref, in: card)
            else { continue }

            let thumbURL = normalizedURL(HTMLScanner.firstCapture(Pattern.thumbnail, in: card))
            let previewVideo = decodedCapture(Pattern.videoSource, in: card, caseInsensitive: true)
            let videoURL = normalizedURL(previewVideo)
            guard let previewURL = thumbURL ?? videoURL else { continue }

            let rawTitle = HTMLScanner.firstCapture(Pattern.dataTitle, in: card)
                ?? HTMLScanner.firstCapture(Pattern.imageAlt, in: card, caseInsensitive: true)
                ?? HTMLScanner.firstCapture(Pattern.titleAttribute, in: card)
                ?? ""
            let title = HTMLScanner.trim(HTMLScanner.decodeEntities(rawTitle))
            let duration = decodedCapture(Pattern.duration, in: card, caseInsensitive: true)
            let channel = decodedCapture(Pattern.channel, in: card, caseInsensitive: true)
            let viewsText = decodedCapture(Pattern.views, in: card, caseInsensitive: true)
            let ratingPercent = HTMLScanner.firstCapture(Pattern.ratingPercent, in: card) ?? ""
            // The premium marker is absent on some cards; those count as free (sexcom.ts:97-99).
            let isPremium = HTMLScanner.firstCapture(Pattern.premium, in: card) == "1"
            let score = HTMLScanner.parseCount(viewsText)

            let artist: [String] = channel.isEmpty ? [] : [channel]
            var general: [String] = []
            if !duration.isEmpty { general.append("duration:" + duration) }
            if !viewsText.isEmpty { general.append("views:" + viewsText) }
            if !ratingPercent.isEmpty { general.append("rating:" + ratingPercent + "%") }

            seen.insert(videoID)
            posts.append(BooruPost(
                id: "sx_\(videoID)",
                sourceID: .sexcom,
                sourceName: "Sex.com",
                title: title.isEmpty ? nil : title,
                previewURL: previewURL,
                previewFallbackURL: nil,
                previewVideoURL: videoURL,
                previewThumbURL: nil,
                previewThumbs: nil,
                sampleURL: videoURL ?? thumbURL,
                // The full file may be time-limited and is resolved at viewer open (sexcom.ts:119-120).
                originalURL: nil,
                width: 1280,
                height: 720,
                aspectRatio: 16.0 / 9.0,
                rating: .explicit,
                score: score,
                favCount: score,
                tags: BooruTagGroups(artist: artist, character: [], copyright: [], general: general, meta: ["video"]),
                allTags: artist,
                sourceLink: normalizedURL(HTMLScanner.decodeEntities(href)),
                fileExt: "mp4",
                fileSize: nil,
                createdAt: createdAt,
                niches: nil,
                isPremium: isPremium,
                pageCount: nil,
                mediaId: nil
            ))
        }
        return posts
    }

    /// First capture of `pattern`, entity-decoded and trimmed. Returns "" when absent.
    private static func decodedCapture(_ pattern: String, in card: String, caseInsensitive: Bool = false) -> String {
        let raw = HTMLScanner.firstCapture(pattern, in: card, caseInsensitive: caseInsensitive) ?? ""
        return HTMLScanner.trim(HTMLScanner.decodeEntities(raw))
    }
}
