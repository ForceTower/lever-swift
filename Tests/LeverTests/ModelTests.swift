import Foundation
import Testing

@testable import Lever

struct Paywall: Codable, Equatable, Sendable {
    let headline: String
    let trialDays: Int
}

extension LeverKeys {
    var flag: LeverKey<Bool> { LeverKey("flag", default: false) }
    var greeting: LeverKey<String> { LeverKey("greeting", default: "hi") }
    var retries: LeverKey<Int> { LeverKey("retries", default: 3) }
    var rate: LeverKey<Double> { LeverKey("rate", default: 1.5) }
    var paywall: LeverKey<Paywall> {
        LeverKey(json: "paywall", default: Paywall(headline: "fallback", trialDays: 0))
    }
}

private func payload(_ pairs: [String: WireValue]) -> [String: WireValue] { pairs }

@Suite("read resolution (§2.3)")
struct ReadResolutionTests {
    private let keys = LeverKeys()

    @Test("every typed key decodes its matching wire value")
    func decodesMatchingTypes() {
        #expect(
            resolveRead(
                keys.flag,
                in: ["flag": WireValue(type: "boolean", value: .bool(true))]
            ).value == true
        )
        #expect(
            resolveRead(
                keys.greeting,
                in: ["greeting": WireValue(type: "string", value: .string("olá"))]
            ).value == "olá"
        )
        #expect(
            resolveRead(
                keys.retries,
                in: ["retries": WireValue(type: "number", value: .int(7))]
            ).value == 7
        )
        #expect(
            resolveRead(
                keys.rate,
                in: ["rate": WireValue(type: "number", value: .double(0.25))]
            ).value == 0.25
        )
        let paywall = WireValue(
            type: "json",
            value: .object(["headline": .string("Go Pro"), "trialDays": .int(7)])
        )
        #expect(
            resolveRead(keys.paywall, in: ["paywall": paywall]).value
                == Paywall(headline: "Go Pro", trialDays: 7)
        )
    }

    @Test("an absent key is absence, not a mismatch")
    func absence() {
        #expect(isAbsent(resolveRead(keys.flag, in: [:])))
        #expect(isAbsent(resolveRead(keys.paywall, in: ["other": .init(type: "json", value: .null)])))
    }

    @Test("a wrong wire type is a mismatch for every typed initializer")
    func wrongWireType() {
        let string = WireValue(type: "string", value: .string("nope"))
        #expect(isMismatch(resolveRead(keys.flag, in: ["flag": string])))
        #expect(isMismatch(resolveRead(keys.retries, in: ["retries": string])))
        #expect(isMismatch(resolveRead(keys.rate, in: ["rate": string])))
        #expect(isMismatch(resolveRead(keys.paywall, in: ["paywall": string])))
        #expect(
            isMismatch(
                resolveRead(
                    keys.greeting,
                    in: ["greeting": .init(type: "boolean", value: .bool(true))]
                )
            )
        )
    }

    @Test("an Int key requires an exactly representable integer")
    func integerExactness() {
        // A whole number arriving as a double is still the same JSON number.
        #expect(
            resolveRead(
                keys.retries,
                in: ["retries": .init(type: "number", value: .double(9))]
            ).value == 9
        )
        #expect(
            isMismatch(
                resolveRead(
                    keys.retries,
                    in: ["retries": .init(type: "number", value: .double(3.5))]
                )
            )
        )
        #expect(
            isMismatch(
                resolveRead(
                    keys.retries,
                    in: ["retries": .init(type: "number", value: .double(1e20))]
                )
            )
        )
        // A Double key takes all of them.
        #expect(
            resolveRead(
                keys.rate,
                in: ["rate": .init(type: "number", value: .double(3.5))]
            ).value == 3.5
        )
        #expect(
            resolveRead(keys.rate, in: ["rate": .init(type: "number", value: .int(4))]).value == 4
        )
    }

    @Test("a json payload that does not fit the model is a mismatch")
    func failingJSONDecode() {
        let missingField = WireValue(type: "json", value: .object(["headline": .string("Go Pro")]))
        #expect(isMismatch(resolveRead(keys.paywall, in: ["paywall": missingField])))

        let wrongMemberType = WireValue(
            type: "json",
            value: .object(["headline": .string("Go Pro"), "trialDays": .string("seven")])
        )
        #expect(isMismatch(resolveRead(keys.paywall, in: ["paywall": wrongMemberType])))
    }

    @Test("an unknown wire type degrades to a mismatch, never a decode failure")
    func unknownWireType() {
        let future = WireValue(type: "duration", value: .string("PT5M"))
        #expect(isMismatch(resolveRead(keys.greeting, in: ["greeting": future])))
    }

    private func isAbsent<Value>(_ outcome: ReadOutcome<Value>) -> Bool {
        if case .absent = outcome { return true }
        return false
    }

    private func isMismatch<Value>(_ outcome: ReadOutcome<Value>) -> Bool {
        if case .mismatch = outcome { return true }
        return false
    }
}

