import Foundation
import Testing

@testable import Lever

private func configured(
    baseURL: String = "https://lever.example",
    clientKey: String = "pk_test",
    context: LeverContext = LeverContext(platform: "ios", appVersion: "5.2.0")
) -> ValidatedConfiguration {
    var configuration = LeverConfiguration(
        baseURL: URL(string: baseURL)!,
        clientKey: clientKey,
        context: context
    )
    configuration.logSink = RecordingLogSink()
    return validate(configuration)
}

@Suite("resolve requests (§6.1)")
struct ResolveRequestTests {
    @Test("the url, query order, and headers are exactly the wire contract")
    func requestShape() {
        let request = ResolveEndpoint.request(
            for: configured(
                context: LeverContext(
                    platform: "ios",
                    appVersion: "5.2.0",
                    attributes: ["locale": "pt-BR", "tier": "free trial"]
                )
            ),
            clientId: "6f9a1c2b3d4e4f5a8b9c0d1e2f3a4b5c",
            ifNoneMatch: nil
        )
        #expect(
            request.url.absoluteString == """
                https://lever.example/v1/resolve?platform=ios&appVersion=5.2.0\
                &clientId=6f9a1c2b3d4e4f5a8b9c0d1e2f3a4b5c&attr.locale=pt-BR&attr.tier=free%20trial
                """
        )
        #expect(request.header("Authorization") == "Bearer pk_test")
        #expect(request.header("If-None-Match") == nil)
    }

    @Test("the validator rides along when one is held")
    func sendsValidator() {
        let request = ResolveEndpoint.request(
            for: configured(),
            clientId: "abc",
            ifNoneMatch: "\"a1b2\""
        )
        #expect(request.header("If-None-Match") == "\"a1b2\"")
    }

    @Test("non-ascii and reserved characters percent-encode over UTF-8")
    func percentEncoding() {
        #expect(ResolveEndpoint.percentEncoded("olá") == "ol%C3%A1")
        #expect(ResolveEndpoint.percentEncoded("a b") == "a%20b")
        #expect(ResolveEndpoint.percentEncoded("a/b?c=d&e") == "a%2Fb%3Fc%3Dd%26e")
        #expect(ResolveEndpoint.percentEncoded("safe-._~") == "safe-._~")
    }

    @Test("an omitted platform or version simply drops out of the query")
    func omittedReservedFields() {
        let request = ResolveEndpoint.request(
            for: configured(context: LeverContext(platform: "ios")),
            clientId: "abc",
            ifNoneMatch: nil
        )
        #expect(request.url.absoluteString == "https://lever.example/v1/resolve?platform=ios&clientId=abc")
    }

    @Test("a base path is preserved under the endpoint")
    func basePath() {
        let request = ResolveEndpoint.request(
            for: configured(baseURL: "https://lever.example/config/"),
            clientId: "abc",
            ifNoneMatch: nil
        )
        #expect(request.url.path == "/config/v1/resolve")
    }
}

@Suite("resolve responses (§6.1)")
struct ResolveResponseTests {
    private func outcome(
        _ response: HTTPResponse,
        sentValidator: Bool = false
    ) throws -> ResolveEndpoint.Outcome {
        try ResolveEndpoint.outcome(for: response, sentValidator: sentValidator)
    }

    @Test("a 200 decodes into a fresh representation with its etag")
    func fresh() throws {
        let response = HTTPResponse.json(
            resolveBody(version: 3, ["flag": boolValue(true)]),
            etag: "\"abc\""
        )
        guard case .fresh(let version, let values, let etag) = try outcome(response) else {
            Issue.record("expected a fresh outcome")
            return
        }
        #expect(version == 3)
        #expect(values["flag"] == WireValue(type: "boolean", value: .bool(true)))
        #expect(etag == "\"abc\"")
    }

