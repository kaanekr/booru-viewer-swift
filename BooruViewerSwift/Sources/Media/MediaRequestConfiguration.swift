import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// One leg of a media fetch: the URL that will actually be requested, the origin
/// URL the headers are derived from, and whether the leg goes through the worker.
struct MediaRouteAttempt {
    let url: URL
    let originalURL: URL
    let isRelayed: Bool
}

/// Shared media transport policy for native image and video loading.
///
/// Mirrors the RN split between `getMediaHeaders` (src/utils/media.ts:314-358) and
/// `proxyService.proxyUrl` (src/services/proxyService.ts:197-211): every media
/// request carries the browser User-Agent plus the per-host `Referer`/`Origin`,
/// and it is routed through the Cloudflare worker when the toggle is on or the
/// host is TLS-fragile. `MediaImageLoader` adds the one-shot retry that
/// `ProxyAwareHTTPClient` performs for API traffic.
enum MediaRequestConfiguration {
    /// proxyService.ts:98-99/`getMediaHeaders` share this exact UA string.
    static let userAgent = ProxyRelay.neutralUserAgent

    /// Guards `storedProxy`; media loads read it from background actors.
    private static let lock = NSLock()
    private static var storedProxy = ProxyConfig()

    /// Proxy settings in effect for media loads; defaults to the disabled config.
    static func currentProxy() -> ProxyConfig {
        lock.lock()
        defer { lock.unlock() }
        return storedProxy
    }

    /// Called whenever the persisted settings change so loaders pick up the toggle.
    static func updateCurrentProxy(_ proxy: ProxyConfig) {
        lock.lock()
        defer { lock.unlock() }
        storedProxy = proxy
    }

    // MARK: Headers

    /// media.ts:314-358 `getMediaHeaders`: browser UA plus the per-host Referer
    /// (and RedGifs Origin) Booru CDNs require.
    static func headers(for url: URL) -> [String: String] {
        var headers: [String: String] = ["User-Agent": userAgent]
        let raw = url.absoluteString
        // media.ts:322-323: Googlebot hits hand out escaped URLs; decode before matching.
        let target = raw.removingPercentEncoding ?? raw

        if contains(target, "realbooru.com") {
            headers["Referer"] = "https://realbooru.com/"
        } else if contains(target, "gelbooru.com") {
            headers["Referer"] = "https://gelbooru.com/"
        } else if contains(target, "rule34.xxx") || contains(target, "rule34.us") {
            headers["Referer"] = "https://rule34.xxx/"
        } else if contains(target, "danbooru.donmai.us") || contains(target, "cdn.donmai.us") {
            headers["Referer"] = "https://danbooru.donmai.us/"
        } else if contains(target, "yande.re") {
            headers["Referer"] = "https://yande.re/"
        } else if contains(target, "cum.st") || contains(target, "coomer.st") {
            headers["Referer"] = "https://cum.st/"
        } else if contains(target, "xvideos-cdn.com") || contains(target, "xvideos.com") {
            headers["Referer"] = "https://www.xvideos.com/"
        } else if contains(target, "xhamster.com")
            || contains(target, "xhamster-cdn")
            || contains(target, "xhpingcdn.com")
            || contains(target, "xhcdn") {
            headers["Referer"] = "https://xhamster.com/"
        } else if contains(target, "pornhub.com") || contains(target, "phncdn.com") {
            headers["Referer"] = "https://www.pornhub.com/"
        } else if contains(target, "sex.com") || contains(target, "sxccdn.com") {
            headers["Referer"] = "https://www.sex.com/"
        } else if contains(target, "hentaihaven.xxx")
            || contains(target, "coverlanyvd.org")
            || contains(target, "octopusmanifest.org") {
            headers["Referer"] = "https://hentaihaven.xxx/"
        } else if contains(target, "redgifs.com") {
            // media.ts:347-350: media.redgifs.com 403s without a Referer and its
            // token is bound to this Origin.
            headers["Referer"] = "https://www.redgifs.com/"
            headers["Origin"] = "https://www.redgifs.com"
        } else if contains(target, "nhentai.net") {
            headers["Referer"] = "https://nhentai.net/"
        }

        return headers
    }

    /// Headers for one leg: worker legs get the scrubbed neutral set
    /// (proxyService.ts:91-104), direct legs the origin headers.
    static func headers(for attempt: MediaRouteAttempt) -> [String: String] {
        guard attempt.isRelayed else { return headers(for: attempt.originalURL) }
        return ProxyRelay.workerHeaders(
            for: attempt.originalURL,
            headers: headers(for: attempt.originalURL)
        )
    }

