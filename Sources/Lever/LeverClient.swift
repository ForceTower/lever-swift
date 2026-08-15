import Foundation
import Observation
import Synchronization

/// A validated payload the client holds, with the network metadata that belongs
/// to *it* rather than to the client globally (§4).
///
/// The split is load-bearing: a 304 confirms whichever representation's
/// validator was sent, so a single shared `etag`/`fetchedAt` pair would let
/// staged metadata corrupt activated state.
struct Representation: Sendable, Equatable {
    var version: Int
    var values: [String: WireValue]
    var etag: String?
    var fetchedAt: Int
    var activatedAt: Int?
}

/// The lever client: synchronous typed reads over the last activated snapshot,
/// with fetching, activation, and observation around them.
///
/// Reads never `await` — that is the whole point. `body` reading a flag must be
/// a lock-protected dictionary lookup, not an actor hop (research 0002 §4.4).
@dynamicMemberLookup
public final class LeverClient: Observable, Sendable {
    let configuration: ValidatedConfiguration
    let clientId: String

    private let cache: CacheStore
    private let writer: SnapshotWriter
    private let registrar = ObservationRegistrar()
    private let state = Mutex(State())
    private let now: @Sendable () -> Int
    private let runtime: LeverRuntime

    /// The single member observation is tracked on. Granularity is deliberately
    /// coarse — any activation invalidates every observing view, which at the
    /// audited scale costs one extra body evaluation per flip and buys a
    /// trivially correct implementation (§4.1).
    private var observedSnapshot: Void { () }

    struct State {
        var activated: Representation?
        var staged: Representation?
        /// Bumped on every activated swap, so a decode that raced an activation
        /// cannot install a stale memo entry.
        var generation: UInt64 = 0
        var memo: [MemoKey: any Sendable] = [:]
        var logged: Set<LogKey> = []
        /// Stamped under this lock on every commit, so persistence can be
        /// replayed to disk in the order the commits actually happened.
        var writeSequence: UInt64 = 0
        var continuations: [Int: AsyncStream<LeverUpdate>.Continuation] = [:]
        var nextContinuationID = 0
    }

    struct MemoKey: Hashable, Sendable {
        let name: String
        let valueType: ObjectIdentifier
    }

    struct LogKey: Hashable, Sendable {
        let name: String
        let version: Int?
        /// `nil` for absence, which dedupes per `(key, version)`; a mismatch
        /// dedupes per `(key, version, Swift type)` because two keys may share
        /// a wire name with different `Value` types (§2.3).
        let valueType: ObjectIdentifier?
    }

    public convenience init(configuration: LeverConfiguration) {
        self.init(configuration: configuration, environment: .live)
    }

    init(configuration: LeverConfiguration, environment: LeverEnvironment) {
        let validated = validate(configuration)
        self.configuration = validated
        self.now = environment.now
        cache = CacheStore(
            directory: validated.cacheDirectory,
            keyHash: validated.cacheKeyHash,
            sink: validated.logSink
        )
        writer = SnapshotWriter(store: cache)

        // Both before any `await`: the identity must exist before the first
        // fetch can send it, and the cache must be in memory before the first
        // read can happen. This ordering is the three-layer floor made
        // structural (§4).
        clientId = cache.loadOrCreateClientId()
        if let cached = cache.loadSnapshot() {
            state.withLock { state in
                state.activated = Representation(
                    version: cached.version,
                    values: cached.values,
                    etag: cached.etag,
                    fetchedAt: cached.fetchedAt,
                    activatedAt: cached.activatedAt
                )
            }
        }

        runtime = LeverRuntime(configuration: validated, environment: environment)
        runtime.start(client: self)
    }

    deinit {
        // The client retains the runtime; the runtime's tasks hold only weak
        // back-references, so this is the one teardown point (§4.1).
        runtime.tearDown()
    }

    // MARK: - Reads

    public subscript<Value>(dynamicMember keyPath: KeyPath<LeverKeys, LeverKey<Value>>) -> Value {
        value(for: LeverKeys()[keyPath: keyPath])
    }

