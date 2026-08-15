import Foundation
import Synchronization

@testable import Lever

// MARK: - Log sink

/// Records everything the SDK logs, and can run an arbitrary block from inside
/// `log` — which is how the reentrancy tests prove no lock is held during a
/// callout (§4.1).
final class RecordingLogSink: LeverLogSink, Sendable {
    struct Entry: Sendable, Equatable {
        let level: LeverLogLevel
        let message: String
    }

    private let entries = Mutex<[Entry]>([])
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    func log(_ level: LeverLogLevel, _ message: String) {
        entries.withLock { $0.append(Entry(level: level, message: message)) }
        hook.withLock { $0 }?()
    }

    var all: [Entry] { entries.withLock { $0 } }

    func messages(_ level: LeverLogLevel) -> [String] {
        all.filter { $0.level == level }.map(\.message)
    }

    func count(_ level: LeverLogLevel, containing needle: String) -> Int {
        messages(level).count { $0.contains(needle) }
    }

    func contains(_ level: LeverLogLevel, _ needle: String) -> Bool {
        count(level, containing: needle) > 0
    }

    func onLog(_ block: @escaping @Sendable () -> Void) {
        hook.withLock { $0 = block }
    }
}

// MARK: - Clock

/// A monotonic clock tests drive by hand: no sleeps, no flakes (§10).
final class ManualClock: LeverClock, Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [Sleeper] = []
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())

    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    /// The delays currently armed, relative to now — what the scheduling tests
    /// assert against.
    var armedDelays: [Duration] {
        state.withLock { state in state.sleepers.map { $0.deadline - state.now } }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Immediate { case fire, cancel, wait }
                let immediate: Immediate = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    let deadline = state.now + duration
                    guard deadline > state.now else { return .fire }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation)
                    )
                    return .wait
                }
                switch immediate {
                case .fire: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    // The handler beat the body; the body resumes instead.
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let fired = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return fired
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits until at least `count` sleepers are armed. Arming happens on the
    /// runtime actor, so a test cannot advance time the instant it asks for it.
    func waitForSleepers(_ count: Int) async {
        for _ in 0..<400 {
            if pendingSleepers >= count { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

// MARK: - Transport

/// Serves scripted responses and records every request. An exhausted script
/// answers like an unreachable network, which is exactly what the floor suite
/// wants by default (§10.1).
final class ScriptedTransport: LeverTransport, Sendable {
    private struct State {
        var responses: [Result<HTTPResponse, any Error>] = []
        var streams: [Result<HTTPStream, any Error>] = []
        var requests: [HTTPRequest] = []
        var streamRequests: [HTTPRequest] = []
        var invalidated = false
        var paused = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var streamRequests: [HTTPRequest] { state.withLock { $0.streamRequests } }
    var requestCount: Int { state.withLock { $0.requests.count } }
    var isInvalidated: Bool { state.withLock { $0.invalidated } }

    func enqueue(_ response: HTTPResponse) {
        state.withLock { $0.responses.append(.success(response)) }
    }

    func enqueue(error: any Error) {
        state.withLock { $0.responses.append(.failure(error)) }
    }

    func enqueue(stream: HTTPStream) {
        state.withLock { $0.streams.append(.success(stream)) }
    }

    func enqueue(streamError: any Error) {
        state.withLock { $0.streams.append(.failure(streamError)) }
    }

    /// Holds every subsequent `send` open — the seam the coalescing and
    /// cancellation tests need.
    func pause() {
        state.withLock { $0.paused = true }
    }

    func resume() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.paused = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until `count` requests have been recorded.
    func waitForRequests(_ count: Int) async {
        for _ in 0..<400 {
            if requestCount >= count { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        state.withLock { $0.requests.append(request) }
        await waitWhilePaused()
        try Task.checkCancellation()
        let next = state.withLock { state -> Result<HTTPResponse, any Error>? in
            state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        guard let next else { throw URLError(.notConnectedToInternet) }
        return try next.get()
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStream {
        state.withLock { $0.streamRequests.append(request) }
        let next = state.withLock { state -> Result<HTTPStream, any Error>? in
            state.streams.isEmpty ? nil : state.streams.removeFirst()
        }
        guard let next else {
            // Nothing scripted: park until cancelled rather than reconnect-loop.
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
        return try next.get()
    }

    func invalidate() {
        state.withLock { $0.invalidated = true }
    }

    private func waitWhilePaused() async {
        await withCheckedContinuation { continuation in
            let go = state.withLock { state -> Bool in
                guard state.paused else { return true }
                state.waiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }
}

extension HTTPResponse {
    static func json(_ body: String, status: Int = 200, etag: String? = nil) -> HTTPResponse {
        var headers = HTTPHeaders()
        if let etag { headers["ETag"] = etag }
        headers["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    static func status(_ status: Int, etag: String? = nil) -> HTTPResponse {
        var headers = HTTPHeaders()
        if let etag { headers["ETag"] = etag }
        return HTTPResponse(status: status, headers: headers, body: Data())
    }

    /// The platform handed back a non-HTTP `URLResponse`.
    static let nonHTTP = HTTPResponse(status: nil, headers: HTTPHeaders(), body: Data())
}

/// A stream whose bytes the test pushes by hand.
struct StreamScript: Sendable {
    let stream: HTTPStream
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

    init(
        status: Int? = 200,
        contentType: String? = "text/event-stream",
        retryAfter: String? = nil
    ) {
        let (bytes, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        var headers = HTTPHeaders()
        if let contentType { headers["Content-Type"] = contentType }
        if let retryAfter { headers["Retry-After"] = retryAfter }
        stream = HTTPStream(status: status, headers: headers, bytes: bytes)
        self.continuation = continuation
    }

    func send(_ text: String) {
        continuation.yield(Array(text.utf8))
    }

    func version(_ version: Int) {
        send("event: version\ndata: {\"version\":\(version)}\n\n")
    }

    func heartbeat() {
        send(": hb\n\n")
    }

    func close() {
        continuation.finish()
    }

    func fail(_ error: any Error = URLError(.networkConnectionLost)) {
        continuation.finish(throwing: error)
    }
}

// MARK: - Lifecycle

final class ManualLifecycleSource: LeverLifecycleSource, Sendable {
    private struct State {
        var initial: LeverLifecyclePhase
        var continuations: [AsyncStream<LeverLifecyclePhase>.Continuation] = []
        var subscriptions = 0
    }

    private let state: Mutex<State>

    init(initial: LeverLifecyclePhase = .foreground) {
        state = Mutex(State(initial: initial))
    }

    /// Zero for a cache-only client: no lifecycle observation ever starts (§5).
    var subscriptions: Int { state.withLock { $0.subscriptions } }

    func phases() -> AsyncStream<LeverLifecyclePhase> {
        AsyncStream { continuation in
            let initial = state.withLock { state -> LeverLifecyclePhase in
                state.subscriptions += 1
                state.continuations.append(continuation)
                return state.initial
            }
            continuation.yield(initial)
        }
    }

    func send(_ phase: LeverLifecyclePhase) {
        for continuation in state.withLock({ $0.continuations }) { continuation.yield(phase) }
    }
}

// MARK: - Harness

/// `Mutex` is `~Copyable`, so a closure that needs shared mutable state
/// captures this reference box instead of the mutex itself.
final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var current: Value { storage.withLock { $0 } }

    func set(_ value: Value) {
        storage.withLock { $0 = value }
    }

    func mutate(_ body: (inout Value) -> Void) {
        storage.withLock { body(&$0) }
    }
}

/// One client with every seam replaced, over a scratch directory.
final class TestHarness: Sendable {
    let transport = ScriptedTransport()
    let clock = ManualClock()
    let lifecycle: ManualLifecycleSource
    let sink = RecordingLogSink()
    let directory: URL
    private let wallClock: Box<Int>
    private let jitterValue: Box<Double>

    init(startingAt now: Int = 1_755_100_000, phase: LeverLifecyclePhase = .foreground) {
        lifecycle = ManualLifecycleSource(initial: phase)
        wallClock = Box(now)
        jitterValue = Box(1.0)
        directory = URL.temporaryDirectory.appendingPathComponent(
            "lever-tests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var now: Int { wallClock.current }

    /// Armed delays at stream scale — backoff tops out at 60 s and a
    /// `Retry-After` floor at 300 s, so this excludes the in-session fetch
    /// timer without the test having to know what interval it configured.
    var backoffDelays: [Duration] { clock.armedDelays.filter { $0 <= .seconds(300) } }

    func advanceWallClock(by seconds: Int) {
        wallClock.mutate { $0 += seconds }
    }

    func setWallClock(to seconds: Int) {
        wallClock.set(seconds)
    }

    /// Moves both clocks together, the way real time does. Tests that want to
    /// prove the timer is immune to wall-clock jumps move only one.
    func advance(by seconds: Int) async {
        advanceWallClock(by: seconds)
        clock.advance(by: .seconds(seconds))
        await settle()
    }

    /// The next backoff draw, as a fraction of the ceiling.
    func setJitter(_ fraction: Double) {
        jitterValue.set(fraction)
    }

    var environment: LeverEnvironment {
        let transport = transport
        let wallClock = wallClock
        let lifecycle = lifecycle
        let jitterValue = jitterValue
        return LeverEnvironment(
            makeTransport: { _ in transport },
            now: { wallClock.current },
            clock: clock,
            lifecycle: { lifecycle },
            jitter: { ceiling in ceiling * jitterValue.current }
        )
    }

    func configuration(
        clientKey: String = "pk_test",
        context: LeverContext = LeverContext(platform: "ios", appVersion: "1.0.0")
    ) -> LeverConfiguration {
        var configuration = LeverConfiguration(
            baseURL: URL(string: "https://lever.example")!,
            clientKey: clientKey,
            context: context
        )
        configuration.cacheDirectory = directory
        configuration.logSink = sink
        return configuration
    }

    func makeClient(_ customize: (inout LeverConfiguration) -> Void = { _ in }) -> LeverClient {
        var configuration = self.configuration()
        customize(&configuration)
        return LeverClient(configuration: configuration, environment: environment)
    }

    /// Writes a snapshot where a client with this configuration will find it.
    @discardableResult
    func seedCache(
        version: Int,
        _ values: [String: WireValue],
        etag: String? = nil,
        fetchedAt: Int? = nil,
        clientKey: String = "pk_test",
        namespace: String? = nil
    ) -> CacheStore {
        let store = cacheStore(clientKey: clientKey, namespace: namespace)
        store.save(
            CachedSnapshot(
                version: version,
                etag: etag,
                values: values,
                fetchedAt: fetchedAt ?? now,
                activatedAt: fetchedAt ?? now
            )
        )
        return store
    }

    /// The cache files a client with this configuration reads and writes.
    func cacheStore(clientKey: String = "pk_test", namespace: String? = nil) -> CacheStore {
        var configuration = self.configuration(clientKey: clientKey)
        configuration.cacheNamespace = namespace
        let validated = validate(configuration)
        return CacheStore(
            directory: validated.cacheDirectory,
            keyHash: validated.cacheKeyHash,
            sink: sink
        )
    }
}

/// Lets the runtime's tasks run. Every seam is deterministic, but actor hops
/// still need a scheduling turn.
func settle(_ turns: Int = 8) async {
    for _ in 0..<turns {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Payload helpers

func resolveBody(version: Int, _ values: [String: String] = [:]) -> String {
    let entries = values.keys.sorted().map { "\"\($0)\":\(values[$0] ?? "null")" }
    return "{\"version\":\(version),\"values\":{\(entries.joined(separator: ","))}}"
}

func boolValue(_ value: Bool) -> String { "{\"type\":\"boolean\",\"value\":\(value)}" }
func stringValue(_ value: String) -> String { "{\"type\":\"string\",\"value\":\"\(value)\"}" }
func numberValue(_ value: String) -> String { "{\"type\":\"number\",\"value\":\(value)}" }
func jsonValue(_ value: String) -> String { "{\"type\":\"json\",\"value\":\(value)}" }
