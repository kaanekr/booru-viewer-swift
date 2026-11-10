import Foundation
import Security

/// Keychain wrapper for user secrets (Gelbooru / Rule34 API credentials, and later the app-lock hash).
///
/// API keys must never be written to the JSON stores or `AppSettings`; they only go here.
/// Items are generic passwords scoped to `service`, readable after the first unlock and never synced
/// to another device. Values are never logged by this type.
enum KeychainStore {
    /// Keychain service shared by every item the app writes.
    static let service = "com.booru.viewer.swift"

    /// Access class matching the app's background-refresh needs; the item never leaves the device.
    static var accessibility: CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// Account names for the two sources that support API authentication (storage.ts:397-433).
    static let gelbooruAuthAccount = "auth.gelbooru"
    static let rule34AuthAccount = "auth.rule34"

    enum KeychainError: Error, Equatable {
        /// `SecItem*` returned a status other than success / item-not-found.
        case unexpectedStatus(OSStatus)
        /// Stored bytes are not valid UTF-8 or not valid JSON for the requested type.
        case invalidValue
    }

    /// Returns the account name for a source, or `nil` when the source has no API auth.
    static func authAccount(for sourceID: SourceID) -> String? {
        switch sourceID {
        case .gelbooru:
            return gelbooruAuthAccount
        case .rule34:
            return rule34AuthAccount
        default:
            return nil
        }
    }

    // MARK: - String values

    static func save(_ value: String, for account: String) throws {
        try saveData(Data(value.utf8), for: account)
    }

    /// Returns `nil` when the account has no stored value.
    static func load(_ account: String) throws -> String? {
        guard let data = try loadData(for: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainError.invalidValue }
        return value
    }

    // MARK: - Codable values

    /// Encodes `value` as JSON inside the Keychain item (e.g. `ApiAuth`).
    static func save<Value: Encodable>(_ value: Value, for account: String) throws {
        try saveData(JSONEncoder().encode(value), for: account)
    }

    /// Returns `nil` when the account has no stored value.
    static func load<Value: Decodable>(_ type: Value.Type, for account: String) throws -> Value? {
        guard let data = try loadData(for: account) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw KeychainError.invalidValue
        }
    }

    // MARK: - Shared

    /// Removes the item; a missing item is not an error.
    static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Item primitives

    private static func saveData(_ data: Data, for account: String) throws {
        let query = baseQuery(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        var status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func loadData(for account: String) throws -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.invalidValue }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
