import Foundation

// MARK: - Shared helpers for the JSON booru adapters

/// Request, URL, decoding, and mapping helpers shared by the Gelbooru, Danbooru, and Moebooru adapters.
/// RN references: USER_AGENT (booruApi.ts:58), ensureAbsoluteUrl (booruApi.ts:109-119),
/// normalizeRating (booruApi.ts:121-128), asTagList (utils/guards.ts:18).
enum BooruJSONSupport {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    // MARK: Requests

    /// Builds `base/path?query`. Every name and value is percent-encoded strictly, so `+`, `&`, and `#` inside a tag cannot change the query.
    static func url(baseURL: String, path: String, items: [URLQueryItem]) -> URL? {
        let base = trimmedTrailingSlash(baseURL)
        let query = items.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
        return URL(string: base + "/" + path + "?" + query)
    }

    private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }

    /// GET request with the RN User-Agent and JSON Accept header (booruApi.ts:784-787).
    static func request(url: URL, referer: String? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let referer {
            urlRequest.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return urlRequest
    }

    /// Sends through the injected transport. Transport failures become `BooruError.network`; cancellation stays a `CancellationError`.
    static func send(_ request: URLRequest, http: any HTTPClientProtocol) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.data(for: request)
        } catch let error as BooruError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw BooruError.network(error.localizedDescription)
        }
    }

    /// Sends a GET and returns the body for 2xx responses. Other statuses throw through `statusError`.
    static func fetchData(baseURL: String, path: String, items: [URLQueryItem], referer: String? = nil, http: any HTTPClientProtocol) async throws -> Data {
        guard let requestURL = url(baseURL: baseURL, path: path, items: items) else {
            throw BooruError.network("Invalid request URL.")
        }
        let (data, response) = try await send(request(url: requestURL, referer: referer), http: http)
        guard isSuccess(response.statusCode) else {
            throw statusError(response.statusCode)
        }
        return data
    }

    static func isSuccess(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }

    /// Non-2xx mapping shared with the transport layer (`HTTPStatusMapping`, URLSessionHTTPClient.swift:102-112).
    static func statusError(_ statusCode: Int) -> BooruError {
        HTTPStatusMapping.error(forStatus: statusCode) ?? BooruError.http(status: statusCode)
    }

    /// `api_key` and `user_id` query items, appended only when both trimmed values are non-empty (booruApi.ts:761-767, 773-779).
    /// Values are never logged or copied into error messages.
    static func credentialItems(_ auth: ApiAuth?) -> [URLQueryItem]? {
        guard let auth else { return nil }
        let userID = auth.userID.booruTrimmed
        let apiKey = auth.apiKey.booruTrimmed
        guard !userID.isEmpty, !apiKey.isEmpty else { return nil }
        return [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "user_id", value: userID)]
    }

    // MARK: Decoding

    /// Decodes a body and turns any JSON or shape error into a short `BooruError.decoding`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, failure: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BooruError.decoding(failure)
        }
    }

    /// Runs one optional step. Failures become nil (RN swallows them and falls through, booruApi.ts:2295-2325, 2523-2526).
    /// Cancellation still propagates.
    static func tolerant<T>(_ body: () async throws -> T?) async throws -> T? {
        do {
            return try await body()
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: Mapping

    /// RN `ensureAbsoluteUrl` (booruApi.ts:109-119): absolute http(s) is kept, `//` gets https, and relative paths join the base.
    /// Empty input returns nil. RN would return the bare base URL here, which is never a valid media target.
    static func absoluteURL(_ raw: String?, baseURL: String) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.booruTrimmed
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }
        let path = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return URL(string: trimmedTrailingSlash(baseURL) + "/" + path)
    }

    /// RN `sourceLink: item.source || undefined` (booruApi.ts:873, 947, 1022).
    static func optionalURL(_ raw: String?) -> URL? {
        guard let raw, !raw.booruTrimmed.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// RN `normalizeRating` (booruApi.ts:121-128). Like RN, `general` and unknown values become `.safe`, so `.general` is never produced.
    static func rating(_ raw: String?) -> PostRating {
        switch (raw ?? "").lowercased() {
        case "questionable", "q": return .questionable
        case "explicit", "e": return .explicit
        default: return .safe
        }
    }

    /// JS `Array.from(new Set(values))`: keeps the first occurrence of each value.
    static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// JS `a || b || c` over strings: the first non-empty value, or "".
    static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// JS `x || fallback` for numeric fields: 0 and missing values use the fallback (booruApi.ts:847-848, 920-921, 995-996).
    static func orDefault(_ value: Int?, _ fallback: Int) -> Int {
        guard let value, value != 0 else { return fallback }
        return value
    }

    /// RN `width / height` with the 0.75 fallback (booruApi.ts:849, 922, 997).
    static func aspectRatio(width: Int, height: Int) -> Double {
        width > 0 && height > 0 ? Double(width) / Double(height) : 0.75
    }

    /// JS `Number(x)` for a finite double. Values outside Int range become nil.
    static func int(fromDouble value: Double) -> Int? {
        guard value.isFinite, abs(value) < 9.0e18 else { return nil }
        return Int(value)
    }

    /// ISO 8601 UTC with milliseconds, matching JS `Date.prototype.toISOString` (RN createdAt values).
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func isoString(unixSeconds: Int) -> String {
        isoString(Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    /// Parses the strings produced by `isoString`. Used by the Gelbooru lower-bound walk (booruApi.ts:722, 729).
    static func date(fromISO string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func trimmedTrailingSlash(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// Media-list page result. RN pages end when a page comes back empty (SearchScreen.tsx:381), so `hasMore` is `!posts.isEmpty`.
    static func page(_ posts: [BooruPost], requestedPage page: Int) -> PostPage {
        let hasMore = !posts.isEmpty
        return PostPage(posts: posts, nextPage: hasMore ? page + 1 : nil, hasMore: hasMore)
    }

    /// Media fields for `BooruSource.resolveMedia`. The image, placeholder, and video choices come from the shared media selectors.
    static func resolvedMedia(for post: BooruPost, quality: ImageQuality) -> ResolvedMedia {
        let video = VideoCandidateSelector.videoCandidates(for: post).first
        return ResolvedMedia(
            imageURL: ImageQualityResolver.imageURL(for: post, quality: quality),
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }
}

// MARK: - Lenient containers

/// One JSON value kept only when it is a string (RN `filter(t => typeof t === 'string')`, utils/guards.ts:18).
struct BooruLossyString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// A JSON array decoded element by element. Malformed elements are dropped, and a non-array value yields no elements.
/// Invalid JSON still fails in `JSONDecoder` before this initializer runs.
struct BooruLenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        let wrapped = (try? decoder.singleValueContainer().decode([FailableDecodable<Element>].self)) ?? []
        elements = wrapped.compactMap { $0.value }
    }
}

/// A JSON array or a single JSON object (RN `post` / `posts` / `tag` shapes, booruApi.ts:821-832).
/// Any other JSON type throws, so `try?` callers can fall through to the next key.
struct BooruLenientList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([FailableDecodable<Element>].self) {
            elements = array.compactMap { $0.value }
            return
        }
        // Throws for scalars; a malformed object yields an empty list.
        _ = try decoder.container(keyedBy: BooruDynamicKey.self)
        if let single = try? Element(from: decoder) {
            elements = [single]
        } else {
            elements = []
        }
    }
}

/// Open-ended coding key, used only to test whether a JSON value is an object.
struct BooruDynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    /// JSON string only. Other JSON types yield nil (RN `typeof x === 'string'`).
    func booruString(_ key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }

    /// JSON string, or JSON integer rendered as a string. Booru ids may arrive as numbers (RN `String(item.id)`).
    func booruIDString(_ key: Key) -> String? {
        if let text = booruString(key) {
            return text
        }
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    /// RN `Number(x)` / `parseInt`: JSON integer, JSON number, or numeric string. Other types yield nil.
    func booruInt(_ key: Key) -> Int? {
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return BooruJSONSupport.int(fromDouble: number)
        }
        if let text = booruString(key) {
            let trimmed = text.booruTrimmed
            if let number = Int(trimmed) {
                return number
            }
            if let number = Double(trimmed) {
                return BooruJSONSupport.int(fromDouble: number)
            }
        }
        return nil
    }

    /// RN `asTagList` (utils/guards.ts:18): a whitespace-separated string, or an array that keeps only string items.
    func booruTagList(_ key: Key) -> [String] {
        if let text = booruString(key) {
            return text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        }
        if let items = try? decodeIfPresent([BooruLossyString].self, forKey: key) {
            return items.compactMap { $0.value }
        }
        return []
    }
}

