import Foundation

/// Errors surfaced by sources and the transport layer. Messages are short English strings.
enum BooruError: Error, LocalizedError, Sendable {
    case network(String)
    case http(status: Int)
    case decoding(String)
    case unsupported(String)
    case authRequired(SourceID)
    case proxyUnavailable
    case rateLimited
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .network(let message):
            return "Network error: \(message)"
        case .http(let status):
            return "The server returned HTTP \(status)."
        case .decoding(let message):
            return "Could not read the response: \(message)"
        case .unsupported(let message):
            return "Not supported: \(message)"
        case .authRequired(let source):
            return "\(source.rawValue) requires an API key."
        case .proxyUnavailable:
            return "The proxy worker is unavailable."
        case .rateLimited:
            return "Too many requests. Try again later."
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        }
    }
}
