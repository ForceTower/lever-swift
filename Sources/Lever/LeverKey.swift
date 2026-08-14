import Foundation

/// The namespace apps extend with their keys, the `EnvironmentValues` pattern:
///
/// ```swift
/// extension LeverKeys {
///     var enableEnrollment: LeverKey<Bool> { LeverKey("enable_enrollment", default: false) }
///     var paywall: LeverKey<PaywallConfig> { LeverKey(json: "paywall", default: .standard) }
/// }
/// ```
public struct LeverKeys: Sendable {
    public init() {}
}

/// A typed config key: the wire name plus the default that is served whenever
/// the live value is absent or does not fit (§2.3).
///
/// `Value` is unconstrained; the typed initializers below install the decoder,
/// so there is no way to build a key the SDK cannot read.
public struct LeverKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    let decode: @Sendable (WireValue) -> Value?
    /// Only `json` keys memoize — the others are a switch, not a `Decodable`.
    let memoizes: Bool

    init(
        name: String,
        defaultValue: Value,
        memoizes: Bool = false,
        decode: @escaping @Sendable (WireValue) -> Value?
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.memoizes = memoizes
        self.decode = decode
    }

    /// Part of the memo and log-dedupe identity: two keys may share a wire name
    /// with different `Value` types, and a decoded value must never be served
    /// to a key expecting another type (§2.3).
    var valueType: ObjectIdentifier { ObjectIdentifier(Value.self) }
}

extension LeverKey where Value == Bool {
    public init(_ name: String, default defaultValue: Bool) {
        self.init(name: name, defaultValue: defaultValue) { raw in
            guard raw.type == WireValue.boolean, case .bool(let value) = raw.value else { return nil }
            return value
        }
    }
}

extension LeverKey where Value == String {
    public init(_ name: String, default defaultValue: String) {
        self.init(name: name, defaultValue: defaultValue) { raw in
            guard raw.type == WireValue.string, case .string(let value) = raw.value else {
                return nil
            }
            return value
        }
    }
}

extension LeverKey where Value == Int {
    /// A `number` reaches an `Int` key only when it is exactly representable:
    /// a fractional part or a magnitude outside `Int` is a mismatch (§2.3).
    public init(_ name: String, default defaultValue: Int) {
        self.init(name: name, defaultValue: defaultValue) { raw in
            guard raw.type == WireValue.number else { return nil }
            switch raw.value {
            case .int(let value):
                return value
            case .double(let value):
                guard value.rounded() == value, value >= -9_223_372_036_854_775_808,
                    value < 9_223_372_036_854_775_808
                else { return nil }
                return Int(value)
            default:
                return nil
            }
        }
    }
}

extension LeverKey where Value == Double {
    public init(_ name: String, default defaultValue: Double) {
        self.init(name: name, defaultValue: defaultValue) { raw in
            guard raw.type == WireValue.number else { return nil }
            switch raw.value {
            case .int(let value): return Double(value)
            case .double(let value): return value
            default: return nil
            }
        }
    }
}

extension LeverKey where Value: Decodable & Sendable {
    /// A `json` parameter. The label is what keeps `Bool` and `String` — which
    /// are also `Decodable` — from racing this in overload resolution (§2.2).
    ///
    /// Prefer value types: "stable between activations" is a promise about the
    /// SDK's storage, not about aliasing a shared reference (§2.2).
    public init(json name: String, default defaultValue: Value) {
        self.init(name: name, defaultValue: defaultValue, memoizes: true) { raw in
            guard raw.type == WireValue.json else { return nil }
            guard let data = try? JSONEncoder().encode(raw.value) else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }
    }
}

/// Why a read resolved the way it did — the caller turns this into the right
/// deduped log line and, for `json`, into a memo entry (§2.3).
enum ReadOutcome<Value: Sendable>: Sendable {
    case resolved(Value)
    /// Not published, or a first run with no cache. Normal mid-rollout.
    case absent
    /// Present but unreadable as `Value`: wrong wire type, a `number` that is
    /// not an exact `Int`, or a `json` payload that failed to decode.
    case mismatch

    var value: Value? {
        if case .resolved(let value) = self { return value }
        return nil
    }
}

/// §2.3, as a pure function over a raw payload. Never throws, never optional.
func resolveRead<Value>(_ key: LeverKey<Value>, in values: [String: WireValue]) -> ReadOutcome<Value>
{
    guard let raw = values[key.name] else { return .absent }
    guard let decoded = key.decode(raw) else { return .mismatch }
    return .resolved(decoded)
}
