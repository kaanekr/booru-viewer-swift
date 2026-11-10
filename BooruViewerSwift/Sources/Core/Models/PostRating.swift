import Foundation

/// Mirrors RN `BooruPost.rating` codes (src/types/booru.ts:44): 's' safe, 'q' questionable, 'e' explicit, 'g' general.
enum PostRating: String, Codable, Hashable, Sendable {
    case safe = "s"
    case questionable = "q"
    case explicit = "e"
    case general = "g"
}
