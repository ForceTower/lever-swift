import Foundation

/// A parsed JSON value, kept exactly as the wire delivered it.
///
/// Integers stay integers: the wire has no `Int`/`Double` distinction, but
/// routing every number through `Double` would quietly mangle large integers on
/// the way back out when a `json` value is re-serialized for decoding (§2.3).
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// `3` and `3.0` are the same JSON number, so they must compare equal —
    /// `changedKeys` is a diff over wire values, not over Swift cases (§4).
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): Double(a) == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        // Hashed as the same number so `==`'s int/double bridge stays consistent.
        case .int(let value): hasher.combine(Double(value))
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }
}

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One entry of the resolve payload's `values` map: `{"type": …, "value": …}`.
///
/// `type` stays a `String` rather than an enum so a server that learns a new
/// parameter type degrades to a read-time mismatch — the floor — instead of
/// failing the whole decode and costing every other key its freshness.
struct WireValue: Sendable, Hashable, Codable {
    let type: String
    let value: JSONValue
}

extension WireValue {
    static let boolean = "boolean"
    static let string = "string"
    static let number = "number"
    static let json = "json"
}
