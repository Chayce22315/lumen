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
