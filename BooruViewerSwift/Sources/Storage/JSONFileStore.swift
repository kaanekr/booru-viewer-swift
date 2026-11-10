import Foundation

/// Serialized JSON file store.
///
/// Replaces the RN per-key write queue (storage.ts:42-53). Every read-modify-write runs inside this
/// actor, so two concurrent callers can never interleave and lose an update.
///
/// Writes are atomic: the document is encoded, written to a unique temporary file in the same
/// directory, then swapped into place with `replaceItemAt` (or a plain move for the first write), so a
/// crash cannot leave a half-written document behind.
///
/// Documents live in `Application Support/BooruViewer/<name>.json`. The directory is created on the
/// first write; a missing file reads as `nil` (the caller supplies the default).
actor JSONFileStore {
    enum StoreError: Error, Equatable {
        /// The file exists but does not decode as the requested type. The file is left untouched.
        case corruptedDocument(name: String)
        /// The store directory could not be created.
        case directoryUnavailable(path: String)
    }

    /// Folder name under Application Support.
    static let directoryName = "BooruViewer"
    /// Extension appended to every document name.
    static let fileExtension = "json"

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL = JSONFileStore.defaultDirectory(), fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// `Application Support/BooruViewer` (falls back to the temporary directory in unusual sandboxes).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Returns `nil` when the document does not exist. Corrupt content throws and is preserved.
    func read<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value? {
        let url = fileURL(for: name)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw StoreError.corruptedDocument(name: name)
        }
    }

    /// Encodes and atomically replaces the whole document.
    func write<Value: Encodable>(_ name: String, _ value: Value) throws {
        try writeData(encoder.encode(value), to: name)
    }

    /// Runs a read-modify-write as one isolated operation; a missing document starts at `defaultValue`.
    /// A corrupt document throws before `transform` runs and is not overwritten, matching RN
    /// `updateList` (storage.ts:63-70).
    @discardableResult
    func update<Value: Codable>(
        _ name: String,
        defaultValue: Value,
        _ transform: (inout Value) -> Void
    ) throws -> Value {
        var value = try read(name, as: Value.self) ?? defaultValue
        transform(&value)
        try writeData(encoder.encode(value), to: name)
        return value
    }

    // MARK: - File primitives

    private func writeData(_ data: Data, to name: String) throws {
        try createDirectoryIfNeeded()
        let destination = fileURL(for: name)
        let temporary = directory.appendingPathComponent(
            ".\(name).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try data.write(to: temporary)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func createDirectoryIfNeeded() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.directoryUnavailable(path: directory.path)
        }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(name).\(JSONFileStore.fileExtension)", isDirectory: false)
    }
}
