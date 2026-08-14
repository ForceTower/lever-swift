import Foundation

/// Header names are case-insensitive; storing them lowercased means a lookup
/// can never depend on what casing the proxy in front of lever happened to use.
struct HTTPHeaders: Sendable, Equatable {
    private var storage: [String: String] = [:]

    init(_ pairs: [(String, String)] = []) {
        for (name, value) in pairs { storage[name.lowercased()] = value }
    }

    subscript(name: String) -> String? {
        get { storage[name.lowercased()] }
        set { storage[name.lowercased()] = newValue }
    }
}

/// Header order is part of the request contract the fixtures pin, so it is an
/// array rather than a dictionary.
struct HTTPRequest: Sendable, Equatable {
    var url: URL
    var headers: [(name: String, value: String)]

    static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.url == rhs.url
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0 == $1 }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct HTTPResponse: Sendable {
    /// `nil` when the platform handed back a non-HTTP `URLResponse` — the
    /// `invalidResponse` case, kept separate from every real status (§6.1).
    var status: Int?
    var headers = HTTPHeaders()
    var body = Data()
}

/// A validated, still-open stream. `bytes` yields whatever chunks arrive; the
/// SSE parser is written to be indifferent to chunk boundaries (§6.2).
struct HTTPStream: Sendable {
    var status: Int?
    var headers = HTTPHeaders()
    var bytes: AsyncThrowingStream<[UInt8], any Error> = .init { $0.finish() }
}

/// Everything the runtime needs from the network, and the seam tests replace
/// with a scripted double (§10).
///
/// Implementations map platform failures to `URLError` and leave every HTTP
/// status alone — status interpretation is `ResolveEndpoint`'s job, so it can
/// be tested without a network.
protocol LeverTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func openStream(_ request: HTTPRequest) async throws -> HTTPStream
    /// A `URLSession` retains its delegate until invalidated, so skipping this
    /// leaks the session, the delegate, and the client behind it (§4.1).
    func invalidate()
}
