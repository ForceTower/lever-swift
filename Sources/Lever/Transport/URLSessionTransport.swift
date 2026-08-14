import Foundation

/// The live transport: one dedicated `URLSession` whose configuration is pinned
/// explicitly rather than inherited (§6.1).
///
/// Every setting here is a decision: the SDK's ETag plus its disk cache *is* the
/// cache, so a second HTTP cache underneath would produce confusing
/// double-freshness; cookies have no business on a public read endpoint; and
/// waiting for connectivity would hold a fetch open long past the point where
/// the three-layer floor has already answered the question.
final class URLSessionTransport: NSObject, LeverTransport, URLSessionTaskDelegate, @unchecked
    Sendable
{
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(
                for: urlRequest(request),
                delegate: self
            )
            guard let http = response as? HTTPURLResponse else {
                return HTTPResponse(status: nil, headers: HTTPHeaders(), body: data)
            }
            return HTTPResponse(status: http.statusCode, headers: headers(of: http), body: data)
        } catch {
            throw Self.normalize(error)
        }
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStream {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest(request), delegate: self)
        } catch {
            throw Self.normalize(error)
        }

        guard let http = response as? HTTPURLResponse else {
            return HTTPStream(status: nil)
        }

        // Chunked at line boundaries. SSE volume is a frame every 25 s, so the
        // per-byte loop costs nothing and keeps the parser's contract honest:
        // it must handle any chunking, and this is one plausible chunking.
        let chunks = AsyncThrowingStream<[UInt8], any Error> { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return HTTPStream(status: http.statusCode, headers: headers(of: http), bytes: chunks)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Redirects are refused: the `Authorization` header must never travel to an
    /// origin the developer did not configure (§6.1). Returning `nil` hands the
    /// 3xx back to the caller, which maps it to `.server(status:)`.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    private func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return urlRequest
    }

    private func headers(of response: HTTPURLResponse) -> HTTPHeaders {
        HTTPHeaders(
            response.allHeaderFields.compactMap { key, value in
                guard let name = key as? String else { return nil }
                return (name, String(describing: value))
            }
        )
    }

    /// Task cancellation reaches us as `URLError.cancelled`; the SDK contract is
    /// that it surfaces as `CancellationError`, never `.network(.cancelled)`
    /// (§5.1).
    private static func normalize(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled, Task.isCancelled {
            return CancellationError()
        }
        return error
    }
}
