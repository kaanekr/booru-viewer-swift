import Foundation

/// Shared pure helpers for the regex-based HTML scrapers (Realbooru, XVideos, XHamster, Sex.com).
/// Scanning uses NSRegularExpression over the page text. No third-party HTML parser is used.
enum HTMLScanner {
    /// A block that begins at a regex marker, such as one listing card.
    struct Section {
        /// Capture groups of the marker match. Index 0 is the whole match.
        let captures: [String]
        /// Raw HTML after the marker, up to the next marker or the end of the page.
        let body: String
    }

    /// HTML character reference: named (`&amp;`), decimal (`&#39;`), or hex (`&#x27;`).
    private static let entityPattern = #"&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);"#
    /// Markup comment, possibly spanning several lines.
    private static let commentPattern = #"<!--[\s\S]*?-->"#
    /// Any markup tag.
    private static let tagPattern = #"<[^>]+>"#
    /// Media file extension at the end of a path (case-insensitive).
    private static let mediaExtensionPattern = #"\.(mp4|webm|mov|m4v|png|jpe?g|gif)$"#
    /// Number with an optional K/M/B suffix, such as `2.4K`.
    private static let abbreviatedCountPattern = #"(\d+(?:\.\d+)?)\s*([KkMmBb])?"#
    /// The words `view` and `views`, removed before a count is read.
    private static let viewsWordPattern = #"views?"#
    /// Keeps an attribute name from matching the tail of a longer name (`src` must not match `data-src`).
    private static let attributeNameLookbehind = #"(?<![A-Za-z0-9_:-])"#

    /// Named HTML entities that the four sources emit.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    // MARK: - Regex plumbing

