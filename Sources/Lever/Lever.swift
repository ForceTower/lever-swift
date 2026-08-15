import Foundation
import Synchronization

/// The one-line entry point.
///
/// There is deliberately no lazy placeholder client: a half-configured
/// singleton silently serving defaults is the failure mode Firebase users know
/// and hate, so misuse traps instead (§2.1). Multiple explicit `LeverClient`
/// instances are always allowed — `shared` is sugar, not a registry.
public enum Lever {
    /// `reserved` is the state between winning the right to configure and
    /// having a client to install. It exists so the configure-once rule is a
    /// guarantee rather than a check: without it, two callers can both read
    /// "not configured", both build a client — each with a live runtime,
    /// timers, and a stream — and install one over the other.
    private enum Installation {
        case empty
        case reserved
        case installed(LeverClient)
    }

    private static let installation = Mutex<Installation>(.empty)

    public static func configure(_ configuration: LeverConfiguration) {
        precondition(
            reserveInstallation(),
            "Lever.configure was called twice. Configure once at launch; for a second environment, construct a LeverClient directly."
        )
        // Deliberately outside the lock: initialization touches the filesystem
        // and logs through a host-provided sink (§4.1).
        let client = LeverClient(configuration: configuration)
        installation.withLock { $0 = .installed(client) }
    }

    public static func configure(baseURL: URL, clientKey: String, context: LeverContext) {
        configure(LeverConfiguration(baseURL: baseURL, clientKey: clientKey, context: context))
    }

    public static var shared: LeverClient {
        guard case .installed(let client) = installation.withLock({ $0 }) else {
            preconditionFailure(
                "Lever.shared was read before Lever.configure. Call Lever.configure(…) at launch, before the first read."
            )
        }
        return client
    }

    /// The atomic half of `configure`: exactly one caller can move the
    /// singleton out of `empty`. Factored out so the race has a test that does
    /// not have to trap the test process to observe the loser.
    static func reserveInstallation() -> Bool {
        installation.withLock { installation in
            guard case .empty = installation else { return false }
            installation = .reserved
            return true
        }
    }

    /// Test-only: the public singleton is process-global, so its suite needs a
    /// way back to the unconfigured state. The production `preconditionFailure`
    /// stays intact (§10.2).
    static func resetForTesting() {
        installation.withLock { $0 = .empty }
    }
}
