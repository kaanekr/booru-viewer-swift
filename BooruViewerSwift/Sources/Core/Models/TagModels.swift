import Foundation

/// Mirrors RN `TagCategory` (src/types/booru.ts:25). Raw values equal the RN strings.
enum TagCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case artist
    case character
    case copyright
    case general
    case meta
}

/// Mirrors RN `BooruTagGroups` (src/types/booru.ts:17-23).
struct BooruTagGroups: Codable, Hashable, Sendable {
    var artist: [String] = []
    var character: [String] = []
    var copyright: [String] = []
    var general: [String] = []
    var meta: [String] = []
}

/// Mirrors RN `BooruTagSuggestion` (src/types/booru.ts:62-66).
struct BooruTagSuggestion: Codable, Hashable, Sendable {
    var name: String
    var category: TagCategory
    var postCount: Int
}
