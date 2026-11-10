import Foundation

/// Transport seam for all source requests. Rate limiting and retry are implemented outside this contract.
protocol HTTPClientProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