    // MARK: Routing

    /// `MediaURLNormalizer` repair, then `proxyUrl` (proxyService.ts:197-211):
    /// relay when the toggle is on or the host is TLS-fragile, otherwise direct.
    static func routedURL(for url: URL, proxy: ProxyConfig? = nil) -> URL {
        routeAttempts(for: url, proxy: proxy).first?.url ?? url
    }

    /// Every leg for `url`, primary first and the alternate leg second (when a
    /// worker makes one possible). The retry mirrors `ProxyAwareHTTPClient`.
    /// CDN mirrors (nhentai i1..i4/t1..t4, Gelbooru thumbnail hosts) follow as
    /// extra legs, so a dead host automatically falls through to a live one.
    static func routeAttempts(for url: URL, proxy: ProxyConfig? = nil) -> [MediaRouteAttempt] {
        let normalized = MediaURLNormalizer.normalize(url) ?? url
        let cfg = proxy ?? currentProxy()
        var legs = attempts(for: normalized, proxy: cfg)
        for mirror in mirrorURLs(for: normalized) {
            guard !legs.contains(where: { $0.originalURL == mirror }) else { continue }
            legs.append(contentsOf: attempts(for: mirror, proxy: cfg))
        }
        return legs
    }

    /// Legs for one origin URL, without mirror expansion.
    private static func attempts(for normalized: URL, proxy cfg: ProxyConfig) -> [MediaRouteAttempt] {
        let worker = ProxyRelay.normalizedWorkerURL(cfg.workerURL)
        // proxyService.ts:81/201: a URL that already points at the worker is not wrapped again.
        let isAlreadyRelay = worker.map { normalized.absoluteString.hasPrefix($0) } ?? false
        let relay: URL? = isAlreadyRelay ? nil : worker.flatMap {
            ProxyRelay.relayURL(for: normalized, workerURL: $0)
        }
        // proxyService.ts:65-67 and :204-209.
        let relayPreferred = cfg.enabled || ProxyRelay.isTLSFragile(normalized)

        let direct = MediaRouteAttempt(url: normalized, originalURL: normalized, isRelayed: isAlreadyRelay)
        guard let relay, relay != normalized else { return [direct] }
        let relayed = MediaRouteAttempt(url: relay, originalURL: normalized, isRelayed: true)
        return relayPreferred ? [relayed, direct] : [direct, relayed]
    }

    /// Alternate CDN hosts to try after `url` fails, in a stable order.
    ///
    /// - nhentai: `i1`...`i4` (or `t1`...`t4`) galleries are mirrored across all four
    ///   hosts, so a throttled/missing host falls through to the next mirror.
    /// - Gelbooru: thumbnails live on `img3`/`assets`, not always `img4`.
    static func mirrorURLs(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased() else { return [] }
        var mirrors: [URL] = []

        if let match = host.range(of: #"^([it])[1-4]?\.nhentai\.net$"#, options: [.regularExpression, .caseInsensitive]) {
            let prefix = String(host[match].prefix(1))
            for index in 1...4 {
                let mirrorHost = "\(prefix)\(index).nhentai.net"
                guard mirrorHost != host else { continue }
                mirrors.append(replacingHost(of: url, with: mirrorHost))
            }
            return mirrors
        }

        let path = url.path.lowercased()
        let isGelbooruThumbnail = host.hasSuffix("gelbooru.com")
            && (path.contains("/thumbnails/") || path.contains("thumbnail_"))
        if isGelbooruThumbnail {
            for mirrorHost in ["img4.gelbooru.com", "img3.gelbooru.com", "assets.gelbooru.com"]
            where mirrorHost != host {
                mirrors.append(replacingHost(of: url, with: mirrorHost))
            }
        }
        return mirrors
    }

    /// Same URL on a different host, keeping scheme, path, query and fragment.
    private static func replacingHost(of url: URL, with host: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = host
        return components.url ?? url
    }

