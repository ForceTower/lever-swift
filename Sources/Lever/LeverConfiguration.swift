import Foundation

/// The targeting platform sent with every resolve. A string, not an enum, so a
/// server-side platform vocabulary can grow without an SDK release.
public struct LeverPlatform: Sendable, Equatable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public static var current: LeverPlatform {
        #if os(visionOS)
            "visionos"
        #elseif os(watchOS)
            "watchos"
        #elseif os(tvOS)
            "tvos"
        #elseif os(iOS)
            "ios"
        #elseif os(macOS)
            "macos"
        #else
            "unknown"
        #endif
    }
}

/// Everything the server evaluates targeting rules against. Fixed at `init` in
/// v1 — mutable, login-scoped attributes are spec §11's open question.
public struct LeverContext: Sendable, Equatable {
    public var platform: LeverPlatform
    public var appVersion: String?
    /// Strings only, mirroring the wire contract (spec 0001 §11).
    public var attributes: [String: String]

    public init(
        platform: LeverPlatform = .current,
        appVersion: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.attributes = attributes
    }
}

public struct LeverConfiguration: Sendable {
    public var baseURL: URL
    /// `pk_…`. An identifier, not a secret — resolved values are readable by
    /// every end user, so config must never carry secrets (research 0001 §6).
    public var clientKey: String
    public var context: LeverContext

    /// Throttles the SDK's automatic paths, never an explicit `fetch()` (§5.1).
    /// Under `#if DEBUG`, set this to `.zero` rather than reaching for a bypass.
    public var minimumFetchInterval: Duration = .seconds(43_200)

    /// `false` makes the client a cache-only reader: no automatic fetch, timer,
    /// lifecycle observation, or stream. This is the App Group extension role
    /// (§5, §7); explicit `fetch()` still works as a deliberate override.
    public var automaticUpdates: Bool = true

    /// Whether a push nudge activates what it fetched (research 0001 §4.4).
    public var autoActivateOnNudge: Bool = true

    /// `nil` → Application Support. Point it at an App Group container to share
    /// the floor with same-device extensions (§7).
    public var cacheDirectory: URL?

    /// Pins the snapshot file's identity to a name you control (e.g. `"prod"`),
    /// so a shipped client-key rotation still lands on the warm cache. `nil`
    /// derives it from `clientKey`, which a rotation orphans (§7).
    public var cacheNamespace: String?

    public var logSink: any LeverLogSink = OSLogSink()

    public init(baseURL: URL, clientKey: String, context: LeverContext) {
        self.baseURL = baseURL
        self.clientKey = clientKey
        self.context = context
    }
}

/// What `activate()` publishes when the serving values actually changed.
/// Metadata-only commits are silent (§4).
public struct LeverUpdate: Sendable, Equatable {
    public let version: Int
    public let changedKeys: Set<String>

    public init(version: Int, changedKeys: Set<String>) {
        self.version = version
        self.changedKeys = changedKeys
    }
}
