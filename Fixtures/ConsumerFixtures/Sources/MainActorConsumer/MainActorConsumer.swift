import Foundation
import Lever

/// Compiled with `MainActor` default isolation — the setting a SwiftUI app
/// most often turns on. Everything here must build warning-free.
/// `nonisolated` is load-bearing under `MainActor` default isolation: without
/// it the synthesized `Decodable` conformance is main-actor-isolated and cannot
/// satisfy `LeverKey(json:default:)`'s `Decodable & Sendable` requirement.
/// Decoding runs off the main actor, so this is the honest annotation — and it
/// is the same "prefer value types" guidance spec §2.2 already gives.
nonisolated struct PaywallConfig: Codable, Sendable {
    var headline: String
    static let standard = PaywallConfig(headline: "Go Pro")
}

extension LeverKeys {
    var enableEnrollment: LeverKey<Bool> { LeverKey("enable_enrollment", default: false) }
    var maxRetries: LeverKey<Int> { LeverKey("max_retries", default: 3) }
    var paywall: LeverKey<PaywallConfig> { LeverKey(json: "paywall", default: .standard) }
    /// Collides with a real member, so it is read through `value(for:)`.
    var updates: LeverKey<String> { LeverKey("updates", default: "off") }
}

enum MainActorConsumer {
    static func start() {
        Lever.configure(
            baseURL: URL(string: "https://lever.example")!,
            clientKey: "pk_example",
            context: LeverContext(appVersion: "1.0.0", attributes: ["tier": "free"])
        )
    }

    /// A synchronous read from a `MainActor` context: no `await`, no hop.
    static func banner() -> String {
        let lever = Lever.shared
        guard lever.enableEnrollment else { return "closed" }
        return "\(lever.paywall.headline) (\(lever.maxRetries) retries, \(lever.value(for: LeverKeys().updates)))"
    }

    static func refresh() async {
        _ = try? await Lever.shared.fetchAndActivate()
    }

    static func observe() -> Task<Void, Never> {
        Task {
            for await update in Lever.shared.updates {
                _ = update.changedKeys
            }
        }
    }
}
