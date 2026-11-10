import Foundation

/// Per-origin request spacing mirroring booruApi.ts:197-204 (at least 800 ms between request starts to the same origin).
/// Each caller reserves its start slot inside the actor, so concurrent callers queue without busy-waiting.
actor RateLimiter {
    /// Shared across clients so spacing holds even when several clients exist (RN keeps one map per service).
    static let shared = RateLimiter()

    /// booruApi.ts:201 `800 - (Date.now() - previous)`.
    static let defaultInterval: TimeInterval = 0.8

    private let interval: TimeInterval
    /// Earliest `ProcessInfo.systemUptime` value at which the next request to a key may start. Keys come from `key(for:)`.
    private var nextStart: [String: TimeInterval] = [:]

    init(interval: TimeInterval = RateLimiter.defaultInterval) {
        self.interval = max(0, interval)
    }

    /// Spacing key, following booruApi.ts:198 `new URL(url).origin` (`scheme://host[:port]`).
    /// Worker relays (`<worker>?url=<encoded>`, proxyService.ts:202) key on the relayed target instead, so distinct
    /// sources are not serialized behind the single worker host.
    static func key(for url: URL) -> String? {
        let target = relayTarget(of: url) ?? url
        guard let scheme = target.scheme?.lowercased(), !scheme.isEmpty,
              let host = target.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let defaultPort: Int? = scheme == "http" ? 80 : (scheme == "https" ? 443 : nil)
        if let port = target.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Original target of a worker relay URL, or nil when the URL has no `url` query parameter naming a URL with a host.
    static func relayTarget(of url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value),
              let host = target.host, !host.isEmpty else {
            return nil
        }
        return target
    }

    /// Reserves the next start slot for `key` at time `now` and returns how long the caller must wait (0 when free).
    /// Pure bookkeeping with no sleeping, so it is directly testable with synthetic times.
    func reserve(key: String, at now: TimeInterval) -> TimeInterval {
        let slot = key.lowercased()
        let start = max(now, nextStart[slot] ?? now)
        nextStart[slot] = start + interval
        return start - now
    }

    /// Suspends until this caller's reserved slot. Cancellation propagates as `CancellationError`.
    func acquire(key: String) async throws {
        let wait = reserve(key: key, at: ProcessInfo.processInfo.systemUptime)
        guard wait > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}
