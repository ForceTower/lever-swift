import Foundation

/// Everything an explicit `fetch()` can fail with. Automatic paths log these
/// and change nothing — the current snapshot keeps serving (spec §5.4).
public enum LeverError: Error, Equatable, Sendable {
    /// 401 — the key is unknown or has been rotated. Never clears the cache.
    case invalidKey
    /// Any HTTP status other than 200/304/401, unexpected 2xx like 204 included.
    case server(status: Int)
    case network(URLError.Code)
    /// Undecodable body, a non-HTTP response, or a 304 we did not ask for.
    case invalidResponse
}

extension LeverError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidKey: "invalid key"
        case .server(let status): "server status=\(status)"
        case .network(let code): "network code=\(code.rawValue)"
        case .invalidResponse: "invalid response"
        }
    }
}
