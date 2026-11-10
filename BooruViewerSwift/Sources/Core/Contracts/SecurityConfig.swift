import Foundation

/// App-lock settings. Mirrors RN `SecurityConfig` (src/services/securityService.ts:7-12) and its defaults (lines 14-19).
/// The PIN itself is never stored here. `passcodeHash` is a parity placeholder only; the real hash lives in the Keychain.
struct SecurityConfig: Codable, Sendable {
    var enabled: Bool = false
    var passcodeHash: String? = nil
    var useBiometrics: Bool = true
    var autoLockImmediately: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case passcodeHash
        case useBiometrics
        case autoLockImmediately
    }
}

extension SecurityConfig {
    /// Missing or malformed keys fall back to the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        passcodeHash = try? c.decode(String.self, forKey: .passcodeHash)
        useBiometrics = (try? c.decode(Bool.self, forKey: .useBiometrics)) ?? true
        autoLockImmediately = (try? c.decode(Bool.self, forKey: .autoLockImmediately)) ?? true
    }
}
