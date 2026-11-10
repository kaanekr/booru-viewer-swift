import Foundation

/// Realbooru list scraper. Mirrors RN `fetchRealbooruPosts` (booruApi.ts:1032-1206) and the tag autocomplete (booruApi.ts:2412-2435).
struct RealbooruSource: BooruSource {
    let id: SourceID = .realbooru
    let displayName = "Realbooru"
    let supportsVideo = true

    /// RN realbooru base URL (sources.ts:31).
    static let baseURL = "https://realbooru.com"
    /// RN User-Agent constant (booruApi.ts:58).
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    /// RN lists 42 posts per page (booruApi.ts:1040-1041).
    static let pageSize = 42

    /// Named regex constants for the Realbooru markup.
    private enum Pattern {
        /// Card start: `<div class="... thumb ..." id="s<digits>">` (booruApi.ts:1065).
        static let cardStart = #"<div\s+class=["'][^"']*thumb[^"']*["']\s+id=["']s?(\d+)["']>"#
        /// Thumbnail path `thumbnails/<dir>/<dir>/thumbnail_<hash>.` shared with the full file (booruApi.ts:1094).
        static let thumbnailPath = #"thumbnails/([a-f0-9]+)/([a-f0-9]+)/thumbnail_([a-f0-9]+)\."#
        /// Score token inside the title, such as `score:17` (booruApi.ts:1086).
        static let scoreToken = #"score:(\d+)"#
        /// Score tokens removed before the title is split into tags (booruApi.ts:1100).
        static let scoreRemoval = #"score:\d+"#
        /// Rating tokens removed before the title is split into tags (booruApi.ts:1100).
        static let ratingRemoval = #"rating:\w+"#
        /// File URL in a data attribute, such as `data-file="..."` (booruApi.ts:1129).
        static let dataURLAttribute = #"data-(?:file|src|original|original-url|media)=["']([^"']+)["']"#
        /// Extension in a data attribute, such as `data-ext="webm"` (booruApi.ts:1141).
        static let dataExtAttribute = #"data-ext=["']([a-z0-9]+)["']"#
        /// Count in an autocomplete label, such as `(12)` (booruApi.ts:2426).
        static let countInLabel = #"\((\d+)\)"#
        /// Detail page `<source …>`, the real playable file (media.ts:553). The whole tag is
        /// captured so `HTMLScanner.attribute` can read `src` in either quote style.
        static let sourceTag = #"(<source\b[^>]*>)"#
        /// Detail page `<video …>`, when the page puts the file on the element itself.
        static let videoTag = #"(<video\b[^>]*>)"#
        /// Detail page `<img …>`, the still a GIF post resolves to (media.ts:564).
        static let imageTag = #"(<img\b[^>]*>)"#
        /// Detail page `<a …>`, which carries the "Original image"/"Original download" links.
        static let anchorTag = #"(<a\b[^>]*>)"#
    }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        let pageNumber = max(1, page)
        guard let url = Self.listURL(page: pageNumber, tags: Self.searchTags(for: query)) else {
            throw BooruError.network("Invalid Realbooru list URL.")
        }
        let request = HTMLScanner.htmlRequest(url, userAgent: Self.userAgent, referer: Self.baseURL + "/")
        let html = try await HTMLScanner.fetchHTML(request, client: context.http)
        let posts = Self.parseListing(html: html)
        return PostPage(posts: posts, nextPage: posts.isEmpty ? nil : pageNumber + 1, hasMore: !posts.isEmpty)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        // RN ignores queries shorter than two characters (booruApi.ts:2291).
        let term = HTMLScanner.trim(prefix)
        guard term.count >= 2,
              let url = URL(string: "\(Self.baseURL)/autocomplete.php?q=\(HTMLScanner.componentEncode(term))")
        else { return [] }
        var request = HTMLScanner.htmlRequest(url, userAgent: Self.userAgent, referer: Self.baseURL + "/")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await context.http.data(for: request)
            guard (200..<300).contains(response.statusCode),
                  let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return items.prefix(12).compactMap { (item: [String: Any]) -> BooruTagSuggestion? in
                let value = item["value"] as? String
                let label = item["label"] as? String
                let name = value ?? label ?? ""
                guard !name.isEmpty else { return nil }
                let count = label.flatMap { HTMLScanner.firstCapture(Pattern.countInLabel, in: $0) }.flatMap { Int($0) } ?? 0
                return BooruTagSuggestion(name: name, category: .general, postCount: count)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // RN returns an empty list on any autocomplete failure (booruApi.ts:2523-2525).
            return []
        }
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        // The listing carries no file extension (video-ness comes from tags), so a card can
        // only *guess* `<base>/images/<hash>.<ext>` from its thumbnail hash. The detail page
        // is the one place naming the real file: mp4, webm (some posts are webm-only), or
        // the full GIF still (RN `resolveRealbooruVideoUrls`, ImageViewerModal.tsx:967-977).
        let files = try await detailFiles(for: post, context: context)
        let detailImage = Self.detailImageURL(files)
        let detailVideo = Self.detailVideoURL(files)
        // A detail page without `<video>` sources but with an `<img>` file means the card's
        // "video" guess was wrong (a mistagged GIF): the image wins over the `.mp4` guess
        // (ImageViewerModal.tsx:1174-1182). With no detail page to read, the listing's own
        // `/images/<hash>.<ext>` derivation is only kept when a HEAD confirms the file
        // exists, so no guessed container ever leaves this source as playable media.
        var video = detailVideo
        if video == nil, detailImage == nil {
            video = try await Self.verifiedThumbnailGuess(for: post, context: context)
        }
        return ResolvedMedia(
            imageURL: detailImage ?? Self.stillImageURL(for: post, quality: context.imageQuality),
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }

