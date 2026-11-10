import Foundation

/// Export JSON written by RN `BackupService.exportBackup` (backupService.ts:388-398).
/// Stored property names equal the RN JSON keys.
///
/// Decoding is lenient:
/// - Missing metadata keys (`creatorName`, `backupVersion`, `exportDate`, `favoritesCount`) decode as nil.
/// - Missing `favorites`, `favoriteTags`, `searchHistory`, `blacklistedTags`, `recentViews` decode as [].
/// - A favorite or recent view that fails to decode (e.g. an unknown `sourceId`) is dropped; the rest are kept.
///
/// Encoding writes the plain arrays, so the output keeps the RN shape.
struct BackupSchema: Codable, Sendable {
    var creatorName: String?
    var backupVersion: String?
    var exportDate: String?
    var favoritesCount: Int?
    var favorites: [BooruPost] = []
    var favoriteTags: [String] = []
    var searchHistory: [String] = []
    var blacklistedTags: [String] = []
    var recentViews: [BooruPost] = []

    enum CodingKeys: String, CodingKey {
        case creatorName
        case backupVersion
        case exportDate
        case favoritesCount
        case favorites
        case favoriteTags
        case searchHistory
        case blacklistedTags
        case recentViews
    }
}

extension BackupSchema {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creatorName = try c.decodeIfPresent(String.self, forKey: .creatorName)
        backupVersion = try c.decodeIfPresent(String.self, forKey: .backupVersion)
        exportDate = try c.decodeIfPresent(String.self, forKey: .exportDate)
        favoritesCount = try c.decodeIfPresent(Int.self, forKey: .favoritesCount)
        favorites = try c.decodeIfPresent([FailableDecodable<BooruPost>].self, forKey: .favorites)?.compactMap { $0.value } ?? []
        favoriteTags = try c.decodeIfPresent([String].self, forKey: .favoriteTags) ?? []
        searchHistory = try c.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
        blacklistedTags = try c.decodeIfPresent([String].self, forKey: .blacklistedTags) ?? []
        recentViews = try c.decodeIfPresent([FailableDecodable<BooruPost>].self, forKey: .recentViews)?.compactMap { $0.value } ?? []
    }
}
