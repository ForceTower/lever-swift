import Foundation

/// The last-activated snapshot, as it lives on disk (§7).
///
/// `values` is the **raw wire payload**, untouched: the cache replays a resolve
/// response rather than re-encoding typed values, so read semantics (§2.3) are
/// identical from cache and from network by construction.
struct CachedSnapshot: Sendable, Equatable {
    var version: Int
    var etag: String?
    var values: [String: WireValue]
    var fetchedAt: Int
    var activatedAt: Int
}

/// Two files under `{cacheDirectory}/Lever/`, splitting what must survive a
/// credential rotation (the identity) from what a rotation may discard (a
/// snapshot). Nothing here throws: a cache is a floor, not a dependency.
struct CacheStore: Sendable {
    static let schemaVersion = 1

    let directory: URL
    let keyHash: String
    let sink: any LeverLogSink

    var identityURL: URL { directory.appendingPathComponent("identity.json") }
    var snapshotURL: URL { directory.appendingPathComponent("\(keyHash).json") }

    // MARK: - Identity

    /// The installation identifier: stable across key rotation, environments,
    /// and contexts, because it is the future rollout bucketing key — one that
    /// reshuffled on every credential rotation would re-randomize every
    /// percentage rollout (§7).
    ///
    /// First creation is an **exclusive create**, and the loser of a race
    /// re-reads the winner's file. Atomic replace alone would let two racing
    /// processes keep different in-memory identities while one file silently
    /// won.
    func loadOrCreateClientId() -> String {
        createDirectory()

        let existing = readIdentity()
        switch existing {
        case .found(let clientId):
            return clientId
        case .outOfReach:
            // Data Protection, almost always: the file is there and will be
            // readable again once the device is unlocked. Minting a replacement
            // is wrong and *persisting* one would destroy the installation's
            // real identity, so this id is deliberately volatile — it lasts for
            // this launch and touches nothing on disk.
            sink.warn("identity file could not be read — using a volatile client id for this launch")
            return UUID().uuidString.lowercased()
        case .absent, .unusable:
            break
        }

        let generated = UUID().uuidString.lowercased()
        let payload = IdentityFile(schemaVersion: Self.schemaVersion, clientId: generated)
        guard let data = try? JSONEncoder.lever.encode(payload) else { return generated }

        // Bytes that parsed but are not an identity are not someone else's
        // identity either, so there is nothing to lose by replacing them.
        if case .unusable = existing { return overwriteIdentity(generated) }

        switch exclusivelyCreate(identityURL, data: data) {
        case .created:
            return generated
        case .alreadyExists:
            // Someone else won between the read and the link; their identity is
            // the one on disk. Overwriting is safe only when the re-read proves
            // the file unusable — never when it merely could not be read.
            switch readIdentity() {
            case .found(let clientId): return clientId
            case .unusable: return overwriteIdentity(generated)
            case .absent, .outOfReach: return generated
            }
        case .failed(let message):
            sink.error("client id could not be persisted error=\(message)")
            // Nothing was published, so a readable file can only be someone
            // else's — preferring it keeps a failed write from minting a second
            // identity for an installation that already has one.
            if case .found(let clientId) = readIdentity() { return clientId }
            return generated
        }
    }

    /// Why absence and unreadability are not the same answer: collapsing them
    /// makes a locked device look like a first run, and the first run path both
    /// mints a new identity *and* writes it over the one already there.
    private enum IdentityRead {
        case found(String)
        /// No file — a genuine first run.
        case absent
        /// A file that cannot be read *right now*. Never a reason to write.
        case outOfReach
        /// Read, but not an identity: wrong schema, bad JSON, not a uuid.
        case unusable
    }

    private func readIdentity() -> IdentityRead {
        let data: Data
        do {
            data = try Data(contentsOf: identityURL)
        } catch {
            return isFileNotFound(error) ? .absent : .outOfReach
        }
        guard let file = try? JSONDecoder().decode(IdentityFile.self, from: data),
            file.schemaVersion == Self.schemaVersion
        else {
            sink.warn("identity file is unreadable — regenerating the client id")
            return .unusable
        }
        // §7 defines the persisted identity as a lowercase UUID, and spec 0001
        // §6.2 caps clientId at 64 chars, so anything unparseable is corrupt.
        guard let uuid = UUID(uuidString: file.clientId) else {
            sink.warn("client id is not a uuid — regenerating")
            return .unusable
        }
        let canonical = uuid.uuidString.lowercased()
        guard canonical == file.clientId else {
            // Same installation, wrong spelling. Rewriting beats regenerating:
            // the client id is the rollout bucketing key, and two SDKs sharing
            // a cache directory that each regenerated on the other's casing
            // would reshuffle every percentage rollout forever.
            sink.warn("client id was not canonical — rewriting it lowercase")
            return .found(overwriteIdentity(canonical))
        }
        return .found(file.clientId)
    }

