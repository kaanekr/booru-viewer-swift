import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// JSON document handed to `fileExporter` for the export action.
///
/// The payload is the RN-compatible backup JSON produced by `BackupService.exportJSONData()`;
/// `.abbj` is only accepted on import.
struct BackupFileDocument: FileDocument {
    /// AnimeBoxes backup extension. Falls back to `.data` when the system has no handler for it.
    static let abbjType: UTType = UTType(filenameExtension: "abbj") ?? .data

    /// Types the import picker accepts (`.json`, `.abbj`, plus a generic data escape hatch).
    static let allowedImportTypes: [UTType] = [.json, Self.abbjType, .data]

    static var readableContentTypes: [UTType] { Self.allowedImportTypes }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// One row of the Test Connection results table: a source with its direct and relay legs.
struct ConnectionRow: Identifiable, Equatable, Sendable {
    let name: String
    let direct: NetworkDiagnosticResult?
    let relay: NetworkDiagnosticResult?

    var id: String { name }
}

/// Errors surfaced to `PasscodeModalView`.
enum SettingsError: Error, LocalizedError {
    case saveFailed

    var errorDescription: String? {
        "Could not save your settings."
    }
}

/// Settings tab state and actions.
///
/// Mirrors `src/screens/settings/useSettings.ts` and `SettingsScreen.tsx` on top of the native
/// contracts: `AppSettings` goes through `SettingsStoring`, Gelbooru / Rule34 credentials stay in
/// `KeychainStore`, blocked tags go through `TagListStoring`, the PIN lives in the Keychain via
/// `SecurityService`, and backup / diagnostics use `BackupService` and `NetworkDiagnostics`.
@MainActor
@Observable
final class SettingsViewModel {
    /// Identifier for an in-flight action, so rows can show a single spinner.
    enum Busy: String, Equatable {
        case source
        case quality
        case previews
        case proxy
        case worker
        case auth
        case biometrics
        case passcode
        case tag
        case importBackup
        case exportBackup
        case clear
    }

    /// Simple alert payload (`Alert(item:)` needs `Identifiable`).
    struct AlertState: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// One image-quality choice, copy taken from `SettingsScreen.tsx:25-29`.
    struct QualityOption: Identifiable, Equatable, Sendable {
        let id: ImageQuality
        let name: String
        let description: String
    }

    static let qualityOptions: [QualityOption] = [
        QualityOption(id: .preview, name: "Quick preview", description: "Sample images. Lower data usage."),
        QualityOption(id: .auto, name: "Automatic", description: "Sample first, original when you zoom."),
        QualityOption(id: .full, name: "Original quality", description: "Full-resolution images from the start.")
    ]

    // MARK: - Dependencies

    private let settingsStore: any SettingsStoring
    private let blacklistedStore: any TagListStoring
    private let backupService: BackupService
    private let security: SecurityService
    private let probeClient: @MainActor () -> any HTTPClientProtocol
    private let onSourceChanged: @MainActor (SourceID) -> Void
    /// `SearchHistoryStoring` has no clear API yet, so the default writes an empty document
    /// through `JSONFileStore`; tests can inject a fake.
    private let clearSearchHistoryAction: @MainActor () async throws -> Void

    /// Owned so the lock overlay and the settings screen share one state machine.
    let lockController: AppLockController

    // MARK: - State

    private(set) var settings = AppSettings()
    private(set) var blacklistedTags: [String] = []
    var newBlacklistTag = ""

    var gelbooruAuth = ApiAuth(userID: "", apiKey: "")
    var rule34Auth = ApiAuth(userID: "", apiKey: "")

    private(set) var savedGelbooruAuth = ApiAuth(userID: "", apiKey: "")
    private(set) var savedRule34Auth = ApiAuth(userID: "", apiKey: "")

    private(set) var isLoading = true
    private(set) var hasLoaded = false
    private(set) var busy: Busy?
    private(set) var isTestingConnection = false
    private(set) var connectionResults: [NetworkDiagnosticResult] = []

    private(set) var passcodeEnabled = false
    private(set) var hasBiometrics = false

    /// Draft Worker URL; saved into `settings.proxy.workerURL` by `saveWorkerURL()`.
    var workerURLDraft = ""
    private(set) var savedWorkerURL = ""

    private(set) var exportDocument: BackupFileDocument?
    var isExporting = false
    var isImporting = false

    var alert: AlertState?

    // MARK: - Init

