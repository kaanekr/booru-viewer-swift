import Foundation

/// Favorite tags or blacklisted tags, persisted as a JSON array of normalized tag strings.
///
/// Both lists behave the same in RN: normalization, dedupe, newest first (storage.ts:259-332).
/// The only difference is the separator used when collapsing whitespace:
/// - favorite tags use a single space (`storage.ts:261`)
/// - blacklisted tags use an underscore (`storage.ts:316`)
struct TagListStore: TagListStoring {
    enum Kind: Sendable {
        case favorite
        case blacklisted

        /// One file per list; the same store type backs both features.
        var fileName: String {
            switch self {
            case .favorite:
                return "favorite-tags"
            case .blacklisted:
                return "blacklisted-tags"
            }
        }

        /// The RN `\s+` replacement for this list.
        var separator: String {
            switch self {
            case .favorite:
                return " "
            case .blacklisted:
                return "_"
            }
        }
    }

    private let file: JSONFileStore
    private let kind: Kind

    init(file: JSONFileStore, kind: Kind) {
        self.file = file
        self.kind = kind
    }

    init(directory: URL, kind: Kind) {
        self.init(file: JSONFileStore(directory: directory), kind: kind)
    }

    func list() async throws -> [String] {
        do {
            return try await file.read(kind.fileName, as: [String].self) ?? []
        } catch {
            // RN getters swallow read failures and report an empty list (storage.ts:224-232, 279-287).
            return []
        }
    }

    /// Prepends unless the normalized tag is already listed (storage.ts:263, 318).
    func add(_ tag: String) async throws {
        let normalized = normalize(tag)
        guard !normalized.isEmpty else { return }
        try await file.update(kind.fileName, defaultValue: [String]()) { tags in
            guard !tags.contains(normalized) else { return }
            tags.insert(normalized, at: 0)
        }
    }

    /// Drops every occurrence of the normalized tag (storage.ts:272, 327).
    func remove(_ tag: String) async throws {
        let normalized = normalize(tag)
        guard !normalized.isEmpty else { return }
        try await file.update(kind.fileName, defaultValue: [String]()) { tags in
            tags.removeAll { $0 == normalized }
        }
    }

    /// RN: `tag.trim().toLowerCase().replace(/\s+/g, ' ')` (or `'_'` for blacklisted tags).
    /// `split` drops leading/trailing whitespace and collapses runs, then lowercase matches `toLowerCase()`.
    private func normalize(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: kind.separator)
            .lowercased()
    }
}
