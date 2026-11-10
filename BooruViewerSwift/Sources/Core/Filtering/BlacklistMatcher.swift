import Foundation

/// Blacklist matching for loaded posts. Mirrors RN `filterBlacklistedPosts` (src/services/booruApi.ts:385-464).
/// Matching ignores case, and `_` and spaces are treated as the same character (booruApi.ts:404-421).
/// The caller decides whether to apply it. The source adapters return unfiltered posts.
struct BlacklistMatcher: Sendable {
    /// Lookup set. Each blacklist entry is stored in three forms: trimmed lowercase, whitespace runs as `_`, and `_` as a space (booruApi.ts:404-412).
    private let entries: Set<String>

    init(tags: [String]) {
        var set = Set<String>()
        for tag in tags {
            let lower = Self.normalized(tag)
            guard !lower.isEmpty else { continue }
            set.insert(lower)
            set.insert(Self.replacingWhitespaceRuns(in: lower, with: "_"))
            set.insert(lower.replacingOccurrences(of: "_", with: " "))
        }
        entries = set
    }

    /// True when the post has a blacklisted tag, niche, or artist (booruApi.ts:424-462).
    func isBlocked(_ post: BooruPost) -> Bool {
        guard !entries.isEmpty else { return false }

        // 1. allTags (booruApi.ts:425-430).
        if post.allTags.contains(where: { matchesTag($0) }) {
            return true
        }

        // 1b. Niches match as `niche:<id>` (booruApi.ts:432-438).
        for niche in post.niches ?? [] {
            let nicheID = Self.normalized(niche)
            if !nicheID.isEmpty, entries.contains("niche:" + nicheID) {
                return true
            }
        }

        // 1c. Artists match as `user:<name>` (booruApi.ts:440-446).
        for artist in post.tags.artist {
            let name = Self.normalized(artist)
            if !name.isEmpty, entries.contains("user:" + name) {
                return true
            }
        }

        // 2. Tag groups: artist, character, copyright, general, meta (booruApi.ts:448-459).
        let groups = [post.tags.artist, post.tags.character, post.tags.copyright, post.tags.general, post.tags.meta]
        for group in groups {
            if group.contains(where: { matchesTag($0) }) {
                return true
            }
        }
        return false
    }

    /// RN `checkTag` (booruApi.ts:414-422). The tag matches when any of its three forms is in the set.
    private func matchesTag(_ tag: String) -> Bool {
        let lower = Self.normalized(tag)
        return entries.contains(lower)
            || entries.contains(Self.replacingWhitespaceRuns(in: lower, with: "_"))
            || entries.contains(lower.replacingOccurrences(of: "_", with: " "))
    }

    /// RN `trim().toLowerCase()`.
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// RN `replace(/\s+/g, replacement)`: each run of whitespace becomes one replacement.
    private static func replacingWhitespaceRuns(in value: String, with replacement: String) -> String {
        var result = ""
        var inRun = false
        for character in value {
            if character.isWhitespace {
                if !inRun {
                    result += replacement
                }
                inRun = true
            } else {
                result.append(character)
                inRun = false
            }
        }
        return result
    }
}