    init(
        settingsStore: any SettingsStoring = SettingsStore(directory: JSONFileStore.defaultDirectory()),
        blacklistedStore: (any TagListStoring)? = nil,
        backupService: BackupService? = nil,
        security: SecurityService = SecurityService(),
        lockController: AppLockController? = nil,
        probeClient: @escaping @MainActor () -> any HTTPClientProtocol = { URLSessionHTTPClient.makeProbeClient() },
        clearSearchHistory: (@MainActor () async throws -> Void)? = nil,
        onSourceChanged: @escaping @MainActor (SourceID) -> Void = { _ in }
    ) {
        let directory = JSONFileStore.defaultDirectory()
        self.settingsStore = settingsStore
        self.blacklistedStore = blacklistedStore ?? TagListStore(directory: directory, kind: .blacklisted)
        self.backupService = backupService ?? BackupService(
            favorites: FavoritesStore(directory: directory),
            favoriteTags: TagListStore(directory: directory, kind: .favorite),
            blacklistedTags: TagListStore(directory: directory, kind: .blacklisted),
            searchHistory: SearchHistoryStore(directory: directory),
            recentViews: RecentViewsStore(directory: directory)
        )
        self.security = security
        self.probeClient = probeClient
        self.onSourceChanged = onSourceChanged
        let defaultClearHistory: @MainActor () async throws -> Void = {
            let store = JSONFileStore(directory: directory)
            try await store.write(SearchHistoryStore.fileName, [String]())
        }
        self.clearSearchHistoryAction = clearSearchHistory ?? defaultClearHistory
        self.lockController = lockController ?? AppLockController(service: security, settings: settingsStore)
    }

    // MARK: - Loading

    /// Loads settings, blocked tags, Keychain credentials, and the security summary.
    func load(force: Bool = false) async {
        if hasLoaded && !force {
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            settings = try await settingsStore.load()
        } catch {
            alert = AlertState(
                title: "Settings unavailable",
                message: "Could not load your preferences. Please reopen Settings."
            )
        }

        blacklistedTags = (try? await blacklistedStore.list()) ?? []
        workerURLDraft = settings.proxy.workerURL
        savedWorkerURL = settings.proxy.workerURL
        loadAuth()
        // Keep the media pipeline on the Worker settings the screen just read.
        MediaRequestConfiguration.updateCurrentProxy(settings.proxy)
        refreshSecurity()
    }

    func refreshBlacklist() async {
        blacklistedTags = (try? await blacklistedStore.list()) ?? blacklistedTags
    }

    private func loadAuth() {
        savedGelbooruAuth = storedAuth(for: .gelbooru)
        savedRule34Auth = storedAuth(for: .rule34)
        gelbooruAuth = savedGelbooruAuth
        rule34Auth = savedRule34Auth
    }

    private func storedAuth(for source: SourceID) -> ApiAuth {
        guard let account = KeychainStore.authAccount(for: source) else {
            return ApiAuth(userID: "", apiKey: "")
        }
        return (try? KeychainStore.load(ApiAuth.self, for: account)) ?? ApiAuth(userID: "", apiKey: "")
    }

    // MARK: - Appearance & playback

    var imageQualityName: String {
        Self.qualityOptions.first { $0.id == settings.imageQuality }?.name ?? settings.imageQuality.rawValue
    }

    func setImageQuality(_ quality: ImageQuality) async {
        guard settings.imageQuality != quality else { return }
        let previous = settings.imageQuality
        settings.imageQuality = quality
        busy = .quality
        defer { busy = nil }
        if await persist() {
            notifySettingsChanged()
        } else {
            settings.imageQuality = previous
        }
    }

    func setGridPreviews(_ enabled: Bool) async {
        guard settings.gridPreviews != enabled else { return }
        let previous = settings.gridPreviews
        settings.gridPreviews = enabled
        busy = .previews
        defer { busy = nil }
        if await persist() {
            notifySettingsChanged()
        } else {
            settings.gridPreviews = previous
        }
    }

    // MARK: - Sources

    var activeSourceID: SourceID { settings.activeSourceID }

    func selectSource(_ id: SourceID) async {
        guard settings.activeSourceID != id else { return }
        let previous = settings.activeSourceID
        settings.activeSourceID = id
        busy = .source
        defer { busy = nil }
        if await persist() {
            notifySettingsChanged()
        } else {
            settings.activeSourceID = previous
        }
    }

