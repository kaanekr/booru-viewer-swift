import Foundation

/// WebM → MP4 availability probe, mirroring RN `getMp4UpgradeUrl` and
/// `checkMp4UpgradeAvailable` (src/utils/media.ts:721-793).
///
/// Deviations from RN, both deliberate:
/// - The in-memory result cache (media.ts:738, 757-760, 791) is omitted so this stays
///   a stateless rule; callers may memoize per URL if they need RN's "never checked twice".
/// - The proxy fallback (`getMediaUrl` + `getMediaHeaders` + `proxyService.fetchWithFallback`,
///   media.ts:769-778) is not part of this layer: `http` is the transport seam.
enum MP4Upgrade {
    /// HEAD timeout, RN `timeoutMs = 6000` (media.ts:748).
    static let timeoutSeconds: TimeInterval = 6

    /// Returns the `.mp4` sibling of `webm` when a HEAD request answers 200-299
    /// (media.ts:746-793), otherwise nil.
    static func upgradedURL(for webm: URL, http: HTTPClientProtocol) async -> URL? {
        guard let mp4 = mp4CandidateURL(for: webm) else { return nil }

        var request = URLRequest(url: mp4)
        request.httpMethod = "HEAD" // media.ts:775
        request.timeoutInterval = timeoutSeconds
        for (name, value) in MediaRequestConfiguration.headers(for: mp4) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (_, response) = try await http.data(for: request)
            return (200...299).contains(response.statusCode) ? mp4 : nil // media.ts:780-783
        } catch {
            return nil // media.ts:784-785
        }
    }

    /// Pure URL derivation of `getMp4UpgradeUrl` (media.ts:725-736):
    /// the `.webm` extension must terminate the path; query string and fragment are
    /// preserved; anything else returns nil.
    static func mp4CandidateURL(for webm: URL) -> URL? {
        let raw = webm.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // RN regex `^([^?#]+)\.webm([?#].*)?$`: the path ends at the first '?' or '#'.
        let pathEnd = raw.firstIndex { $0 == "?" || $0 == "#" } ?? raw.endIndex
        let path = raw[..<pathEnd]
        let suffix = raw[pathEnd...]
        guard path.lowercased().hasSuffix(".webm") else { return nil }

        // `[^?#]+` must have matched at least one character before ".webm".
        let base = path.dropLast(".webm".count)
        guard !base.isEmpty else { return nil }

        let upgraded = String(base) + ".mp4" + String(suffix)
        return URL(string: upgraded)
    }
}
