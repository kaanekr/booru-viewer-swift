import Foundation

/// Result of merging a backup file into the local stores.
///
/// Mirrors the spirit of RN `ImportResult` (backupService.ts:10-15) with the store-oriented
/// field names used by the native app. `skippedCount` counts favorites that were already
/// present (by `postKey` or `mediaKey`) plus entries the parser could not convert.
struct BackupImportSummary: Equatable, Sendable {
    var addedFavorites = 0
    /// Favorite tags written (RN `tagsImported`, backupService.ts:336).
    var addedTags = 0
    var addedBlacklistedTags = 0
    var addedHistory = 0
    var addedRecentViews = 0
    var skippedCount = 0
    var totalFavorites = 0
}

/// Backup export / import.
///
/// Export shape is RN `exportBackup` (backupService.ts:380-401): `creatorName` "BooruViewer",
/// `backupVersion` "1.0", an ISO export date, `favoritesCount = favorites.count` (fixes the
/// W0 F2 note about a stale count), and the plain store arrays.
///
/// Import is always a merge, for both the native JSON above and legacy AnimeBoxes `.abbj`
/// (backupService.ts:289-340): nothing is deleted, favorites dedupe by `postKey` **and**
/// `mediaKey`, tag lists union, search history unions then keeps the import cap, and recent
/// views union newest-first up to `PersistenceLimits.recentViews`.
struct BackupService: Sendable {
    static let creatorName = "BooruViewer"
    static let backupVersion = "1.0"

    private let favorites: any FavoritesStoring
    private let favoriteTags: any TagListStoring
    private let blacklistedTags: any TagListStoring
    private let searchHistory: any SearchHistoryStoring
    private let recentViews: any RecentViewsStoring
    private let now: @Sendable () -> Date

    init(
        favorites: any FavoritesStoring,
        favoriteTags: any TagListStoring,
        blacklistedTags: any TagListStoring,
        searchHistory: any SearchHistoryStoring,
        recentViews: any RecentViewsStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.favorites = favorites
        self.favoriteTags = favoriteTags
        self.blacklistedTags = blacklistedTags
        self.searchHistory = searchHistory
        self.recentViews = recentViews
        self.now = now
    }

    // MARK: - Export

    /// Collects every store into the RN export document. `favoritesCount` is derived from the
    /// exported array, never carried over from a previous file.
    func exportBackup() async throws -> BackupSchema {
        let favoritePosts = try await favorites.list()
        let favoriteTagList = try await favoriteTags.list()
        let history = try await searchHistory.list()
        let blacklist = try await blacklistedTags.list()
        let views = try await recentViews.list()

        return BackupSchema(
            creatorName: Self.creatorName,
            backupVersion: Self.backupVersion,
            exportDate: BooruJSONSupport.isoString(now()),
            favoritesCount: favoritePosts.count,
            favorites: favoritePosts,
            favoriteTags: favoriteTagList,
            searchHistory: history,
            blacklistedTags: blacklist,
            recentViews: views
        )
    }

