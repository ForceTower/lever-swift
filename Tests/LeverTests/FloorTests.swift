import Foundation
import Testing

@testable import Lever

/// Research 0001 §7's three-layer floor — live values, disk-cached
/// last-activated values, code defaults — exercised end to end with the
/// transport failing in every way it can.
///
/// This is the suite that decides whether the SDK is functional. Everything it
/// asserts was already unit-proven a layer down; what it adds is that the whole
/// stack, wired together, still keeps an app running when the network does not.
@Suite("the three-layer floor (§10.1)")
struct FloorTests {
    private let warmValues: [String: WireValue] = [
        "flag": WireValue(type: "boolean", value: .bool(true)),
        "greeting": WireValue(type: "string", value: .string("olá")),
        "retries": WireValue(type: "number", value: .int(9)),
        "rate": WireValue(type: "number", value: .double(0.25)),
        "paywall": WireValue(
            type: "json",
            value: .object(["headline": .string("Go Pro"), "trialDays": .int(7)])
        ),
    ]

    @Test("first run with an unreachable server: every read is its code default, nothing throws")
    func firstRunOffline() async {
        let harness = TestHarness()
        // Nothing scripted: every request fails like an unreachable network.
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }

        #expect(client.flag == false)
        #expect(client.greeting == "hi")
        #expect(client.retries == 3)
        #expect(client.rate == 1.5)
        #expect(client.paywall == Paywall(headline: "fallback", trialDays: 0))
        #expect(client.activatedVersion == nil)

