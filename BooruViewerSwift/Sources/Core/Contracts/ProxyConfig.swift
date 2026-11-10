import Foundation

/// Cloudflare worker proxy settings. JSON key for `workerURL` matches RN `workerUrl` (storage.ts getProxyConfig).
struct ProxyConfig: Codable, Sendable {
    var enabled: Bool = false
    var workerURL: String = ""

    enum CodingKeys: String, CodingKey {
        case enabled
        case workerURL = "workerUrl"
    }
}

extension ProxyConfig {
    /// Missing or malformed keys fall back to the defaults, matching RN getProxyConfig.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        workerURL = (try? c.decode(String.self, forKey: .workerURL)) ?? ""
    }
}
