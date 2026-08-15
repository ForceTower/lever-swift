import Foundation

/// Request construction and status mapping for `GET /v1/resolve` (§6.1), as
/// pure functions over the validated configuration — no network involved, so
/// the contract fixtures can assert both halves directly.
enum ResolveEndpoint {
    /// RFC 3986 unreserved set. `CharacterSet.alphanumerics` would let every
    /// non-ASCII letter through unencoded, which is not what the fixtures pin.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Reserved names first, in a fixed order, then `attr.*` sorted by name —
    /// the ordering the contract fixtures pin for every SDK.
    static func query(for configuration: ValidatedConfiguration, clientId: String) -> String {
        var items: [String] = []
        if let platform = configuration.platform {
            items.append("platform=\(percentEncoded(platform))")
        }
        if let appVersion = configuration.appVersion {
            items.append("appVersion=\(percentEncoded(appVersion))")
        }
        items.append("clientId=\(percentEncoded(clientId))")
        // `configuration.attributes` is already in ascending UTF-8 byte order.
        for attribute in configuration.attributes {
            items.append(
                "attr.\(percentEncoded(attribute.name))=\(percentEncoded(attribute.value))"
            )
        }
        return items.joined(separator: "&")
    }

    static func request(
        for configuration: ValidatedConfiguration,
        clientId: String,
        ifNoneMatch: String?
    ) -> HTTPRequest {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("v1/resolve"),
            resolvingAgainstBaseURL: false
        )
        components?.percentEncodedQuery = query(for: configuration, clientId: clientId)

        var headers = [
            (name: "Authorization", value: "Bearer \(configuration.clientKey)"),
            (name: "Accept", value: "application/json"),
        ]
        if let ifNoneMatch { headers.append((name: "If-None-Match", value: ifNoneMatch)) }

        return HTTPRequest(
            url: components?.url ?? configuration.baseURL,
            headers: headers
        )
    }

    /// The spec 0001 §5.1 envelope. `message` is deliberately not decoded: it
    /// is explicitly non-contractual, so nothing here may branch on it.
    private struct Envelope: Decodable {
        let ok: Bool
        let data: Payload?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String?
    }

    /// The §6.3 payload, one level below the envelope: `version` must be a
    /// non-negative integer representable as `Int`. Any shape violation is
    /// `invalidResponse`, and the caller changes nothing — decode is atomic.
    private struct Payload: Decodable {
        let version: Int
        let values: [String: WireValue]
    }

    /// The `error.code` a failure envelope carried, for the log line only —
    /// never for control flow; the status code already carries the branch
    /// (spec 0001 §5.1).
    static func errorCode(for response: HTTPResponse) -> String? {
        (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error?.code
    }

    enum Outcome: Sendable {
        case fresh(version: Int, values: [String: WireValue], etag: String?)
        /// The representation whose validator we sent is still current.
        case notModified
    }

    /// Maps one HTTP response to what the runtime should do with it.
    /// `sentValidator` decides whether a 304 is legitimate at all.
    static func outcome(for response: HTTPResponse, sentValidator: Bool) throws -> Outcome {
        guard let status = response.status else { throw LeverError.invalidResponse }

        switch status {
        case 200:
            // `ok: false`, or a null/absent `data`, is a fetch failure —
            // **never** an empty `values` map. Treating it as empty would
            // resolve every key to its code default while the previous snapshot
            // was still perfectly serviceable, silently collapsing the
            // three-layer floor on a server that was reachable (research §4.4).
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.body),
                envelope.ok,
                let payload = envelope.data,
                payload.version >= 0
            else { throw LeverError.invalidResponse }
            // A 200 with no ETag is accepted; later requests simply send no
            // validator for that representation.
            return .fresh(
                version: payload.version,
                values: payload.values,
                etag: response.headers["ETag"]
            )

        case 304:
            // Nothing to confirm — the server answered a question we did not ask.
            guard sentValidator else { throw LeverError.invalidResponse }
            return .notModified

        case 401:
            throw LeverError.invalidKey

        default:
            // 204 and the rest of the 2xx range included: the contract is
            // 200/304/401, and anything else is a server the SDK cannot read.
            throw LeverError.server(status: status)
        }
    }
}