    // MARK: - API credentials

    func auth(for source: SourceID) -> ApiAuth {
        source == .rule34 ? rule34Auth : gelbooruAuth
    }

    func savedAuth(for source: SourceID) -> ApiAuth {
        source == .rule34 ? savedRule34Auth : savedGelbooruAuth
    }

    func setAuth(_ auth: ApiAuth, for source: SourceID) {
        if source == .rule34 {
            rule34Auth = auth
        } else {
            gelbooruAuth = auth
        }
    }

    /// True when the draft equals the Keychain copy and a key exists.
    func isAuthSaved(for source: SourceID) -> Bool {
        let saved = savedAuth(for: source)
        let draft = auth(for: source)
        return !saved.apiKey.isEmpty
            && saved.apiKey == draft.apiKey
            && saved.userID == draft.userID
    }

    func saveAuth(for source: SourceID) async {
        guard let account = KeychainStore.authAccount(for: source) else { return }
        let sourceName = source == .rule34 ? "Rule34" : "Gelbooru"
        var draft = auth(for: source)
        draft.userID = draft.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !draft.userID.isEmpty,
              draft.userID.allSatisfy({ $0.isASCII && $0.isNumber }),
              !draft.apiKey.isEmpty else {
            alert = AlertState(
                title: "Missing Info",
                message: "Enter your \(sourceName) user_id (numbers only) and api_key. Each source needs its own key."
            )
            return
        }

        busy = .auth
        defer { busy = nil }
        do {
            try KeychainStore.save(draft, for: account)
            setAuth(draft, for: source)
            if source == .rule34 {
                savedRule34Auth = draft
            } else {
                savedGelbooruAuth = draft
            }
            notifySettingsChanged()
        } catch {
            alert = AlertState(
                title: "Could not save key",
                message: "The \(sourceName) API key could not be stored on this device."
            )
        }
    }

    func clearAuth(for source: SourceID) async {
        guard let account = KeychainStore.authAccount(for: source) else { return }
        busy = .auth
        defer { busy = nil }
        do {
            try KeychainStore.delete(account)
            let empty = ApiAuth(userID: "", apiKey: "")
            setAuth(empty, for: source)
            if source == .rule34 {
                savedRule34Auth = empty
            } else {
                savedGelbooruAuth = empty
            }
            notifySettingsChanged()
        } catch {
            alert = AlertState(title: "Could not delete key", message: "Please try again.")
        }
    }

    // MARK: - Blocked tags

    func addBlacklistedTag() async {
        let normalized = newBlacklistTag
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
            .lowercased()
        guard !normalized.isEmpty else { return }
        busy = .tag
        defer { busy = nil }
        do {
            try await blacklistedStore.add(normalized)
            blacklistedTags = (try? await blacklistedStore.list()) ?? blacklistedTags
            newBlacklistTag = ""
            notifySettingsChanged()
        } catch {
            alert = AlertState(title: "Could not block tag", message: "Please try again.")
        }
    }

    func removeBlacklistedTag(_ tag: String) async {
        busy = .tag
        defer { busy = nil }
        do {
            try await blacklistedStore.remove(tag)
            blacklistedTags.removeAll { $0 == tag }
            notifySettingsChanged()
        } catch {
            alert = AlertState(title: "Could not unblock tag", message: "Please try again.")
        }
    }

    func clearBlacklistedTags() async {
        busy = .tag
        defer { busy = nil }
        for tag in blacklistedTags {
            try? await blacklistedStore.remove(tag)
        }
        blacklistedTags = []
        notifySettingsChanged()
    }

    // MARK: - App lock

    func refreshSecurity() {
        let config = settings.security
        let hash: String?
        do {
            hash = try security.storedPasscodeHash(config: config)
        } catch {
            hash = nil
        }
        passcodeEnabled = config.enabled && hash != nil
        hasBiometrics = security.canUseBiometrics()
    }

    /// RN `verifyPasscode` collapse: false on a wrong PIN or unreadable config.
    func verifyPIN(_ pin: String) -> Bool {
        (try? security.verifyPasscode(pin, config: settings.security)) ?? false
    }

    /// Hashes the PIN, enables the lock, and saves the parity placeholder to `AppSettings`.
    func setPasscode(_ pin: String) async throws {
        busy = .passcode
        defer { busy = nil }
        let hash = try security.setPasscode(pin)
        settings.security.enabled = true
        settings.security.passcodeHash = hash
        guard await persist() else {
            refreshSecurity()
            throw SettingsError.saveFailed
        }
        refreshSecurity()
    }

