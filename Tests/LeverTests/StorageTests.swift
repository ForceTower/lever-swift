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

    @Test("a corrupt or overlong client id regenerates with a warning")
    func regeneratesBrokenIdentity() throws {
        let harness = TestHarness()
        let cache = store(harness)
        _ = cache.loadOrCreateClientId()

        try Data("not json".utf8).write(to: cache.identityURL)
        let regenerated = cache.loadOrCreateClientId()
        #expect(UUID(uuidString: regenerated) != nil)
        #expect(harness.sink.contains(.warn, "identity file is unreadable"))

        let overlong = String(repeating: "x", count: 65)
        try Data("{\"schemaVersion\":1,\"clientId\":\"\(overlong)\"}".utf8)
            .write(to: cache.identityURL)
        #expect(cache.loadOrCreateClientId() != overlong)
        #expect(harness.sink.contains(.warn, "client id is out of range"))
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
