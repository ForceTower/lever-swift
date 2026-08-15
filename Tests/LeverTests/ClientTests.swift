import Foundation
import Observation
import Testing

@testable import Lever

/// A second `json` model over the same wire key, to prove the memo never serves
/// a decoded value to a key expecting a different type (§2.3).
struct Headline: Codable, Equatable, Sendable {
    let headline: String
}

extension LeverKeys {
    var paywallHeadline: LeverKey<Headline> {
        LeverKey(json: "paywall", default: Headline(headline: "fallback"))
    }
}

private func representation(
    version: Int,
    _ values: [String: WireValue],
    etag: String? = nil,
    fetchedAt: Int = 1_755_100_000
) -> Representation {
    Representation(
        version: version,
        values: values,
        etag: etag,
        fetchedAt: fetchedAt,
        activatedAt: nil
    )
}

private let flagOn: [String: WireValue] = ["flag": WireValue(type: "boolean", value: .bool(true))]
private let flagOff: [String: WireValue] = ["flag": WireValue(type: "boolean", value: .bool(false))]

@Suite("staging and activation (§4)")
struct ActivationTests {
    private func cacheOnlyHarness() -> (TestHarness, LeverClient) {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        return (harness, client)
    }

    @Test("a fetch stages: reads are stable until activate")
    func stagingIsInvisible() {
        let (_, client) = cacheOnlyHarness()
        #expect(client.flag == false)
        #expect(client.activatedVersion == nil)

        client.stage(representation(version: 1, flagOn))
        #expect(client.flag == false)
        #expect(client.activatedVersion == nil)

        #expect(client.activate() == true)
        #expect(client.flag == true)
        #expect(client.activatedVersion == 1)
    }

    @Test("activate with nothing staged does nothing")
    func emptyActivate() {
        let (_, client) = cacheOnlyHarness()
        #expect(client.activate() == false)
        #expect(client.activatedVersion == nil)
    }

    @Test("an identical staged payload commits silently")
    func identicalPayload() async {
        let (harness, client) = cacheOnlyHarness()
        client.stage(representation(version: 1, flagOn, etag: "\"a\""))
        #expect(client.activate() == true)

        let updates = client.updates
        client.stage(representation(version: 1, flagOn, etag: "\"a\""))
        #expect(client.activate() == false)

        // No LeverUpdate was yielded.
        let received = Box<LeverUpdate?>(nil)
        let collector = Task { for await update in updates { received.set(update) } }
        await settle()
        collector.cancel()
        #expect(received.current == nil)
        _ = harness
    }

    @Test("a metadata-only commit advances the version, the etag, and the cache — silently")
    func metadataOnlyCommit() {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }

        client.stage(representation(version: 1, flagOn, etag: "\"one\""))
        #expect(client.activate() == true)

        // Same resolved values, new publish: the service always changes version
        // and ETag, even when this client's values are identical (§4).
        client.stage(representation(version: 2, flagOn, etag: "\"two\""))
        #expect(client.activate() == false)
        #expect(client.activatedVersion == 2)

        let cached = harness.cacheStore().loadSnapshot()
        #expect(cached?.version == 2)
        #expect(cached?.etag == "\"two\"")

        // And it survives a restart.
        let restarted = harness.makeClient { $0.automaticUpdates = false }
        #expect(restarted.activatedVersion == 2)
        #expect(restarted.flag == true)
    }

    @Test("activating a never-published environment yields version 0, not nil")
    func versionZero() {
        let (_, client) = cacheOnlyHarness()
        client.stage(representation(version: 0, [:]))
        #expect(client.activate() == false)
        #expect(client.activatedVersion == 0)
        #expect(client.flag == false)
    }

    @Test("changedKeys is the exact raw diff: added, removed, and changed")
    func changedKeysDiff() async {
        let (_, client) = cacheOnlyHarness()
        client.stage(
            representation(
                version: 1,
                [
                    "kept": WireValue(type: "string", value: .string("same")),
                    "changed": WireValue(type: "boolean", value: .bool(false)),
                    "removed": WireValue(type: "number", value: .int(1)),
                ]
            )
        )
        #expect(client.activate() == true)

        let updates = client.updates
        client.stage(
            representation(
                version: 2,
                [
                    "kept": WireValue(type: "string", value: .string("same")),
                    "changed": WireValue(type: "boolean", value: .bool(true)),
                    "added": WireValue(type: "number", value: .int(9)),
                ]
            )
        )
        #expect(client.activate() == true)

        var iterator = updates.makeAsyncIterator()
        let update = await iterator.next()
        #expect(update?.version == 2)
        #expect(update?.changedKeys == ["changed", "added", "removed"])
    }

    @Test("a number that only changes its Swift case is not a change")
    func numberEquivalence() {
        let (_, client) = cacheOnlyHarness()
        client.stage(
            representation(version: 1, ["n": WireValue(type: "number", value: .int(3))])
        )
        #expect(client.activate() == true)
        client.stage(
            representation(version: 2, ["n": WireValue(type: "number", value: .double(3.0))])
        )
        #expect(client.activate() == false)
    }
}

@Suite("reads (§2.3)")
struct ReadTests {
    @Test("the cache is loaded before any async work, so the first read serves it")
    func synchronousCacheLoad() {
        let harness = TestHarness()
        harness.seedCache(version: 7, flagOn, etag: "\"cached\"")

        let client = harness.makeClient { $0.automaticUpdates = false }
        // Deliberately the first statement after init — no await in between.
        #expect(client.flag == true)
        #expect(client.activatedVersion == 7)
    }

    @Test("absence logs once per key and version, at debug")
    func absenceDedupe() {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }

