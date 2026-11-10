import Foundation

/// App preferences persisted as a single JSON document.
///
/// Secrets are never part of `AppSettings`: Gelbooru / Rule34 credentials live in the Keychain
/// (`KeychainStore`). The security config only carries the parity placeholder `passcodeHash`.
struct SettingsStore: SettingsStoring {
    static let fileName = "settings"

    private let file: JSONFileStore

    init(file: JSONFileStore) {
        self.file = file
    }

    init(directory: URL) {
        self.init(file: JSONFileStore(directory: directory))
    }

    /// A missing or unreadable document loads the defaults, like the RN getters (storage.ts:103-114).
    func load() async throws -> AppSettings {
        (try? await file.read(Self.fileName, as: AppSettings.self)) ?? AppSettings()
    }

    func save(_ settings: AppSettings) async throws {
        try await file.write(Self.fileName, settings)
    }
}
