import Foundation

/// One reachability probe. `target` is "<name> (direct)" or "<name> (relay)".
/// `reachable` means an HTTP response of any status was received; `latencyMs` is nil when unreachable or not configured.
struct NetworkDiagnosticResult: Sendable, Equatable {
    let target: String
    let reachable: Bool
    let latencyMs: Int?
}

/// Parallel reachability probes mirroring networkDiagnostics.ts (direct and relay legs for each target).
enum NetworkDiagnostics {
    private struct Target: Sendable {
        let name: String
        let url: String
        let userAgent: String
        let isRedGifs: Bool
    }

    private struct Job: Sendable {
        let label: String
        /// Nil when the relay leg has no valid worker: reported as unreachable without a request.
        let url: URL?
        let headers: [String: String]
    }

    /// networkDiagnostics.ts:14-23, same order. Public hostnames only; no worker URL or key is included.
    private static let iPhoneUserAgent = ProxyRelay.neutralUserAgent
    private static let targets: [Target] = [
        Target(name: "Pornhub API", url: "https://www.pornhub.com/webmasters/search?search=test&page=1&thumbsize=medium", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "Pornhub", url: "https://www.pornhub.com/video?o=mv&page=1", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "XHamster", url: "https://xhamster.com/newest/1", userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", isRedGifs: false),
        Target(name: "XVideos", url: "https://www.xvideos.com/new/1", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "Sex.com", url: "https://www.sex.com/en/videos", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "HentaiHaven", url: "https://hentaihaven.xxx/browse/trending/", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "Sex.com CDN", url: "https://videos2.sex.com/1038553/preview_240p.mp4", userAgent: iPhoneUserAgent, isRedGifs: false),
        Target(name: "RedGifs", url: "https://api.redgifs.com/v2/gifs/search?type=g&order=trending&count=1&page=1", userAgent: iPhoneUserAgent, isRedGifs: true),
    ]

    /// Runs all probes in parallel and returns results in target order (networkDiagnostics.ts:46-57).
    /// Pass a transport without retry, such as `URLSessionHTTPClient.makeProbeClient()`, and do not pass a ProxyAwareHTTPClient:
    /// the direct and relay legs must each be a single raw request. Each request has the transport's 12 s timeout.
    static func run(proxy: ProxyConfig, http: HTTPClientProtocol) async -> [NetworkDiagnosticResult] {
        let worker = ProxyRelay.normalizedWorkerURL(proxy.workerURL)
        var jobs: [Job] = []
        for target in targets {
            guard let url = URL(string: target.url) else { continue }
            let headers = NetworkDiagnostics.probeHeaders(for: target, url: url)
            jobs.append(Job(label: "\(target.name) (direct)", url: url, headers: headers))
            // networkDiagnostics.ts:54: the relay probe runs whether or not the toggle is on.
            let relay = worker.flatMap { ProxyRelay.relayURL(for: url, workerURL: $0) }
            jobs.append(Job(label: "\(target.name) (relay)", url: relay, headers: ProxyRelay.workerHeaders(for: url, headers: headers)))
        }

        return await withTaskGroup(of: (Int, NetworkDiagnosticResult).self, returning: [NetworkDiagnosticResult].self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    let result = await NetworkDiagnostics.probe(job, http: http)
                    return (index, result)
                }
            }
            var results = [NetworkDiagnosticResult?](repeating: nil, count: jobs.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }
    }

    /// networkDiagnostics.ts:47-51: User-Agent, Referer set to the target origin; RedGifs also sends Origin and its own Referer.
    private static func probeHeaders(for target: Target, url: URL) -> [String: String] {
        let origin = "\(url.scheme ?? "https")://\(url.host ?? "")"
        var headers = ["User-Agent": target.userAgent, "Referer": "\(origin)/"]
        if target.isRedGifs {
            headers["Origin"] = "https://www.redgifs.com"
            headers["Referer"] = "https://www.redgifs.com/"
        }
        return headers
    }

    private static func probe(_ job: Job, http: HTTPClientProtocol) async -> NetworkDiagnosticResult {
        guard let url = job.url else {
            return NetworkDiagnosticResult(target: job.label, reachable: false, latencyMs: nil)
        }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = job.headers
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await http.data(for: request)
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return NetworkDiagnosticResult(target: job.label, reachable: true, latencyMs: Int(elapsedMs.rounded()))
        } catch {
            return NetworkDiagnosticResult(target: job.label, reachable: false, latencyMs: nil)
        }
    }
}