extension String {
    /// JS `trim()`: strips surrounding whitespace and newlines.
    var booruTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Gelbooru / Rule34 DAPI DTOs

/// One DAPI post from `index.php?page=dapi&s=post&q=index&json=1` (RN fields: booruApi.ts:834-875).
/// Only a missing or empty `id` makes the element malformed. Other fields with the wrong type become nil.
struct GelbooruPostDTO: Decodable {
    let id: String
    let score: Int?
    let width: Int?
    let height: Int?
    let rating: String?
    let source: String?
    /// Unix seconds of the last change. RN uses it for `favCount` and `createdAt` (booruApi.ts:864, 875).
    let change: Int?
    let directory: String?
    let image: String?
    let tags: [String]
    let fileURL: String?
    let previewURL: String?
    let sampleURL: String?

    enum CodingKeys: String, CodingKey {
        case id, score, width, height, rating, source, change, directory, image, tags
        case fileURL = "file_url"
        case previewURL = "preview_url"
        case sampleURL = "sample_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = c.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: c, debugDescription: "Post id is missing.")
        }
        id = decodedID
        score = c.booruInt(.score)
        width = c.booruInt(.width)
        height = c.booruInt(.height)
        rating = c.booruString(.rating)
        source = c.booruString(.source)
        change = c.booruInt(.change)
        directory = c.booruIDString(.directory)
        image = c.booruString(.image)
        tags = c.booruTagList(.tags)
        fileURL = c.booruString(.fileURL)
        previewURL = c.booruString(.previewURL)
        sampleURL = c.booruString(.sampleURL)
    }
}

