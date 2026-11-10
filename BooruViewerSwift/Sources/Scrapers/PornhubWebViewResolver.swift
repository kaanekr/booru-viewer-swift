import Foundation

/// Loads a Pornhub page the plain HTTP client cannot read, using a real browser engine.
///
/// Mirrors RN `PornhubWebViewResolver` (src/components/PornhubWebViewResolver.tsx): the bot wall
/// (JS proof-of-work plus access cookies) is solved by WebKit itself, then the finished document
/// HTML — which carries the `flashvars` / `mediaDefinitions` block — is handed back to
/// `PornhubSource`. URLs carry expiring tokens, so nothing is cached.
protocol PornhubChallengeSolving: Sendable {
    /// Fully loaded HTML of `url`, after any JS challenge has been solved.
    /// Throws `BooruError` when the page never exposes a stream, or `CancellationError` when cancelled.
    func resolvePageHTML(url: URL, timeout: TimeInterval) async throws -> String
}

/// Markers that tell a fully served Pornhub page from the JS challenge interstitial.
enum PornhubChallengeMarkers {
    /// Stream block every playable page carries (PornhubWebViewResolver.tsx:41-44).
    static let streamMarkers = ["mediaDefinitions", "flashvars"]
    /// Proof-of-work helper and access-cookie script fragments of the challenge page.
    static let challengeMarkers = [
        "leastFactor", "accessAgeDisclaimerPH", "accessPH", "challenge-platform", "captcha",
    ]

    /// True when the page carries the `mediaDefinitions` / `flashvars` stream block.
    static func hasStreams(_ html: String) -> Bool {
        containsAny(streamMarkers, in: html)
    }

    /// True when the page looks like the JS challenge wall instead of the video page.
    static func looksLikeChallenge(_ html: String) -> Bool {
        containsAny(challengeMarkers, in: html)
    }

    private static func containsAny(_ markers: [String], in html: String) -> Bool {
        guard !html.isEmpty else { return false }
        let lower = html.lowercased()
        return markers.contains { lower.contains($0.lowercased()) }
    }
}

#if canImport(WebKit)
import WebKit

/// Headless `WKWebView` challenge solver. The view is never attached to a window: it only needs the
/// engine to run the challenge script and expose the finished DOM.
@MainActor
final class PornhubWebViewResolver: NSObject, PornhubChallengeSolving {
    /// Absolute ceiling, so a hung connection cannot spin forever (PornhubWebViewResolver.tsx:24-32).
    static let defaultTimeout: TimeInterval = 20
    /// RN polls every second (PornhubWebViewResolver.tsx:55).
    static let pollInterval: UInt64 = 1_000_000_000
    /// RN gives up after 15 polls (PornhubWebViewResolver.tsx:45-48).
    static let maxPolls = 15
    /// Attempt after which a challenge page is reloaded, now carrying the cookies its script set.
    static let challengeReloadAttempt = 3
    /// The probe RN injects, returning the document instead of posting it to a bridge.
    static let probeScript = "(function(){var d=document.documentElement;return d?(d.outerHTML||''):'';})()"

    func resolvePageHTML(url: URL, timeout: TimeInterval) async throws -> String {
        let session = Session(pageURL: url, timeout: timeout)
        return try await session.run()
    }

    /// One page load. Owns the offscreen web view for the duration of a single call.
    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        private let pageURL: URL
        private let timeout: TimeInterval
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<String, Error>?
        private var pollTask: Task<Void, Never>?
        private var deadlineTask: Task<Void, Never>?
        private var finished = false
        private var didReloadForChallenge = false

        init(pageURL: URL, timeout: TimeInterval) {
            self.pageURL = pageURL
            self.timeout = max(1, timeout)
            super.init()
        }

        func run() async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    self.continuation = continuation
                    self.start()
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finish(.failure(CancellationError()))
                }
            }
        }

        // MARK: - Loading

        private func start() {
            guard !finished else { return }
            let configuration = WKWebViewConfiguration()
            // Shared cookies: the challenge cookie survives for the next call (PornhubWebViewResolver.tsx:108).
            configuration.websiteDataStore = .default()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            // The viewer only wants the DOM, never playback (mediaPlaybackRequiresUserAction=false in RN).
            configuration.mediaTypesRequiringUserActionForPlayback = .all

            let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView.isHidden = true
            webView.customUserAgent = PornhubSource.userAgent
            webView.navigationDelegate = self
            self.webView = webView

            // The age-gate cookies the RN fast path sends (media.ts:499).
            for cookie in Self.ageCookies() {
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }

            var request = URLRequest(url: pageURL)
            request.setValue(PornhubSource.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(PornhubSource.baseURL + "/", forHTTPHeaderField: "Referer")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            _ = webView.load(request)

            schedulePolling()
            scheduleDeadline()
        }

        private static func ageCookies() -> [HTTPCookie] {
            let names = [("accessAgeDisclaimerPH", "1"), ("accessPH", "1")]
            let expiry = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30)
            return names.compactMap { pair -> HTTPCookie? in
                HTTPCookie(properties: [
                    .domain: ".pornhub.com",
                    .path: "/",
                    .name: pair.0,
                    .value: pair.1,
                    .expires: expiry,
                    .secure: "TRUE",
                ])
            }
        }

        // MARK: - Polling

        private func schedulePolling() {
            pollTask = Task { [weak self] in
                for attempt in 1...PornhubWebViewResolver.maxPolls {
                    try? await Task.sleep(nanoseconds: PornhubWebViewResolver.pollInterval)
                    if Task.isCancelled { return }
                    guard let self, !self.finished else { return }
                    if await self.poll(attempt: attempt) { return }
                }
                guard let self else { return }
                self.finish(.failure(BooruError.network("Pornhub did not expose a playable stream.")))
            }
        }

        /// Returns true when the session has finished. Stream markers end it; a challenge page is
        /// reloaded once so the cookie its script set can be sent with the real request.
        private func poll(attempt: Int) async -> Bool {
            guard let webView, !finished else { return true }
            let html = (try? await webView.evaluateJavaScript(PornhubWebViewResolver.probeScript)) as? String ?? ""
            if PornhubChallengeMarkers.hasStreams(html) {
                finish(.success(html))
                return true
            }
            if attempt >= PornhubWebViewResolver.challengeReloadAttempt,
               !didReloadForChallenge,
               PornhubChallengeMarkers.looksLikeChallenge(html) {
                didReloadForChallenge = true
                _ = webView.reload()
            }
            return false
        }

        private func scheduleDeadline() {
            deadlineTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                if Task.isCancelled { return }
                self.finish(.failure(BooruError.network("Pornhub challenge page timed out.")))
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failFast(for: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failFast(for: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(BooruError.network("Pornhub challenge page crashed.")))
        }

        /// A cancelled load is a redirect or a replaced provisional load, not a real failure.
        private func failFast(for error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            finish(.failure(error))
        }

        // MARK: - Teardown

        private func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            pollTask?.cancel()
            deadlineTask?.cancel()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
            let continuation = self.continuation
            self.continuation = nil
            switch result {
            case .success(let html):
                continuation?.resume(returning: html)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }
}

#else

/// Platforms without WebKit have no engine that can solve the challenge.
@MainActor
final class PornhubWebViewResolver: NSObject, PornhubChallengeSolving {
    func resolvePageHTML(url: URL, timeout: TimeInterval) async throws -> String {
        throw BooruError.unsupported("Pornhub challenge solving requires WebKit.")
    }
}

#endif