    /// The non-magic read, and the way to read a key whose property name would
    /// collide with a real member (`fetch`, `updates`, …) — real members always
    /// win over dynamic ones (§2.2).
    public func value<Value>(for key: LeverKey<Value>) -> Value {
        registrar.access(self, keyPath: \.observedSnapshot)

        let memoKey = MemoKey(name: key.name, valueType: key.valueType)
        let (raw, version, generation, memoized) = state.withLock {
            state -> (WireValue?, Int?, UInt64, (any Sendable)?) in
            (
                state.activated?.values[key.name],
                state.activated?.version,
                state.generation,
                key.memoizes ? state.memo[memoKey] : nil
            )
        }

        // Everything below runs outside the lock: `JSONDecoder` runs arbitrary
        // `Decodable` code and the sink is the host app's (§4.1).
        if let memoized = memoized as? Value { return memoized }

        switch resolveRead(key, in: raw.map { [key.name: $0] } ?? [:]) {
        case .resolved(let decoded):
            if key.memoizes {
                state.withLock { state in
                    guard state.generation == generation else { return }
                    state.memo[memoKey] = decoded
                }
            }
            return decoded

        case .absent:
            // Absence is the normal state mid-rollout, and a hot SwiftUI read
            // must not flood even the debug channel.
            logOnce(
                LogKey(name: key.name, version: version, valueType: nil),
                level: .debug,
                message: "key absent key=\(key.name)"
            )
            return key.defaultValue

        case .mismatch:
            logOnce(
                LogKey(name: key.name, version: version, valueType: key.valueType),
                level: .warn,
                message:
                    "type mismatch key=\(key.name) wire=\(raw?.type ?? "none") as=\(Value.self)"
            )
            return key.defaultValue
        }
    }

    /// `nil` until the first activation ever; `0` after activating a
    /// never-published environment (§2).
    public var activatedVersion: Int? {
        registrar.access(self, keyPath: \.observedSnapshot)
        return state.withLock { $0.activated?.version }
    }

