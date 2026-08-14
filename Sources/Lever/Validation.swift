import CryptoKit
import Foundation

/// The configuration the rest of the SDK runs on: repaired, canonical, and
/// already reduced to what goes on the wire.
///
/// Validation happens once, at `LeverClient.init`, and never throws. The policy
/// is uniform (§3): anything the server would answer with a 400 is repaired or
/// omitted here, because a 400 costs *every* key its freshness — omission is
/// the floor-preserving choice.
struct ValidatedConfiguration: Sendable {
    let baseURL: URL
    let clientKey: String
    let platform: String?
    let appVersion: String?
    /// Already ordered the way the query string must be built.
    let attributes: [(name: String, value: String)]
    let minimumFetchInterval: Duration
    let automaticUpdates: Bool
    let autoActivateOnNudge: Bool
    let cacheDirectory: URL
    let cacheKeyHash: String
    let logSink: any LeverLogSink
}

/// All length checks count **UTF-16 code units** — the server measures
/// JavaScript string length, and Swift's grapheme-cluster `count` would let
/// through strings it rejects (§3).
private let maxReservedLength = 64
private let maxAttributeNameLength = 64
private let maxAttributeValueLength = 256
private let maxAttributes = 20

/// The official semver.org grammar, the same one the server validates with
/// (spec 0001 §4). Computed, not stored: a `Regex` is not `Sendable`, and
/// validation runs once per client.
private var strictSemver: some RegexComponent {
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/
}

/// `"5"` → `"5.2.0"`-shaped padding for purely numeric 1- or 2-component
/// marketing versions; `nil` for anything else.
private func zeroPadded(_ version: String) -> String? {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { return nil }
    for part in parts {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard part == "0" || !part.hasPrefix("0") else { return nil }
    }
    return parts.count == 1 ? "\(parts[0]).0.0" : "\(parts[0]).\(parts[1]).0"
}

/// Ascending UTF-8 byte order — the same order the contract fixtures pin for
/// query items, and identical to Unicode scalar order.
func precedesByteWise(_ lhs: String, _ rhs: String) -> Bool {
    Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
}

func validate(_ configuration: LeverConfiguration) -> ValidatedConfiguration {
    let sink = configuration.logSink
    let baseURL = canonicalize(configuration.baseURL, sink: sink)

    if !configuration.clientKey.hasPrefix("pk_") {
        sink.warn("client key does not look like a pk_ key — the server is the authority")
    }

    return ValidatedConfiguration(
        baseURL: baseURL,
        clientKey: configuration.clientKey,
        platform: validatePlatform(configuration.context.platform, sink: sink),
        appVersion: validateAppVersion(configuration.context.appVersion, sink: sink),
        attributes: validateAttributes(configuration.context.attributes, sink: sink),
        minimumFetchInterval: validateInterval(configuration.minimumFetchInterval, sink: sink),
        automaticUpdates: configuration.automaticUpdates,
        autoActivateOnNudge: configuration.autoActivateOnNudge,
        cacheDirectory: (configuration.cacheDirectory ?? defaultCacheDirectory())
            .appendingPathComponent("Lever", isDirectory: true),
        cacheKeyHash: cacheKeyHash(
            baseURL: baseURL,
            namespace: configuration.cacheNamespace ?? configuration.clientKey
        ),
        logSink: sink
    )
}

/// Scheme and host lowercased, a default port dropped, trailing slashes
/// stripped. This canonical form is what requests are built from *and* what the
/// cache identity hashes, so the two can never disagree (§3, §7).
func canonicalize(_ url: URL, sink: any LeverLogSink) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        sink.error("base url is not a valid url url=\(url.absoluteString)")
        return url
    }

    let scheme = components.scheme?.lowercased()
    if scheme != "http" && scheme != "https" {
        sink.error("base url scheme must be http or https scheme=\(scheme ?? "none")")
    }
    components.scheme = scheme
    components.host = components.host?.lowercased()

    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
        components.port = nil
    }

    // The SDK owns the path and query space under the base.
    if components.query != nil || components.fragment != nil {
        sink.warn("base url query and fragment are ignored url=\(url.absoluteString)")
        components.query = nil
        components.fragment = nil
    }

    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path

    guard let canonical = components.url else {
        sink.error("base url could not be canonicalized url=\(url.absoluteString)")
        return url
    }
    return canonical
}

/// An absent platform means platform clauses never match — degraded targeting,
/// which beats a 400 that costs every key its freshness (§3).
private func validatePlatform(_ platform: LeverPlatform, sink: any LeverLogSink) -> String? {
    guard platform.rawValue.utf16.count <= maxReservedLength else {
        sink.warn("platform omitted, over \(maxReservedLength) utf-16 units — platform clauses will not match")
        return nil
    }
    return platform.rawValue
}

private func validateAppVersion(_ appVersion: String?, sink: any LeverLogSink) -> String? {
    guard let appVersion else { return nil }

    guard appVersion.utf16.count <= maxReservedLength else {
        sink.error("appVersion omitted, over \(maxReservedLength) utf-16 units — version clauses will not match")
        return nil
    }
    if appVersion.wholeMatch(of: strictSemver) != nil { return appVersion }

    // Marketing versions are the common case and the intent is unambiguous.
    if let padded = zeroPadded(appVersion) {
        sink.info("appVersion normalized from=\(appVersion) to=\(padded)")
        return padded
    }

    sink.error("appVersion is not semver and no version clause will ever match it appVersion=\(appVersion)")
    return appVersion
}

/// Wire-limit violations are dropped individually, and the survivors are capped
/// deterministically: Swift's dictionary order must never decide which
/// targeting inputs reach the server (§3).
private func validateAttributes(
    _ attributes: [String: String],
    sink: any LeverLogSink
) -> [(name: String, value: String)] {
    var valid: [(name: String, value: String)] = []
    var dropped: [String] = []

    for name in attributes.keys.sorted(by: precedesByteWise) {
        let value = attributes[name] ?? ""
        let nameLength = name.utf16.count
        if nameLength < 1 || nameLength > maxAttributeNameLength
            || value.utf16.count > maxAttributeValueLength
        {
            dropped.append(name)
            continue
        }
        valid.append((name: name, value: value))
    }
    if !dropped.isEmpty {
        sink.warn("attributes dropped, outside the wire limits names=\(dropped.joined(separator: ","))")
    }

    guard valid.count > maxAttributes else { return valid }
    let overflow = valid[maxAttributes...].map(\.name)
    sink.warn("attributes dropped, over \(maxAttributes) names=\(overflow.joined(separator: ","))")
    return Array(valid.prefix(maxAttributes))
}

private func validateInterval(_ interval: Duration, sink: any LeverLogSink) -> Duration {
    if interval < .zero {
        // A negative interval would make every deadline permanently overdue,
        // which §5.1's hot-loop guard depends on not happening.
        sink.warn("minimumFetchInterval clamped to zero from a negative value")
        return .zero
    }
    if interval > .zero && interval < .seconds(60) {
        sink.info("minimumFetchInterval is under the 60s polling floor — the in-session timer runs at 60s, lifecycle edges keep the configured value")
    }
    return interval
}

private func defaultCacheDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL.temporaryDirectory
}

/// The snapshot file's name: the first 16 hex chars of SHA-256 over the
/// canonical base URL and the cache namespace (§7).
func cacheKeyHash(baseURL: URL, namespace: String) -> String {
    let input = Data("\(baseURL.absoluteString)\n\(namespace)".utf8)
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined().prefix(16)
        .lowercased()
}