/// Top-level DAPI post body (booruApi.ts:806-832). Only invalid JSON fails here; other shapes become empty results.
struct GelbooruDAPIResponse: Decodable {
    /// The body when it is a bare JSON string. Rule34 sends auth failures this way (booruApi.ts:814-815).
    let text: String?
    /// `success` on object bodies (booruApi.ts:814).
    let success: Bool?
    /// `message` on object bodies (booruApi.ts:815).
    let message: String?
    /// Posts from a top-level array, a `post` key, or a `posts` key (booruApi.ts:821-832).
    let posts: [GelbooruPostDTO]

    enum CodingKeys: String, CodingKey {
        case success, message, post, posts
    }

    init(from decoder: Decoder) throws {
        if let body = try? decoder.singleValueContainer().decode(String.self) {
            text = body
            success = nil
            message = nil
            posts = []
            return
        }
        if let array = try? decoder.singleValueContainer().decode([FailableDecodable<GelbooruPostDTO>].self) {
            text = nil
            success = nil
            message = nil
            posts = array.compactMap { $0.value }
            return
        }
        text = nil
        guard let keyed = try? decoder.container(keyedBy: CodingKeys.self) else {
            success = nil
            message = nil
            posts = []
            return
        }
        success = try? keyed.decodeIfPresent(Bool.self, forKey: .success)
        message = keyed.booruString(.message)
        if let list = try? keyed.decodeIfPresent(BooruLenientList<GelbooruPostDTO>.self, forKey: .post) {
            posts = list.elements
        } else if let list = try? keyed.decodeIfPresent(BooruLenientList<GelbooruPostDTO>.self, forKey: .posts) {
            posts = list.elements
        } else {
            posts = []
        }
    }
}

/// One tag from the DAPI tag list (`page=dapi&s=tag&q=index&json=1`, booruApi.ts:2327-2381).
struct GelbooruTagDTO: Decodable {
    let name: String?
    /// RN `type`: 1 artist, 3 copyright, 4 character, 5 meta (booruApi.ts:2366-2371).
    let type: Int?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case name, type, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.booruString(.name)
        type = c.booruInt(.type)
        count = c.booruInt(.count)
    }
}

/// DAPI tag list body: a top-level array, or a `tag` key holding an array or object (booruApi.ts:2352-2360).
struct GelbooruTagListResponse: Decodable {
    let tags: [GelbooruTagDTO]

    enum CodingKeys: String, CodingKey {
        case tag
    }

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([FailableDecodable<GelbooruTagDTO>].self) {
            tags = array.compactMap { $0.value }
            return
        }
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let list = try? keyed.decodeIfPresent(BooruLenientList<GelbooruTagDTO>.self, forKey: .tag) {
            tags = list.elements
        } else {
            tags = []
        }
    }
}

/// One entry from `page=autocomplete2&type=tag_query` (booruApi.ts:2302-2320).
struct GelbooruAutocompleteDTO: Decodable {
    let value: String?
    let label: String?
    /// `artist`, `character`, `copyright`, `metadata`, or other.
    let category: String?
    let postCount: Int?

    enum CodingKeys: String, CodingKey {
        case value, label, category
        case postCount = "post_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.booruString(.value)
        label = c.booruString(.label)
        category = c.booruString(.category)
        postCount = c.booruInt(.postCount)
    }
}

/// One entry from `autocomplete.php?q=`, used by Rule34 and Realbooru (booruApi.ts:2423-2434).
struct GelbooruAutocompletePHPDTO: Decodable {
    let value: String?
    /// Tag label with the post count in parentheses, e.g. `cat (123)`.
    let label: String?