    /// Removes the Keychain hash and turns the lock off.
    func disablePasscode() async throws {
        busy = .passcode
        defer { busy = nil }
        try security.clearPasscode()
        settings.security.enabled = false
        settings.security.passcodeHash = nil
        guard await persist() else {
            refreshSecurity()
            throw SettingsError.saveFailed
        }
        refreshSecurity()
    }

    func setUseBiometrics(_ enabled: Bool) async {
        guard settings.security.useBiometrics != enabled else { return }
        settings.security.useBiometrics = enabled
        busy = .biometrics
        defer { busy = nil }
        if !(await persist()) {
            settings.security.useBiometrics = !enabled
        }
    }

    func setAutoLockImmediately(_ enabled: Bool) async {
        guard settings.security.autoLockImmediately != enabled else { return }
        settings.security.autoLockImmediately = enabled
        if !(await persist()) {
            settings.security.autoLockImmediately = !enabled
        }
    }

    // MARK: - Backup & restore

    var exportFileName: String {
        backupService.suggestedFileName()
    }

    /// Builds the backup JSON and raises the export sheet.
    func prepareExport() async {
        busy = .exportBackup
        defer { busy = nil }
        do {
            let data = try await backupService.exportJSONData()
            exportDocument = BackupFileDocument(data: data)
            isExporting = true
        } catch {
            alert = AlertState(
                title: "Export failed",
                message: "Could not build your backup. Please try again."
            )
        }
    }

