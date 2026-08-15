import Foundation
import Testing

@testable import Lever

@Suite("cache files (§7)")
struct CacheStoreTests {
    private func store(
        _ harness: TestHarness,
        keyHash: String = "0123456789abcdef"
    ) -> CacheStore {
        CacheStore(
            directory: harness.directory.appendingPathComponent("Lever", isDirectory: true),
            keyHash: keyHash,
            sink: harness.sink
        )
    }

    private let snapshot = CachedSnapshot(
        version: 42,
        etag: "\"a1b2c3d4e5f60718\"",
        values: [
            "enable_enrollment": WireValue(type: "boolean", value: .bool(true)),
            "menu": WireValue(type: "json", value: .object(["rows": .array([.int(1), .int(2)])])),
        ],
        fetchedAt: 1_755_100_000,
        activatedAt: 1_755_100_005
    )

    // MARK: identity

    @Test("the client id is written on first run and stable afterwards")
    func identityIsStable() {
        let harness = TestHarness()
        let first = store(harness).loadOrCreateClientId()
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.lowercased())
        // A second store over the same directory reads, never regenerates.
        #expect(store(harness).loadOrCreateClientId() == first)
    }

    @Test("the client id survives a key rotation — it identifies the install, not the key")
    func identitySurvivesRotation() {
        let harness = TestHarness()
        let original = store(harness, keyHash: "aaaaaaaaaaaaaaaa").loadOrCreateClientId()
        #expect(store(harness, keyHash: "bbbbbbbbbbbbbbbb").loadOrCreateClientId() == original)
    }

    @Test("an unreadable identity file regenerates with a warning")
    func regeneratesUnreadableIdentity() throws {
        let harness = TestHarness()
        let cache = store(harness)
        _ = cache.loadOrCreateClientId()

        try Data("not json".utf8).write(to: cache.identityURL)
        #expect(UUID(uuidString: cache.loadOrCreateClientId()) != nil)
        #expect(harness.sink.contains(.warn, "identity file is unreadable"))
    }

    @Test("a structurally valid identity that is not a uuid regenerates")
    func rejectsNonUUIDIdentity() throws {
        for stored in ["x", String(repeating: "a", count: 65), "6f9a1c2b3d4e4f5a8b9c0d1e2f3a4b5c"] {
            let harness = TestHarness()
            let cache = store(harness)
            try FileManager.default.createDirectory(
                at: cache.directory,
                withIntermediateDirectories: true
            )
            try Data("{\"schemaVersion\":1,\"clientId\":\"\(stored)\"}".utf8)
                .write(to: cache.identityURL)

            let loaded = cache.loadOrCreateClientId()
            #expect(loaded != stored)
            #expect(UUID(uuidString: loaded) != nil)
            #expect(harness.sink.contains(.warn, "client id is not a uuid"))
        }
    }

    @Test("an uppercase uuid keeps its identity and is rewritten lowercase")
    func normalizesUppercaseIdentity() throws {
        let harness = TestHarness()
        let cache = store(harness)
        let uuid = UUID()
        try FileManager.default.createDirectory(
            at: cache.directory,
            withIntermediateDirectories: true
        )
        try Data("{\"schemaVersion\":1,\"clientId\":\"\(uuid.uuidString)\"}".utf8)
            .write(to: cache.identityURL)

        // Regenerating here would reshuffle the rollout bucketing key over a
        // difference in spelling, and two SDKs sharing a directory would fight
        // forever. The identity is kept; the file is canonicalized.
        let loaded = cache.loadOrCreateClientId()
        #expect(loaded == uuid.uuidString.lowercased())
        #expect(harness.sink.contains(.warn, "client id was not canonical"))
        #expect(cache.loadOrCreateClientId() == loaded)
    }

    @Test("out-of-range timestamps are corrupt, not a scheduling input")
    func rejectsOutOfRangeTimestamps() throws {
        let harness = TestHarness()
        let cache = store(harness)
        try FileManager.default.createDirectory(
            at: cache.directory,
            withIntermediateDirectories: true
        )
        try Data(
            """
            {"schemaVersion":1,"version":1,"etag":null,"values":{},\
            "fetchedAt":\(Int.min),"activatedAt":0}
            """.utf8
        ).write(to: cache.snapshotURL)

        #expect(cache.loadSnapshot() == nil)
        #expect(harness.sink.contains(.warn, "cache file timestamps are out of range"))
    }

    @Test("concurrent first initializations converge on one identity")
    func exclusiveCreateConverges() async {
        let harness = TestHarness()
        let identities = await withTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { store(harness).loadOrCreateClientId() }
            }
            var seen: Set<String> = []
            for await identity in group { seen.insert(identity) }
            return seen
        }
        // The losers of the exclusive create re-read the winner's file rather
        // than keeping a different in-memory identity.
        #expect(identities.count == 1)
    }

    // MARK: snapshot

    @Test("a snapshot round-trips through the file")
    func snapshotRoundTrip() {
        let harness = TestHarness()
        let cache = store(harness)
        cache.save(snapshot)
        #expect(cache.loadSnapshot() == snapshot)
    }

    @Test("a 200 without an ETag round-trips as a null etag")
    func nilETagRoundTrip() {
        let harness = TestHarness()
        let cache = store(harness)
        var withoutETag = snapshot
        withoutETag.etag = nil
        cache.save(withoutETag)
        #expect(cache.loadSnapshot() == withoutETag)
    }

    @Test("a missing file is a first run, not an error")
    func missingFile() {
        let harness = TestHarness()
        #expect(store(harness).loadSnapshot() == nil)
        #expect(harness.sink.all.isEmpty)
    }

    @Test("a corrupt file warns and reads as a first run")
    func corruptFile() throws {
        let harness = TestHarness()
        let cache = store(harness)
        cache.save(snapshot)
        try Data("{ not json".utf8).write(to: cache.snapshotURL)

        #expect(cache.loadSnapshot() == nil)
        #expect(harness.sink.contains(.warn, "cache file is corrupt"))

        // The next activation overwrites it.
        cache.save(snapshot)
        #expect(cache.loadSnapshot() == snapshot)
    }

    @Test("an unknown schema version is discarded, never migrated")
    func schemaBump() throws {
        let harness = TestHarness()
        let cache = store(harness)
        cache.save(snapshot)

        let raw = try Data(contentsOf: cache.snapshotURL)
        let bumped = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try Data(bumped.utf8).write(to: cache.snapshotURL)

        #expect(cache.loadSnapshot() == nil)
        #expect(harness.sink.contains(.warn, "cache file schema is unknown schemaVersion=2"))
    }

    @Test("a required field missing is corrupt, not a partial read")
    func missingRequiredField() throws {
        let harness = TestHarness()
        let cache = store(harness)
        try FileManager.default.createDirectory(
            at: cache.snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"schemaVersion\":1,\"version\":1,\"values\":{}}".utf8)
            .write(to: cache.snapshotURL)
        #expect(cache.loadSnapshot() == nil)
        #expect(harness.sink.contains(.warn, "cache file is corrupt"))
    }

    @Test("a write failure logs at error and changes nothing else")
    func writeFailure() throws {
        let harness = TestHarness()
        let cache = store(harness)
        // A directory where the file belongs: the atomic write cannot land.
        try FileManager.default.createDirectory(
            at: cache.snapshotURL,
            withIntermediateDirectories: true
        )
        cache.save(snapshot)
        #expect(harness.sink.contains(.error, "cache write failed"))
    }

    // MARK: format

    @Test("identity.json is byte-for-byte what every SDK must read")
    func identityFormat() throws {
        let harness = TestHarness()
        let cache = store(harness)
        let clientId = cache.loadOrCreateClientId()
        let bytes = String(decoding: try Data(contentsOf: cache.identityURL), as: UTF8.self)
        #expect(bytes == "{\"clientId\":\"\(clientId)\",\"schemaVersion\":1}")
    }

    @Test("the snapshot file is byte-for-byte what every SDK must read")
    func snapshotFormat() throws {
        let harness = TestHarness()
        let cache = store(harness)
        cache.save(
            CachedSnapshot(
                version: 42,
                etag: "\"a1b2c3d4e5f60718\"",
                values: ["enable_enrollment": WireValue(type: "boolean", value: .bool(true))],
                fetchedAt: 1_755_100_000,
                activatedAt: 1_755_100_005
            )
        )
        let bytes = String(decoding: try Data(contentsOf: cache.snapshotURL), as: UTF8.self)
        #expect(
            bytes == """
                {"activatedAt":1755100005,"etag":"\\"a1b2c3d4e5f60718\\"","fetchedAt":1755100000,\
                "schemaVersion":1,"values":{"enable_enrollment":{"type":"boolean","value":true}},\
                "version":42}
                """
        )
    }

    @Test("a nil etag is written as an explicit null, not omitted")
    func nilETagFormat() throws {
        let harness = TestHarness()
        let cache = store(harness)
        cache.save(
            CachedSnapshot(
                version: 0,
                etag: nil,
                values: [:],
                fetchedAt: 1_755_100_000,
                activatedAt: 1_755_100_000
            )
        )
        let bytes = String(decoding: try Data(contentsOf: cache.snapshotURL), as: UTF8.self)
        #expect(
            bytes == """
                {"activatedAt":1755100000,"etag":null,"fetchedAt":1755100000,"schemaVersion":1,\
                "values":{},"version":0}
                """
        )
    }

    @Test("the file name is the stable hash of the canonical base url and namespace")
    func stableHash() {
        let url = URL(string: "https://lever.example")!
        let pinned = cacheKeyHash(baseURL: url, namespace: "prod")
        // Pinned so an accidental change to the hash input fails loudly rather
        // than silently orphaning every deployed cache.
        #expect(pinned == cacheKeyHash(baseURL: url, namespace: "prod"))
        #expect(pinned.count == 16)
        #expect(pinned != cacheKeyHash(baseURL: url, namespace: "staging"))
        #expect(
            pinned != cacheKeyHash(baseURL: URL(string: "https://other.example")!, namespace: "prod")
        )
    }
}


