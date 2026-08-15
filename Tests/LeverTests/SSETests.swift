import Foundation
import Testing

@testable import Lever

private func events(_ chunks: [String]) throws -> [ServerSentEventParser.Event] {
    var parser = ServerSentEventParser()
    var all: [ServerSentEventParser.Event] = []
    for chunk in chunks { all += try parser.consume(Array(chunk.utf8)) }
    return all
}

@Suite("the SSE parser (§6.2)")
struct ServerSentEventParserTests {
    @Test("a whole frame parses")
    func wholeFrame() throws {
        #expect(
            try events(["event: version\ndata: {\"version\":42}\n\n"])
                == [.init(name: "version", data: "{\"version\":42}")]
        )
    }

    @Test("a frame split at every byte boundary parses identically")
    func splitAtEveryBoundary() throws {
        let frame = "event: version\ndata: {\"version\":7}\n\n"
        let bytes = Array(frame.utf8)
        for split in 1..<bytes.count {
            let chunks = [
                String(decoding: bytes[..<split], as: UTF8.self),
                String(decoding: bytes[split...], as: UTF8.self),
            ]
            #expect(try events(chunks) == [.init(name: "version", data: "{\"version\":7}")])
        }
    }

    @Test("CRLF and LF are both line terminators, including a CRLF split across chunks")
    func lineTerminators() throws {
        #expect(
            try events(["event: version\r\ndata: 1\r\n\r\n"])
                == [.init(name: "version", data: "1")]
        )
        // The lone CR at the end of a chunk must wait for its LF.
        #expect(
            try events(["event: version\r\ndata: 1\r", "\n\r\n"])
                == [.init(name: "version", data: "1")]
        )
    }

    @Test("comment heartbeats produce no events")
    func heartbeats() throws {
        #expect(try events([": hb\n\n", ":\n\n"]).isEmpty)
        #expect(
            try events([": hb\n\nevent: version\ndata: 3\n\n"])
                == [.init(name: "version", data: "3")]
        )
    }

    @Test("retry and unknown fields are discarded — backoff is client-owned")
    func ignoredFields() throws {
        #expect(
            try events(["retry: 15000\nevent: version\ndata: 3\nid: 9\nwhatever: x\n\n"])
                == [.init(name: "version", data: "3")]
        )
    }

    @Test("multi-line data joins with newlines and a field with no value is empty")
    func dataAccumulation() throws {
        #expect(try events(["data: a\ndata: b\n\n"]) == [.init(name: nil, data: "a\nb")])
        #expect(try events(["data:x\n\n"]) == [.init(name: nil, data: "x")])
        #expect(try events(["data\n\n"]) == [.init(name: nil, data: "")])
    }

    @Test("a blank line with nothing accumulated dispatches nothing")
    func emptyDispatch() throws {
        #expect(try events(["\n\n", "event: version\n\n"]).isEmpty)
    }

    @Test("a frame past the 1MiB bound errors rather than buffering without limit")
    func frameBound() {
        var parser = ServerSentEventParser()
        let oversized = Array(String(repeating: "x", count: ServerSentEventParser.maxFrameBytes + 1).utf8)
        #expect(throws: ServerSentEventParser.ParseError.frameTooLarge) {
            _ = try parser.consume(oversized)
        }
    }

    @Test(
        "the bound covers every field kind, not just the incomplete tail",
        arguments: ["event: ", "data: ", ": ", "retry: ", "whatever: "]
    )
    func boundCoversEveryFieldKind(prefix: String) {
        var parser = ServerSentEventParser()
        // Terminated, so a check that only looked at what was left over after
        // consuming the chunk would find nothing wrong — after allocating it.
        let line = prefix + String(repeating: "x", count: ServerSentEventParser.maxFrameBytes) + "\n"
        #expect(throws: ServerSentEventParser.ParseError.frameTooLarge) {
            _ = try parser.consume(Array(line.utf8))
        }
    }

    @Test("many small fields that together exceed the bound still error")
    func boundIsPerFrameNotPerLine() {
        var parser = ServerSentEventParser()
        let line = Array("data: \(String(repeating: "x", count: 1_000))\n".utf8)
        #expect(throws: ServerSentEventParser.ParseError.frameTooLarge) {
            for _ in 0..<2_000 { _ = try parser.consume(line) }
        }
    }

    @Test("an unterminated line delivered in bounded chunks still errors")
    func boundSurvivesChunking() {
        var parser = ServerSentEventParser()
        let chunk = Array(repeating: UInt8(ascii: "x"), count: 16 * 1024)
        #expect(throws: ServerSentEventParser.ParseError.frameTooLarge) {
            for _ in 0..<128 { _ = try parser.consume(chunk) }
        }
    }

    @Test("the budget resets per frame, so a long-lived stream is not cumulative")
    func budgetResetsBetweenFrames() throws {
        var parser = ServerSentEventParser()
        let frame = Array("event: version\ndata: {\"version\":1}\n\n".utf8)
        var dispatched = 0
        // Comfortably more total bytes than one frame is allowed.
        for _ in 0..<50_000 { dispatched += try parser.consume(frame).count }
        #expect(dispatched == 50_000)
    }

    @Test("a heartbeat between oversized-looking frames does not accumulate")
    func heartbeatsResetTheBudget() throws {
        var parser = ServerSentEventParser()
        let almost = Array("data: \(String(repeating: "x", count: 900_000))\n\n".utf8)
        _ = try parser.consume(almost)
        _ = try parser.consume(Array(": hb\n\n".utf8))
        // A second near-bound frame is fine because the first one dispatched.
        #expect(throws: Never.self) { _ = try parser.consume(almost) }
    }

    @Test("the version frame decodes, and anything else does not")
    func versionFrame() {
        #expect(VersionFrame.version(in: "{\"version\":42}") == 42)
        #expect(VersionFrame.version(in: "{\"version\":0}") == 0)
        #expect(VersionFrame.version(in: "{}") == nil)
        #expect(VersionFrame.version(in: "not json") == nil)
    }
}