    /// The export document as JSON. Pretty-printed and unescaped slashes like
    /// `JSON.stringify(backupObj, null, 2)` (backupService.ts:400).
    func exportJSONData(prettyPrinted: Bool = true) async throws -> Data {
        let schema = try await exportBackup()
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        }
        return try encoder.encode(schema)
    }

    /// `booru_backup_YYYY-MM-DD.json` (backupService.ts:401).
    func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return "booru_backup_\(formatter.string(from: now())).json"
    }

    // MARK: - Import

    /// Imports native BooruViewer JSON or an AnimeBoxes `.abbj` document. Always merges; the
    /// file never replaces local data.
    func importBackup(data: Data) async throws -> BackupImportSummary {
        let parsed = try AnimeBoxesParser.parse(data: data, now: now())
        return try await merge(parsed)
    }

    private func merge(_ parsed: ParsedBackup) async throws -> BackupImportSummary {
        var summary = BackupImportSummary()

        // 0. Recent views first, like RN (backupService.ts:294-303): favorites and saved
        //    recent views are merged together, newest first.
        summary.addedRecentViews = try await mergeRecentViews(parsed.favorites + parsed.recentViews)

        // 1. Favorites: postKey + mediaKey dedupe (backupService.ts:306-321).
        let favoriteResult = try await mergeFavorites(parsed.favorites)
        summary.addedFavorites = favoriteResult.added
        summary.skippedCount = favoriteResult.skipped + parsed.unreadablePostCount
        summary.totalFavorites = favoriteResult.total

        // 2. Tag lists: favorite and blacklisted, unioned (backupService.ts:324-332).
        summary.addedTags = try await mergeTags(parsed.favoriteTags, into: favoriteTags)
        summary.addedBlacklistedTags = try await mergeTags(parsed.blacklistedTags, into: blacklistedTags)

        // 3. Search history, capped at the import limit (backupService.ts:327).
        summary.addedHistory = try await mergeSearchHistory(parsed.searchHistory)

        return summary
    }

    /// RN `uniquePosts`/(`[...added, ...currentFavs]`): new favorites keep the backup's order
    /// in front of the existing list.
    private func mergeFavorites(_ posts: [BooruPost]) async throws -> (added: Int, skipped: Int, total: Int) {
        let existing = try await favorites.list()
        var keys = Set(existing.map(postKey))
        var mediaKeys = Set(existing.map(mediaKey))
        var added: [BooruPost] = []
        var skipped = 0

        for post in posts {
            let key = postKey(post)
            let media = mediaKey(post)
            guard !keys.contains(key), !mediaKeys.contains(media) else {
                skipped += 1
                continue
            }
            keys.insert(key)
            mediaKeys.insert(media)
            added.append(post)
        }

        // `add` prepends, so replay in reverse to land the backup order at the front.
        for post in added.reversed() {
            try await favorites.add(post)
        }
        return (added.count, skipped, existing.count + added.count)
    }

    /// Adds each tag through the store (which normalizes) and counts what actually appeared.
    private func mergeTags(_ tags: [String], into store: any TagListStoring) async throws -> Int {
        let before = Set(try await store.list())
        for tag in tags {
            try await store.add(tag)
        }
        let after = try await store.list()
        return after.filter { !before.contains($0) }.count
    }

    /// RN `updateSearchHistory` union (backupService.ts:327): the first
    /// `PersistenceLimits.searchHistoryImport` (100) imported entries are merged in front of the
    /// existing history, deduped case-insensitively, and the merge itself keeps 100 entries — the
    /// store's 30-entry runtime cap would otherwise drop imported entries and evict local ones.
    private func mergeSearchHistory(_ queries: [String]) async throws -> Int {
        let capped = Array(queries.prefix(PersistenceLimits.searchHistoryImport))
        if let bulk = searchHistory as? any SearchHistoryBulkImporting {
            return try await bulk.mergeImported(capped, limit: PersistenceLimits.searchHistoryImport)
        }
        let before = Set(try await searchHistory.list())
        // `record` prepends and moves duplicates to the front, so replay in reverse.
        for query in capped.reversed() {
            try await searchHistory.record(query)
        }
        let after = try await searchHistory.list()
        return after.filter { !before.contains($0) }.count
    }

    /// RN `mergeRecentViews` (backupService.ts:292-300, storage.ts): existing views first,
    /// imported ones appended newest-first, deduped by `postKey`, capped at 500.
    private func mergeRecentViews(_ imported: [BooruPost]) async throws -> Int {
        let existing = try await recentViews.list()
        let existingKeys = Set(existing.map(postKey))

        var merged = existing
        var seen = existingKeys
        for post in sortedNewestFirst(imported) {
            guard seen.insert(postKey(post)).inserted else { continue }
            merged.append(post)
        }
        if merged.count > PersistenceLimits.recentViews {
            merged.removeLast(merged.count - PersistenceLimits.recentViews)
        }

        let added = merged.filter { !existingKeys.contains(postKey($0)) }.count
        // `record` prepends; replaying in reverse reproduces the merged order.
        for post in merged.reversed() {
            try await recentViews.record(post)
        }
        return added
    }

    /// RN sorts with `Date.parse`; an unparseable date counts as 0 and lands last.
    private func sortedNewestFirst(_ posts: [BooruPost]) -> [BooruPost] {
        posts.enumerated()
            .sorted { lhs, rhs in
                let left = Self.date(fromISO: lhs.element.createdAt) ?? .distantPast
                let right = Self.date(fromISO: rhs.element.createdAt) ?? .distantPast
                if left == right { return lhs.offset < rhs.offset }
                return left > right
            }
            .map { $0.element }
    }

    /// RN `Date.parse` accepts ISO strings with or without milliseconds; exports carry the
    /// millisecond form (`BooruJSONSupport.date(fromISO:)`), older files may not.
    private static func date(fromISO value: String) -> Date? {
        if let date = BooruJSONSupport.date(fromISO: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