    /// Display image for `post`, never a video file. When the sample/original chain resolves
    /// to the post's own video container, the card's thumbnail stands in, so an unplayable
    /// WebM shows a cover instead of a spinner or a black box.
    private static func stillImageURL(for post: BooruPost, quality: ImageQuality) -> URL? {
        if let resolved = ImageQualityResolver.imageURL(for: post, quality: quality),
           !isVideoPath(resolved) {
            return resolved
        }
        return ImageQualityResolver.placeholderURL(for: post) ?? post.previewURL
    }

    /// True when the URL names a video container (never a decodable still).
    private static func isVideoPath(_ url: URL) -> Bool {
        let clean = url.absoluteString.lowercased().components(separatedBy: "?")[0]
        return videoExtensions.contains { clean.hasSuffix("." + $0) }
    }

    // MARK: - Detail page

    /// Files of one detail page (RN `parseRealbooruDetail`, media.ts:550-576).
    struct DetailFiles: Sendable {
        /// `.mp4` full file, the preferred playable.
        var mp4: String = ""
        /// WebM full file, preserved as-is: AVPlayer cannot decode WebM, so the viewer
        /// probes its `.mp4` sibling and keeps the WebM URL in the post's metadata either way.
        var webm: String = ""
        /// Full still of a GIF post, which has no `<video>` tag.
        var image: String = ""
    }

