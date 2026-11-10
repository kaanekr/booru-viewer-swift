import Foundation

/// Cloudflare relay helpers mirroring src/services/proxyService.ts. All members are pure.
enum ProxyRelay {
    /// proxyService.ts:98-99 neutral iPhone UA used on worker legs.
    static let neutralUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// Unreserved set of JavaScript encodeURIComponent: A-Z a-z 0-9 - _ . ! ~ * ' ( )
    private static let componentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// proxyService.ts:52 and :62: trim whitespace and drop one trailing "/". Valid only for http(s) URLs with a host.
    static func normalizedWorkerURL(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") {
            value.removeLast()
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        return value
    }

    /// proxyService.ts:82 and :202: `<workerUrl>?url=<encodeURIComponent(original)>`. Nil when the worker is invalid.
    static func relayURL(for original: URL, workerURL: String) -> URL? {
        guard let worker = normalizedWorkerURL(workerURL),
              let encoded = original.absoluteString.addingPercentEncoding(withAllowedCharacters: componentAllowed) else {
            return nil
        }
        return URL(string: "\(worker)?url=\(encoded)")
    }

    /// proxyService.ts:94-97: drop Referer and Cookie, matched case-insensitively.
    static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { entry in
            let name = entry.key.lowercased()
            return name != "referer" && name != "cookie"
        }
    }

    /// proxyService.ts:21-29 `TLS_FRAGILE_PATTERNS`: CDN hosts that drop the TLS handshake in iOS AVPlayer.
    private static let tlsFragilePatterns = [
        "api-cdn[^/]*\\.rule34\\.(xxx|us)",
        "thumb-cdn\\d*\\.xvideos-cdn\\.com",
        "thumbs-gcore\\.xvideos-cdn\\.com",
        "mp4-cdn\\d*\\.xvideos-cdn\\.com",
        "videos\\d*\\.sex\\.com",
        "premium-videos\\d*\\.sex\\.com",
        "nhentai\\.net",
    ]

    /// proxyService.ts:31-40 `isTlsFragileUrl`: percent-decode first, then case-insensitive regex over the whole string.
    static func isTLSFragile(_ url: URL) -> Bool {
        let raw = url.absoluteString
        let decoded = raw.removingPercentEncoding ?? raw
        return tlsFragilePatterns.contains { pattern in
            decoded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// proxyService.ts:93: RedGifs skips header rewriting because its token needs the original UA, Origin and Referer.
    static func isRedGifs(_ url: URL) -> Bool {
        contains(url, "redgifs.com")
    }

    /// proxyService.ts:91-104 `workerHeaders`. Applied to fallback legs only (proxyService.ts:153-158).
    static func workerHeaders(for original: URL, headers: [String: String]) -> [String: String] {
        guard !isRedGifs(original) else { return headers }
        var out = sanitizedHeaders(headers).filter { $0.key.lowercased() != "user-agent" }
        out["User-Agent"] = neutralUserAgent
        // proxyService.ts:100-102: xvideos truncates compressed bodies on the worker path; nhentai Brotli stalls RN.
        if contains(original, "xvideos.com") || contains(original, "nhentai.net") {
            out = out.filter { $0.key.lowercased() != "accept-encoding" }
            out["Accept-Encoding"] = "gzip, deflate, identity"
        }
        return out
    }

    /// Case-insensitive substring test on the absolute string, like the RN `/host/i` regex tests.
    private static func contains(_ url: URL, _ needle: String) -> Bool {
        url.absoluteString.range(of: needle, options: .caseInsensitive) != nil
    }
}