    /// A one-leg `URLRequest` carrying the right headers for its route.
    static func makeURLRequest(for url: URL, proxy: ProxyConfig? = nil) -> URLRequest {
        let attempts = routeAttempts(for: url, proxy: proxy)
        let attempt = attempts.first
            ?? MediaRouteAttempt(url: MediaURLNormalizer.normalize(url) ?? url, originalURL: url, isRelayed: false)
        var request = URLRequest(url: attempt.url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = !attempt.isRelayed
        for (name, value) in headers(for: attempt) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    // MARK: Video

    #if canImport(AVFoundation)
    /// `AVPlayerItem` that routes like the image loader and carries the
    /// `Referer`/`User-Agent` headers AVPlayer would otherwise omit.
    static func makePlayerItem(for url: URL, proxy: ProxyConfig? = nil) -> AVPlayerItem {
        let attempts = routeAttempts(for: url, proxy: proxy)
        if let attempt = attempts.first {
            return makePlayerItem(for: attempt)
        }
        let normalized = MediaURLNormalizer.normalize(url) ?? url
        return makePlayerItem(for: MediaRouteAttempt(url: normalized, originalURL: normalized, isRelayed: false))
    }

    /// `AVPlayerItem` for an explicit route leg (used for the one-shot retry).
    static func makePlayerItem(for attempt: MediaRouteAttempt) -> AVPlayerItem {
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers(for: attempt)]
        let asset = AVURLAsset(url: attempt.url, options: options)
        return AVPlayerItem(asset: asset)
    }
    #endif

    // MARK: Helpers

    /// Case-insensitive substring test, like the RN `/host/i` regexes.
    private static func contains(_ value: String, _ needle: String) -> Bool {
        value.range(of: needle, options: .caseInsensitive) != nil
    }
}

/// Aspect-ratio memo of media that actually loaded, keyed by normalized URL.
///
/// Booru posts often arrive without `width`/`height`, so cards measure the
/// image the loader decoded (or the video poster frame it generated) and reuse
/// that ratio for the following passes. Ratios are clamped to `0.45...1.85`,
/// slightly wider than the card clamp, so the clamp still has room to work.
enum MediaAspectRatioCache {
    private static let lock = NSLock()
    private static var ratios: [String: Double] = [:]
    private static let minimumRatio = 0.45
    private static let maximumRatio = 1.85

    /// Ratio recorded for `url`, if any.
    static func aspectRatio(for url: URL?) -> Double? {
        guard let url else { return nil }
        let key = cacheKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        return ratios[key]
    }

    /// First recorded ratio across the post's preview, sample and original URLs.
    static func aspectRatio(for post: BooruPost) -> Double? {
        for candidate in [post.previewURL, post.sampleURL, post.originalURL] {
            if let ratio = aspectRatio(for: candidate) { return ratio }
        }
        return nil
    }

    /// Stores the clamped `width / height` ratio for `url`.
    static func record(width: CGFloat, height: CGFloat, for url: URL) {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return }
        let ratio = min(maximumRatio, max(minimumRatio, Double(width / height)))
        let key = cacheKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        ratios[key] = ratio
    }

    /// Same normalization as the image cache, so a post URL and its loaded
    /// mirror share one entry.
    private static func cacheKey(for url: URL) -> String {
        (MediaURLNormalizer.normalize(url) ?? url).absoluteString
    }
}

