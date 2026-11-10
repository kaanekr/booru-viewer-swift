import Foundation

/// Size caps taken from RN behaviour.
enum PersistenceLimits {
    /// Search history kept at runtime (storage.ts:208).
    static let searchHistoryRuntime = 30
    /// Search history merged on import (backupService.ts:327).
    static let searchHistoryImport = 100
    /// Recent views kept (storage.ts:442, 488, 518).
    static let recentViews = 500
}

/// Favorite posts. Identity is source-qualified (see `postKey`).
protocol FavoritesStoring: Sendable {
    func list() async throws -> [BooruPost]
    func add(_ post: BooruPost) async throws
    func remove(id: String, sourceID: SourceID) async throws
    func contains(_ post: BooruPost) async throws -> Bool
}

/// Tag list. Used twice: once for favorite tags and once for blacklisted tags.
protocol TagListStoring: Sendable {
    func list() async throws -> [String]
    func add(_ tag: String) async throws
    func remove(_ tag: String) async throws
}

/// Search history. Runtime cap is `PersistenceLimits.searchHistoryRuntime`.
protocol SearchHistoryStoring: Sendable {
    func list() async throws -> [String]
    func record(_ query: String) async throws
}

/// Recently viewed posts. Cap is `PersistenceLimits.recentViews`.
protocol RecentViewsStoring: Sendable {
    func list() async throws -> [BooruPost]
    func record(_ post: BooruPost) async throws
}

/// App settings load and save.
protocol SettingsStoring: Sendable {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}
