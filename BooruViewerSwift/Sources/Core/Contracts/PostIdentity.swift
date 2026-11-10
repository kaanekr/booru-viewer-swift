import Foundation

/// Sources whose numeric IDs may carry an old "<source>_" prefix (postIdentity.ts:4).
private let numericBooruSourceIDs: Set<SourceID> = [.danbooru, .gelbooru, .rule34, .realbooru, .yandere]

/// Source-qualified dedupe key. Mirrors RN `getPostKey` (postIdentity.ts:7-15): `JSON.stringify([source, id])`.
/// Accepts old AnimeBoxes numeric ID prefixes without rewriting backups.
func postKey(_ post: BooruPost) -> String {
    let source = post.sourceID.rawValue
    var id = post.id
    let prefix = source + "_"
    if numericBooruSourceIDs.contains(post.sourceID), id.hasPrefix(prefix) {
        let digits = id.dropFirst(prefix.count)
        if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            id = String(digits)
        }
    }
    return "[" + jsonStringLiteral(source) + "," + jsonStringLiteral(id) + "]"
}

/// Media-level dedupe key. Mirrors the RN `mediaKey` in backupService.ts:309:
/// `JSON.stringify([sourceId, originalUrl || sampleUrl || previewUrl])`. A missing URL serializes as `null`.
func mediaKey(_ post: BooruPost) -> String {
    let media = (post.originalURL ?? post.sampleURL ?? post.previewURL)?.absoluteString
    return "[" + jsonStringLiteral(post.sourceID.rawValue) + "," + (media.map(jsonStringLiteral) ?? "null") + "]"
}

/// Quotes and escapes a string the way `JSON.stringify` does for the characters that can appear here.
private func jsonStringLiteral(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
