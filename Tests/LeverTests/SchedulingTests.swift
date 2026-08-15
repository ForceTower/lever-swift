import Foundation
import Testing

@testable import Lever

private let onFlag: [String: WireValue] = ["flag": WireValue(type: "boolean", value: .bool(true))]

@Suite("fetch policy and the in-session timer (§5.1)")
struct SchedulingTests {
    @Test("init inside the interval issues no request and arms the timer for the remainder")
    func insideTheInterval() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, onFlag)
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }

        await settle()
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
        #expect(client.flag == true)
    }

    @Test("init outside the interval fetches once")
    func outsideTheInterval() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:], fetchedAt: harness.now - 3_601)
        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))

        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 2)
        #expect(client.flag == true)
    }

    @Test("a first run with no cache always fetches")
    func firstRunFetches() async {
        let harness = TestHarness()
        harness.transport.enqueue(.json(resolveBody(version: 1, ["flag": boolValue(true)])))
        let client = harness.makeClient()
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(client.flag == true)
    }

    @Test("the timer fires at lastFetchAt + interval and re-arms from the attempt")
    func timerFiresAndReArms() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        await settle()
        #expect(harness.clock.armedDelays == [.seconds(3_600)])

        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))
        await harness.advance(by: 3_600)

        #expect(harness.transport.requests.count == 1)
        #expect(client.flag == true)
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
    }

    @Test("a zero interval never arms a timer — always eligible, never continuously")
    func zeroIntervalDoesNotLoop() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        let client = harness.makeClient { $0.minimumFetchInterval = .zero }
        defer { withExtendedLifetime(client) {} }
        await settle()

        // Eligible, so init fetched — but there is no timer to loop on.
        #expect(harness.transport.requests.count == 1)
        #expect(harness.clock.armedDelays.isEmpty)

        await harness.advance(by: 10_000)
        #expect(harness.transport.requests.count == 1)
    }

    @Test("a sub-60s interval arms the timer at the floor while lifecycle edges keep it")
    func pollingFloor() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(30) }
        defer { withExtendedLifetime(client) {} }
        await settle()

        // Clamped for the timer only.
        #expect(harness.clock.armedDelays == [.seconds(60)])

        // A lifecycle edge 31s later is eligible at the configured interval.
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        harness.advanceWallClock(by: 31)
        harness.lifecycle.send(.foreground)
        await settle()
        #expect(harness.transport.requests.count == 1)
    }

    @Test("exactly 60s arms as configured")
    func exactlySixtySeconds() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(60) }
        defer { withExtendedLifetime(client) {} }
        await settle()
        #expect(harness.clock.armedDelays == [.seconds(60)])
    }

    @Test("a failed automatic fetch re-arms from the attempt, never on an expired deadline")
    func failedFetchReArms() async {
        let harness = TestHarness()
        // First run offline: no cache, nothing scripted, so the transport fails.
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.transport.requests.count == 1)
        // Anchored on the attempt: a failed fetch does not advance lastFetchAt,
        // and re-arming from that would hot-loop.
        #expect(harness.clock.armedDelays == [.seconds(3_600)])

        await harness.advance(by: 3_600)
        #expect(harness.transport.requests.count == 2)
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
    }

    @Test("a wall-clock jump does not disturb the armed timer")
    func wallClockJump() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        defer { withExtendedLifetime(client) {} }
        await settle()
        #expect(harness.clock.armedDelays == [.seconds(3_600)])

        harness.advanceWallClock(by: 100_000)
        await settle()
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
        #expect(harness.transport.requests.isEmpty)
    }

    @Test("a lastFetchAt in the future counts as passed and cannot loop")
    func backwardsWallClock() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:], fetchedAt: harness.now + 10_000)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        defer { withExtendedLifetime(client) {} }
        await settle()

        // One fetch rewrites fetchedAt to now, so the next check is normal.
        #expect(harness.transport.requests.count == 1)
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
    }

    @Test("an explicit fetch ignores the interval entirely")
    func explicitFetchIgnoresInterval() async throws {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(43_200) }
        await settle()
        #expect(harness.transport.requests.isEmpty)

        harness.transport.enqueue(.json(resolveBody(version: 2, ["flag": boolValue(true)])))
        #expect(try await client.fetchAndActivate() == true)
        #expect(harness.transport.requests.count == 1)
        #expect(client.flag == true)
    }
}

@Suite("foreground and background (§5.2)")
struct LifecycleTests {
    @Test("background cancels the in-session timer; foreground re-arms and refetches")
    func backgroundTearsDownTheTimer() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        defer { withExtendedLifetime(client) {} }
        await settle()
        #expect(harness.clock.armedDelays == [.seconds(3_600)])

        harness.lifecycle.send(.background)
        await settle()
        #expect(harness.clock.armedDelays.isEmpty)

