import Foundation

/// Gelbooru / Rule34 credentials. JSON keys match RN `{ userId, apiKey }` (storage.ts getGelbooruAuth).
/// Values are user-supplied secrets: never log or hard-code them.
struct ApiAuth: Codable, Sendable {
    var userID: String
    var apiKey: String

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case apiKey
    }
}
