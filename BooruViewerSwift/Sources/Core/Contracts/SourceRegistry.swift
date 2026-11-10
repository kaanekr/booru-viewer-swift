import Foundation

/// Maps a `SourceID` to its `BooruSource` implementation.
///
/// This is the single place where the app layer chooses a concrete adapter. The lookup is
/// exhaustive over `SourceID`, so adding a case here fails to compile until it is wired.
enum SourceRegistry {
    static func source(for id: SourceID) -> (any BooruSource)? {
        switch id {
        case .gelbooru:
            return GelbooruSource(id: .gelbooru)
        case .rule34:
            return GelbooruSource(id: .rule34)
        case .danbooru:
            return DanbooruSource()
        case .yandere:
            return MoebooruSource()
        case .realbooru:
            return RealbooruSource()
        case .cumst:
            return CumstSource()
        case .redgifs:
            return RedGifsSource()
        case .nhentai:
            return NHentaiSource()
        case .hentaihaven:
            return HentaiHavenSource()
        case .xvideos:
            return XVideosSource()
        case .xhamster:
            return XHamsterSource()
        case .sexcom:
            return SexComSource()
        case .pornhub:
            return PornhubSource(challengeResolver: PornhubChallengeAdapter())
        }
    }
}

/// Sendable bridge from the nonisolated source layer to the `@MainActor` WebKit solver.
///
/// Pornhub's bot wall needs a real browser engine, and `PornhubWebViewResolver` is main-actor
/// bound because `WKWebView` is. The adapter carries no state, so each resolution hops to the
/// main actor, builds a short-lived resolver, and lets the source stay Sendable.
private struct PornhubChallengeAdapter: PornhubChallengeSolving {
    func resolvePageHTML(url: URL, timeout: TimeInterval) async throws -> String {
        let resolver = await PornhubWebViewResolver()
        return try await resolver.resolvePageHTML(url: url, timeout: timeout)
    }
}