@Suite("JSON value model")
struct JSONValueTests {
    @Test("3 and 3.0 are the same JSON number")
    func numberEquality() {
        #expect(JSONValue.int(3) == JSONValue.double(3.0))
        #expect(JSONValue.array([.int(3)]) == JSONValue.array([.double(3.0)]))
        #expect(JSONValue.int(3) != JSONValue.double(3.5))
    }

    @Test("large integers survive a decode/encode round trip")
    func integersDoNotBecomeDoubles() throws {
        let data = Data("{\"n\":9007199254740993}".utf8)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(String(decoding: reencoded, as: UTF8.self) == "{\"n\":9007199254740993}")
    }

    @Test("every JSON shape round-trips")
    func roundTrip() throws {
        let source = Data(
            "{\"a\":null,\"b\":true,\"c\":[1,2.5,\"x\"],\"d\":{\"e\":false}}".utf8
        )
        let decoded = try JSONDecoder().decode(JSONValue.self, from: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(decoded), as: UTF8.self) == String(decoding: source, as: UTF8.self))
    }
}

@Suite("configuration validation (§3)")
struct ValidationTests {
    private func validated(
        _ customize: (inout LeverConfiguration) -> Void
    ) -> (ValidatedConfiguration, RecordingLogSink) {
        let sink = RecordingLogSink()
        var configuration = LeverConfiguration(
            baseURL: URL(string: "https://lever.example")!,
            clientKey: "pk_test",
            context: LeverContext(platform: "ios")
        )
        configuration.logSink = sink
        customize(&configuration)
        return (validate(configuration), sink)
    }

    // MARK: base URL

    @Test("scheme and host are lowercased, a default port dropped, trailing slashes stripped")
    func canonicalizesBaseURL() {
        let (config, sink) = validated {
            $0.baseURL = URL(string: "HTTPS://Lever.Example:443/base/")!
        }
        #expect(config.baseURL.absoluteString == "https://lever.example/base")
        #expect(sink.all.isEmpty)
    }

    @Test("a non-default port is kept")
    func keepsExplicitPort() {
        let (config, _) = validated { $0.baseURL = URL(string: "http://localhost:48093/")! }
        #expect(config.baseURL.absoluteString == "http://localhost:48093")
    }

    @Test("a query or fragment is stripped with a warning — the SDK owns that space")
    func stripsQueryAndFragment() {
        let (config, sink) = validated {
            $0.baseURL = URL(string: "https://lever.example/api?token=x#frag")!
        }
        #expect(config.baseURL.absoluteString == "https://lever.example/api")
        #expect(sink.contains(.warn, "base url query and fragment are ignored"))
    }

    @Test("a non-http scheme logs an error")
    func rejectsScheme() {
        let (_, sink) = validated { $0.baseURL = URL(string: "ftp://lever.example")! }
        #expect(sink.contains(.error, "base url scheme must be http or https"))
    }

    // MARK: app version

    @Test("strict semver passes silently")
    func strictSemver() {
        let (config, sink) = validated { $0.context.appVersion = "5.2.0-beta.1+build.9" }
        #expect(config.appVersion == "5.2.0-beta.1+build.9")
        #expect(sink.all.isEmpty)
    }

    @Test("a numeric marketing version is zero-padded with an info log")
    func padsMarketingVersions() {
        let (one, oneSink) = validated { $0.context.appVersion = "5" }
        #expect(one.appVersion == "5.0.0")
        #expect(oneSink.contains(.info, "appVersion normalized from=5 to=5.0.0"))

        let (two, twoSink) = validated { $0.context.appVersion = "5.2" }
        #expect(two.appVersion == "5.2.0")
        #expect(twoSink.contains(.info, "to=5.2.0"))
    }

    @Test("in-limit garbage is sent verbatim with an error naming the consequence")
    func garbageVersion() {
        let (config, sink) = validated { $0.context.appVersion = "v5.2-rc" }
        #expect(config.appVersion == "v5.2-rc")
        #expect(sink.contains(.error, "no version clause will ever match"))
    }

    @Test("an overlong version is omitted rather than 400ing the whole resolve")
    func overlongVersionOmitted() {
        let (config, sink) = validated { $0.context.appVersion = String(repeating: "9", count: 65) }
        #expect(config.appVersion == nil)
        #expect(sink.contains(.error, "appVersion omitted"))
    }

