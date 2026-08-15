import Synchronization

/// Persists snapshots in commit order and drops obsolete writes.
///
/// Activation deliberately does its filesystem work *outside* the state lock
/// (§4.1's no-callout rule), which leaves two commits free to reach the disk in
/// either order: a thread preempted between committing version 2 and writing it
/// can land after a version 3 write, and the next launch would then restore
/// version 2 over a process that has been serving version 3. Nothing detects
/// that — it is a logical ordering bug, not a data race.
///
/// Every write carries the sequence it was stamped with under the state lock,
/// so "commit order" and "write order" are the same order by construction.
final class SnapshotWriter: Sendable {
    private let store: CacheStore
    /// The highest sequence that has reached the file. Held across the write
    /// itself — that is what serializes concurrent writers, and a cache write
    /// is a per-activation event, not a hot path.
    private let written = Mutex<UInt64>(0)

    init(store: CacheStore) {
        self.store = store
    }

    func write(_ snapshot: CachedSnapshot, sequence: UInt64) {
        written.withLock { highest in
            // A delayed write from an older commit has nothing to add.
            guard sequence > highest else { return }
            highest = sequence
            store.save(snapshot)
        }
    }
}
