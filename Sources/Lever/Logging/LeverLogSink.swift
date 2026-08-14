/// Where SDK diagnostics go. Host apps implement this to route lever's logs
/// into their own pipeline; the protocol stays this small on purpose (spec §8).
public protocol LeverLogSink: Sendable {
    func log(_ level: LeverLogLevel, _ message: String)
}

public enum LeverLogLevel: Sendable, Equatable, CaseIterable {
    case debug, info, warn, error
}

extension LeverLogSink {
    func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
    func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}
