import Foundation

/// A minimal SSE parser for exactly what lever emits (spec 0001 §7): `event:`/
/// `data:` frames, `:` comment heartbeats, and a `retry:` hint. No third-party
/// client exists in Foundation and the SDK has zero dependencies (§6.2).
///
/// It is fed arbitrary byte chunks and holds whatever is incomplete, so frames
/// split across chunk boundaries — the normal case on a socket — parse the same
/// as frames that arrive whole.
struct ServerSentEventParser: Sendable {
    struct Event: Sendable, Equatable {
        var name: String?
        var data: String
    }

    enum ParseError: Error, Equatable {
        /// The server emits tiny frames, so an overrun means a broken peer. The
        /// stream errors and reconnects through backoff rather than buffering
        /// without limit (§6.2).
        case frameTooLarge
    }

    static let maxFrameBytes = 1 << 20

    private var buffer: [UInt8] = []
    private var pendingName: String?
    private var pendingData: String?

    init() {}

    mutating func consume(_ chunk: [UInt8]) throws -> [Event] {
        buffer.append(contentsOf: chunk)

        var events: [Event] = []
        var lineStart = 0
        var index = 0

        while index < buffer.count {
            let byte = buffer[index]
            guard byte == 0x0A || byte == 0x0D else {
                index += 1
                continue
            }
            // A lone CR at the very end may still be the first half of a CRLF.
            if byte == 0x0D, index + 1 == buffer.count { break }

            let line = Array(buffer[lineStart..<index])
            index += (byte == 0x0D && buffer[index + 1] == 0x0A) ? 2 : 1
            lineStart = index
            if let event = handle(line: line) { events.append(event) }
        }

        buffer.removeFirst(lineStart)
        guard buffer.count <= Self.maxFrameBytes,
            (pendingData?.utf8.count ?? 0) <= Self.maxFrameBytes
        else {
            throw ParseError.frameTooLarge
        }
        return events
    }

    private mutating func handle(line: [UInt8]) -> Event? {
        // The blank line dispatches whatever has accumulated.
        if line.isEmpty {
            defer {
                pendingName = nil
                pendingData = nil
            }
            guard let data = pendingData else { return nil }
            return Event(name: pendingName, data: data)
        }
        // `:` starts a comment — this is what a heartbeat is.
        if line[0] == 0x3A { return nil }

        let (field, value) = Self.split(line)
        switch field {
        case "event":
            pendingName = value
        case "data":
            pendingData = pendingData.map { "\($0)\n\(value)" } ?? value
        case "retry":
            // Parsed and discarded: backoff is client-owned (§6.2).
            break
        default:
            break
        }
        return nil
    }

    private static func split(_ line: [UInt8]) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: 0x3A) else {
            return (String(decoding: line, as: UTF8.self), "")
        }
        var valueStart = colon + 1
        // A single leading space after the colon is part of the syntax.
        if valueStart < line.count, line[valueStart] == 0x20 { valueStart += 1 }
        return (
            String(decoding: line[..<colon], as: UTF8.self),
            String(decoding: line[valueStart...], as: UTF8.self)
        )
    }
}

/// The one frame lever sends: `{"version":42}`. Version numbers only, never
/// values — the stream is a nudge, not a source of truth (research 0001 §3.2).
enum VersionFrame {
    private struct Payload: Decodable {
        let version: Int
    }

    static func version(in data: String) -> Int? {
        try? JSONDecoder().decode(Payload.self, from: Data(data.utf8)).version
    }
}