    /// A fresh stream per access, so any number of consumers can listen
    /// independently and a stream obtained before an activation receives it.
    public var updates: AsyncStream<LeverUpdate> {
        let (stream, continuation) = AsyncStream<LeverUpdate>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = state.withLock { state -> Int in
            state.nextContinuationID += 1
            state.continuations[state.nextContinuationID] = continuation
            return state.nextContinuationID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.continuations[id] = nil }
        }
        return stream
    }

    // MARK: - Control

    /// Fetches and stages. Explicit calls always hit the network: the interval
    /// throttles the SDK, not the developer (§5.1).
    public func fetch() async throws {
        try await runtime.fetch(reason: .explicit)
    }

    /// Commits the staged representation, if any.
    ///
    /// Returns `true` only when the **serving values** changed. The service
    /// bumps version and ETag on every publish even when this client's resolved
    /// values are identical, so representation commit and observable value
    /// change are deliberately separate (§4).
    @discardableResult
    public func activate() -> Bool {
        let activatedAt = now()

        let outcome = state.withLock { state -> Activation? in
            guard let staged = state.staged else { return nil }

            let before = state.activated?.values ?? [:]
            let changed = staged.values != before

            var committed = staged
            committed.activatedAt = activatedAt
            state.activated = committed
            state.staged = nil
            state.generation &+= 1
            state.writeSequence &+= 1
            // A version bump re-opens the per-version dedupe either way.
            state.logged.removeAll()
            if changed { state.memo.removeAll() }

            return Activation(
                sequence: state.writeSequence,
                snapshot: CachedSnapshot(
                    version: committed.version,
                    etag: committed.etag,
                    values: committed.values,
                    fetchedAt: committed.fetchedAt,
                    activatedAt: activatedAt
                ),
                update: changed
                    ? LeverUpdate(
                        version: committed.version,
                        changedKeys: changedKeys(from: before, to: committed.values)
                    )
                    : nil,
                continuations: changed ? Array(state.continuations.values) : []
            )
        }

        guard let outcome else { return false }

        // A metadata-only commit still persists, so `activatedVersion` and the
        // cached snapshot track the server across value-identical publishes.
        writer.write(outcome.snapshot, sequence: outcome.sequence)

        guard let update = outcome.update else {
            configuration.logSink.debug("committed version=\(outcome.snapshot.version) changed=0")
            return false
        }

        configuration.logSink.info(
            "activated version=\(update.version) changed=\(update.changedKeys.count)"
        )
        // The swap already happened; this notifies observers of it. Firing the
        // registrar outside the lock is what keeps a host observer that reads a
        // flag from deadlocking (§4.1).
        registrar.withMutation(of: self, keyPath: \.observedSnapshot) {}
        for continuation in outcome.continuations { continuation.yield(update) }
        return true
    }

    @discardableResult
    public func fetchAndActivate() async throws -> Bool {
        try await fetch()
        return activate()
    }

    private struct Activation {
        let sequence: UInt64
        let snapshot: CachedSnapshot
        let update: LeverUpdate?
        let continuations: [AsyncStream<LeverUpdate>.Continuation]
    }

    // MARK: - Runtime seam

    /// The version of the newest validated representation this process holds.
    /// Derived, never stored — this, never a nudge frame, is what nudge dedupe
    /// compares against (§4).
    var lastKnownVersion: Int? {
        state.withLock { $0.staged?.version ?? $0.activated?.version }
    }

    /// The validator and min-interval clock both read the newest
    /// representation: staged when present, otherwise activated (§4). Which one
    /// it was decides who a later 304 confirms.
    var newestRepresentation: (representation: Representation, isStaged: Bool)? {
        state.withLock { state in
            if let staged = state.staged { return (staged, true) }
            if let activated = state.activated { return (activated, false) }
            return nil
        }
    }

    func stage(_ representation: Representation) {
        state.withLock { $0.staged = representation }
    }

    /// A 304 refreshes the freshness of whichever representation's validator was
    /// sent (§6.1). Returns `true` when the activated representation was the one
    /// confirmed, which is the case that must be persisted.
    @discardableResult
    func confirmFreshness(ofStaged: Bool, at fetchedAt: Int) -> Bool {
        let commit = state.withLock { state -> (CachedSnapshot, UInt64)? in
            if ofStaged {
                // Staged metadata must never be combined with activated values.
                state.staged?.fetchedAt = fetchedAt
                return nil
            }
            guard var activated = state.activated else { return nil }
            activated.fetchedAt = fetchedAt
            state.activated = activated
            state.writeSequence &+= 1
            return (
                CachedSnapshot(
                    version: activated.version,
                    etag: activated.etag,
                    values: activated.values,
                    fetchedAt: fetchedAt,
                    activatedAt: activated.activatedAt ?? fetchedAt
                ),
                state.writeSequence
            )
        }
        guard let commit else { return false }
        // Without this write the refreshed clock is lost on relaunch and the
        // next launch refetches inside the interval (§6.1). It is sequenced
        // like any other commit, so a delayed 304 write cannot land on top of a
        // newer activation.
        writer.write(commit.0, sequence: commit.1)
        return true
    }

    private func logOnce(_ key: LogKey, level: LeverLogLevel, message: @autoclosure () -> String) {
        let isFirst = state.withLock { $0.logged.insert(key).inserted }
        if isFirst { configuration.logSink.log(level, message()) }
    }

    // MARK: - Testing seams

    /// Test-only: the cache files this client reads and writes.
    var cacheStore: CacheStore { cache }
}

/// The raw diff `LeverUpdate.changedKeys` reports: added, removed, and changed,
/// compared over wire values rather than decoded ones (§4).
func changedKeys(from before: [String: WireValue], to after: [String: WireValue]) -> Set<String> {
    var changed: Set<String> = []
    for (key, value) in after where before[key] != value { changed.insert(key) }
    for key in before.keys where after[key] == nil { changed.insert(key) }
    return changed
}