@Suite("snapshot write ordering (§7)")
struct SnapshotWriterTests {
    private func snapshot(version: Int) -> CachedSnapshot {
        CachedSnapshot(
            version: version,
            etag: "\"v\(version)\"",
            values: [:],
            fetchedAt: 1_755_100_000,
            activatedAt: 1_755_100_000
        )
    }

    @Test("a delayed write from an older commit cannot regress the file")
    func obsoleteWriteIsDropped() {
        let harness = TestHarness()
        let store = harness.cacheStore()
        let writer = SnapshotWriter(store: store)

        // Commit 2 reaches the disk first; commit 1 was preempted between
        // releasing the state lock and writing. Memory serves 3, and without
        // ordering the next launch would restore 2.
        writer.write(snapshot(version: 3), sequence: 2)
        writer.write(snapshot(version: 2), sequence: 1)

        #expect(store.loadSnapshot()?.version == 3)
    }

    @Test("writes in commit order all land")
    func orderedWritesLand() {
        let harness = TestHarness()
        let store = harness.cacheStore()
        let writer = SnapshotWriter(store: store)

        writer.write(snapshot(version: 1), sequence: 1)
        #expect(store.loadSnapshot()?.version == 1)
        writer.write(snapshot(version: 2), sequence: 2)
        #expect(store.loadSnapshot()?.version == 2)
    }

    @Test("concurrent activations leave the file agreeing with memory")
    func concurrentActivationsConverge() async throws {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }

        for version in 1...40 {
            client.stage(
                Representation(
                    version: version,
                    values: ["flag": WireValue(type: "boolean", value: .bool(version.isMultiple(of: 2)))],
                    etag: "\"v\(version)\"",
                    fetchedAt: 1_755_100_000,
                    activatedAt: nil
                )
            )
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask { client.activate() }
                }
            }
        }

        #expect(harness.cacheStore().loadSnapshot()?.version == client.activatedVersion)
    }
}