        for _ in 0..<50 { _ = client.flag }
        #expect(harness.sink.count(.debug, containing: "key absent key=flag") == 1)

        client.stage(representation(version: 1, flagOn))
        _ = client.activate()
        for _ in 0..<50 { _ = client.greeting }
        #expect(harness.sink.count(.debug, containing: "key absent key=greeting") == 1)
    }

    @Test("a mismatch warns once per key, version, and Swift type")
    func mismatchDedupe() {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        client.stage(
            representation(version: 1, ["flag": WireValue(type: "string", value: .string("x"))])
        )
        _ = client.activate()

        for _ in 0..<50 { _ = client.flag }
        #expect(client.flag == false)
        #expect(harness.sink.count(.warn, containing: "type mismatch key=flag") == 1)

        // A new version re-opens the dedupe: the payload may have been fixed.
        client.stage(
            representation(version: 2, ["flag": WireValue(type: "string", value: .string("x"))])
        )
        _ = client.activate()
        _ = client.flag
        #expect(harness.sink.count(.warn, containing: "type mismatch key=flag") == 2)
    }

    @Test("one wire key read through two json types decodes each correctly")
    func memoIsPerType() {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        client.stage(
            representation(
                version: 1,
                [
                    "paywall": WireValue(
                        type: "json",
                        value: .object(["headline": .string("Go Pro"), "trialDays": .int(7)])
                    )
                ]
            )
        )
        _ = client.activate()

        #expect(client.paywall == Paywall(headline: "Go Pro", trialDays: 7))
        #expect(client.paywallHeadline == Headline(headline: "Go Pro"))
        // Reading in the other order must not serve a memoized value of the
        // wrong type either.
        #expect(client.paywall == Paywall(headline: "Go Pro", trialDays: 7))
    }

    @Test("the json memo is dropped when the values change")
    func memoInvalidation() {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        let first = WireValue(
            type: "json",
            value: .object(["headline": .string("One"), "trialDays": .int(1)])
        )
        client.stage(representation(version: 1, ["paywall": first]))
        _ = client.activate()
        #expect(client.paywall.headline == "One")

        let second = WireValue(
            type: "json",
            value: .object(["headline": .string("Two"), "trialDays": .int(2)])
        )
        client.stage(representation(version: 2, ["paywall": second]))
        _ = client.activate()
        #expect(client.paywall.headline == "Two")
    }
}

@Suite("observation and updates (§4.1)")
struct ObservationTests {
    @Test("observation fires on a value change")
    func firesOnValueChange() async {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        let fired = Box(false)

        withObservationTracking {
            _ = client.flag
        } onChange: {
            fired.set(true)
        }

        client.stage(representation(version: 1, flagOn))
        #expect(client.activate() == true)
        await settle(2)
        #expect(fired.current == true)
    }

    @Test("observation stays quiet for a metadata-only commit")
    func silentOnMetadataOnly() async {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        client.stage(representation(version: 1, flagOff, etag: "\"one\""))
        _ = client.activate()

        let fired = Box(false)
        withObservationTracking {
            _ = client.flag
        } onChange: {
            fired.set(true)
        }

        client.stage(representation(version: 2, flagOff, etag: "\"two\""))
        #expect(client.activate() == false)
        await settle(2)
        #expect(fired.current == false)
        #expect(client.activatedVersion == 2)
    }

    @Test("every consumer of updates gets every activation")
    func multipleConsumers() async {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }

        let first = client.updates
        let second = client.updates

        async let firstUpdate = { () -> LeverUpdate? in
            var iterator = first.makeAsyncIterator()
            return await iterator.next()
        }()
        async let secondUpdate = { () -> LeverUpdate? in
            var iterator = second.makeAsyncIterator()
            return await iterator.next()
        }()

        await settle(2)
        client.stage(representation(version: 3, flagOn))
        #expect(client.activate() == true)

        #expect(await firstUpdate == LeverUpdate(version: 3, changedKeys: ["flag"]))
        #expect(await secondUpdate == LeverUpdate(version: 3, changedKeys: ["flag"]))
    }

    @Test("a log sink that reads the client does not deadlock", .timeLimit(.minutes(1)))
    func reentrantLogSink() {
        let harness = TestHarness()
        let clientBox = Box<LeverClient?>(nil)
        harness.sink.onLog {
            // Reading from inside a callout would deadlock if the state lock
            // were still held (§4.1).
            _ = clientBox.current?.greeting
        }
        let client = harness.makeClient { $0.automaticUpdates = false }
        clientBox.set(client)

        client.stage(
            representation(version: 1, ["flag": WireValue(type: "string", value: .string("x"))])
        )
        _ = client.activate()
        _ = client.flag
        #expect(client.activatedVersion == 1)
    }

    @Test("an observation callback that reads the client does not deadlock", .timeLimit(.minutes(1)))
    func reentrantObservation() async {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        let observed = Box<Bool?>(nil)

        withObservationTracking {
            _ = client.flag
        } onChange: {
            observed.set(client.flag)
        }

        client.stage(representation(version: 1, flagOn))
        _ = client.activate()
        await settle(2)
        #expect(observed.current != nil)
    }
}

@Suite("the shared instance (§2.1)")
struct SharedInstanceTests {
    @Test("configure installs a client that shared returns")
    func configureAndRead() {
        Lever.resetForTesting()
        defer { Lever.resetForTesting() }

        let harness = TestHarness()
        harness.seedCache(version: 4, flagOn)
        var configuration = harness.configuration()
        configuration.automaticUpdates = false
        Lever.configure(configuration)

        #expect(Lever.shared.flag == true)
        #expect(Lever.shared.activatedVersion == 4)
        #expect(Lever.shared === Lever.shared)
    }
}