    enum CodingKeys: String, CodingKey {
        case value, label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.booruString(.value)
        label = c.booruString(.label)
    }
}

// MARK: - Danbooru DTOs

/// One post from `posts.json` (booruApi.ts:913-951).
struct DanbooruPostDTO: Decodable {
    let id: String
    let fileURL: String?
    let largeFileURL: String?
    let previewFileURL: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let rating: String?
    let score: Int?
    let favCount: Int?
    let source: String?
    let fileExt: String?
    let fileSize: Int?
    let createdAt: String?
    let tagString: [String]
    let tagStringArtist: [String]
    let tagStringCharacter: [String]
    let tagStringCopyright: [String]
    let tagStringGeneral: [String]
    let tagStringMeta: [String]

    enum CodingKeys: String, CodingKey {
        case id, rating, score, source
        case fileURL = "file_url"
        case largeFileURL = "large_file_url"
        case previewFileURL = "preview_file_url"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case favCount = "fav_count"
        case fileExt = "file_ext"
        case fileSize = "file_size"
        case createdAt = "created_at"
        case tagString = "tag_string"
        case tagStringArtist = "tag_string_artist"
        case tagStringCharacter = "tag_string_character"
        case tagStringCopyright = "tag_string_copyright"
        case tagStringGeneral = "tag_string_general"
        case tagStringMeta = "tag_string_meta"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = c.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: c, debugDescription: "Post id is missing.")
        }
        id = decodedID
        fileURL = c.booruString(.fileURL)
        largeFileURL = c.booruString(.largeFileURL)
        previewFileURL = c.booruString(.previewFileURL)
        imageWidth = c.booruInt(.imageWidth)
        imageHeight = c.booruInt(.imageHeight)
        rating = c.booruString(.rating)
        score = c.booruInt(.score)
        favCount = c.booruInt(.favCount)
        source = c.booruString(.source)
        fileExt = c.booruString(.fileExt)
        fileSize = c.booruInt(.fileSize)
        createdAt = c.booruString(.createdAt)
        tagString = c.booruTagList(.tagString)
        tagStringArtist = c.booruTagList(.tagStringArtist)
        tagStringCharacter = c.booruTagList(.tagStringCharacter)
        tagStringCopyright = c.booruTagList(.tagStringCopyright)
        tagStringGeneral = c.booruTagList(.tagStringGeneral)
        tagStringMeta = c.booruTagList(.tagStringMeta)
    }
}

/// One tag from `tags.json` (booruApi.ts:2499-2505).
struct DanbooruTagDTO: Decodable {
    let name: String?
    /// Numeric category only, matching RN's strict `switch` (booruApi.ts:95-106).
    let category: Int?
    let postCount: Int?

    enum CodingKeys: String, CodingKey {
        case name, category
        case postCount = "post_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.booruString(.name)
        category = try? c.decodeIfPresent(Int.self, forKey: .category)
        postCount = c.booruInt(.postCount)
    }
}

// MARK: - Moebooru DTOs

/// One post from `post.json` (booruApi.ts:988-1026). `created_at` is unix seconds.
struct MoebooruPostDTO: Decodable {
    let id: String
    let previewURL: String?
    let sampleURL: String?
    let fileURL: String?
    let width: Int?
    let height: Int?
    let rating: String?
    let score: Int?
    let source: String?
    let fileExt: String?
    let fileSize: Int?
    let createdAt: Int?
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, width, height, rating, score, source, tags
        case previewURL = "preview_url"
        case sampleURL = "sample_url"
        case fileURL = "file_url"
        case fileExt = "file_ext"
        case fileSize = "file_size"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = c.booruIDString(.id), !decodedID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.id, in: c, debugDescription: "Post id is missing.")
        }
        id = decodedID
        previewURL = c.booruString(.previewURL)
        sampleURL = c.booruString(.sampleURL)
        fileURL = c.booruString(.fileURL)
        width = c.booruInt(.width)
        height = c.booruInt(.height)
        rating = c.booruString(.rating)
        score = c.booruInt(.score)
        source = c.booruString(.source)
        fileExt = c.booruString(.fileExt)
        fileSize = c.booruInt(.fileSize)
        createdAt = c.booruInt(.createdAt)
        tags = c.booruTagList(.tags)
    }
}

/// One tag from `tag.json` (booruApi.ts:2507-2521).
struct MoebooruTagDTO: Decodable {
    let name: String?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case name, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.booruString(.name)
        count = c.booruInt(.count)
    }
}
