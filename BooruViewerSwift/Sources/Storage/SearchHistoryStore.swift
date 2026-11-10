import Foundation

/// Bulk search-history merge used by backup import.
///
/// RN's import unions the incoming and existing arrays and keeps up to 100 entries
/// (`backupService.ts:327`), while `record(_:)` enforces the 30-entry runtime cap
/// (`storage.ts:208`). Replaying an import through `record(_:)` would therefore lose the
/// import cap; this protocol exposes the single write the merge needs.
protocol SearchHistoryBulkImporting: SearchHistoryStoring {
    /// Unions `queries` in front of the stored history, normalizing each entry and dropping
    /// case-insensitive duplicates in order, then keeps the newest `limit` entries.
    /// Returns the number of imported entries that were not already stored.
    func mergeImported(_ queries: [String], limit: Int) async throws -> Int
}

/// Search history persisted as a JSON array of normalized queries, newest first.
/// Runtime cap is 30 entries (`storage.ts:208`, `PersistenceLimits.searchHistoryRuntime`).
struct SearchHistoryStore: SearchHistoryStoring, SearchHistoryBulkImporting {
    static let fileName = "search-history"

    private let file: JSONFileStore

    init(file: JSONFileStore) {
        self.file = file
    }

    init(directory: URL) {
        self.init(file: JSONFileStore(directory: directory))
    }

    func list() async throws -> [String] {
        do {
            return try await file.read(Self.fileName, as: [String].self) ?? []
        } catch {
            // RN getSearchHistory swallows read failures (storage.ts:193-201).
            return []
        }
    }

    /// RN `addSearchHistory` (storage.ts:203-213): trim, lowercase, collapse whitespace to single
    /// spaces, ignore empties, move the query to the front (case-insensitive dedupe) and keep the
    /// newest `PersistenceLimits.searchHistoryRuntime` (30) entries.
    func record(_ query: String) async throws {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return }
        try await file.update(Self.fileName, defaultValue: [String]()) { history in
            history.removeAll { $0.lowercased() == normalized }
            history.insert(normalized, at: 0)
            let overflow = history.count - PersistenceLimits.searchHistoryRuntime
            if overflow > 0 {
                history.removeLast(overflow)
            }
        }
    }

    /// RN `updateSearchHistory` on import (backupService.ts:327): the imported entries come first,
    /// the existing ones follow, duplicates are dropped case-insensitively in first-seen order,
    /// and the merged list keeps `limit` entries instead of the 30-entry runtime cap.
    func mergeImported(_ queries: [String], limit: Int = PersistenceLimits.searchHistoryImport) async throws -> Int {
        let existing = try await list()
        let existingKeys = Set(existing.map { normalize($0) })

        var merged: [String] = []
        var seen = Set<String>()
        for query in queries {
            let normalized = normalize(query)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            merged.append(normalized)
        }
        for query in existing {
            let normalized = normalize(query)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            merged.append(normalized)
        }
        if merged.count > limit {
            merged.removeLast(merged.count - limit)
        }

        let added = merged.filter { !existingKeys.contains($0) }.count
        // Skip the write when the merge changed nothing (import of only-duplicates).
        if merged != existing {
            try await file.update(Self.fileName, defaultValue: [String]()) { history in
                history = merged
            }
        }
        return added
    }

    /// `tag.trim().toLowerCase().replace(/\s+/g, ' ')` (storage.ts:205).
    private func normalize(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
