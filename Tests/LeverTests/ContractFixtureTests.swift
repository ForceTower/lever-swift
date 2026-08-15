import Foundation
import Testing

@testable import Lever

/// Replays the HTTP tapes recorded against the real service (spec §10.4).
///
/// The fixtures live in the lever monorepo, pinned by SHA in
/// `.contract-fixtures-sha`; CI checks that revision out and points
/// `LEVER_CONTRACT_FIXTURES` at it. Locally, a sibling `lever` checkout is used
/// if one is there. Same tapes, three languages — this is what keeps the SDKs
/// from each agreeing with a slightly different server.
private func contractFixturesDirectory() -> URL? {
    let fileManager = FileManager.default
    if let path = ProcessInfo.processInfo.environment["LEVER_CONTRACT_FIXTURES"] {
        let url = URL(fileURLWithPath: path)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sibling = packageRoot
        .deletingLastPathComponent()
        .appending(path: "lever/packages/contract-fixtures/fixtures/http")
    return fileManager.fileExists(atPath: sibling.path) ? sibling : nil
}

private func contractFixtureFiles() -> [URL] {
    guard let directory = contractFixturesDirectory(),
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appending(path: $0) }
}

/// The SDK's half of the fixture format. `setup` is the server test's business
/// and is deliberately not decoded here.
private struct HTTPFixture: Decodable {
    let name: String
    let steps: [Step]

    struct Step: Decodable {
        let request: Request
        let response: Response
        let expect: Expect
    }

    struct Request: Decodable {
        let path: String
        let context: Context
        let query: String
        let ifNoneMatch: Validator?
    }

    struct Validator: Decodable {
        let fromStep: Int
    }

    struct Context: Decodable {
        let platform: String?
        let appVersion: String?
        let clientId: String?
        let attributes: [String: String]
    }

    struct Response: Decodable {
        let status: Int
        let etag: String?
        let body: JSONValue?
    }

    struct Expect: Decodable {
        let activatedVersion: Int?
        let changed: Bool?
        let error: String?
        let reads: [Read]?
    }

    struct Read: Decodable {
        let key: String
        let type: String
        let `default`: JSONValue
        let expected: JSONValue
    }
}

private func asBool(_ value: JSONValue) -> Bool? {
    if case .bool(let bool) = value { return bool }
    return nil
}

private func asString(_ value: JSONValue) -> String? {
    if case .string(let string) = value { return string }
    return nil
}

private func asInt(_ value: JSONValue) -> Int? {
    switch value {
    case .int(let int): return int
    case .double(let double) where double.rounded() == double: return Int(double)
    default: return nil
    }
}

private func asDouble(_ value: JSONValue) -> Double? {
    switch value {
    case .int(let int): return Double(int)
    case .double(let double): return double
    default: return nil
    }
}

/// The fixture format's `json` read type: a string-to-string map, so a
/// non-string member is a decode failure that must fall back to the default.
private func asStringMap(_ value: JSONValue) -> [String: String]? {
    guard case .object(let object) = value else { return nil }
    var map: [String: String] = [:]
    for (key, member) in object {
        guard case .string(let string) = member else { return nil }
        map[key] = string
    }
    return map
}

@Suite("contract fixtures (§10.4)")
struct ContractFixtureTests {
    @Test("the pinned fixture checkout is where CI said it would be")
    func fixturesArePresent() {
        guard ProcessInfo.processInfo.environment["LEVER_CONTRACT_FIXTURES"] != nil else { return }
        #expect(contractFixtureFiles().count >= 6)
    }

    @Test(
        "replays the tape",
        .enabled(if: contractFixturesDirectory() != nil),
        arguments: contractFixtureFiles()
    )
    func replay(file: URL) async throws {
        let fixture = try JSONDecoder().decode(HTTPFixture.self, from: Data(contentsOf: file))
        #expect(file.deletingPathExtension().lastPathComponent == fixture.name)

        let harness = TestHarness()
        let context = try #require(fixture.steps.first).request.context

        // The client id is an installation identifier the SDK generates, so the
        // tape's value is planted where init will find it.
        if let clientId = context.clientId {
            let store = harness.cacheStore()
            try FileManager.default.createDirectory(
                at: store.directory,
                withIntermediateDirectories: true
            )
            try Data("{\"clientId\":\"\(clientId)\",\"schemaVersion\":1}".utf8)
                .write(to: store.identityURL)
        }

        let client = harness.makeClient {
            $0.context = LeverContext(
                platform: LeverPlatform(context.platform ?? "ios"),
                appVersion: context.appVersion,
                attributes: context.attributes
            )
            $0.automaticUpdates = false
        }
        #expect(client.clientId == context.clientId)

        var recordedETags: [String?] = []

        for (index, step) in fixture.steps.enumerated() {
            var headers = HTTPHeaders()
            if let etag = step.response.etag { headers["ETag"] = etag }
            let body =
                step.response.body.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            harness.transport.enqueue(
                HTTPResponse(status: step.response.status, headers: headers, body: body)
            )
            recordedETags.append(step.response.etag)

            var changed: Bool?
            var thrown: (any Error)?
            do {
                changed = try await client.fetchAndActivate()
            } catch {
                thrown = error
            }

            // The request the SDK built must be the one the server answered.
            let request = harness.transport.requests[index]
            #expect(request.url.path == step.request.path)
            #expect(request.url.query(percentEncoded: true) == step.request.query)
            if let validator = step.request.ifNoneMatch {
                #expect(request.header("If-None-Match") == recordedETags[validator.fromStep - 1])
            } else {
                #expect(request.header("If-None-Match") == nil)
            }

            switch step.expect.error {
            case "invalidKey":
                #expect(thrown as? LeverError == .invalidKey)
            case .some(let name):
                Issue.record("unhandled expected error: \(name)")
            case nil:
                #expect(thrown == nil, "step \(index + 1) threw \(String(describing: thrown))")
                if let expected = step.expect.changed { #expect(changed == expected) }
            }

            #expect(client.activatedVersion == step.expect.activatedVersion)

            for read in step.expect.reads ?? [] {
                switch read.type {
                case "boolean":
                    let key = LeverKey(read.key, default: try #require(asBool(read.default) as Bool?))
                    #expect(client.value(for: key) == asBool(read.expected))
                case "string":
                    let key = LeverKey(read.key, default: try #require(asString(read.default)))
                    #expect(client.value(for: key) == asString(read.expected))
                case "int":
                    let key = LeverKey(read.key, default: try #require(asInt(read.default)))
                    #expect(client.value(for: key) == asInt(read.expected))
                case "double":
                    let key = LeverKey(read.key, default: try #require(asDouble(read.default)))
                    #expect(client.value(for: key) == asDouble(read.expected))
                case "json":
                    let fallback = try #require(asStringMap(read.default))
                    let key = LeverKey(json: read.key, default: fallback)
                    #expect(client.value(for: key) == asStringMap(read.expected))
                default:
                    Issue.record("unknown read type: \(read.type)")
                }
            }
        }

        #expect(harness.transport.requests.count == fixture.steps.count)
        withExtendedLifetime(client) {}
    }
}
