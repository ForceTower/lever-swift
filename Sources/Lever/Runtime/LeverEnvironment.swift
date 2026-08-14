import Foundation
import Synchronization

/// The monotonic clock the runtime schedules on: immune to wall-clock jumps,
/// and the seam that makes every timing test deterministic (§10).
protocol LeverClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousLeverClock: LeverClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, tolerance: .seconds(1))
    }
}

/// Everything non-deterministic, in one injectable bundle.
///
/// The two time seams are separate on purpose: persisted timestamps must
/// survive a relaunch (so they are wall-clock Unix seconds), while timers,
/// backoff, and the watchdog must not care what the wall clock does (§5.1).
struct LeverEnvironment: Sendable {
    var makeTransport: @Sendable (ValidatedConfiguration) -> any LeverTransport
    /// Wall clock, Unix seconds.
    var now: @Sendable () -> Int
    var clock: any LeverClock
    var lifecycle: @Sendable () -> any LeverLifecycleSource
    /// Full jitter: a value in `0...ceiling` (§6.2).
    var jitter: @Sendable (Double) -> Double

    static let live = LeverEnvironment(
        makeTransport: { _ in URLSessionTransport() },
        now: { Int(Date().timeIntervalSince1970) },
        clock: ContinuousLeverClock(),
        lifecycle: { PlatformLifecycleSource() },
        jitter: { ceiling in Double.random(in: 0...ceiling) }
    )
}

/// Awaits `task` without ever cancelling it.
///
/// Coalesced fetches share transport work, so one waiter walking away must not
/// take the request with it: this caller sees `CancellationError` while the
/// shared fetch runs on for everyone still interested (§5.1).
private enum Wait<Success: Sendable>: Sendable {
    case pending
    case waiting(CheckedContinuation<Success, any Error>)
    case finished(Result<Success, any Error>)
    /// The cancellation handler fired before the continuation was installed.
    case cancelled
    case done
}

func awaitWithoutCancelling<Success: Sendable>(_ task: Task<Success, any Error>) async throws
    -> Success
{
    let state = Mutex<Wait<Success>>(.pending)

    let observer = Task {
        let result = await task.result
        let continuation: CheckedContinuation<Success, any Error>? = state.withLock { wait in
            switch wait {
            case .waiting(let continuation):
                wait = .done
                return continuation
            case .pending:
                wait = .finished(result)
                return nil
            default:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
    defer { observer.cancel() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Success, any Error>? = state.withLock { wait in
                switch wait {
                case .pending:
                    wait = .waiting(continuation)
                    return nil
                case .finished(let result):
                    wait = .done
                    return result
                // The handler already fired, before the body even ran.
                case .cancelled:
                    wait = .done
                    return .failure(CancellationError())
                default:
                    return nil
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    } onCancel: {
        let continuation: CheckedContinuation<Success, any Error>? = state.withLock { wait in
            switch wait {
            case .waiting(let continuation):
                wait = .done
                return continuation
            case .pending:
                wait = .cancelled
                return nil
            default:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }
}
