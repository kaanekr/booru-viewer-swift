import Foundation
import CryptoKit
import LocalAuthentication

/// Storage for the app-lock hash. Production uses `KeychainPasscodeStore`; tests inject an
/// in-memory double so the real Keychain is never touched.
protocol PasscodeHashStoring: Sendable {
    /// Returns `nil` when no hash has been stored yet.
    func load() throws -> String?
    func save(_ hash: String) throws
    func delete() throws
}

/// Keychain-backed passcode hash (generic password, account `passcode_hash`).
/// The PIN itself is never stored anywhere.
struct KeychainPasscodeStore: PasscodeHashStoring {
    func load() throws -> String? {
        try KeychainStore.load(SecurityService.passcodeHashAccount)
    }

    func save(_ hash: String) throws {
        try KeychainStore.save(hash, for: SecurityService.passcodeHashAccount)
    }

    func delete() throws {
        try KeychainStore.delete(SecurityService.passcodeHashAccount)
    }
}

/// Biometric prompt wrapper. Split from `SecurityService` so tests never touch real hardware.
protocol BiometricAuthenticating: Sendable {
    /// Hardware present and at least one biometric enrolled.
    func canEvaluateBiometrics() -> Bool
    /// Presents the system prompt; `false` for cancel, lockout, or any failure.
    func authenticate(prompt: String) async -> Bool
}

/// `LocalAuthentication` implementation mirroring RN `authenticateWithBiometrics`
/// (securityService.ts:163-184).
///
/// The policy is `.deviceOwnerAuthenticationWithBiometrics` (never `...OrPasscode`) because RN
/// passes `disableDeviceFallback: true`: the app's own 4-digit PIN pad is the only fallback.
struct LocalAuthenticationBiometricAuthenticator: BiometricAuthenticating {
    func canEvaluateBiometrics() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func authenticate(prompt: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: prompt
            )
        } catch {
            return false
        }
    }
}

enum SecurityError: Error, Equatable {
    /// Not exactly four ASCII digits.
    case invalidPIN
}

/// App-lock PIN hashing, verification, and biometric prompts.
/// Mirrors RN `SecurityService` (src/services/securityService.ts).
///
/// The hash is SHA-256 hex of `booru_salt_<pin>` — the exact input RN feeds to
/// `Crypto.digestStringAsync` (securityService.ts:27-33), so an RN-era hash keeps verifying.
/// Only the hash is persisted: the Keychain account `passcode_hash` is authoritative, and
/// `SecurityConfig.passcodeHash` is read as a fallback for configs migrated from RN.
struct SecurityService: Sendable {
    /// Keychain account for the stored hash.
    static let passcodeHashAccount = "passcode_hash"
    /// Salt prefix from `securityService.ts:30`.
    static let saltPrefix = "booru_salt_"
    /// The PIN pad only accepts four digits.
    static let pinLength = 4

    private let store: any PasscodeHashStoring
    private let biometrics: any BiometricAuthenticating

    init(
        store: any PasscodeHashStoring = KeychainPasscodeStore(),
        biometrics: any BiometricAuthenticating = LocalAuthenticationBiometricAuthenticator()
    ) {
        self.store = store
        self.biometrics = biometrics
    }

    // MARK: - Hashing

    /// Lowercase SHA-256 hex of `booru_salt_\(pin)`, byte-for-byte equal to
    /// `expo-crypto`'s `digestStringAsync(SHA256, ...)` (securityService.ts:28-32).
    static func hashPasscode(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data((saltPrefix + pin).utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Exactly four ASCII digits. Anything else is rejected before hashing.
    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Configuration

    /// The Keychain hash, falling back to `SecurityConfig.passcodeHash` when the Keychain has
    /// nothing (migrated RN config). Empty strings count as absent.
    func storedPasscodeHash(config: SecurityConfig) throws -> String? {
        if let hash = try store.load(), !hash.isEmpty {
            return hash
        }
        if let hash = config.passcodeHash, !hash.isEmpty {
            return hash
        }
        return nil
    }

    /// RN `isPasscodeEnabled` (securityService.ts:65-68): enabled *and* a hash exists.
    func isPasscodeEnabled(config: SecurityConfig) throws -> Bool {
        guard config.enabled else { return false }
        return try storedPasscodeHash(config: config) != nil
    }

    // MARK: - Passcode lifecycle

    /// Hashes and persists a new PIN. Returns the hash for callers that also keep the
    /// `SecurityConfig.passcodeHash` parity placeholder.
    ///
    /// RN `setPasscode` (securityService.ts:85-95) additionally flips `enabled`; settings are
    /// owned by `SettingsStoring`, so the caller saves the updated `SecurityConfig`.
    @discardableResult
    func setPasscode(_ pin: String) throws -> String {
        guard Self.isValidPIN(pin) else { throw SecurityError.invalidPIN }
        let hash = Self.hashPasscode(pin)
        try store.save(hash)
        return hash
    }

    /// RN `disablePasscode` (securityService.ts:100-108): removes the stored hash.
    func clearPasscode() throws {
        try store.delete()
    }

    /// RN `verifyPasscode` (securityService.ts:73-80):
    /// - lock disabled or no hash → `true` ("not locked"),
    /// - otherwise compare the entered PIN's hash with the stored one.
    func verifyPasscode(_ pin: String, config: SecurityConfig) throws -> Bool {
        guard config.enabled, let stored = try storedPasscodeHash(config: config) else {
            return true
        }
        guard Self.isValidPIN(pin) else { return false }
        return Self.hashPasscode(pin) == stored
    }

    // MARK: - Biometrics

    /// RN `getBiometricStatus` collapse: hardware plus an enrolled biometric.
    func canUseBiometrics() -> Bool {
        biometrics.canEvaluateBiometrics()
    }

    /// RN `authenticateWithBiometrics` (securityService.ts:163-184).
    /// Returns `false` when the device cannot evaluate the policy or the prompt fails.
    func authenticateWithBiometrics(prompt: String = "Verify to unlock the app") async -> Bool {
        guard biometrics.canEvaluateBiometrics() else { return false }
        return await biometrics.authenticate(prompt: prompt)
    }
}
