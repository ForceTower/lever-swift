import Foundation

// watchOS is checked first: it can import UIKit too, but `WKApplication` is the
// type that carries its lifecycle notifications.
#if os(watchOS)
    import WatchKit
#elseif canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum LeverLifecyclePhase: Sendable, Equatable {
    case foreground
    case background
}

/// Reports the **current** phase at subscription, then every transition.
///
/// Initial state, not just events, is the requirement: a client created after
/// the app is already active must connect the stream immediately — waiting for
/// a foreground transition that already happened would leave SSE closed for the
/// whole session (§5.2).
protocol LeverLifecycleSource: Sendable {
    func phases() -> AsyncStream<LeverLifecyclePhase>
}

/// Binds the platform's notifications behind `#if canImport`, from the runtime
/// actor, keeping public API and the client core platform-free (§5.2).
struct PlatformLifecycleSource: LeverLifecycleSource {
    func phases() -> AsyncStream<LeverLifecyclePhase> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                // No lifecycle API here: foreground forever, no events (§5.2).
                guard let names = lifecycleNotificationNames() else {
                    continuation.yield(.foreground)
                    continuation.finish()
                    return
                }
                continuation.yield(currentPhase())
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(
                            named: names.foreground
                        ) {
                            continuation.yield(.foreground)
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(
                            named: names.background
                        ) {
                            continuation.yield(.background)
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Resolved on the main actor because watchOS declares its notification names
/// there, unlike UIKit and AppKit.
@MainActor
private func lifecycleNotificationNames()
    -> (foreground: Notification.Name, background: Notification.Name)?
{
    #if os(watchOS)
        (WKApplication.didBecomeActiveNotification, WKApplication.didEnterBackgroundNotification)
    #elseif canImport(UIKit)
        (UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification)
    #elseif canImport(AppKit)
        (NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification)
    #else
        nil
    #endif
}

/// The shared application object is unavailable to app extensions, and this
/// package must compile into one (§7). Reaching it through the Objective-C
/// runtime keeps that symbol out of the extension-unsafe surface: an app gets
/// its real state, an extension gets the foreground default that §5.2
/// prescribes wherever lifecycle APIs are absent.
@MainActor
private func currentPhase() -> LeverLifecyclePhase {
    #if os(macOS)
        let className = "NSApplication"
        let property = "active"
        let isBackground: (Int) -> Bool = { $0 == 0 }
    #elseif os(watchOS)
        let className = "WKApplication"
        let property = "applicationState"
        let isBackground: (Int) -> Bool = { $0 == 2 }
    #else
        let className = "UIApplication"
        let property = "applicationState"
        // UIApplicationState: 0 active, 1 inactive, 2 background.
        let isBackground: (Int) -> Bool = { $0 == 2 }
    #endif

    guard let type = NSClassFromString(className) as? NSObject.Type else { return .foreground }
    let selector = NSSelectorFromString("sharedApplication")
    guard type.responds(to: selector),
        let shared = type.perform(selector)?.takeUnretainedValue() as? NSObject,
        let state = shared.value(forKey: property) as? Int
    else { return .foreground }

    return isBackground(state) ? .background : .foreground
}
