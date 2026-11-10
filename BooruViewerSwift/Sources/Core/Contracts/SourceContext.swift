import Foundation

/// Per-request dependencies handed to a source by the app layer. Sources never build their own.
struct SourceContext: Sendable {
    let http: any HTTPClientProtocol
    let proxy: ProxyConfig
    let gelbooruAuth: ApiAuth?
    let rule34Auth: ApiAuth?
    let imageQuality: ImageQuality
}
