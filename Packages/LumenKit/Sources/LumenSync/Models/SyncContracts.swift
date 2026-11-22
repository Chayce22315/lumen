import Foundation
import LumenFoundation
import LumenPersistence

/// The remote side of synchronization. Implementations talk to a server (or iCloud); the engine
/// owns ordering, merging, retries and bookkeeping.
public protocol SyncTransport: Sendable {
    /// Sends local changes. Must be idempotent: re-sending an envelope with the same entity and
    /// timestamp has no further effect.
    func push(_ envelopes: [SyncEnvelope]) async throws
    /// Changes after `cursor` (`nil` = from the beginning), oldest first.
    func pull(after cursor: String?, limit: Int) async throws -> PullResult
    /// Called at the start of every run, before pushing. `hasSynchronizedBefore` is true when this
    /// device has pulled from the remote before. A transport whose remote store has been emptied
    /// since (for example, the user deleted their iCloud data) throws `.remoteReset`; the engine
    /// then re-sends everything it knows.
    func prepare(hasSynchronizedBefore: Bool) async throws
}

extension SyncTransport {
    public func prepare(hasSynchronizedBefore: Bool) async throws {}
}

/// Carries document files, which are not part of the change log. Files are content-addressed by
/// their SHA-256, so uploading the same file twice is a no-op.
public protocol BlobTransport: Sendable {
    func containsBlob(sha256: String) async throws -> Bool
    func uploadBlob(_ data: Data, sha256: String) async throws
    /// The file's bytes, or `nil` when no device has uploaded it (yet).
    func downloadBlob(sha256: String) async throws -> Data?
}

public enum SyncTransportError: Error, Sendable, Equatable {
    /// No connectivity; the engine reports "offline" instead of an error.
    case offline
    /// The credentials were rejected; retrying will not help.
    case unauthorized
    /// A temporary server problem; retried with backoff.
    case unavailable(retryAfter: TimeInterval?)
    /// The server rejected the request; not retried.
    case rejected(String)
    /// The remote store lost what this device synchronized before (it was deleted or reset).
    /// The engine re-sends every entity it knows and reads the remote from the beginning.
    case remoteReset
}

/// Reads and writes one entity kind on behalf of the sync engine. Implemented in the application
/// layer on top of each module's repository (`upsertRow` / `deleteRow`).
public protocol SyncEntityHandler: Sendable {
    var kind: EntityKind { get }
    /// The current local snapshot, `nil` when the entity doesn't exist locally.
    func snapshot(id: UUID, in db: DatabaseConnection) throws -> JSONValue?
    /// Writes a snapshot (without recording a change; the engine does that).
    func apply(_ snapshot: JSONValue, id: UUID, in db: DatabaseConnection) throws
    /// Removes the entity locally (without recording a change).
    func remove(id: UUID, in db: DatabaseConnection) throws
}