@Suite("retry-after parsing (§6.2)")
struct RetryAfterTests {
    @Test("integer seconds only, capped at 300")
    func parsing() {
        #expect(LeverRuntime.retryAfterSeconds("30") == 30)
        #expect(LeverRuntime.retryAfterSeconds(" 30 ") == 30)
        #expect(LeverRuntime.retryAfterSeconds("0") == 0)
        #expect(LeverRuntime.retryAfterSeconds("9999") == 300)
        #expect(LeverRuntime.retryAfterSeconds("-1") == nil)
        #expect(LeverRuntime.retryAfterSeconds("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(LeverRuntime.retryAfterSeconds(nil) == nil)
    }
}

/// A client that is inside its fetch interval with a warm cache, so every
/// request these tests observe came from the stream, not from scheduling.
private func nudgeHarness(
    version: Int = 1,
    etag: String? = "\"one\""
) -> TestHarness {
    let harness = TestHarness()
    harness.seedCache(version: version, [:], etag: etag)
    return harness
}

@Suite("the SSE state machine (§6.2)")
struct StreamStateMachineTests {
    @Test("a foregrounded client connects with the right request")
    func connects() async {
        let harness = nudgeHarness()
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.transport.streamRequests.count == 1)
        let request = harness.transport.streamRequests[0]
        #expect(request.url.absoluteString == "https://lever.example/v1/stream")
        #expect(request.header("Authorization") == "Bearer pk_test")
        #expect(request.header("Accept") == "text/event-stream")
    }

    @Test("a 200 with the wrong media type never reaches the parser")
    func wrongMediaType() async {
        let harness = nudgeHarness()
        let html = StreamScript(status: 200, contentType: "text/html")
        harness.transport.enqueue(stream: html.stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        // A proxy's HTML error page must fail fast into backoff, not sit in the
        // byte loop until the watchdog fires.
        html.version(99)
        await settle()
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.sink.contains(.warn, "stream refused, media type=text/html"))
        #expect(harness.backoffDelays == [.seconds(1)])
    }

    @Test("non-200, non-HTTP, and redirect responses all back off")
    func failedConnects() async {
        for stream in [
            StreamScript(status: 500),
            StreamScript(status: 302),
            StreamScript(status: nil),
            StreamScript(status: 200, contentType: nil),
        ] {
            let harness = nudgeHarness()
            harness.transport.enqueue(stream: stream.stream)
            let client = harness.makeClient()
            defer { withExtendedLifetime(client) {} }
            await settle()
            #expect(harness.backoffDelays == [.seconds(1)])
        }
    }

    @Test("503 honors Retry-After as the floor for that round")
    func retryAfterFloor() async {
        let harness = nudgeHarness()
        harness.setJitter(0)
        harness.transport.enqueue(stream: StreamScript(status: 503, retryAfter: "45").stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        // Jitter drew zero; the floor still applies.
        #expect(harness.backoffDelays == [.seconds(45)])
    }

    @Test("backoff walks the exponential ceiling and resets after a live frame")
    func backoffEnvelope() async {
        let harness = nudgeHarness()
        harness.setJitter(1)
        for _ in 0..<4 { harness.transport.enqueue(stream: StreamScript(status: 500).stream) }
        let live = StreamScript()
        harness.transport.enqueue(stream: live.stream)

        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        for expected in [1, 2, 4, 8] {
            #expect(harness.backoffDelays == [.seconds(expected)])
            await harness.advance(by: expected)
        }

        // The live connection delivers a frame, so the next round starts at 2^0.
        live.version(1)
        await settle()
        live.close()
        await settle()
        #expect(harness.backoffDelays == [.seconds(1)])
    }

    @Test("401 stops reconnecting until the next foreground")
    func unauthorizedStops() async {
        let harness = nudgeHarness()
        harness.transport.enqueue(stream: StreamScript(status: 401).stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.transport.streamRequests.count == 1)
        #expect(harness.backoffDelays.isEmpty)
        #expect(harness.sink.contains(.warn, "stream stopped, invalid key"))

        await harness.advance(by: 10_000)
        #expect(harness.transport.streamRequests.count == 1)

        // The app is expected to ship a new key; the next foreground retries.
        harness.transport.enqueue(stream: StreamScript().stream)
        harness.lifecycle.send(.background)
        await settle()
        harness.lifecycle.send(.foreground)
        await settle()
        #expect(harness.transport.streamRequests.count == 2)
    }

    @Test("60s of silence reconnects")
    func idleWatchdog() async {
        let harness = nudgeHarness()
        let first = StreamScript()
        harness.transport.enqueue(stream: first.stream)
        harness.transport.enqueue(stream: StreamScript().stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()
        first.version(1)
        await settle()

        // A heartbeat resets the timer, so this alone is not enough silence.
        await harness.advance(by: 40)
        first.heartbeat()
        await settle()
        await harness.advance(by: 40)
        #expect(harness.transport.streamRequests.count == 1)

        await harness.advance(by: 60)
        await harness.advance(by: 1)
        #expect(harness.transport.streamRequests.count == 2)
    }

    @Test("backgrounding tears the stream down without logging a transport failure")
    func backgroundTearsDown() async {
        let harness = nudgeHarness()
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        harness.lifecycle.send(.background)
        await settle()
        await harness.advance(by: 10_000)

        #expect(harness.transport.streamRequests.count == 1)
        #expect(!harness.sink.contains(.warn, "stream refused"))
        #expect(harness.sink.messages(.warn).isEmpty)
    }
}

@Suite("nudges (§5.3)")
struct NudgeTests {
    @Test("the replayed connect frame for the version we already hold is ignored")
    func dedupe() async {
        let harness = nudgeHarness(version: 5)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        script.version(5)
        await settle()
        #expect(harness.transport.requests.isEmpty)
    }

    @Test("a differing version fetches — higher or lower, because it is identity, not ordering")
    func differingVersionFetches() async {
        for announced in [6, 4] {
            let harness = nudgeHarness(version: 5)
            let script = StreamScript()
            harness.transport.enqueue(stream: script.stream)
            harness.transport.enqueue(
                .json(resolveBody(version: announced, ["flag": boolValue(true)]))
            )
            let client = harness.makeClient()
            defer { withExtendedLifetime(client) {} }
            await settle()

            script.version(announced)
            await settle()

            #expect(harness.transport.requests.count == 1)
            #expect(client.activatedVersion == announced)
            #expect(client.flag == true)
        }
    }

    @Test("a missed publish while disconnected costs exactly one fetch on reconnect")
    func replayAfterMissedPublish() async {
        let harness = nudgeHarness(version: 5)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 9)))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        // The connect frame replays the current version, which we missed.
        script.version(9)
        await settle()
        #expect(harness.transport.requests.count == 1)

        // A duplicate of the same frame is free.
        script.version(9)
        await settle()
        #expect(harness.transport.requests.count == 1)
    }

    @Test("a nudge landing mid-fetch yields exactly one follow-up fetch")
    func pendingNudge() async {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        harness.transport.enqueue(.json(resolveBody(version: 3, ["flag": boolValue(true)])))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        harness.transport.pause()
        script.version(2)
        await harness.transport.waitForRequests(1)

        // The server may have chosen the in-flight response before 3 was
        // published, so coalescing into it would lose the update.
        script.version(3)
        await settle()
        harness.transport.resume()
        await settle()

        #expect(harness.transport.requests.count == 2)
        #expect(client.activatedVersion == 3)
        #expect(client.flag == true)
    }

    @Test("several nudges during one fetch coalesce into one follow-up")
    func pendingNudgesCoalesce() async {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        harness.transport.enqueue(.json(resolveBody(version: 5)))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        harness.transport.pause()
        script.version(2)
        await harness.transport.waitForRequests(1)
        script.version(3)
        script.version(4)
        script.version(5)
        await settle()
        harness.transport.resume()
        await settle()

        // Last one wins: versions are identity tokens, never maxed.
        #expect(harness.transport.requests.count == 2)
        #expect(client.activatedVersion == 5)
    }

    @Test("a nudge already covered by the in-flight response yields no follow-up")
    func pendingNudgeAlreadyCovered() async {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 3)))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        harness.transport.pause()
        script.version(2)
        await harness.transport.waitForRequests(1)
        script.version(3)
        await settle()
        harness.transport.resume()
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 3)
    }

    @Test("a nudge that joins an explicit fetch still applies its activation policy")
    func nudgeJoiningExplicitFetchActivates() async throws {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(43_200) }
        defer { withExtendedLifetime(client) {} }
        await settle()
        #expect(harness.transport.requests.isEmpty)

        // The in-flight request belongs to a staging-only caller. What
        // coalesces is transport work; the nudge's activation policy is its
        // own, and must survive being answered by someone else's request.
        harness.transport.pause()
        let explicit = Task { try await client.fetch() }
        await harness.transport.waitForRequests(1)
        script.version(2)
        await settle()
        harness.transport.resume()
        try await explicit.value
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 2)
        #expect(client.flag == true)
    }

    @Test("opting out still means a nudge on someone else's fetch only stages")
    func nudgeJoiningExplicitFetchRespectsOptOut() async throws {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))
        let client = harness.makeClient {
            $0.minimumFetchInterval = .seconds(43_200)
            $0.autoActivateOnNudge = false
        }
        defer { withExtendedLifetime(client) {} }
        await settle()

        harness.transport.pause()
        let explicit = Task { try await client.fetch() }
        await harness.transport.waitForRequests(1)
        script.version(2)
        await settle()
        harness.transport.resume()
        try await explicit.value
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 1)
        #expect(client.activate() == true)
        #expect(client.flag == true)
    }

    @Test("a nudge fetch bypasses the interval and resets the clock")
    func nudgeBypassesInterval() async {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(43_200) }
        defer { withExtendedLifetime(client) {} }
        await settle()
        #expect(harness.transport.requests.isEmpty)

        harness.advanceWallClock(by: 100)
        script.version(2)
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(harness.cacheStore().loadSnapshot()?.fetchedAt == harness.now)
    }

    @Test("autoActivateOnNudge = false stages only")
    func optOutOfAutoActivation() async {
        let harness = nudgeHarness(version: 1)
        let script = StreamScript()
        harness.transport.enqueue(stream: script.stream)
        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))
        let client = harness.makeClient { $0.autoActivateOnNudge = false }
        defer { withExtendedLifetime(client) {} }
        await settle()

        script.version(2)
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 1)
        #expect(client.flag == false)

        // The app activates on its own schedule.
        #expect(client.activate() == true)
        #expect(client.flag == true)
    }
}