    private func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT)
        default:
            return false
        }
    }

    @discardableResult
    private func overwriteIdentity(_ clientId: String) -> String {
        let payload = IdentityFile(schemaVersion: Self.schemaVersion, clientId: clientId)
        if let data = try? JSONEncoder.lever.encode(payload) {
            write(data, to: identityURL, what: "identity")
        }
        return clientId
    }

    // MARK: - Snapshot

    /// `nil` for a first run, and for every unusable file: the snapshot file is
    /// a cache, so a schema bump discards rather than migrates (§7).
    func loadSnapshot() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let file = try? JSONDecoder().decode(SnapshotFile.self, from: data) else {
            sink.warn("cache file is corrupt — treating as a first run")
            return nil
        }
        guard file.schemaVersion == Self.schemaVersion else {
            sink.warn("cache file schema is unknown schemaVersion=\(file.schemaVersion) — discarding")
            return nil
        }
        guard file.version >= 0 else {
            sink.warn("cache file version is negative — treating as a first run")
            return nil
        }
        // Unix seconds are non-negative. Letting a negative one through would
        // reach the scheduler's elapsed-time arithmetic and trap, turning a
        // corrupt cache into a crash — the one thing the floor forbids (§10.1).
        guard file.fetchedAt >= 0, file.activatedAt >= 0 else {
            sink.warn("cache file timestamps are out of range — treating as a first run")
            return nil
        }
        return CachedSnapshot(
            version: file.version,
            etag: file.etag,
            values: file.values,
            fetchedAt: file.fetchedAt,
            activatedAt: file.activatedAt
        )
    }

    /// A write failure logs and changes nothing about the in-memory activation:
    /// reads serve the new snapshot, only the floor is stale (§7).
    func save(_ snapshot: CachedSnapshot) {
        createDirectory()
        let file = SnapshotFile(
            schemaVersion: Self.schemaVersion,
            version: snapshot.version,
            etag: snapshot.etag,
            values: snapshot.values,
            fetchedAt: snapshot.fetchedAt,
            activatedAt: snapshot.activatedAt
        )
        guard let data = try? JSONEncoder.lever.encode(file) else {
            sink.error("cache snapshot could not be encoded version=\(snapshot.version)")
            return
        }
        write(data, to: snapshotURL, what: "cache")
    }

    // MARK: - File plumbing

    private func createDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            sink.error("cache directory could not be created error=\(error.localizedDescription)")
        }
    }

    /// `.atomic`, plus an explicit protection class on the platforms that have
    /// one. Left to inherit, these files take whatever the host app made its
    /// default — and an app that opts into complete protection would make them
    /// unreadable whenever the device is locked, which is exactly when a
    /// background launch reads them. Until-first-unlock is the platform's own
    /// default for app data: it survives a locked device without asking for
    /// weaker protection than the app already chose for everything else.
    private var writingOptions: Data.WritingOptions {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            return [.atomic]
        #endif
    }

    private func write(_ data: Data, to url: URL, what: String) {
        do {
            try data.write(to: url, options: writingOptions)
        } catch {
            sink.error("\(what) write failed error=\(error.localizedDescription)")
        }
    }

    private enum ExclusiveCreate {
        case created
        case alreadyExists
        case failed(String)
    }

    /// Write-then-`link`, not `O_CREAT | O_EXCL` on the destination.
    ///
    /// An exclusive create publishes the *name* before the bytes, so a racing
    /// reader can find an empty file, decide it is corrupt, and overwrite the
    /// winner's identity with its own. `link` publishes a fully written file in
    /// one atomic step, which makes "the file exists" mean "the file is
    /// complete" — the property the loser's re-read depends on (§7).
    private func exclusivelyCreate(_ url: URL, data: Data) -> ExclusiveCreate {
        let temporary = directory.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        do {
            // The link shares the temporary's inode, so the protection class
            // set here is the one identity.json ends up carrying.
            try data.write(to: temporary, options: writingOptions)
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let linked = temporary.withUnsafeFileSystemRepresentation { source -> Int32 in
            url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return link(source, destination)
            }
        }
        if linked == 0 { return .created }
        return errno == EEXIST ? .alreadyExists : .failed(String(cString: strerror(errno)))
    }
}

// MARK: - File shapes

private struct IdentityFile: Codable {
    let schemaVersion: Int
    let clientId: String
}

/// All fields are required except `etag`, which is nullable — the file exists
/// only once something has been activated, so there is no half-empty state to
/// represent (§7).
private struct SnapshotFile: Codable {
    let schemaVersion: Int
    let version: Int
    let etag: String?
    let values: [String: WireValue]
    let fetchedAt: Int
    let activatedAt: Int

    /// `etag` is written as an explicit `null` rather than omitted, so every
    /// snapshot file has the same key set whatever produced it — the format
    /// fixtures other SDKs read stay one shape.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(version, forKey: .version)
        try container.encode(etag, forKey: .etag)
        try container.encode(values, forKey: .values)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(activatedAt, forKey: .activatedAt)
    }
}

extension JSONEncoder {
    /// Sorted keys keep both files byte-stable, so the format fixtures catch
    /// accidental drift instead of key-order noise.
    static var lever: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
