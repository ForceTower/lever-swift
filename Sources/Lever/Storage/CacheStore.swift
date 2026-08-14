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

        if let existing = readIdentity() { return existing }

        let generated = UUID().uuidString.lowercased()
        let payload = IdentityFile(schemaVersion: Self.schemaVersion, clientId: generated)
        guard let data = try? JSONEncoder.lever.encode(payload) else { return generated }

        switch exclusivelyCreate(identityURL, data: data) {
        case .created:
            return generated
        case .alreadyExists:
            // Someone else won; their identity is the one on disk.
            return readIdentity() ?? overwriteIdentity(generated)
        case .failed(let message):
            sink.error("client id could not be persisted error=\(message)")
            return generated
        }
    }

    private func readIdentity() -> String? {
        guard let data = try? Data(contentsOf: identityURL) else { return nil }
        guard let file = try? JSONDecoder().decode(IdentityFile.self, from: data),
            file.schemaVersion == Self.schemaVersion
        else {
            sink.warn("identity file is unreadable — regenerating the client id")
            return nil
        }
        // Spec 0001 §6.2 caps clientId at 64 chars; an overlong one would 400.
        guard !file.clientId.isEmpty, file.clientId.utf16.count <= 64 else {
            sink.warn("client id is out of range — regenerating")
            return nil
        }
        return file.clientId
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

    private func write(_ data: Data, to url: URL, what: String) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            sink.error("\(what) write failed error=\(error.localizedDescription)")
        }
    }

    private enum ExclusiveCreate {
        case created
        case alreadyExists
        case failed(String)
    }

    private func exclusivelyCreate(_ url: URL, data: Data) -> ExclusiveCreate {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        }
        if descriptor < 0 {
            return errno == EEXIST ? .alreadyExists : .failed(String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return .created
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - File shapes

private struct IdentityFile: Codable {
    let schemaVersion: Int
    let clientId: String
}

/// All fields are required except `etag` — the file exists only once something
/// has been activated, so there is no half-empty state to represent (§7).
private struct SnapshotFile: Codable {
    let schemaVersion: Int
    let version: Int
    let etag: String?
    let values: [String: WireValue]
    let fetchedAt: Int
    let activatedAt: Int
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