    /// Compiles a pattern constant. A malformed pattern yields nil, so a parse finds nothing instead of crashing.
    static func compile(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Capture groups of the first match (index 0 is the whole match). Groups that did not participate are "".
    static func captures(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String]? {
        guard let regex = compile(pattern, caseInsensitive: caseInsensitive) else { return nil }
        let ns = NSString(string: text)
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return allGroups(of: match, in: ns)
    }

    /// Capture group 1 of the first match.
    static func firstCapture(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        guard let groups = captures(pattern, in: text, caseInsensitive: caseInsensitive), groups.count > 1 else {
            return nil
        }
        return groups[1]
    }

    /// Capture groups of every match, in page order. Index 0 of each entry is the whole match.
    static func allCaptures(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [[String]] {
        guard let regex = compile(pattern, caseInsensitive: caseInsensitive) else { return [] }
        let ns = NSString(string: text)
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map {
            allGroups(of: $0, in: ns)
        }
    }

    /// Capture group 1 of every match, in page order. Used where a page lists the same item several times.
    static func allFirstCaptures(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String] {
        guard let regex = compile(pattern, caseInsensitive: caseInsensitive) else { return [] }
        let ns = NSString(string: text)
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// Splits `html` at every match of `pattern`. Each section's body runs up to the next match.
    static func sections(_ pattern: String, in html: String, caseInsensitive: Bool = false) -> [Section] {
        guard let regex = compile(pattern, caseInsensitive: caseInsensitive) else { return [] }
        let ns = NSString(string: html)
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [Section] = []
        for (index, match) in matches.enumerated() {
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = bodyEnd > bodyStart
                ? ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                : ""
            result.append(Section(captures: allGroups(of: match, in: ns), body: body))
        }
        return result
    }

    /// Splits `text` at every match of `pattern` and returns the pieces between matches.
    static func split(_ text: String, by pattern: String) -> [String] {
        guard let regex = compile(pattern) else { return [text] }
        let ns = NSString(string: text)
        var pieces: [String] = []
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces
    }

    /// Replaces every match of `pattern`. `template` may use `$1`-style group references.
    static func replace(_ pattern: String, in text: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = compile(pattern, caseInsensitive: caseInsensitive) else { return text }
        let ns = NSString(string: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }

    /// First opening tag with the given element name (for example `img` or `a`), including its attributes.
    static func firstTag(_ name: String, in html: String) -> String? {
        // `<name\b[^>]*>`: the word boundary keeps `<a` from matching `<abbr`.
        let pattern = "<" + NSRegularExpression.escapedPattern(for: name) + #"\b[^>]*>"#
        return captures(pattern, in: html, caseInsensitive: true)?[0]
    }

    /// Entity-decoded value of attribute `name` inside `tag`. Accepts double or single quotes.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = attributeNameLookbehind
            + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let groups = captures(pattern, in: tag, caseInsensitive: true) else { return nil }
        return decodeEntities(groups[1].isEmpty ? groups[2] : groups[1])
    }

    // MARK: - Text helpers

    /// Decodes HTML character references in one pass, so `&amp;lt;` becomes `&lt;` and not `<`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = compile(entityPattern) else { return text }
        let ns = NSString(string: text)
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            output += decodedEntity(name) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// Unescapes a value taken from inline script or data attributes: `\u002f`, `\/`, `\u0026`, `&amp;` (RN xvideos.ts:105-112).
    static func decodeScriptValue(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\\u002f", with: "/", options: .caseInsensitive)
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        return trim(value)
    }

    /// Removes comments and tags, then trims (RN xhamster.ts:307-313).
    static func stripTags(_ html: String) -> String {
        let withoutComments = replace(commentPattern, in: html, with: "")
        return trim(replace(tagPattern, in: withoutComments, with: ""))
    }

    /// Trims spaces, tabs, and newlines.
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on whitespace and drops empty pieces.
    static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// Removes duplicates and keeps the first occurrence of each value.
    static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    /// Reads a count such as `2.4K`, `1,234`, `125K views`, or `<1K` (RN sexcom.ts:42-52, xhamster.ts:140-153).
    static func parseCount(_ raw: String) -> Int {
        let plain = decodeEntities(raw).replacingOccurrences(of: ",", with: "")
        let cleaned = replace(viewsWordPattern, in: plain, with: "", caseInsensitive: true)
        guard let groups = captures(abbreviatedCountPattern, in: cleaned), let value = Double(groups[1]) else {
            return 0
        }
        let multiplier: Double
        switch groups[2].uppercased() {
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "B": multiplier = 1_000_000_000
        default: multiplier = 1
        }
        let product = (value * multiplier).rounded()
        // Clamp before converting: a hostile count must not overflow Int and trap.
        guard product.isFinite else { return 0 }
        return Int(min(product, 9_000_000_000_000_000_000))
    }

    /// Lowercase media extension of a URL path, ignoring the query string (RN booruApi.ts:1122). `jpeg` becomes `jpg`.
    static func mediaExtension(in raw: String) -> String? {
        let path = raw.components(separatedBy: "?")[0]
        guard let ext = firstCapture(mediaExtensionPattern, in: path, caseInsensitive: true)?.lowercased() else {
            return nil
        }
        return ext == "jpeg" ? "jpg" : ext
    }

    // MARK: - URLs and requests

    /// Resolves a scraped URL against `base` like RN `ensureAbsoluteUrl` (booruApi.ts:109-119), plus `//` handling.
    /// Empty values and `data:` URLs return nil.
    static func absoluteURL(_ raw: String, base: String) -> URL? {
        let value = trim(raw)
        let lower = value.lowercased()
        guard !value.isEmpty, !lower.hasPrefix("data:") else { return nil }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: value) }
        if value.hasPrefix("//") { return URL(string: "https:" + value) }
        if value.hasPrefix("/") { return URL(string: root + value) }
        return URL(string: root + "/" + value)
    }

    /// Encodes a value like `URLSearchParams` (space becomes `+`), as RN builds list query strings.
    static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    /// Encodes a value like `encodeURIComponent` (space becomes `%20`), as RN builds path and search segments.
    static func componentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Search tokens in RN order: query text, then `filter.tags`, then `extra` (booruApi.ts:253-258).
    static func searchTokens(for query: SearchQuery, extra: [String] = []) -> [String] {
        uniqued(tokens(query.tags) + query.filter.tags.flatMap { tokens($0) } + extra.flatMap { tokens($0) })
    }

    /// Plain-text user filter for sources without a `user:` syntax (booruApi.ts:267-271).
    static func plainUserTokens(_ filter: SearchFilterConfig) -> [String] {
        guard let user = filter.user.map({ trim($0) }), !user.isEmpty else { return [] }
        return tokens(user)
    }

    /// Browser-like GET request for an HTML page, with the same headers the RN fetches send.
    static func htmlRequest(_ url: URL, userAgent: String, referer: String, acceptLanguage: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if let acceptLanguage {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
        return request
    }

    /// Sends `request` and returns the body as text. Non-2xx responses throw a `BooruError`.
    static func fetchHTML(_ request: URLRequest, client: any HTTPClientProtocol) async throws -> String {
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw httpError(for: response.statusCode)
        }
        return text(from: data)
    }

    /// Decodes a response body. Invalid UTF-8 bytes become replacement characters, so a bad byte never fails a page.
    static func text(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Maps a failed HTTP status to the shared error type. 429 is a rate limit.
    static func httpError(for status: Int) -> BooruError {
        status == 429 ? .rateLimited : .http(status: status)
    }

    /// ISO-8601 timestamp with milliseconds, matching RN `new Date().toISOString()`.
    static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Private

    private static func allGroups(of match: NSTextCheckingResult, in ns: NSString) -> [String] {
        (0..<match.numberOfRanges).map { (index: Int) -> String in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static func decodedEntity(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return scalarString(Int(name.dropFirst(2), radix: 16))
        }
        if name.hasPrefix("#") {
            return scalarString(Int(name.dropFirst()))
        }
        return namedEntities[name]
    }

    private static func scalarString(_ value: Int?) -> String? {
        guard let value, value >= 0, value <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(value)) else {
            return nil
        }
        return String(Character(scalar))
    }
}