        harness.advanceWallClock(by: 3_601)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        harness.lifecycle.send(.foreground)
        await settle()
        #expect(harness.transport.requests.count == 1)
        #expect(harness.clock.armedDelays == [.seconds(3_600)])
    }

    @Test("a client created while already foregrounded runs the foreground path immediately")
    func initialForegroundState() async {
        let harness = TestHarness(phase: .foreground)
        harness.transport.enqueue(.json(resolveBody(version: 1)))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        // No foreground *transition* ever happened, only the initial state.
        #expect(harness.transport.streamRequests.count == 1)
        #expect(harness.transport.requests.count == 1)
    }

    @Test("a client created while backgrounded still runs the init fetch but connects nothing")
    func initialBackgroundState() async {
        let harness = TestHarness(phase: .background)
        harness.transport.enqueue(.json(resolveBody(version: 1)))
        let client = harness.makeClient()
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.transport.requests.count == 1)
        #expect(harness.transport.streamRequests.isEmpty)
        #expect(harness.clock.armedDelays.isEmpty)
    }
}

@Suite("cache-only readers (§5, §7)")
struct CacheOnlyTests {
    @Test("nothing automatic starts, and reads still serve the cache")
    func nothingStarts() async {
        let harness = TestHarness()
        harness.seedCache(version: 3, onFlag)
        let client = harness.makeClient { $0.automaticUpdates = false }
        await settle()

        #expect(client.flag == true)
        #expect(client.activatedVersion == 3)
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.transport.streamRequests.isEmpty)
        #expect(harness.clock.armedDelays.isEmpty)
        // No lifecycle observation ever starts.
        #expect(harness.lifecycle.subscriptions == 0)
    }

    @Test("an explicit fetchAndActivate is still the deliberate override")
    func explicitOverrideStillWorks() async throws {
        let harness = TestHarness()
        let client = harness.makeClient { $0.automaticUpdates = false }
        harness.transport.enqueue(.json(resolveBody(version: 1, ["flag": boolValue(true)])))

        #expect(try await client.fetchAndActivate() == true)
        #expect(client.flag == true)
    }

    @Test("a writer's atomic update is visible to the next reader initialization")
    func writerThenReader() async throws {
        let harness = TestHarness()
        let writer = harness.makeClient { $0.automaticUpdates = false }
        harness.transport.enqueue(
            .json(resolveBody(version: 4, ["flag": boolValue(true)]), etag: "\"w\"")
        )
        _ = try await writer.fetchAndActivate()

        let reader = harness.makeClient { $0.automaticUpdates = false }
        #expect(reader.flag == true)
        #expect(reader.activatedVersion == 4)
    }

    @Test("readers never write")
    func readersNeverWrite() async {
        let harness = TestHarness()
        harness.seedCache(version: 2, onFlag)
        let before = try? Data(contentsOf: harness.cacheStore().snapshotURL)

        let first = harness.makeClient { $0.automaticUpdates = false }
        let second = harness.makeClient { $0.automaticUpdates = false }
        _ = first.flag
        _ = second.flag
        await settle()

        #expect((try? Data(contentsOf: harness.cacheStore().snapshotURL)) == before)
    }
}

@Suite("teardown (§4.1)")
struct TeardownTests {
    @Test("deallocation cancels every task and nothing fires afterwards")
    func deallocationCancels() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        do {
            let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
            await settle()
            #expect(harness.clock.armedDelays == [.seconds(3_600)])
            withExtendedLifetime(client) {}
        }
        await settle()

        #expect(harness.transport.isInvalidated)
        let requestsAtTeardown = harness.transport.requests.count
        let logsAtTeardown = harness.sink.all.count

        // The timer is gone, so time passing produces nothing at all.
        await harness.advance(by: 100_000)
        #expect(harness.transport.requests.count == requestsAtTeardown)
        #expect(harness.sink.all.count == logsAtTeardown)
    }
}


@Suite("scheduler arithmetic (§5.1)")
struct SchedulerArithmeticTests {
    @Test("elapsed time saturates instead of trapping")
    func elapsedSaturates() {
        #expect(LeverRuntime.elapsed(from: 100, to: 400) == 300)
        #expect(LeverRuntime.elapsed(from: 400, to: 100) == -300)
        // Both of these overflow a plain subtraction.
        #expect(LeverRuntime.elapsed(from: Int.min, to: Int.max) == Int.max)
        #expect(LeverRuntime.elapsed(from: Int.max, to: Int.min) == Int.min)
    }

    @Test("a cache timestamp far in the future is a scheduling input, not a crash")
    func farFutureTimestamp() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:], fetchedAt: Int.max)
        harness.transport.enqueue(.json(resolveBody(version: 2)))
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(3_600) }
        defer { withExtendedLifetime(client) {} }
        await settle()

        // "In the future" counts as passed, so one fetch rewrites it to now.
        #expect(harness.transport.requests.count == 1)
        #expect(client.activatedVersion == 2)
    }

    @Test("an interval too large to schedule is clamped, not trapped on")
    func extremeInterval() async {
        let harness = TestHarness()
        harness.seedCache(version: 1, [:])
        let client = harness.makeClient { $0.minimumFetchInterval = .seconds(Int.max) }
        defer { withExtendedLifetime(client) {} }
        await settle()

        #expect(harness.sink.contains(.warn, "minimumFetchInterval clamped to 365 days"))
        #expect(harness.clock.armedDelays == [.seconds(365 * 24 * 60 * 60)])
        #expect(harness.transport.requests.isEmpty)
    }
}
