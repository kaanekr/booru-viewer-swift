import Foundation

/// Source IDs from RN `AVAILABLE_SOURCES` (src/services/sources.ts:5-108).
/// Raw values must equal the RN `id` strings exactly. The RN default source is `gelbooru` (sources.ts:113).
enum SourceID: String, Codable, CaseIterable, Hashable, Sendable {
    case gelbooru = "gelbooru"          // sources.ts:5
    case yandere = "yandere"            // sources.ts:13
    case danbooru = "danbooru"          // sources.ts:21
    case realbooru = "realbooru"        // sources.ts:29
    case rule34 = "rule34"              // sources.ts:37
    case cumst = "cumst"                // sources.ts:45
    case redgifs = "redgifs"            // sources.ts:53
    case xvideos = "xvideos"            // sources.ts:61
    case xhamster = "xhamster"          // sources.ts:69
    case pornhub = "pornhub"            // sources.ts:77
    case sexcom = "sexcom"              // sources.ts:85 (hidden in the RN picker, still a valid ID)
    case hentaihaven = "hentaihaven"    // sources.ts:94
    case nhentai = "nhentai"            // sources.ts:103
}