    @Test("a 200 with no ETag is accepted and carries a nil validator")
    func freshWithoutETag() throws {
        guard case .fresh(_, _, let etag) = try outcome(.json(resolveBody(version: 1))) else {
            Issue.record("expected a fresh outcome")
            return
        }
        #expect(etag == nil)
    }

    @Test("version 0 is valid — a never-published environment")
    func versionZero() throws {
        guard case .fresh(let version, let values, _) = try outcome(.json(resolveBody(version: 0)))
        else {
            Issue.record("expected a fresh outcome")
            return
        }
        #expect(version == 0)
        #expect(values.isEmpty)
    }

    @Test("any shape violation in the body is invalidResponse")
    func invalidBodies() {
        let bodies = [
            "{\"version\":-1,\"values\":{}}",
            "{\"version\":1.5,\"values\":{}}",
            "{\"version\":\"1\",\"values\":{}}",
            "{\"values\":{}}",
            "{\"version\":1}",
            "not json",
            "",
        ]
        for body in bodies {
            #expect(throws: LeverError.invalidResponse) {
                try outcome(.json(body))
            }
        }
    }

    @Test("304 requires that we asked; unsolicited is invalidResponse")
    func notModified() throws {
        guard case .notModified = try outcome(.status(304), sentValidator: true) else {
            Issue.record("expected notModified")
            return
        }
        #expect(throws: LeverError.invalidResponse) {
            try outcome(.status(304), sentValidator: false)
        }
    }

    @Test("401 is invalidKey; every other status is server, 2xx included")
    func statusMatrix() {
        #expect(throws: LeverError.invalidKey) { try outcome(.status(401)) }
        for status in [204, 201, 301, 302, 400, 403, 404, 429, 500, 503] {
            #expect(throws: LeverError.server(status: status)) { try outcome(.status(status)) }
        }
    }

    @Test("a non-HTTP response is invalidResponse, never a status")
    func nonHTTP() {
        #expect(throws: LeverError.invalidResponse) { try outcome(.nonHTTP) }
    }
}

@Suite("fetching through the client (§6.1)")
struct ClientFetchTests {
    private func client(_ harness: TestHarness) -> LeverClient {
        harness.makeClient { $0.automaticUpdates = false }
    }

    @Test("an explicit fetch stages and activate commits")
    func fetchThenActivate() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.enqueue(
            .json(resolveBody(version: 1, ["flag": boolValue(true)]), etag: "\"one\"")
        )