        await settle()
        #expect(harness.transport.requests.count == 1)
        #expect(client.flag == false)
        #expect(harness.sink.contains(.warn, "automatic fetch failed"))
    }

    @Test("a warm cache serves from the first statement after init, offline")
    func warmCacheOffline() async {
        let harness = TestHarness()
        harness.seedCache(version: 12, warmValues, fetchedAt: harness.now - 100_000)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }

        // Deliberately before any await: the cache load is synchronous, which
        // is the floor made structural rather than promised.
        #expect(client.flag == true)
        #expect(client.greeting == "olá")
        #expect(client.retries == 9)
        #expect(client.rate == 0.25)
        #expect(client.paywall == Paywall(headline: "Go Pro", trialDays: 7))
        #expect(client.activatedVersion == 12)

        await settle()
        // The fetch was due and failed; the snapshot keeps serving.
        #expect(harness.transport.requests.count == 1)
        #expect(client.flag == true)
        #expect(client.activatedVersion == 12)
    }

    @Test("a 401 on resolve never clears the cache or stops reads")
    func unauthorizedResolveKeepsServing() async throws {
        let harness = TestHarness()
        harness.seedCache(version: 12, warmValues, fetchedAt: harness.now - 100_000)
        harness.transport.enqueue(.status(401))
        harness.transport.enqueue(.status(401))

        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(client.flag == true)
        #expect(client.activatedVersion == 12)
        #expect(harness.cacheStore().loadSnapshot()?.version == 12)

        // And explicitly, as a thrown error that still changes nothing.
        await #expect(throws: LeverError.invalidKey) { try await client.fetch() }
        #expect(client.flag == true)
        #expect(harness.cacheStore().loadSnapshot()?.version == 12)
    }

    @Test("a 401 on the stream stops retrying until foreground, and reads carry on")
    func unauthorizedStreamKeepsServing() async {
        let harness = TestHarness()
        harness.seedCache(version: 12, warmValues)
        harness.transport.enqueue(stream: StreamScript(status: 401).stream)

        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.transport.streamRequests.count == 1)
        await harness.advance(by: 100_000)
        #expect(harness.transport.streamRequests.count == 1)
        #expect(client.flag == true)
        #expect(harness.cacheStore().loadSnapshot()?.version == 12)
    }

    @Test("a corrupt cache falls back to defaults, warns, and rewrites on the next activation")
    func corruptCache() async throws {
        let harness = TestHarness()
        harness.seedCache(version: 12, warmValues)
        try Data("{ truncated".utf8).write(to: harness.cacheStore().snapshotURL)

        harness.transport.enqueue(
            .json(resolveBody(version: 13, ["flag": boolValue(true)]), etag: "\"new\"")
        )
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }

        #expect(client.flag == false)
        #expect(client.activatedVersion == nil)
        #expect(harness.sink.contains(.warn, "cache file is corrupt"))

        await settle()
        #expect(client.flag == true)
        #expect(harness.cacheStore().loadSnapshot()?.version == 13)
    }

    @Test("a cache file from a future schema is discarded, not migrated")
    func futureSchemaCache() throws {
        let harness = TestHarness()
        harness.seedCache(version: 12, warmValues)
        let url = harness.cacheStore().snapshotURL
        let bumped = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        try Data(bumped.utf8).write(to: url)

        let client = harness.makeClient { $0.automaticUpdates = false }
        #expect(client.flag == false)
        #expect(client.activatedVersion == nil)
        #expect(harness.sink.contains(.warn, "cache file schema is unknown"))
    }

    @Test("every kind of unreadable value falls back to its default with one warning")
    func mismatchFloor() async throws {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        harness.transport.enqueue(
            .json(
                resolveBody(
                    version: 1,
                    [
                        // Wrong wire type for every typed initializer.
                        "flag": stringValue("yes"),
                        "greeting": boolValue(true),
                        // A number that is not an exact Int.
                        "retries": numberValue("3.5"),
                        // A json payload the model cannot decode.
                        "paywall": jsonValue("{\"headline\":\"Go Pro\"}"),
                        // And one that is fine, to prove the rest still resolve.
                        "rate": numberValue("2.5"),
                    ]
                )
            )
        )
        _ = try await client.fetchAndActivate()

        for _ in 0..<20 {
            #expect(client.flag == false)
            #expect(client.greeting == "hi")
            #expect(client.retries == 3)
            #expect(client.paywall == Paywall(headline: "fallback", trialDays: 0))
            #expect(client.rate == 2.5)
        }

        for key in ["flag", "greeting", "retries", "paywall"] {
            #expect(harness.sink.count(.warn, containing: "type mismatch key=\(key)") == 1)
        }
    }

    @Test("an out-of-range number falls back rather than trapping")
    func outOfRangeNumber() async throws {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        harness.transport.enqueue(
            .json(resolveBody(version: 1, ["retries": numberValue("1e20")]))
        )
        _ = try await client.fetchAndActivate()
        #expect(client.retries == 3)
        #expect(client.rate == 1.5)
    }

    @Test("a key rotation with cacheNamespace set keeps the warm floor offline")
    func rotationWithNamespace() async throws {
        let harness = TestHarness()
        let before = harness.makeClient {
            $0.clientKey = "pk_one"
            $0.cacheNamespace = "prod"
            $0.automaticUpdates = false
        }
        harness.transport.enqueue(
            .json(resolveBody(version: 20, ["flag": boolValue(true)]), etag: "\"a\"")
        )
        _ = try await before.fetchAndActivate()

        // The app ships a new key; the server is unreachable on that launch.
        let after = harness.makeClient {
            $0.clientKey = "pk_two"
            $0.cacheNamespace = "prod"
            $0.automaticUpdates = false
        }
        #expect(after.flag == true)
        #expect(after.activatedVersion == 20)
        #expect(after.clientId == before.clientId)
    }

    @Test("a key rotation without a namespace starts cold, but the client id is stable")
    func rotationWithoutNamespace() async throws {
        let harness = TestHarness()
        let before = harness.makeClient {
            $0.clientKey = "pk_one"
            $0.automaticUpdates = false
        }
        harness.transport.enqueue(
            .json(resolveBody(version: 20, ["flag": boolValue(true)]), etag: "\"a\"")
        )
        _ = try await before.fetchAndActivate()

        let after = harness.makeClient {
            $0.clientKey = "pk_two"
            $0.automaticUpdates = false
        }
        // One cold start's worth of degradation — the documented cost of not
        // setting cacheNamespace.
        #expect(after.flag == false)
        #expect(after.activatedVersion == nil)
        // But the installation identity, the future bucketing key, is stable.
        #expect(after.clientId == before.clientId)
    }

    @Test("a cache-write failure leaves the in-memory activation standing")
    func cacheWriteFailure() async throws {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        // A directory where the snapshot file belongs.
        try FileManager.default.createDirectory(
            at: harness.cacheStore().snapshotURL,
            withIntermediateDirectories: true
        )

        harness.transport.enqueue(
            .json(resolveBody(version: 30, ["flag": boolValue(true)]), etag: "\"a\"")
        )
        #expect(try await client.fetchAndActivate() == true)

        // Reads serve the new snapshot; only the floor is stale.
        #expect(client.flag == true)
        #expect(client.activatedVersion == 30)
        #expect(harness.sink.contains(.error, "cache write failed"))
    }

    @Test("one writer, many readers: the reader sees the writer's last activation")
    func singleWriterManyReaders() async throws {
        let harness = TestHarness()
        let writer = harness.makeClient {
            $0.cacheNamespace = "prod"
            $0.automaticUpdates = false
        }
        harness.transport.enqueue(
            .json(resolveBody(version: 40, ["flag": boolValue(true)]), etag: "\"a\"")
        )
        _ = try await writer.fetchAndActivate()

        let readers = (0..<3).map { _ in
            harness.makeClient {
                $0.cacheNamespace = "prod"
                $0.automaticUpdates = false
            }
        }
        for reader in readers {
            #expect(reader.flag == true)
            #expect(reader.activatedVersion == 40)
            #expect(reader.clientId == writer.clientId)
        }
        await settle()
        // Readers never issue a request of their own.
        #expect(harness.transport.requests.count == 1)

        // A later write is visible to the next reader initialization.
        harness.transport.enqueue(
            .json(resolveBody(version: 41, ["flag": boolValue(false)]), etag: "\"b\"")
        )
        _ = try await writer.fetchAndActivate()
        let fresh = harness.makeClient {
            $0.cacheNamespace = "prod"
            $0.automaticUpdates = false
        }
        #expect(fresh.flag == false)
        #expect(fresh.activatedVersion == 41)
    }

}
