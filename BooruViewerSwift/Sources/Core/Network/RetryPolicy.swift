import Foundation

/// Retry rule mirroring booruApi.ts:218-245: one retry on 403, 429 or 5xx after waiting for Retry-After.
struct RetryPolicy: Sendable, Equatable {
    /// booruApi.ts:218 `retries = 1`.
    let maxRetries: Int
    /// booruApi.ts:241 `Number(retry-after) || 2`: used when the header is missing, empty, non-numeric (HTTP dates included), or 0.
    let fallbackDelay: TimeInterval
    /// booruApi.ts:242 `Math.min(retryAfter, 5)`. Cap is 5 s to match RN (the brief's 10 s example was not used for parity).
    let maxDelay: TimeInterval

    init(maxRetries: Int = 1, fallbackDelay: TimeInterval = 2, maxDelay: TimeInterval = 5) {
        self.maxRetries = max(0, maxRetries)
        self.fallbackDelay = fallbackDelay
        self.maxDelay = maxDelay
    }

    /// booruApi.ts:240 `res.status === 403 || res.status === 429 || res.status >= 500`.
    func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 403 || statusCode == 429 || statusCode >= 500
    }

    /// Seconds to wait before the retry. Parses delta-seconds like JavaScript `Number()`; negative values clamp to 0.
    func delay(forRetryAfter rawValue: String?) -> TimeInterval {
        guard let rawValue,
              let seconds = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              !seconds.isNaN,
              seconds != 0 else {
            return min(fallbackDelay, maxDelay)
        }
        return min(max(seconds, 0), maxDelay)
    }
}
