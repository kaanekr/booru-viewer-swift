import Foundation

/// Routes requests through the Cloudflare relay with the proxyService.ts fallback rules.
/// - Toggle on with a valid worker: the first leg goes through the relay (proxyService.ts:126, :199-202).
/// - Toggle off: the first leg is direct, except TLS-fragile CDN hosts, which still go through the relay when a worker
///   is configured (proxyService.ts:204-209); a valid worker also serves as the fallback (proxyService.ts:126, :134-136, :141-143).
/// - Network failure on the first leg, or 403/429/5xx, falls back once to the worker with scrubbed headers (proxyService.ts:129-151).
/// Composition note: in RN, retry (booruApi.ts:218-245) wraps this fallback (proxyService.ts:122). Here a retrying
/// `direct` transport retries inside each leg, so the attempt order can differ from RN. See the report.
struct ProxyAwareHTTPClient: HTTPClientProtocol, Sendable {
    let direct: HTTPClientProtocol
    let proxy: ProxyConfig

    init(direct: HTTPClientProtocol, proxy: ProxyConfig) {
        self.direct = direct
        self.proxy = proxy
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw BooruError.network("Invalid request URL")
        }
        let worker = ProxyRelay.normalizedWorkerURL(proxy.workerURL)
        // proxyService.ts:80-81: a URL that already points at the worker is not wrapped again.
        let isAlreadyRelay = worker.map { url.absoluteString.hasPrefix($0) } ?? false
        // proxyService.ts:78-83 forceProxyUrl; nil when there is no valid worker or no relay is needed.
        let fallbackURL: URL? = isAlreadyRelay ? nil : worker.flatMap { ProxyRelay.relayURL(for: url, workerURL: $0) }
        // proxyService.ts:127: scrubbing is skipped for RedGifs.
        let sanitize = !ProxyRelay.isRedGifs(url)
        // proxyService.ts:65-67 isEnabled(): toggle on and a worker is configured.
        let relayEnabled = proxy.enabled && worker != nil
        // proxyService.ts:204-209 proxyUrl: TLS-fragile hosts are relayed even when the toggle is off.
        let relayPreferred = relayEnabled || ProxyRelay.isTLSFragile(url)
        let primaryIsRelay = relayPreferred && fallbackURL != nil
        // proxyService.ts:126 with proxyUrl (:197-211): relay when preferred, otherwise direct.
        let primaryURL: URL = (primaryIsRelay ? fallbackURL : nil) ?? url

        let first: (Data, HTTPURLResponse)
        do {
            if primaryIsRelay {
                first = try await send(request, original: url, to: primaryURL, sanitize: sanitize)
            } else {
                first = try await direct.data(for: ProxyAwareHTTPClient.retarget(request, to: primaryURL))
            }
        } catch {
            // proxyService.ts:131-136: caller cancellation is final; otherwise fall back when an alternate route exists.
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            if primaryIsRelay {
                return try await direct.data(for: request)
            }
            guard let relay = fallbackURL, relay != primaryURL else {
                throw error
            }
            return try await send(request, original: url, to: relay, sanitize: sanitize)
        }

        // proxyService.ts:140: only 403, 429 and 5xx trigger the fallback.
        let status = first.1.statusCode
        guard status == 403 || status == 429 || status >= 500 else {
            return first
        }
        if primaryIsRelay {
            do {
                return try await direct.data(for: request)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                return first
            }
        }
        // proxyService.ts:141-144: retry through the worker when it is a different URL.
        if let relay = fallbackURL, relay != primaryURL {
            return try await send(request, original: url, to: relay, sanitize: sanitize)
        }
        return first
    }

    /// Fallback leg (proxyService.ts:153-159 fetchViaProxy). Scrubbing applies the workerHeaders policy and disables cookies.
    private func send(_ request: URLRequest, original: URL, to target: URL, sanitize: Bool) async throws -> (Data, HTTPURLResponse) {
        guard sanitize else {
            return try await direct.data(for: ProxyAwareHTTPClient.retarget(request, to: target))
        }
        // Assigning `allHTTPHeaderFields` merges with the headers already on the request on Darwin, so the
        // origin `Referer`/`Cookie` survived into the relayed leg. Build a fresh request instead: only the
        // sanitized worker headers are ever set, so nothing from the original request leaks through.
        var routed = URLRequest(url: target)
        routed.httpMethod = request.httpMethod
        if let body = request.httpBody {
            routed.httpBody = body
        } else if let stream = request.httpBodyStream {
            routed.httpBodyStream = stream
        }
        routed.timeoutInterval = request.timeoutInterval
        routed.cachePolicy = request.cachePolicy
        // Keeps URLSession from adding a stored Cookie, so the leg really carries no Cookie header.
        routed.httpShouldHandleCookies = false
        for (name, value) in ProxyRelay.workerHeaders(for: original, headers: request.allHTTPHeaderFields ?? [:]) {
            routed.setValue(value, forHTTPHeaderField: name)
        }
        // Defensive: make sure no implicit merge reintroduces a sensitive header.
        routed.setValue(nil, forHTTPHeaderField: "Referer")
        routed.setValue(nil, forHTTPHeaderField: "Cookie")
        return try await direct.data(for: routed)
    }

    private static func retarget(_ request: URLRequest, to url: URL) -> URLRequest {
        var copy = request
        copy.url = url
        return copy
    }
}
