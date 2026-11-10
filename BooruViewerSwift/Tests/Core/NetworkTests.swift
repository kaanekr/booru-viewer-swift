import XCTest
@testable import BooruViewer

/// Synthetic tests only: no real HTTP. Worker and source URLs use example.com.
final class NetworkTests: XCTestCase {
    private let workerURL = "https://worker.example.com/"
    private let itemURL = URL(string: "https://example.com/item?id=1")!
    private let relayItemURLString = "https://worker.example.com?url=https%3A%2F%2Fexample.com%2Fitem%3Fid%3D1"

    // MARK: - Relay URL building (proxyService.ts:82, :202)

    func testRelayURLPercentEncodesOriginalLikeEncodeURIComponent() {
        let original = URL(string: "https://example.com/a%20b?x=1&y=2")!
        let relay = ProxyRelay.relayURL(for: original, workerURL: "https://worker.example.com")
        XCTAssertEqual(relay?.absoluteString,
                       "https://worker.example.com?url=https%3A%2F%2Fexample.com%2Fa%2520b%3Fx%3D1%26y%3D2")
    }

    func testRelayURLTrimsWorkerWhitespaceAndOneTrailingSlash() {
        let relay = ProxyRelay.relayURL(for: itemURL, workerURL: "  https://worker.example.com/  ")
        XCTAssertEqual(relay?.absoluteString, relayItemURLString)
    }

    func testRelayURLRejectsInvalidWorkerURL() {
        XCTAssertNil(ProxyRelay.relayURL(for: itemURL, workerURL: ""))
        XCTAssertNil(ProxyRelay.relayURL(for: itemURL, workerURL: "ftp://worker.example.com"))
        XCTAssertNil(ProxyRelay.relayURL(for: itemURL, workerURL: "not a url"))
    }

    // MARK: - TLS-fragile hosts (proxyService.ts:21-40)

    func testIsTLSFragileMatchesRNPatternsCaseInsensitively() {
        let fragile = [
            "https://api-cdn-mp4.rule34.xxx/x.mp4",
            "https://API-CDN.rule34.us/x.mp4",
            "https://thumb-cdn12.xvideos-cdn.com/x.jpg",
            "https://thumbs-gcore.xvideos-cdn.com/x.jpg",
            "https://mp4-cdn3.xvideos-cdn.com/x.mp4",
            "https://videos7.sex.com/x.mp4",
            "https://premium-videos2.sex.com/x.mp4",
            "https://nhentai.net/g/1/",
        ]
        for string in fragile {
            XCTAssertTrue(ProxyRelay.isTLSFragile(URL(string: string)!), string)
        }
        let safe = [
            "https://example.com/x.mp4",
            "https://rule34.xxx/x.mp4",
            "https://xvideos-cdn.com/x.jpg",
            "https://sex.com/x.mp4",
            "https://nhentai.example/x",
        ]
        for string in safe {
            XCTAssertFalse(ProxyRelay.isTLSFragile(URL(string: string)!), string)
        }
    }

    func testIsTLSFragilePercentDecodesBeforeMatching() {
        // proxyService.ts:35 decodes first, so a fragile host inside an encoded relay URL still matches.
        let encoded = URL(string: "https://worker.example.com?url=https%3A%2F%2Fnhentai.net%2Fg%2F1%2F")!
        XCTAssertTrue(ProxyRelay.isTLSFragile(encoded))
    }

    // MARK: - Header scrubbing (proxyService.ts:91-104)

    func testSanitizedHeadersRemovesRefererAndCookieCaseInsensitively() {
        let headers = [
            "Referer": "https://example.com/",
            "cookie": "a=1",
            "COOKIE": "b=2",
            "Accept": "image/*",
            "User-Agent": "Test",
        ]
        XCTAssertEqual(ProxyRelay.sanitizedHeaders(headers), ["Accept": "image/*", "User-Agent": "Test"])
    }

    func testWorkerHeadersUseNeutralUserAgentAndSkipRedGifs() {
        let headers = ["Referer": "https://example.com/", "User-Agent": "Desktop", "Accept": "image/*"]
        let out = ProxyRelay.workerHeaders(for: itemURL, headers: headers)
        XCTAssertNil(out["Referer"])
        XCTAssertEqual(out["User-Agent"], ProxyRelay.neutralUserAgent)
        XCTAssertEqual(out["Accept"], "image/*")
        XCTAssertNil(out["Accept-Encoding"])

        let redGifsURL = URL(string: "https://example.com/?site=redgifs.com")!
        XCTAssertEqual(ProxyRelay.workerHeaders(for: redGifsURL, headers: headers), headers)
    }

