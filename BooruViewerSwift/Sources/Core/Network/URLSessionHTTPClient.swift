import Foundation

/// Foundation transport for source requests, following the booruApi.ts:197-245 policy.
/// - 12 s request and resource timeouts (booruApi.ts:218).
/// - Per-origin spacing via `RateLimiter` before every attempt (booruApi.ts:197-204).
/// - Retry per `RetryPolicy` on 403/429/5xx, honoring Retry-After (booruApi.ts:240-245).
/// `data(for:)` returns the final response for any HTTP status; map it with `HTTPStatusMapping` when needed.
/// Transport failures are thrown as `BooruError.network`; cancellation is rethrown as `CancellationError`.
final class URLSessionHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    /// booruApi.ts:218 `timeoutMs = 12000`.
    static let requestTimeout: TimeInterval = 12

    private let session: URLSession
    private let rateLimiter: RateLimiter
    private let retryPolicy: RetryPolicy

    init(session: URLSession? = nil, rateLimiter: RateLimiter = .shared, retryPolicy: RetryPolicy = RetryPolicy()) {
        self.session = session ?? URLSessionHTTPClient.makeSession()
        self.rateLimiter = rateLimiter
        self.retryPolicy = retryPolicy
    }

    /// Client for connection diagnostics: no spacing and no retry, so each probe is one attempt (networkDiagnostics.ts has neither).
    static func makeProbeClient() -> URLSessionHTTPClient {
        URLSessionHTTPClient(rateLimiter: RateLimiter(interval: 0), retryPolicy: RetryPolicy(maxRetries: 0))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let key = RateLimiter.key(for: url) else {
            throw BooruError.network("Invalid request URL")
        }
        var retriesUsed = 0
        while true {
            let (data, response) = try await send(request, key: key)
            guard retriesUsed < retryPolicy.maxRetries,
                  retryPolicy.shouldRetry(statusCode: response.statusCode) else {
                return (data, response)
            }
            retriesUsed += 1
            let delay = retryPolicy.delay(forRetryAfter: URLSessionHTTPClient.retryAfterValue(in: response))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// One attempt: reserve the origin slot, then send with the request timeout applied.
    private func send(_ request: URLRequest, key: String) async throws -> (Data, HTTPURLResponse) {
        try await rateLimiter.acquire(key: key)
        var timed = request
        timed.timeoutInterval = URLSessionHTTPClient.requestTimeout
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: timed)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw BooruError.network(URLSessionHTTPClient.describe(error.code))
        } catch {
            throw BooruError.network("Request failed")
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw BooruError.network("Non-HTTP response")
        }
        return (result.0, http)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }

    /// Case-insensitive lookup; URLResponse headers are not guaranteed to match the request's casing.
    private static func retryAfterValue(in response: HTTPURLResponse) -> String? {
        let match = response.allHeaderFields.first(where: { entry in
            (entry.key as? String)?.caseInsensitiveCompare("Retry-After") == .orderedSame
        })
        return match?.value as? String
    }

    /// Short English descriptions without URLs, so error text never leaks a worker or source address.
    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut:
            return "timed out"
        case .notConnectedToInternet, .networkConnectionLost:
            return "no connection"
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "host unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "TLS connection failed"
        default:
            return "request failed"
        }
    }
}

/// Maps a final HTTP status to a BooruError for callers that need one. 2xx and 3xx return nil.
enum HTTPStatusMapping {
    static func error(forStatus statusCode: Int) -> BooruError? {
        switch statusCode {
        case 429:
            return .rateLimited
        case 400...599:
            return .http(status: statusCode)
        default:
            return nil
        }
    }
}