#if canImport(UIKit)
/// Shared in-memory image loader with the proxy fallback the RN media path gets
/// from `proxyService.fetchWithFallback` (proxyService.ts:106-151).
actor MediaImageLoader {
    static let shared = MediaImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [NSString: Task<UIImage, Error>] = [:]
    private var prefetching: Set<NSString> = []
    private let session: URLSession

    /// Concurrent background prefetches; visible loads are not limited by this.
    private static let maxConcurrentPrefetches = 6

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .useProtocolCachePolicy
        self.session = session ?? URLSession(configuration: configuration)
        cache.countLimit = 260
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    /// Cache hit check usable before a `task` spends time on the actor hop.
    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: MediaImageLoader.cacheKey(for: url))
    }

    /// Background warm-up for URLs that are not cached yet (manga reader
    /// scrolling). At most six prefetches run at a time; the rest are picked up
    /// on the next call.
    func prefetch(urls: [URL]) {
        let session = self.session
        for url in urls {
            guard prefetching.count < MediaImageLoader.maxConcurrentPrefetches else { return }
            let key = MediaImageLoader.cacheKey(for: url)
            guard cache.object(forKey: key) == nil,
                  inFlight[key] == nil,
                  !prefetching.contains(key) else { continue }
            let task = Task<UIImage, Error> { [session] in
                try await MediaImageLoader.fetchImage(for: url, proxy: nil, session: session)
            }
            inFlight[key] = task
            prefetching.insert(key)
            let prefetchKey = key as String
            Task.detached { [weak self] in
                let image = try? await task.value
                await self?.finishPrefetch(key: prefetchKey, image: image)
            }
        }
    }

    /// Decoded image for `url`, relay-first with a single alternate-leg retry.
    func image(for url: URL, proxy: ProxyConfig? = nil) async throws -> UIImage {
        let key = MediaImageLoader.cacheKey(for: url)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // Coalesce concurrent requests for the same asset (grid + preview).
        if let pending = inFlight[key] {
            return try await pending.value
        }
        let session = self.session
        let task = Task<UIImage, Error> { [session] in
            try await MediaImageLoader.fetchImage(for: url, proxy: proxy, session: session)
        }
        inFlight[key] = task

        let image: UIImage
        do {
            image = try await task.value
        } catch {
            inFlight[key] = nil
            throw error
        }
        inFlight[key] = nil
        cache.setObject(image, forKey: key, cost: MediaImageLoader.cost(of: image))
        return image
    }

    /// Drops every cached image (settings changes, memory warnings).
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Completes one background prefetch, caching the decoded image on success.
    private func finishPrefetch(key: String, image: UIImage?) {
        let cacheKey = key as NSString
        inFlight[cacheKey] = nil
        prefetching.remove(cacheKey)
        guard let image else { return }
        cache.setObject(image, forKey: cacheKey, cost: MediaImageLoader.cost(of: image))
    }

    // MARK: Fetch

    private static func fetchImage(for url: URL, proxy: ProxyConfig?, session: URLSession) async throws -> UIImage {
        let attempts = MediaRequestConfiguration.routeAttempts(for: url, proxy: proxy)
        let legs = attempts.isEmpty
            ? [MediaRouteAttempt(url: MediaURLNormalizer.normalize(url) ?? url, originalURL: url, isRelayed: false)]
            : attempts

        let wantsVideoPoster = isVideoURL(url)
        var lastError: Error = BooruError.network("Media request failed")
        for attempt in legs {
            try Task.checkCancellation()
            if wantsVideoPoster {
                // Video-only cards (Cum.st, raw .mp4/.m3u8 links) never yield a
                // static image: extract a poster frame instead of a black box.
                #if canImport(AVFoundation)
                if let poster = await videoPosterImage(for: attempt) {
                    return await prepared(poster, for: url)
                }
                #endif
                lastError = BooruError.network("Video poster extraction failed")
                continue
            }
            var request = URLRequest(url: attempt.url)
            request.timeoutInterval = 30
            request.httpShouldHandleCookies = !attempt.isRelayed
            for (name, value) in MediaRequestConfiguration.headers(for: attempt) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = BooruError.network("Media request failed with status \(http.statusCode)")
                    continue
                }
                guard let image = UIImage(data: data) else {
                    // A payload that is not an image can still be video bytes.
                    #if canImport(AVFoundation)
                    if let poster = await videoPosterImage(for: attempt) {
                        return await prepared(poster, for: url)
                    }
                    #endif
                    lastError = BooruError.network("Media payload was not a decodable image")
                    continue
                }
                return await prepared(image, for: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Fully prepares an image for display and memoizes its aspect ratio.
    private static func prepared(_ image: UIImage, for url: URL) async -> UIImage {
        MediaAspectRatioCache.record(width: image.size.width, height: image.size.height, for: url)
        let display = await image.byPreparingForDisplay() ?? image
        return display
    }

    #if canImport(AVFoundation)
    /// Mid-frame poster for one route leg, carrying the media headers AVPlayer
    /// relies on.
    private static func videoPosterImage(for attempt: MediaRouteAttempt) async -> UIImage? {
        let asset = AVURLAsset(
            url: attempt.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": MediaRequestConfiguration.headers(for: attempt)]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
    #endif

    /// Card cover extensions that never decode as a still image.
    static func isVideoURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.lowercased()
        let raw = url.absoluteString.lowercased()
        let clean = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? raw
        let extensions = ["mp4", "mov", "m4v", "m3u8", "webm"]
        return extensions.contains { path.hasSuffix("." + $0) || clean.hasSuffix("." + $0) }
    }

    private static func cacheKey(for url: URL) -> NSString {
        (MediaURLNormalizer.normalize(url) ?? url).absoluteString as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
#endif