    func testWorkerHeadersSetIdentityEncodingForXVideosAndNhentai() {
        let url = URL(string: "https://example.com/?site=xvideos.com")!
        let out = ProxyRelay.workerHeaders(for: url, headers: ["Accept-Encoding": "br"])
        XCTAssertEqual(out["Accept-Encoding"], "gzip, deflate, identity")
    }

    // MARK: - Retry policy (booruApi.ts:218, :240-242)

    func testRetryPolicyRetriesOnlyOnRNStatusSet() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.maxRetries, 1)
        for status in [403, 429, 500, 503, 599] {
            XCTAssertTrue(policy.shouldRetry(statusCode: status), "status \(status)")
        }
        for status in [200, 301, 400, 401, 404] {
            XCTAssertFalse(policy.shouldRetry(statusCode: status), "status \(status)")
        }
    }

    func testRetryAfterParsesSecondsAndCapsAtFiveSeconds() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(forRetryAfter: "3"), 3)
        XCTAssertEqual(policy.delay(forRetryAfter: " 1.5 "), 1.5)
        XCTAssertEqual(policy.delay(forRetryAfter: "9"), 5)
        XCTAssertEqual(policy.delay(forRetryAfter: "-4"), 0)
    }

    func testRetryAfterFallsBackToTwoSecondsWhenMissingOrInvalid() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(forRetryAfter: nil), 2)
        XCTAssertEqual(policy.delay(forRetryAfter: ""), 2)
        XCTAssertEqual(policy.delay(forRetryAfter: "0"), 2)
        XCTAssertEqual(policy.delay(forRetryAfter: "soon"), 2)
        // RN parses delta-seconds only, so an HTTP-date falls back to 2 s (booruApi.ts:241).
        XCTAssertEqual(policy.delay(forRetryAfter: "Wed, 21 Oct 2015 07:28:00 GMT"), 2)
    }

    // MARK: - Status mapping

    func testHTTPStatusMappingMapsRateLimitAndErrors() {
        XCTAssertNil(HTTPStatusMapping.error(forStatus: 200))
        if case .rateLimited? = HTTPStatusMapping.error(forStatus: 429) {} else {
            XCTFail("429 should map to rateLimited")
        }
        if case .http(let status)? = HTTPStatusMapping.error(forStatus: 404) {
            XCTAssertEqual(status, 404)
        } else {
            XCTFail("404 should map to http(status:)")
        }
    }

    // MARK: - Rate limiter (booruApi.ts:197-204)

    func testRateLimiterSpacesSameHostBy800Milliseconds() async {
        let limiter = RateLimiter(interval: 0.8)
        let first = await limiter.reserve(key: "example.com", at: 10.0)
        let second = await limiter.reserve(key: "example.com", at: 10.1)
        let third = await limiter.reserve(key: "example.com", at: 10.2)
        XCTAssertEqual(first, 0, accuracy: 1e-9)
        XCTAssertEqual(second, 0.7, accuracy: 1e-9)
        XCTAssertEqual(third, 1.4, accuracy: 1e-9)
    }

    func testRateLimiterDoesNotDelayOtherHostsOrAfterTheWindow() async {
        let limiter = RateLimiter(interval: 0.8)
        _ = await limiter.reserve(key: "example.com", at: 10.0)
        let otherHost = await limiter.reserve(key: "other.example", at: 10.1)
        let caseVariant = await limiter.reserve(key: "EXAMPLE.com", at: 10.1)
        // example.com slots now start at 10.8 and 11.6; a request arriving after 11.6 is free.
        let afterWindow = await limiter.reserve(key: "example.com", at: 12.0)
        XCTAssertEqual(otherHost, 0, accuracy: 1e-9)
        XCTAssertEqual(caseVariant, 0.7, accuracy: 1e-9)
        XCTAssertEqual(afterWindow, 0, accuracy: 1e-9)
    }

    func testRateLimiterAcquireSuspendsBetweenRequestsToSameHost() async throws {
        let limiter = RateLimiter(interval: 0.05)
        let start = ProcessInfo.processInfo.systemUptime
        try await limiter.acquire(key: "example.com")
        try await limiter.acquire(key: "example.com")
        try await limiter.acquire(key: "example.com")
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // Two 50 ms gaps; the lower bound leaves slack for timer granularity.
        XCTAssertGreaterThanOrEqual(elapsed, 0.09)
    }

    // MARK: - Rate limiter key extraction (booruApi.ts:198, proxyService.ts:202)

    func testRateLimiterKeyUsesOriginAndRelayTarget() {
        let relayed = URL(string: "https://worker.example.com?url=https%3A%2F%2Fapi-cdn-mp4.rule34.xxx%2Fa.mp4")!
        XCTAssertEqual(RateLimiter.key(for: relayed), "https://api-cdn-mp4.rule34.xxx")
        XCTAssertEqual(RateLimiter.key(for: URL(string: "https://API.Example.com:8443/x")!), "https://api.example.com:8443")
        XCTAssertEqual(RateLimiter.key(for: URL(string: "https://example.com:443/x")!), "https://example.com")
        XCTAssertEqual(RateLimiter.key(for: URL(string: "http://example.com:80/x")!), "http://example.com")
        // A `url` value that is not a URL with a host keeps the request's own origin.
        XCTAssertEqual(RateLimiter.key(for: URL(string: "https://worker.example.com/?url=not-a-url")!),
                       "https://worker.example.com")
        XCTAssertNil(RateLimiter.key(for: URL(string: "file:///tmp/x")!))
    }

    func testRateLimiterDoesNotSerializeDistinctRelayTargets() async {
        let limiter = RateLimiter(interval: 0.8)
        let first = URL(string: "https://worker.example.com?url=https%3A%2F%2Fa.example%2F1")!
        let second = URL(string: "https://worker.example.com?url=https%3A%2F%2Fb.example%2F2")!
        let sameTarget = URL(string: "https://worker.example.com?url=https%3A%2F%2Fa.example%2F3")!
        _ = await limiter.reserve(key: RateLimiter.key(for: first)!, at: 10.0)
        let other = await limiter.reserve(key: RateLimiter.key(for: second)!, at: 10.1)
        let same = await limiter.reserve(key: RateLimiter.key(for: sameTarget)!, at: 10.1)
        XCTAssertEqual(other, 0, accuracy: 1e-9)
        XCTAssertEqual(same, 0.7, accuracy: 1e-9)
    }

    // MARK: - Proxy-aware routing (proxyService.ts:122-159)

    func testProxyAwareRoutesThroughRelayWhenEnabled() async throws {
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 200))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: true, workerURL: workerURL))

        let (_, response) = try await client.data(for: URLRequest(url: itemURL))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, [relayItemURLString])
    }

    func testProxyAwareRelaysTLSFragileURLWhenToggleOffAndWorkerConfigured() async throws {
        // proxyService.ts:204-209: toggle off still relays TLS-fragile CDN hosts when a worker exists.
        let fragileURL = URL(string: "https://api-cdn-mp4.rule34.xxx/a.mp4")!
        let expectedRelay = ProxyRelay.relayURL(for: fragileURL, workerURL: workerURL)?.absoluteString
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 200))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: workerURL))

        let (_, response) = try await client.data(for: URLRequest(url: fragileURL))

        XCTAssertEqual(response.statusCode, 200)
        // One relayed leg only; no direct attempt precedes it.
        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, [expectedRelay])
        XCTAssertEqual(stub.requests.first?.url?.host, "worker.example.com")
    }

    func testProxyAwareKeepsNonFragileURLDirectWhenToggleOff() async throws {
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 200))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: workerURL))

        _ = try await client.data(for: URLRequest(url: itemURL))

        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, [itemURL.absoluteString])
    }

    func testProxyAwareFallsBackOnNetworkErrorWithScrubbedHeaders() async throws {
        let stub = ScriptedHTTPClient { request in
            if request.url?.host == "example.com" {
                throw BooruError.network("timed out")
            }
            return (Data(), makeResponse(request.url!, status: 200))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: workerURL))
        var original = URLRequest(url: itemURL)
        original.setValue("https://example.com/", forHTTPHeaderField: "Referer")
        original.setValue("a=1", forHTTPHeaderField: "Cookie")
        original.setValue("image/*", forHTTPHeaderField: "Accept")

        let (_, response) = try await client.data(for: original)

        XCTAssertEqual(response.statusCode, 200)
        let requests = stub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "example.com")
        XCTAssertEqual(requests[1].url?.absoluteString, relayItemURLString)
        let relayHeaders = requests[1].allHTTPHeaderFields ?? [:]
        XCTAssertNil(relayHeaders["Referer"])
        XCTAssertNil(relayHeaders["Cookie"])
        XCTAssertEqual(relayHeaders["Accept"], "image/*")
        XCTAssertEqual(relayHeaders["User-Agent"], ProxyRelay.neutralUserAgent)
        XCTAssertEqual(requests[1].httpShouldHandleCookies, false)
    }

    func testProxyAwareForwardsAllowedHeadersAndDirectLegKeepsOriginHeaders() async throws {
        // The relayed leg must carry exactly the sanitized set; the direct leg must keep every origin header.
        let stub = ScriptedHTTPClient { request in
            if request.url?.host == "example.com" {
                throw BooruError.network("timed out")
            }
            return (Data(), makeResponse(request.url!, status: 200))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: workerURL))
        var original = URLRequest(url: itemURL)
        original.setValue("https://example.com/", forHTTPHeaderField: "Referer")
        original.setValue("a=1", forHTTPHeaderField: "Cookie")
        original.setValue("image/*", forHTTPHeaderField: "Accept")
        original.setValue("token-123", forHTTPHeaderField: "X-Test-Key")

        _ = try await client.data(for: original)

        let requests = stub.requests
        XCTAssertEqual(requests.count, 2)
        let directHeaders = requests[0].allHTTPHeaderFields ?? [:]
        XCTAssertEqual(directHeaders["Referer"], "https://example.com/")
        XCTAssertEqual(directHeaders["Cookie"], "a=1")
        XCTAssertEqual(directHeaders["Accept"], "image/*")
        XCTAssertEqual(directHeaders["X-Test-Key"], "token-123")
        let relayHeaders = requests[1].allHTTPHeaderFields ?? [:]
        XCTAssertEqual(relayHeaders["Accept"], "image/*")
        XCTAssertEqual(relayHeaders["X-Test-Key"], "token-123")
        XCTAssertNil(relayHeaders["Referer"])
        XCTAssertNil(relayHeaders["Cookie"])
    }

    func testProxyAwareFallsBackOnForbiddenThroughRelay() async throws {
        let stub = ScriptedHTTPClient { request in
            let status = request.url?.host == "example.com" ? 403 : 200
            return (Data(), makeResponse(request.url!, status: status))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: workerURL))

        let (_, response) = try await client.data(for: URLRequest(url: itemURL))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, [itemURL.absoluteString, relayItemURLString])
    }

    func testProxyAwareRetriesRelayOnceScrubbedWhenEnabledAndForbidden() async throws {
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 403))
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: true, workerURL: workerURL))
        var original = URLRequest(url: itemURL)
        original.setValue("https://example.com/", forHTTPHeaderField: "Referer")

        let (_, response) = try await client.data(for: original)

        XCTAssertEqual(response.statusCode, 403)
        let requests = stub.requests
        XCTAssertEqual(requests.count, 2)
        // The first relay leg is unscrubbed (proxyService.ts:126); the retry is scrubbed (proxyService.ts:145-148).
        XCTAssertEqual(requests[0].allHTTPHeaderFields?["Referer"], "https://example.com/")
        XCTAssertNil(requests[1].allHTTPHeaderFields?["Referer"])
        XCTAssertEqual(requests[1].url?.absoluteString, relayItemURLString)
    }

    func testProxyAwareRethrowsWhenNoWorkerConfigured() async {
        let stub = ScriptedHTTPClient { _ in
            throw BooruError.network("offline")
        }
        let client = ProxyAwareHTTPClient(direct: stub, proxy: ProxyConfig(enabled: false, workerURL: ""))
        do {
            _ = try await client.data(for: URLRequest(url: itemURL))
            XCTFail("Expected the network error to propagate")
        } catch {
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    // MARK: - Connection diagnostics (networkDiagnostics.ts:14-57)

    func testNetworkDiagnosticsReportsRelayUnconfiguredWithoutRequests() async {
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 200))
        }
        let results = await NetworkDiagnostics.run(proxy: ProxyConfig(enabled: false, workerURL: ""), http: stub)

        XCTAssertEqual(results.count, 16)
        XCTAssertEqual(results[0].target, "Pornhub API (direct)")
        XCTAssertEqual(results[1].target, "Pornhub API (relay)")
        XCTAssertTrue(results.filter { $0.target.hasSuffix("(direct)") }.allSatisfy { $0.reachable && $0.latencyMs != nil })
        XCTAssertTrue(results.filter { $0.target.hasSuffix("(relay)") }.allSatisfy { !$0.reachable && $0.latencyMs == nil })
        XCTAssertEqual(stub.requests.count, 8)
    }

    func testNetworkDiagnosticsProbesRelayWhenWorkerConfigured() async {
        let stub = ScriptedHTTPClient { request in
            (Data(), makeResponse(request.url!, status: 200))
        }
        let results = await NetworkDiagnostics.run(proxy: ProxyConfig(enabled: false, workerURL: workerURL), http: stub)

        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0.reachable })
        XCTAssertEqual(stub.requests.count, 16)
    }
}

/// Test double that records requests and answers with a scripted handler. No network access.
private final class ScriptedHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return try handler(request)
    }
}

private func makeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}
