import Foundation
import Synchronization

/// Everything asynchronous the SDK does: scheduling, lifecycle reaction, the
/// SSE connection, and fetch execution — every `Task` and timer, so
/// cancellation has exactly one home (§4.1).
///
/// The ownership boundary is one-way. The runtime calls into the client's
/// thread-safe core to stage or activate; the core never calls into the
/// runtime, and the runtime's back-reference is weak so its tasks cannot keep
/// a released client alive.
actor LeverRuntime {
    enum FetchReason: Sendable {
        case explicit
        case automatic
        case nudge
    }

    private let configuration: ValidatedConfiguration
    private let environment: LeverEnvironment
    private let transport: any LeverTransport
    private let clock: any LeverClock
    private var sink: any LeverLogSink { configuration.logSink }

    /// Set synchronously by `start`, not on the actor: an explicit `fetch()`
    /// issued on the line after `init` must not race the runtime's first hop
    /// and silently find no client. Weak, so the runtime's tasks can never keep
    /// a released client alive (§4.1).
    private struct ClientRef: Sendable {
        weak var client: LeverClient?
        var clientId = ""
    }

    private let clientRef = Mutex(ClientRef())
    private nonisolated var client: LeverClient? { clientRef.withLock { $0.client } }
    private nonisolated var clientId: String { clientRef.withLock { $0.clientId } }

    private var inFlight: Task<Void, any Error>?
    private var timer: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamPump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var initialFetch: Task<Void, Never>?

    /// The latest differing announced version seen while a fetch was already in
    /// flight. Last one wins — versions are identity tokens, never `max`ed
    /// (§5.3).
    private var pendingNudge: Int?
    private var foregrounded = false
    /// A 401 on the stream stops reconnecting until the next foreground (§6.2).
    private var streamStopped = false
    private var isTornDown = false

    private var parser = ServerSentEventParser()
    private var sawStreamActivity = false

    init(configuration: ValidatedConfiguration, environment: LeverEnvironment) {
        self.configuration = configuration
        self.environment = environment
        transport = environment.makeTransport(configuration)
        clock = environment.clock
    }

    // MARK: - Lifetime

    nonisolated func start(client: LeverClient) {
        clientRef.withLock { $0 = ClientRef(client: client, clientId: client.clientId) }
        Task { await self.begin() }
    }

    private func begin() {
        // Cache-only reader: reads and explicit fetches still work, but nothing
        // here starts — no fetch, timer, lifecycle observer, or stream (§5).
        guard configuration.automaticUpdates else { return }

        // §5.1's "on init, run the automatic fetch path", independent of the
        // lifecycle phase. A foreground event arriving right behind it coalesces
        // into the same request rather than issuing a second one.
        initialFetch = Task { await self.runAutomaticFetch() }

        let source = environment.lifecycle()
        lifecycleTask = Task { [weak self] in
            for await phase in source.phases() {
                await self?.handle(phase: phase)
            }
        }
    }

    nonisolated func tearDown() {
        Task { await self.stop() }
    }

    private func stop() {
        isTornDown = true
        inFlight?.cancel()
        initialFetch?.cancel()
        timer?.cancel()
        lifecycleTask?.cancel()
        streamTask?.cancel()
        streamPump?.cancel()
        watchdog?.cancel()
        inFlight = nil
        timer = nil
        streamTask = nil
        transport.invalidate()
    }

    // MARK: - Lifecycle

    private func handle(phase: LeverLifecyclePhase) {
        guard !isTornDown else { return }
        switch phase {
        case .foreground:
            foregrounded = true
            streamStopped = false
            connectStream()
            Task { await self.runAutomaticFetch() }
        case .background:
            foregrounded = false
            timer?.cancel()
            timer = nil
            disconnectStream()
        }
    }

    // MARK: - Fetching

    /// Explicit calls always hit the network; automatic ones honor the interval;
    /// nudges bypass it by design and reset the clock on success (§5.1).
    func fetch(reason: FetchReason) async throws {
        guard !isTornDown else { return }
        sink.debug("fetch reason=\(reason)")
        try await awaitWithoutCancelling(sharedFetch())
    }

    private func sharedFetch() -> Task<Void, any Error> {
        if let inFlight { return inFlight }
        let task = Task { try await self.execute() }
        inFlight = task
        return task
    }

    private func execute() async throws {
        defer {
            inFlight = nil
            drainPendingNudge()
        }
        guard let client else { return }

        let newest = client.newestRepresentation
        let validator = newest?.representation.etag
        let request = ResolveEndpoint.request(
            for: configuration,
            clientId: clientId,
            ifNoneMatch: validator
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as URLError {
            throw LeverError.network(error.code)
        }

        let fetchedAt = environment.now()
        switch try ResolveEndpoint.outcome(for: response, sentValidator: validator != nil) {
        case .fresh(let version, let values, let etag):
            client.stage(
                Representation(
                    version: version,
                    values: values,
                    etag: etag,
                    fetchedAt: fetchedAt,
                    activatedAt: nil
                )
            )
        case .notModified:
            // The 304 confirms whichever representation's validator we sent.
            client.confirmFreshness(ofStaged: newest?.isStaged ?? false, at: fetchedAt)
        }
    }

    /// Init, foreground, and the in-session timer all land here.
    private func runAutomaticFetch() async {
        guard !isTornDown, configuration.automaticUpdates else { return }
        let attemptAt = environment.now()

        guard isDue(at: attemptAt) else {
            armTimer(anchoredAt: nil)
            return
        }

        do {
            try await fetch(reason: .automatic)
            client?.activate()
        } catch is CancellationError {
            // Never logged as a network failure (§5.1).
        } catch {
            sink.warn("automatic fetch failed error=\(error)")
        }
        // Always from the attempt, never from an already-expired deadline: a
        // failed fetch does not advance `fetchedAt`, and re-arming from it would
        // hot-loop (§5.1).
        armTimer(anchoredAt: attemptAt)
    }

    private func isDue(at now: Int) -> Bool {
        guard let fetchedAt = client?.newestRepresentation?.representation.fetchedAt else {
            return true
        }
        // The wall clock moved backwards; one fetch rewrites it to now, so this
        // cannot loop.
        if fetchedAt > now { return true }
        return now - fetchedAt >= Int(configuration.minimumFetchInterval.components.seconds)
    }

    // MARK: - The in-session timer

    /// The degraded polling mode when the stream is down — there is no second,
    /// faster poll loop (§5.1).
    private func armTimer(anchoredAt attemptAt: Int?) {
        timer?.cancel()
        timer = nil
        guard !isTornDown, foregrounded, configuration.automaticUpdates else { return }

        let interval = configuration.minimumFetchInterval
        // `.zero` means "always eligible", never "continuously": automatic
        // fetching happens on lifecycle edges only.
        guard interval > .zero else { return }

        // The 60 s polling floor is a timer-only clamp; lifecycle-edge
        // eligibility keeps the configured interval (§5.1).
        let armed = max(interval, .seconds(60))
        let anchor =
            attemptAt ?? client?.newestRepresentation?.representation.fetchedAt
            ?? environment.now()
        let delay = max(0, anchor + Int(armed.components.seconds) - environment.now())

        let clock = clock
        timer = Task { [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runAutomaticFetch()
        }
    }

    // MARK: - Nudges

    /// §5.3's dedupe: identity, not ordering. A *lower* announced version still
    /// means "different", which is what keeps a restored-from-backup server
    /// self-healing.
    private func handleNudge(version: Int) {
        guard !isTornDown, let client else { return }
        guard version != client.lastKnownVersion else { return }

        // Coalescing into the in-flight request can lose an update: the server
        // may have chosen that response before this version was published.
        if inFlight != nil {
            pendingNudge = version
            return
        }
        startNudgeFetch()
    }

    private func drainPendingNudge() {
        guard let pending = pendingNudge else { return }
        pendingNudge = nil
        guard !isTornDown, let client, pending != client.lastKnownVersion else { return }
        startNudgeFetch()
    }

    private func startNudgeFetch() {
        Task {
            do {
                try await self.fetch(reason: .nudge)
                if self.configuration.autoActivateOnNudge {
                    self.client?.activate()
                }
            } catch is CancellationError {
            } catch {
                self.sink.warn("nudge fetch failed error=\(error)")
            }
        }
    }

    // MARK: - SSE

    private func connectStream() {
        guard !isTornDown, configuration.automaticUpdates, foregrounded, !streamStopped,
            streamTask == nil
        else { return }
        streamTask = Task { await self.runStream() }
    }

    private func disconnectStream() {
        streamTask?.cancel()
        streamTask = nil
        streamPump?.cancel()
        streamPump = nil
        watchdog?.cancel()
        watchdog = nil
    }

    private enum StreamRound {
        /// A frame arrived, so the backoff counter resets.
        case active
        case failed(retryAfter: Double?)
        /// 401: stop reconnecting until the next foreground.
        case stop
    }

    private func runStream() async {
        var attempt = 0
        while !Task.isCancelled, foregrounded, !streamStopped, !isTornDown {
            let round = await connectOnce()
            switch round {
            case .stop:
                return
            case .active:
                attempt = 0
                continue
            case .failed(let retryAfter):
                // Full jitter over an exponential ceiling (§6.2).
                let ceiling = min(60, pow(2, Double(attempt)))
                let delay = max(retryAfter ?? 0, environment.jitter(ceiling))
                attempt += 1
                do {
                    try await clock.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func connectOnce() async -> StreamRound {
        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("v1/stream"),
            headers: [
                (name: "Authorization", value: "Bearer \(configuration.clientKey)"),
                (name: "Accept", value: "text/event-stream"),
            ]
        )

        let stream: HTTPStream
        do {
            stream = try await transport.openStream(request)
        } catch is CancellationError {
            return .stop
        } catch {
            return .failed(retryAfter: nil)
        }

        // "Open" means validated: anything else never reaches the parser, so a
        // proxy's 200 HTML error page fails fast instead of sitting in the byte
        // loop until the watchdog fires (§6.2).
        guard let status = stream.status else { return .failed(retryAfter: nil) }
        switch status {
        case 200:
            break
        case 401:
            streamStopped = true
            sink.warn("stream stopped, invalid key — retrying at the next foreground")
            return .stop
        case 503:
            return .failed(retryAfter: Self.retryAfterSeconds(stream.headers["Retry-After"]))
        default:
            return .failed(retryAfter: nil)
        }

        let mediaType =
            stream.headers["Content-Type"]?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard mediaType == "text/event-stream" else {
            sink.warn("stream refused, media type=\(mediaType ?? "none")")
            return .failed(retryAfter: nil)
        }

        await pump(stream)
        return sawStreamActivity ? .active : .failed(retryAfter: nil)
    }

    private func pump(_ stream: HTTPStream) async {
        parser = ServerSentEventParser()
        sawStreamActivity = false

        let pump = Task { [weak self] in
            do {
                for try await chunk in stream.bytes {
                    await self?.consume(chunk)
                }
            } catch {
                // EOF and read errors are both "reconnect through backoff".
            }
        }
        streamPump = pump
        armWatchdog()
        await pump.value

        watchdog?.cancel()
        watchdog = nil
        streamPump = nil
    }

    private func consume(_ chunk: [UInt8]) {
        // Any bytes reset the idle timer — heartbeats included (§6.2).
        armWatchdog()
        sawStreamActivity = true

        let events: [ServerSentEventParser.Event]
        do {
            events = try parser.consume(chunk)
        } catch {
            sink.warn("stream frame exceeded the 1MiB bound — reconnecting")
            streamPump?.cancel()
            return
        }

        for event in events where event.name == "version" {
            guard let version = VersionFrame.version(in: event.data) else { continue }
            handleNudge(version: version)
        }
    }

    /// Server heartbeats land every 25 s, so 60 s of silence is two lost beats —
    /// decisive without flapping (§6.2).
    private func armWatchdog() {
        watchdog?.cancel()
        let clock = clock
        watchdog = Task { [weak self] in
            do {
                try await clock.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.watchdogFired()
        }
    }

    private func watchdogFired() {
        sink.debug("stream idle for 60s — reconnecting")
        streamPump?.cancel()
    }

    /// Integer seconds only — the syntax the service emits — capped at 300 s.
    /// An unparseable value is ignored (§6.2).
    static func retryAfterSeconds(_ header: String?) -> Double? {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)),
            seconds >= 0
        else { return nil }
        return Double(min(seconds, 300))
    }
}