    func finishExport(_ result: Result<URL, Error>) {
        exportDocument = nil
        switch result {
        case .success(let url):
            alert = AlertState(
                title: "Backup exported",
                message: "Your library was saved as \(url.lastPathComponent)."
            )
        case .failure(let error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
            alert = AlertState(
                title: "Export failed",
                message: "The backup file could not be written."
            )
        }
    }

    /// Entry point for `fileImporter`'s completion.
    func handleImport(_ result: Result<URL, Error>) async {
        switch result {
        case .success(let url):
            await importBackup(from: url)
        case .failure(let error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
            alert = AlertState(
                title: "Import failed",
                message: "The file could not be opened."
            )
        }
    }

    func importBackup(from url: URL) async {
        busy = .importBackup
        defer { busy = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let summary = try await backupService.importBackup(data: data)
            await refreshBlacklist()
            notifySettingsChanged()
            alert = AlertState(
                title: "Backup imported",
                message: "\(summary.addedFavorites.formatted()) new favorites • \(summary.addedTags) tags • \(summary.addedHistory) searches\n\(summary.totalFavorites.formatted()) total favorites"
            )
        } catch {
            alert = AlertState(
                title: "Import failed",
                message: "That file could not be read as an .abbj or JSON backup."
            )
        }
    }

    // MARK: - Network & proxy

    var networkSummary: String {
        if settings.proxy.enabled {
            return "Relay via Worker"
        }
        return savedWorkerURL.isEmpty ? "Direct connection" : "Direct with Worker fallback"
    }

    func setProxyEnabled(_ enabled: Bool) async {
        guard settings.proxy.enabled != enabled else { return }
        guard !enabled || !savedWorkerURL.isEmpty else {
            alert = AlertState(
                title: "Worker URL required",
                message: "Save your Cloudflare Worker URL before enabling the relay."
            )
            return
        }
        settings.proxy.enabled = enabled
        busy = .proxy
        defer { busy = nil }
        if await persist() {
            notifySettingsChanged()
        } else {
            settings.proxy.enabled = !enabled
        }
    }

    /// Validates the draft and saves it as the stored Worker URL.
    ///
    /// A pasted bare host (`my-worker.workers.dev`) gets `https://` automatically, and
    /// surrounding whitespace plus any trailing slashes are trimmed before validation.
    func saveWorkerURL() async {
        let value = Self.normalizedWorkerURL(workerURLDraft)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            alert = AlertState(
                title: "Invalid Worker URL",
                message: "Use an HTTPS Worker URL without a query, fragment or embedded credentials."
            )
            return
        }

        let previousProxy = settings.proxy
        settings.proxy.workerURL = value
        busy = .worker
        defer { busy = nil }
        if await persist() {
            workerURLDraft = value
            savedWorkerURL = value
            connectionResults = []
            notifySettingsChanged()
        } else {
            settings.proxy = previousProxy
            workerURLDraft = previousProxy.workerURL
        }
    }

    func removeWorker() async {
        let previousProxy = settings.proxy
        settings.proxy = ProxyConfig()
        busy = .worker
        defer { busy = nil }
        if await persist() {
            workerURLDraft = ""
            savedWorkerURL = ""
            connectionResults = []
            notifySettingsChanged()
        } else {
            settings.proxy = previousProxy
            workerURLDraft = previousProxy.workerURL
        }
    }

    /// RN `testProxyConnection`: probes direct and relay legs for every target.
    func testConnection() async {
        guard !savedWorkerURL.isEmpty else {
            alert = AlertState(
                title: "Save the Worker URL",
                message: "Save your Cloudflare Worker URL before testing."
            )
            return
        }
        let draft = Self.normalizedWorkerURL(workerURLDraft)
        guard draft == savedWorkerURL else {
            alert = AlertState(
                title: "Save the Worker URL",
                message: "Save your current Worker URL before testing."
            )
            return
        }

        isTestingConnection = true
        connectionResults = []
        defer { isTestingConnection = false }
        let results = await NetworkDiagnostics.run(proxy: settings.proxy, http: probeClient())
        connectionResults = results
        if results.isEmpty {
            alert = AlertState(
                title: "Connection test failed",
                message: "Please try again."
            )
        }
    }

    /// Pairs the flat probe results into the direct / relay table the RN screen renders.
    var connectionRows: [ConnectionRow] {
        var rows: [ConnectionRow] = []
        var indexByName: [String: Int] = [:]

        for result in connectionResults {
            let isDirect = result.target.hasSuffix(" (direct)")
            let name = result.target
                .replacingOccurrences(of: " (direct)", with: "")
                .replacingOccurrences(of: " (relay)", with: "")

            if let index = indexByName[name] {
                let existing = rows[index]
                rows[index] = ConnectionRow(
                    name: name,
                    direct: isDirect ? result : existing.direct,
                    relay: isDirect ? existing.relay : result
                )
            } else {
                indexByName[name] = rows.count
                rows.append(ConnectionRow(
                    name: name,
                    direct: isDirect ? result : nil,
                    relay: isDirect ? nil : result
                ))
            }
        }
        return rows
    }

    // MARK: - Local data

    /// Clears the shared `URLCache` and the decoded `MediaImageLoader` cache, the
    /// native stand-in for the RN image cache purge.
    func clearCache() {
        busy = .clear
        defer { busy = nil }
        URLCache.shared.removeAllCachedResponses()
        Task { await MediaImageLoader.shared.clearCache() }
        alert = AlertState(
            title: "Cache cleared",
            message: "Downloaded thumbnails and temporary post data were removed. Your favorites and settings were kept."
        )
    }

    /// Clears the stored search history.
    ///
    /// `SearchHistoryStoring` only exposes `list`/`record`, so the default implementation
    /// writes an empty document through `JSONFileStore`; injectable for tests.
    func clearSearchHistory() async {
        busy = .clear
        defer { busy = nil }
        do {
            try await clearSearchHistoryAction()
            alert = AlertState(
                title: "History cleared",
                message: "Searches saved on this device were removed. Your favorites and blocked tags were kept."
            )
        } catch {
            alert = AlertState(
                title: "Could not clear history",
                message: "Please try again."
            )
        }
    }

    // MARK: - Persistence

    /// Trims whitespace, prepends `https://` for a bare host, then drops trailing slashes.
    ///
    /// A pasted `my-worker.workers.dev` is the common case; anything that already carries a
    /// scheme is left for `saveWorkerURL()` to validate.
    nonisolated static func normalizedWorkerURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !value.contains("://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Pushes a persisted settings edit to the app layer and the media pipeline.
    ///
    /// The tabs reload through `onSourceChanged`, and `MediaRequestConfiguration` keeps the
    /// media headers/API transport on the Worker the user just saved, so no edit needs a restart.
    private func notifySettingsChanged() {
        MediaRequestConfiguration.updateCurrentProxy(settings.proxy)
        onSourceChanged(settings.activeSourceID)
    }

    @discardableResult
    private func persist() async -> Bool {
        do {
            try await settingsStore.save(settings)
            return true
        } catch {
            alert = AlertState(
                title: "Could not save changes",
                message: "Please try again."
            )
            return false
        }
    }
}
