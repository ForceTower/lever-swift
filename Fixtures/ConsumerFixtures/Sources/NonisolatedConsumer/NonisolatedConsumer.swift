import Foundation
import Lever

/// The same code compiled with nonisolated default isolation — the setting a
/// framework or a package target usually keeps.
struct PaywallConfig: Codable, Sendable {
    var headline: String
    static let standard = PaywallConfig(headline: "Go Pro")
}

extension LeverKeys {
    var enableEnrollment: LeverKey<Bool> { LeverKey("enable_enrollment", default: false) }
    var maxRetries: LeverKey<Int> { LeverKey("max_retries", default: 3) }
    var paywall: LeverKey<PaywallConfig> { LeverKey(json: "paywall", default: .standard) }
    var updates: LeverKey<String> { LeverKey("updates", default: "off") }
}

struct NonisolatedConsumer: Sendable {
    let client: LeverClient

    init(cacheDirectory: URL?) {
        var configuration = LeverConfiguration(
            baseURL: URL(string: "https://lever.example")!,
            clientKey: "pk_example",
            context: LeverContext()
        )
        // The App Group reader role: no fetch, timer, lifecycle, or stream.
        configuration.cacheDirectory = cacheDirectory
        configuration.cacheNamespace = "prod"
        configuration.automaticUpdates = false
        client = LeverClient(configuration: configuration)
    }

    func banner() -> String {
        guard client.enableEnrollment else { return "closed" }
        return "\(client.paywall.headline) (\(client.maxRetries), \(client.value(for: LeverKeys().updates)))"
    }

    /// Reads from a detached, nonisolated context — the client is `Sendable`.
    func readFromAnywhere() async -> Bool {
        await Task.detached { client.enableEnrollment }.value
    }
}
