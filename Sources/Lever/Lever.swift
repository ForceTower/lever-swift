import Foundation
import Synchronization

/// The one-line entry point.
///
/// There is deliberately no lazy placeholder client: a half-configured
/// singleton silently serving defaults is the failure mode Firebase users know
/// and hate, so misuse traps instead (§2.1). Multiple explicit `LeverClient`
/// instances are always allowed — `shared` is sugar, not a registry.
public enum Lever {
    private static let installed = Mutex<LeverClient?>(nil)

    public static func configure(_ configuration: LeverConfiguration) {
        precondition(
            installed.withLock { $0 == nil },
            "Lever.configure was called twice. Configure once at launch; for a second environment, construct a LeverClient directly."
        )
        let client = LeverClient(configuration: configuration)
        installed.withLock { $0 = client }
    }

    public static func configure(baseURL: URL, clientKey: String, context: LeverContext) {
        configure(LeverConfiguration(baseURL: baseURL, clientKey: clientKey, context: context))
    }

    public static var shared: LeverClient {
        guard let client = installed.withLock({ $0 }) else {
            preconditionFailure(
                "Lever.shared was read before Lever.configure. Call Lever.configure(…) at launch, before the first read."
            )
        }
        return client
    }

    /// Test-only: the public singleton is process-global, so its suite needs a
    /// way back to the unconfigured state. The production `preconditionFailure`
    /// stays intact (§10.2).
    static func resetForTesting() {
        installed.withLock { $0 = nil }
    }
}