    @Test("length limits count UTF-16 code units, not graphemes")
    func utf16Boundaries() {
        // 32 emoji: 32 graphemes, 64 UTF-16 units — exactly at the limit.
        let atLimit = String(repeating: "🙂", count: 32)
        let (kept, keptSink) = validated { $0.context.platform = LeverPlatform(atLimit) }
        #expect(kept.platform == atLimit)
        #expect(keptSink.all.isEmpty)

        // 33 emoji: 66 units — over, even though `count` says 33.
        let overLimit = String(repeating: "🙂", count: 33)
        let (dropped, droppedSink) = validated { $0.context.platform = LeverPlatform(overLimit) }
        #expect(dropped.platform == nil)
        #expect(droppedSink.contains(.warn, "platform omitted"))
    }

    // MARK: attributes

    @Test("attributes outside the wire limits are dropped by name")
    func dropsInvalidAttributes() {
        let (config, sink) = validated {
            $0.context.attributes = [
                "ok": "value",
                String(repeating: "n", count: 65): "x",
                "big": String(repeating: "v", count: 257),
                "": "empty name",
            ]
        }
        #expect(config.attributes.map(\.name) == ["ok"])
        #expect(sink.contains(.warn, "attributes dropped, outside the wire limits"))
    }

    @Test("the surviving twenty are the same twenty whatever the insertion order")
    func deterministicAttributeCap() {
        let names = (0..<21).map { "attr\(String(format: "%02d", $0))" }

        var ascending: [String: String] = [:]
        for name in names { ascending[name] = "v" }
        var descending: [String: String] = [:]
        for name in names.reversed() { descending[name] = "v" }

        let (first, sink) = validated { $0.context.attributes = ascending }
        let (second, _) = validated { $0.context.attributes = descending }

        #expect(first.attributes.map(\.name) == Array(names.prefix(20)))
        #expect(second.attributes.map(\.name) == first.attributes.map(\.name))
        #expect(sink.contains(.warn, "attributes dropped, over 20 names=attr20"))
    }

    @Test("attributes come out in ascending UTF-8 byte order")
    func attributeOrdering() {
        let (config, _) = validated {
            $0.context.attributes = ["b": "1", "A": "2", "á": "3", "a": "4"]
        }
        #expect(config.attributes.map(\.name) == ["A", "a", "b", "á"])
    }

    // MARK: client key and interval

    @Test("a key that does not look like pk_ warns but is still sent")
    func clientKeyShape() {
        let (config, sink) = validated { $0.clientKey = "sk_oops" }
        #expect(config.clientKey == "sk_oops")
        #expect(sink.contains(.warn, "does not look like a pk_ key"))
    }

    @Test("a negative interval clamps to zero, sub-60s logs the polling floor, 60s is silent")
    func intervalClamping() {
        let (negative, negativeSink) = validated { $0.minimumFetchInterval = .seconds(-5) }
        #expect(negative.minimumFetchInterval == .zero)
        #expect(negativeSink.contains(.warn, "clamped to zero"))

        let (zero, zeroSink) = validated { $0.minimumFetchInterval = .zero }
        #expect(zero.minimumFetchInterval == .zero)
        #expect(zeroSink.messages(.info).isEmpty)

        let (short, shortSink) = validated { $0.minimumFetchInterval = .seconds(30) }
        #expect(short.minimumFetchInterval == .seconds(30))
        #expect(shortSink.contains(.info, "under the 60s polling floor"))

        let (exact, exactSink) = validated { $0.minimumFetchInterval = .seconds(60) }
        #expect(exact.minimumFetchInterval == .seconds(60))
        #expect(exactSink.messages(.info).isEmpty)
    }

    // MARK: cache identity

    @Test("the cache hash follows the namespace, so a key rotation keeps the warm floor")
    func cacheIdentity() {
        let (first, _) = validated {
            $0.clientKey = "pk_one"
            $0.cacheNamespace = "prod"
        }
        let (rotated, _) = validated {
            $0.clientKey = "pk_two"
            $0.cacheNamespace = "prod"
        }
        #expect(first.cacheKeyHash == rotated.cacheKeyHash)

        let (defaultOne, _) = validated { $0.clientKey = "pk_one" }
        let (defaultTwo, _) = validated { $0.clientKey = "pk_two" }
        #expect(defaultOne.cacheKeyHash != defaultTwo.cacheKeyHash)
    }

    @Test("the hash is 16 lowercase hex chars over the canonical url")
    func cacheHashShape() {
        let (config, _) = validated { $0.baseURL = URL(string: "HTTPS://Lever.Example:443/")! }
        #expect(config.cacheKeyHash.count == 16)
        #expect(config.cacheKeyHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(
            config.cacheKeyHash
                == cacheKeyHash(baseURL: URL(string: "https://lever.example")!, namespace: "pk_test")
        )
    }
}