        try await client.fetch()
        #expect(client.flag == false)
        #expect(client.activate() == true)
        #expect(client.flag == true)
        #expect(harness.transport.requests.count == 1)
    }

    @Test("the second fetch sends the validator the first one earned")
    func sendsIfNoneMatch() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.enqueue(.json(resolveBody(version: 1), etag: "\"one\""))
        try await client.fetch()
        _ = client.activate()

        harness.transport.enqueue(.status(304, etag: "\"one\""))
        try await client.fetch()

        #expect(harness.transport.requests[0].header("If-None-Match") == nil)
        #expect(harness.transport.requests[1].header("If-None-Match") == "\"one\"")
    }

    @Test("a 304 confirming activated state persists freshness across a restart")
    func activatedConfirmationPersists() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.enqueue(.json(resolveBody(version: 1), etag: "\"one\""))
        try await client.fetch()
        _ = client.activate()

        harness.advanceWallClock(by: 3_600)
        harness.transport.enqueue(.status(304, etag: "\"one\""))
        try await client.fetch()

        // Without the metadata-only write the refreshed clock is lost on
        // relaunch and the next launch refetches inside the interval.
        let cached = harness.cacheStore().loadSnapshot()
        #expect(cached?.fetchedAt == harness.now)
        #expect(cached?.version == 1)
    }

    @Test("a 304 confirming staged state never touches activated values")
    func stagedConfirmationIsIsolated() async throws {
        let harness = TestHarness()
        let client = client(harness)

        harness.transport.enqueue(
            .json(resolveBody(version: 1, ["flag": boolValue(true)]), etag: "\"one\"")
        )
        try await client.fetch()
        _ = client.activate()

        // Stage version 2 without activating, then revalidate it.
        harness.transport.enqueue(
            .json(resolveBody(version: 2, ["flag": boolValue(false)]), etag: "\"two\"")
        )
        try await client.fetch()
        harness.advanceWallClock(by: 100)
        harness.transport.enqueue(.status(304, etag: "\"two\""))
        try await client.fetch()

        // The validator sent was the staged one.
        #expect(harness.transport.requests[2].header("If-None-Match") == "\"two\"")
        // Activated state is untouched: still version 1, still true.
        #expect(client.activatedVersion == 1)
        #expect(client.flag == true)
        #expect(harness.cacheStore().loadSnapshot()?.version == 1)

        // And the staged payload is still activatable.
        #expect(client.activate() == true)
        #expect(client.activatedVersion == 2)
        #expect(client.flag == false)
    }

    @Test("an invalid 200 body changes nothing at all")
    func invalidBodyIsAtomic() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.enqueue(
            .json(resolveBody(version: 1, ["flag": boolValue(true)]), etag: "\"one\"")
        )
        try await client.fetch()
        _ = client.activate()
        let before = harness.cacheStore().loadSnapshot()

        harness.transport.enqueue(.json("{\"version\":\"nope\"}", etag: "\"two\""))
        await #expect(throws: LeverError.invalidResponse) { try await client.fetch() }

        #expect(client.activatedVersion == 1)
        #expect(client.flag == true)
        #expect(client.activate() == false)
        #expect(harness.cacheStore().loadSnapshot() == before)
    }

    @Test("a 401 surfaces as invalidKey and leaves the cache serving")
    func invalidKey() async throws {
        let harness = TestHarness()
        harness.seedCache(version: 5, ["flag": WireValue(type: "boolean", value: .bool(true))])
        let client = client(harness)

        harness.transport.enqueue(.status(401))
        await #expect(throws: LeverError.invalidKey) { try await client.fetch() }

        #expect(client.flag == true)
        #expect(client.activatedVersion == 5)
        #expect(harness.cacheStore().loadSnapshot()?.version == 5)
    }

    @Test("a transport failure surfaces as network")
    func networkFailure() async {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.enqueue(error: URLError(.timedOut))
        await #expect(throws: LeverError.network(.timedOut)) { try await client.fetch() }
    }

    @Test("concurrent fetches collapse to one request")
    func coalescing() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.pause()
        harness.transport.enqueue(.json(resolveBody(version: 1, ["flag": boolValue(true)])))

        async let first: Void = client.fetch()
        async let second: Void = client.fetch()
        async let third: Void = client.fetch()

        await harness.transport.waitForRequests(1)
        await settle(2)
        harness.transport.resume()

        _ = try await (first, second, third)
        #expect(harness.transport.requests.count == 1)
        #expect(client.activate() == true)
        #expect(client.flag == true)
    }

    @Test("one waiter's cancellation leaves the shared fetch running")
    func cancellationDoesNotKillTheSharedFetch() async throws {
        let harness = TestHarness()
        let client = client(harness)
        harness.transport.pause()
        harness.transport.enqueue(.json(resolveBody(version: 9, ["flag": boolValue(true)])))

        let survivor = Task { try await client.fetch() }
        let quitter = Task { try await client.fetch() }
        await harness.transport.waitForRequests(1)
        await settle(2)

        quitter.cancel()
        // Never mapped to .network(.cancelled) (§5.1).
        await #expect(throws: CancellationError.self) { try await quitter.value }

        harness.transport.resume()
        try await survivor.value
        #expect(harness.transport.requests.count == 1)
        #expect(client.activate() == true)
        #expect(client.activatedVersion == 9)
    }

    @Test("teardown cancels the transport and invalidates the session")
    func teardown() async {
        let harness = TestHarness()
        do {
            let client = client(harness)
            _ = client.flag
        }
        await settle()
        #expect(harness.transport.isInvalidated)
    }
}
