import Foundation

/// Normalized contents of a backup file, whichever format it used.
struct ParsedBackup: Equatable, Sendable {
    var favorites: [BooruPost] = []
    var recentViews: [BooruPost] = []
    var favoriteTags: [String] = []
    var blacklistedTags: [String] = []
    var searchHistory: [String] = []
    /// Favorites / recent views present in the file but not convertible to `BooruPost`.
    var unreadablePostCount = 0
}

enum BackupParseError: Error, Equatable {
    /// The bytes are not JSON.
    case invalidJSON
    /// The document's top level is not a JSON object.
    case unexpectedTopLevel
}

/// Reads the two shapes accepted by RN `BackupService.parseAnimeBoxesBackup`
/// (backupService.ts:234-284):
///
/// - **native BooruViewer export** — `favorites[]` / `recentViews[]` are `BooruPost` objects,
///   tag lists are plain string arrays.
/// - **legacy AnimeBoxes `.abbj`** — `favorites[].preview.url`, `favorite.tags` as a space
///   separated string, `searchHistory[].searchText`, `bannedTags[]` of strings or `{ name }`.
///
/// Entries are classified per favorite, exactly like RN: an entry with a string
/// `previewUrl` / `sampleUrl` / `originalUrl` is a native post, otherwise it is mapped as an
/// AnimeBoxes favorite (backupService.ts:142-149, 241-244).
enum AnimeBoxesParser {
    /// `now` supplies `createdAt` for AnimeBoxes entries with no `dateAdded`, like RN's
    /// `new Date().toISOString()` fallback (backupService.ts:134).
    static func parse(data: Data, now: Date = Date()) throws -> ParsedBackup {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BackupParseError.unexpectedTopLevel
            }
            root = object
        } catch let error as BackupParseError {
            throw error
        } catch {
            throw BackupParseError.invalidJSON
        }

        var parsed = ParsedBackup()

        for entry in root["favorites"] as? [Any] ?? [] {
            guard let object = entry as? [String: Any] else {
                parsed.unreadablePostCount += 1
                continue
            }
            if isBooruPostShape(object) {
                // Native entry: unknown `sourceId` strings are dropped instead of guessed.
                guard let post = nativePost(object) else {
                    parsed.unreadablePostCount += 1
                    continue
                }
                parsed.favorites.append(post)
            } else {
                parsed.favorites.append(animeBoxesPost(object, now: now))
            }
        }

        // RN only accepts native BooruPost shapes for recent views (backupService.ts:272-275).
        for entry in root["recentViews"] as? [Any] ?? [] {
            guard let object = entry as? [String: Any], let post = nativePost(object) else {
                parsed.unreadablePostCount += 1
                continue
            }
            parsed.recentViews.append(post)
        }

        // Search history is shared by both formats: plain strings or `{ searchText, starred }`.
        // RN also folds every string entry into the starred tags (backupService.ts:249-256).
        var history: [String] = []
        var starred: [String] = []
        for entry in root["searchHistory"] as? [Any] ?? [] {
            if let text = entry as? String {
                let cleaned = cleanText(text)
                guard !cleaned.isEmpty else { continue }
                history.append(cleaned)
                starred.append(cleaned)
            } else if let object = entry as? [String: Any],
                      let text = object["searchText"] as? String {
                let cleaned = cleanText(text)
                guard !cleaned.isEmpty else { continue }
                history.append(cleaned)
                if object["starred"] as? Bool == true {
                    starred.append(cleaned)
                }
            }
        }

        let ownFavoriteTags = stringList(root["favoriteTags"]).map(cleanText).filter { !$0.isEmpty }
        let ownBlacklistedTags = stringList(root["blacklistedTags"]).map(cleanText).filter { !$0.isEmpty }

        let bannedTags = (root["bannedTags"] as? [Any] ?? []).compactMap { entry -> String? in
            if let name = entry as? String {
                return name
            }
            if let object = entry as? [String: Any], let name = object["name"] as? String {
                return name
            }
            return nil
        }.map(cleanText).filter { !$0.isEmpty }

        parsed.favoriteTags = unique(starred + ownFavoriteTags)
        parsed.blacklistedTags = unique(bannedTags + ownBlacklistedTags)
        parsed.searchHistory = unique(history)
        return parsed
    }

    // MARK: - Native posts

    /// backupService.ts:142-149.
    private static func isBooruPostShape(_ object: [String: Any]) -> Bool {
        for key in ["previewUrl", "sampleUrl", "originalUrl"] {
            if let value = object[key], value is String { return true }
        }
        return false
    }

    /// Decodes a native entry through `BooruPost`'s lenient decoder. Unknown `sourceId`
    /// strings fail here and the entry is reported as unreadable instead of guessed.
    private static func nativePost(_ object: [String: Any]) -> BooruPost? {
        guard isBooruPostShape(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(BooruPost.self, from: data)
    }

    // MARK: - AnimeBoxes favorites

    /// `mapAnimeBoxesFavoriteToBooruPost` (backupService.ts:17-136). Like RN, any object is
    /// mapped, with Gelbooru as the fallback source.
    private static func animeBoxesPost(_ favorite: [String: Any], now: Date) -> BooruPost {
        let preview = favorite["preview"] as? [String: Any]
        let sample = favorite["sample"] as? [String: Any]
        let file = favorite["file"] as? [String: Any]
        let jpeg = favorite["jpeg"] as? [String: Any]

        let ppostURL = nonEmpty(favorite["ppostUrl"] as? String)
        let inferred = ppostURL.flatMap(inferSourceFromPostURL)
            ?? nonEmpty(preview?["url"] as? String).flatMap(inferSourceFromPreviewURL)
            ?? (SourceID.gelbooru, "Gelbooru")
        let (sourceID, sourceName) = inferred

        let rawTags: [String]
        if let list = favorite["tags"] as? [String] {
            rawTags = list
        } else if let text = favorite["tags"] as? String {
            rawTags = text.components(separatedBy: .whitespacesAndNewlines)
        } else {
            rawTags = []
        }
        let tags = rawTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let fileURL = nonEmpty(file?["url"] as? String)
        let isVideo = file?["ext"] as? String == "mp4"
            || file?["ext"] as? String == "webm"
            || (fileURL.map { urlEndsWith($0, ".mp4", ".webm") } ?? false)
            || tags.contains("video")
            || tags.contains("mp4")
            || tags.contains("webm")
            || tags.contains("animated")

        let rawPreview = nonEmpty(preview?["url"] as? String)
            ?? nonEmpty(sample?["url"] as? String)
            ?? fileURL
            ?? ""
        let rawSample = nonEmpty(sample?["url"] as? String)
            ?? nonEmpty(jpeg?["url"] as? String)
            ?? fileURL
            ?? rawPreview
        let rawOriginal = fileURL
            ?? nonEmpty(jpeg?["url"] as? String)
            ?? rawSample

        let width = firstPositive(
            number(file?["width"]),
            number(jpeg?["width"]),
            number(sample?["width"]),
            number(preview?["width"])
        ).map { Int($0) } ?? 800
        let height = firstPositive(
            number(file?["height"]),
            number(jpeg?["height"]),
            number(sample?["height"]),
            number(preview?["height"])
        ).map { Int($0) } ?? 1000
        let aspectRatio = width > 0 && height > 0 ? Double(width) / Double(height) : 0.75

        let ratingText = (favorite["rating"] as? String)?.lowercased() ?? ""
        let rating: PostRating
        switch ratingText {
        case "explicit", "e":
            rating = .explicit
        case "questionable", "q", "sensitive":
            rating = .questionable
        default:
            rating = .safe
        }

        let rawID = scalarString(favorite["ppostId"])
            ?? nonEmpty(favorite["md5"] as? String)
            ?? String(UUID().uuidString.lowercased().prefix(8))
        let id = "\(sourceID.rawValue)_\(rawID)"

        var fileExt = (file?["ext"] as? String ?? jpeg?["ext"] as? String)?.lowercased()
        if fileExt == nil, let fileURL {
            fileExt = pathExtension(of: fileURL)
        }
        if fileExt == nil, isVideo {
            fileExt = sourceID == .realbooru ? "webm" : "mp4"
        }
        let resolvedExt = fileExt ?? (isVideo ? "mp4" : "jpg")

        let sourceLink = nonEmpty(favorite["source"] as? String) ?? ppostURL

        return BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: sourceName,
            title: nil,
            previewURL: mediaURL(rawPreview),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: mediaURL(rawSample),
            originalURL: mediaURL(rawOriginal),
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            rating: rating,
            score: Int(number(favorite["score"]) ?? 0),
            favCount: 0,
            tags: BooruTagGroups(general: tags, meta: isVideo ? ["video"] : []),
            allTags: tags,
            sourceLink: sourceLink.flatMap { URL(string: $0) },
            fileExt: resolvedExt,
            fileSize: nil,
            createdAt: nonEmpty(favorite["dateAdded"] as? String) ?? BooruJSONSupport.isoString(now),
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    // MARK: - Source inference

    /// `mapAnimeBoxesFavoriteToBooruPost`'s `ppostUrl` branch (backupService.ts:21-41).
    private static func inferSourceFromPostURL(_ url: String) -> (SourceID, String)? {
        let lower = url.lowercased()
        if lower.contains("gelbooru.com") { return (.gelbooru, "Gelbooru") }
        if lower.contains("rule34.xxx") || lower.contains("rule34.us") { return (.rule34, "Rule34.xxx") }
        if lower.contains("danbooru") { return (.danbooru, "Danbooru") }
        if lower.contains("realbooru.com") { return (.realbooru, "Realbooru") }
        if lower.contains("yande.re") { return (.yandere, "Yande.re") }
        if lower.contains("cum.st") || lower.contains("coomer.st") { return (.cumst, "Cum.st") }
        return nil
    }

    /// The `preview.url` branch (backupService.ts:42-63); note the narrower host set.
    private static func inferSourceFromPreviewURL(_ url: String) -> (SourceID, String)? {
        let lower = url.lowercased()
        if lower.contains("gelbooru") { return (.gelbooru, "Gelbooru") }
        if lower.contains("rule34") { return (.rule34, "Rule34.xxx") }
        if lower.contains("donmai.us") { return (.danbooru, "Danbooru") }
        if lower.contains("realbooru") { return (.realbooru, "Realbooru") }
        if lower.contains("yande.re") { return (.yandere, "Yande.re") }
        if lower.contains("cum.st") { return (.cumst, "Cum.st") }
        return nil
    }

    // MARK: - Value helpers

    /// `tag.trim().toLowerCase().replace(/\s+/g, ' ')` (backupService.ts:247-248).
    private static func cleanText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Order-preserving dedupe, matching `Array.from(new Set(...))`.
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func firstPositive(_ values: Double?...) -> Double? {
        values.compactMap { $0 }.first { $0 > 0 }
    }

    /// String form of a JSON scalar id (`ppostId` may be a number or a string).
    private static func scalarString(_ value: Any?) -> String? {
        if let text = nonEmpty(value as? String) {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// Media URLs go through `MediaURLNormalizer` (RN `normalizeBooruMediaUrl`,
    /// backupService.ts:83-85). An unparseable string becomes nil; the lenient `BooruPost`
    /// decoder has the same contract.
    private static func mediaURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw) else { return nil }
        return MediaURLNormalizer.normalize(url)
    }

    /// `urlEndsWith` (guards.ts): extension checked before query/fragment, case-insensitive.
    private static func urlEndsWith(_ url: String, _ suffixes: String...) -> Bool {
        let clean = String(url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "").lowercased()
        return suffixes.contains { clean.hasSuffix($0) }
    }

    private static func pathExtension(of url: String) -> String? {
        let clean = String(url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "")
        guard let last = clean.split(separator: "/").last,
              let dot = last.lastIndex(of: ".") else {
            return nil
        }
        let ext = last[last.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }
}
