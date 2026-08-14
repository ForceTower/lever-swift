import Foundation
import os

/// The default sink: one `os.Logger` under the host bundle's subsystem.
///
/// Messages are interpolated as `public` — lever's diagnostics are key names,
/// versions, and HTTP statuses, and config values are public by design
/// (research 0001 §6). Redacting them would only make the log useless.
public struct OSLogSink: LeverLogSink, Sendable {
    private let logger: Logger

    public init() {
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lever", category: "lever")
    }

    public func log(_ level: LeverLogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