    /// Detail files of `post`, or nil when there is no page to read so the card URLs stay.
    /// Cancellation propagates; any other failure is tolerated, like RN's `.catch(() => {})`.
    private func detailFiles(for post: BooruPost, context: SourceContext) async throws -> DetailFiles? {
        guard let pageURL = Self.detailPageURL(for: post) else { return nil }
        let request = HTMLScanner.htmlRequest(pageURL, userAgent: Self.userAgent, referer: Self.baseURL + "/")
        do {
            return Self.parseDetailFiles(html: try await HTMLScanner.fetchHTML(request, client: context.http))
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    /// The post page itself, then the canonical `index.php?page=post&s=view&id=<raw id>`
    /// (booruApi.ts:1174-1176).
    static func detailPageURL(for post: BooruPost) -> URL? {
        if let link = post.sourceLink, link.host != nil { return link }
        let rawID = post.id.hasPrefix("realbooru_") ? String(post.id.dropFirst("realbooru_".count)) : post.id
        guard !rawID.isEmpty else { return nil }
        return URL(string: baseURL + "/index.php?page=post&s=view&id=" + HTMLScanner.componentEncode(rawID))
    }

    /// mp4 first, then webm (media.ts:579-582). The webm URL is handed on: the viewer's
    /// `MP4Upgrade` probes its `.mp4` sibling, since AVPlayer cannot decode WebM.
    static func detailVideoURL(_ files: DetailFiles?) -> URL? {
        guard let files else { return nil }
        for value in [files.mp4, files.webm] where !value.isEmpty {
            if let url = HTMLScanner.absoluteURL(value, base: baseURL) {
                return MediaURLNormalizer.normalize(url, sourceID: .realbooru)
            }
        }
        return nil
    }

    /// Full still of a GIF post (media.ts:563-574).
    static func detailImageURL(_ files: DetailFiles?) -> URL? {
        guard let files, !files.image.isEmpty,
              let url = HTMLScanner.absoluteURL(files.image, base: baseURL)
        else { return nil }
        return MediaURLNormalizer.normalize(url, sourceID: .realbooru)
    }

    /// Reads the detail page's real file (RN `parseRealbooruDetail`, media.ts:550-576):
    /// `<source src>`, the `<video src>` fallback, an "Original image" / "Original download"
    /// anchor, else the full `/images/` still of a GIF post.
    ///
    /// Tags are captured whole and their attributes read through `HTMLScanner.attribute`, so
    /// single- and double-quoted values both parse and HTML entities are decoded once.
    static func parseDetailFiles(html: String) -> DetailFiles {
        var files = DetailFiles()
        guard !html.isEmpty else { return files }

        // Playable files first: `<source src>` inside the `<video>` element, in page order.
        for tag in HTMLScanner.allFirstCaptures(Pattern.sourceTag, in: html, caseInsensitive: true) {
            guard let src = HTMLScanner.attribute("src", in: tag) else { continue }
            store(path: normalizeFileURL(src), into: &files, allowImage: false)
        }
        // Some markup puts the file on `<video src>` itself instead of a `<source>` child.
        if files.mp4.isEmpty, files.webm.isEmpty {
            for tag in HTMLScanner.allFirstCaptures(Pattern.videoTag, in: html, caseInsensitive: true) {
                guard let src = HTMLScanner.attribute("src", in: tag) else { continue }
                store(path: normalizeFileURL(src), into: &files, allowImage: false)
            }
        }
        // A Gelbooru-engine page also links the file itself as "Original image" /
        // "Original download"; only a path inside `/images/` counts, so a sample,
        // a thumbnail or a post link is never mistaken for the file.
        for tag in HTMLScanner.allFirstCaptures(Pattern.anchorTag, in: html, caseInsensitive: true) {
            guard let href = HTMLScanner.attribute("href", in: tag) else { continue }
            let path = normalizeFileURL(href)
            guard isFullFilePath(path) else { continue }
            store(path: path, into: &files, allowImage: true)
            if !files.mp4.isEmpty, !files.webm.isEmpty, !files.image.isEmpty { break }
        }
        // No video and no linked file: the full still of a GIF post (media.ts:563-574).
        if files.mp4.isEmpty, files.webm.isEmpty, files.image.isEmpty {
            for tag in HTMLScanner.allFirstCaptures(Pattern.imageTag, in: html, caseInsensitive: true) {
                guard let src = HTMLScanner.attribute("src", in: tag) else { continue }
                let path = normalizeFileURL(src)
                guard isFullFilePath(path) else { continue }
                store(path: path, into: &files, allowImage: true)
                if !files.image.isEmpty { break }
            }
        }
        return files
    }

    /// Classifies one already-resolved path into `files`. Only the first file of each kind
    /// wins, so the page order decides and a duplicate never overwrites a better entry.
    private static func store(path: String, into files: inout DetailFiles, allowImage: Bool) {
        guard !path.isEmpty else { return }
        let clean = path.components(separatedBy: "?")[0].lowercased()
        if clean.hasSuffix(".mp4") {
            if files.mp4.isEmpty { files.mp4 = path }
        } else if clean.hasSuffix(".webm") {
            if files.webm.isEmpty { files.webm = path }
        } else if allowImage,
                  files.image.isEmpty,
                  imageExtensions.contains(where: { clean.hasSuffix("." + $0) }) {
            files.image = path
        }
    }

    /// A path inside Realbooru's full-file tree that names a media file, e.g.
    /// `/images/25/a2/<hash>.webm`. The detail page writes `//images/…` (which also
    /// contains `/images/`); a bare relative `images/…` is accepted as the same tree.
    private static func isFullFilePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/images/") || lower.hasPrefix("images/") else { return false }
        let clean = lower.components(separatedBy: "?")[0]
        return videoExtensions.contains { clean.hasSuffix("." + $0) }
            || imageExtensions.contains { clean.hasSuffix("." + $0) }
    }

    private static let imageExtensions = ["gif", "jpg", "jpeg", "png", "webp"]
    private static let videoExtensions = ["mp4", "webm"]

    /// Path roots that only ever appear as a Realbooru path, never as a host: the detail
    /// page writes `//images/<d1>/<d2>/<hash>.<ext>` (a path with a leading double slash).
    private static let sameOriginPathRoots: Set<String> = ["images", "thumbnails", "samples"]

    /// RN `normalizeRealbooruFileUrl` (media.ts:533-540): entity-decoded and
    /// protocol-relative repaired.
    ///
    /// Deliberate difference from the RN template: an intentional path double slash is
    /// preserved. `//images/…` is repaired into the same-origin
    /// `https://realbooru.com//images/…` the page wrote (both spellings serve the file),
    /// while a genuinely protocol-relative host (`//cdn.example/…`) keeps its own host.
    /// An already absolute URL is returned verbatim, double slash included.
    static func normalizeFileURL(_ raw: String) -> String {
        let value = HTMLScanner.trim(HTMLScanner.decodeEntities(raw))
        guard !value.isEmpty else { return "" }
        guard value.hasPrefix("//") else { return value }
        let root = value.dropFirst(2).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard sameOriginPathRoots.contains(root.lowercased()) else { return "https:" + value }
        return baseURL + value
    }

    /// True when `url` is one of the listing's thumbnail-hash guesses
    /// (`<base>/images/<d1>/<d2>/<hash>.<ext>`), whose existence is unknown until probed.
    /// The listing has no file extension, so the RN-parity `.mp4` guess must be verified
    /// before it is handed to the player.
    static func isThumbnailHashGuess(_ url: URL?, for post: BooruPost) -> Bool {
        guard post.sourceID == .realbooru, let url else { return false }
        let value = (MediaURLNormalizer.normalize(url, sourceID: .realbooru) ?? url).absoluteString
        return thumbnailHashGuesses(for: post).contains(value)
    }

    /// The `/images/<d1>/<d2>/<hash>.<ext>` URLs the listing can derive from the thumbnail
    /// path (booruApi.ts:1155-1161), for the extensions Realbooru actually serves.
    static func thumbnailHashGuesses(for post: BooruPost) -> [String] {
        guard let thumb = post.previewURL?.absoluteString,
              let parts = HTMLScanner.captures(Pattern.thumbnailPath, in: thumb, caseInsensitive: true),
              parts.count > 3
        else { return [] }
        return ["mp4", "webm", "gif"].map { baseURL + "/images/\(parts[1])/\(parts[2])/\(parts[3]).\($0)" }
    }

    /// The listing's `/images/` derivation, kept only when the server confirms the file
    /// exists. Cancellation propagates; any other failure, including a rejected HEAD, leaves
    /// the file unproven so no video URL is returned.
    private static func verifiedThumbnailGuess(for post: BooruPost, context: SourceContext) async throws -> URL? {
        for candidate in [post.originalURL, post.sampleURL].compactMap({ $0 })
        where isThumbnailHashGuess(candidate, for: post) {
            if try await fileExists(candidate, http: context.http) { return candidate }
        }
        return nil
    }

    /// Status-only HEAD probe: the response body is never read, so no media bytes are
    /// fetched. A host that rejects HEAD leaves the URL unproven instead of guessed.
    private static func fileExists(_ url: URL, http: any HTTPClientProtocol) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = MP4Upgrade.timeoutSeconds
        do {
            let (_, response) = try await http.data(for: request)
            return (200...299).contains(response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    // MARK: - URLs and tags

    /// List URL for one page: `index.php?page=post&s=list&pid=<(page-1)*42>[&tags=...]` (booruApi.ts:1039-1051).
    static func listURL(page: Int, tags: String) -> URL? {
        let pid = (max(1, page) - 1) * pageSize
        var parameters: [(String, String)] = [("page", "post"), ("s", "list"), ("pid", String(pid))]
        if !tags.isEmpty {
            parameters.append(("tags", tags))
        }
        let query = parameters
            .map { HTMLScanner.formEncode($0.0) + "=" + HTMLScanner.formEncode($0.1) }
            .joined(separator: "&")
        return URL(string: baseURL + "/index.php?" + query)
    }

    /// The `tags` value: query text, filter tags, then the Gelbooru-engine tokens RN adds in order:
    /// score, user, leaderboard date, rating, sort (booruApi.ts:248-383).
    static func searchTags(for query: SearchQuery) -> String {
        let filter = query.filter
        var derived: [String] = []
        if let minScore = filter.minScore, minScore > 0 {
            derived.append("score:>=\(minScore)")
        }
        if let user = filter.user.map({ HTMLScanner.trim($0) }), !user.isEmpty {
            derived.append("user:\(user)")
        }
        // Historical leaderboard anchor. Realbooru is not in RN's exclusion list, so the raw date is a literal `date:` tag (booruApi.ts:287-296).
        if let leaderboard = filter.leaderboardDate, !leaderboard.isEmpty {
            derived.append("date:\(leaderboard.booruTrimmed)")
        }
        switch filter.rating {
        case .all: break
        case .safe: derived.append("rating:safe")
        case .questionable: derived.append("rating:questionable")
        case .explicit: derived.append("rating:explicit")
        }
        // Gelbooru-engine sort tokens; the unsupported orders send nothing (booruApi.ts:316-380).
        // The listing has no date-window parameter, so a timed top falls back to
        // the all-time score order (`sort:score:desc`).
        var sortToken: String?
        if filter.sortBy == .score || filter.timeRange != .all {
            sortToken = "sort:score:desc"
        } else {
            switch filter.sortBy {
            case .id: sortToken = "sort:id:desc"
            case .height: sortToken = "sort:height:desc"
            case .width: sortToken = "sort:width:desc"
            default: break
            }
        }
        if let sortToken {
            derived.append(sortToken)
        }
        return HTMLScanner.searchTokens(for: query, extra: derived).joined(separator: " ")
    }

    // MARK: - Parsing

    /// Parses one list page. A card without a link, an image, or a numeric id is skipped (booruApi.ts:1065-1203).
    static func parseListing(html: String) -> [BooruPost] {
        let createdAt = HTMLScanner.isoTimestamp()
        var posts: [BooruPost] = []
        for section in HTMLScanner.sections(Pattern.cardStart, in: html, caseInsensitive: true) {
            guard section.captures.count > 1 else { continue }
            guard let post = parseCard(id: section.captures[1], body: section.body, createdAt: createdAt) else { continue }
            posts.append(post)
        }
        return posts
    }

    private static func parseCard(id: String, body: String, createdAt: String) -> BooruPost? {
        guard let anchor = HTMLScanner.firstTag("a", in: body),
              let href = HTMLScanner.attribute("href", in: anchor),
              let image = HTMLScanner.firstTag("img", in: body),
              let rawThumb = HTMLScanner.attribute("src", in: image),
              let previewURL = MediaURLNormalizer.normalize(
                  HTMLScanner.absoluteURL(rawThumb, base: baseURL),
                  sourceID: .realbooru
              )
        else { return nil }

        let alt = HTMLScanner.attribute("alt", in: image) ?? ""
        let title = HTMLScanner.attribute("title", in: image) ?? ""
        let rating = ratingFromTitle(title)
        let score = HTMLScanner.firstCapture(Pattern.scoreToken, in: title).flatMap { Int($0) } ?? 0
        let rawTags = tagsFromCard(title: title, alt: alt)
        let lowerTags = rawTags.map { $0.lowercased() }

        // GIFs are tagged `animated` + `gif` with no `video` tag; they must not reach the video player (booruApi.ts:1106-1110).
        let hasGifTag = lowerTags.contains("gif")
        let hasVideoTag = lowerTags.contains { ["video", "webm", "mp4"].contains($0) }
        let isGif = hasGifTag && !hasVideoTag
        let thumbString = previewURL.absoluteString
        let hasVideoHint = lowerTags.contains { ["video", "webm", "mp4", "sound", "animated"].contains($0) }
        let isVideo = !isGif && (thumbString.hasSuffix(".mp4") || thumbString.hasSuffix(".webm") || hasVideoHint)

        // A verified file URL in the link, a data attribute, or a data-ext attribute sets the extension (booruApi.ts:1118-1145).
        var verifiedExt: String?
        var verifiedOriginal: URL?
        if let ext = HTMLScanner.mediaExtension(in: href) {
            verifiedExt = ext
            verifiedOriginal = HTMLScanner.absoluteURL(href, base: baseURL)
                .flatMap { MediaURLNormalizer.normalize($0, sourceID: .realbooru) }
        }
        if verifiedExt == nil,
           let dataURL = HTMLScanner.firstCapture(Pattern.dataURLAttribute, in: body, caseInsensitive: true),
           let ext = HTMLScanner.mediaExtension(in: HTMLScanner.trim(HTMLScanner.decodeEntities(dataURL))) {
            verifiedExt = ext
            verifiedOriginal = HTMLScanner.absoluteURL(HTMLScanner.decodeEntities(dataURL), base: baseURL)
                .flatMap { MediaURLNormalizer.normalize($0, sourceID: .realbooru) }
        }
        if verifiedExt == nil,
           let dataExt = HTMLScanner.firstCapture(Pattern.dataExtAttribute, in: body, caseInsensitive: true) {
            let lower = dataExt.lowercased()
            verifiedExt = lower == "jpeg" ? "jpg" : lower
        }
        // The listing names no file extension in any URL, so the container comes only from
        // the card's own tags (`video, webm, sound` on a WebM post). A plain `video` /
        // `animated` / `sound` card reports no extension instead of an invented `.mp4`.
        let taggedContainer = isGif ? "gif" : videoContainerTag(lowerTags)
        let fileExt = verifiedExt ?? taggedContainer ?? (isVideo ? nil : "jpg")

        // The full GIF is tens of MB, so a GIF keeps the light thumbnail as its sample and
        // its `/images/<hash>.gif` original (booruApi.ts:1155-1161). A card whose tags name
        // the container gets the matching `/images/<hash>.<container>` original: `.webm`
        // stays `.webm` (AVPlayer's codec limit is not a URL defect), and `resolveMedia`
        // still prefers whatever the detail page actually serves.
        var sampleURL: URL? = previewURL
        var originalURL: URL?
        if let verifiedOriginal {
            originalURL = verifiedOriginal
            sampleURL = verifiedOriginal
        } else if let container = taggedContainer,
                  let parts = HTMLScanner.captures(Pattern.thumbnailPath, in: thumbString, caseInsensitive: true),
                  parts.count > 3 {
            let file = "\(baseURL)/images/\(parts[1])/\(parts[2])/\(parts[3]).\(container)"
            originalURL = MediaURLNormalizer.normalize(URL(string: file), sourceID: .realbooru)
            sampleURL = isGif ? previewURL : originalURL
        }

        let sourceLink: URL?
        if href.contains("page=post") {
            sourceLink = MediaURLNormalizer.normalize(
                HTMLScanner.absoluteURL(href, base: baseURL),
                sourceID: .realbooru
            )
        } else {
            sourceLink = URL(string: "\(baseURL)/index.php?page=post&s=view&id=\(id)")
        }

        return BooruPost(
            id: "realbooru_\(id)",
            sourceID: .realbooru,
            sourceName: "Realbooru",
            title: nil,
            previewURL: previewURL,
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: sampleURL,
            originalURL: originalURL,
            width: 800,
            height: 1000,
            aspectRatio: 0.8,
            rating: rating,
            score: score,
            favCount: 0,
            tags: BooruTagGroups(
                artist: [],
                character: [],
                copyright: [],
                general: rawTags,
                meta: isVideo ? ["video"] : []
            ),
            allTags: rawTags,
            sourceLink: sourceLink,
            fileExt: fileExt,
            fileSize: nil,
            createdAt: createdAt,
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    /// Container named by the card's own tags (`webm` / `mp4`), or nil when the tags only
    /// say `video` / `animated` / `sound`.
    private static func videoContainerTag(_ lowerTags: [String]) -> String? {
        if lowerTags.contains("webm") { return "webm" }
        if lowerTags.contains("mp4") { return "mp4" }
        return nil
    }

    /// Rating from the title tokens (booruApi.ts:1081-1083). The default is safe.
    private static func ratingFromTitle(_ title: String) -> PostRating {
        if title.contains("rating:questionable") || title.contains("rating:q") { return .questionable }
        if title.contains("rating:explicit") || title.contains("rating:e") { return .explicit }
        return .safe
    }

    /// Tags come from the title when present, otherwise from alt (booruApi.ts:1097-1103). Score and rating tokens are removed first.
    private static func tagsFromCard(title: String, alt: String) -> [String] {
        let source: String
        if title.isEmpty {
            source = alt
        } else {
            let withoutScore = HTMLScanner.replace(Pattern.scoreRemoval, in: title, with: "")
            source = HTMLScanner.replace(Pattern.ratingRemoval, in: withoutScore, with: "")
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let pieces = source.components(separatedBy: separators).filter { !$0.isEmpty }
        return HTMLScanner.uniqued(pieces)
    }
}
