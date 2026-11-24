import Foundation
import LumenFoundation
import LumenPersistence

/// One field's value and the hybrid timestamp of the change that last set it.
public struct FieldState: Sendable, Hashable, Codable {
    /// `nil` means the field is absent (a cleared optional).
    public var value: JSONValue?
    public var timestamp: HybridTimestamp

    public init(value: JSONValue?, timestamp: HybridTimestamp) {
        self.value = value
        self.timestamp = timestamp
    }
}

/// The synchronized state of one entity: a last-writer-wins map of fields plus a deletion
/// tombstone. Merging is commutative, associative and idempotent, so every replica converges to
/// the same state regardless of the order in which it receives changes.
public struct EntityState: Sendable, Hashable, Codable {
    public var fields: [String: FieldState]
    public var tombstone: HybridTimestamp?

    public init(fields: [String: FieldState] = [:], tombstone: HybridTimestamp? = nil) {
        self.fields = fields
        self.tombstone = tombstone
    }

    public static let empty = EntityState()

    public var latestFieldTimestamp: HybridTimestamp? {
        fields.values.map(\.timestamp).max()
    }

    public var latestTimestamp: HybridTimestamp {
        [latestFieldTimestamp, tombstone].compactMap { $0 }.max() ?? .zero
    }

    /// Deleted when the tombstone is at least as new as every field write.
    public var isDeleted: Bool {
        guard let tombstone else { return false }
        guard let latest = latestFieldTimestamp else { return true }
        return tombstone >= latest
    }

    public var isEmpty: Bool { fields.isEmpty && tombstone == nil }

    /// The entity snapshot, or `nil` when deleted or unknown.
    public var snapshot: JSONValue? {
        guard !isDeleted, !fields.isEmpty else { return nil }
        return .object(fields.compactMapValues(\.value))
    }

    /// Field-wise last-writer-wins merge.
    public func merged(with other: EntityState) -> EntityState {
        var result = fields
        for (key, theirs) in other.fields {
            guard let ours = result[key] else {
                result[key] = theirs
                continue
            }
            if theirs.timestamp > ours.timestamp {
                result[key] = theirs
            } else if theirs.timestamp == ours.timestamp, theirs.value != ours.value {
                // Identical timestamps with different values cannot come from a correct clock; pick
                // deterministically so replicas still agree.
                let theirsText = (try? theirs.value?.compactString()) ?? ""
                let oursText = (try? ours.value?.compactString()) ?? ""
                if theirsText > oursText { result[key] = theirs }
            }
        }
        let tombstone = [self.tombstone, other.tombstone].compactMap { $0 }.max()
        return EntityState(fields: result, tombstone: tombstone)
    }
}

/// One entity's state on the wire.
public struct SyncEnvelope: Sendable, Hashable, Codable {
    public let entity: EntityReference
    public let state: EntityState
    /// Replica that pushed the envelope; a replica skips its own envelopes when pulling.
    public let origin: String

    public init(entity: EntityReference, state: EntityState, origin: String) {
        self.entity = entity
        self.state = state
        self.origin = origin
    }
}

public struct PullResult: Sendable, Hashable {
    public let envelopes: [SyncEnvelope]
    /// Opaque position to resume from next time.
    public let cursor: String
    public let hasMore: Bool

    public init(envelopes: [SyncEnvelope], cursor: String, hasMore: Bool) {
        self.envelopes = envelopes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// A field both replicas changed differently since they last agreed. The later write won; the
/// other value is kept so the user can restore it.
public struct FieldConflict: Sendable, Hashable, Codable {
    public let field: String
    public let localValue: JSONValue?
    public let remoteValue: JSONValue?
    public let chosen: Side

    public enum Side: String, Sendable, Hashable, Codable {
        case local
        case remote
    }

    public init(field: String, localValue: JSONValue?, remoteValue: JSONValue?, chosen: Side) {
        self.field = field
        self.localValue = localValue
        self.remoteValue = remoteValue
        self.chosen = chosen
    }
}

/// A conflict that was resolved automatically and is kept for the user to review.
public struct SyncConflict: Sendable, Hashable, Identifiable {
    public typealias ID = Identifier<SyncConflict>

    public let id: ID
    public let entity: EntityReference
    public let fields: [FieldConflict]
    public let detectedAt: Date
    public var reviewedAt: Date?

    public init(id: ID = ID(), entity: EntityReference, fields: [FieldConflict], detectedAt: Date, reviewedAt: Date? = nil) {
        self.id = id
        self.entity = entity
        self.fields = fields
        self.detectedAt = detectedAt
        self.reviewedAt = reviewedAt
    }
}

public struct SyncRun: Sendable, Hashable, Identifiable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case succeeded
        case failed
        case offline
        case skipped
    }

    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let outcome: Outcome
    public let pushed: Int
    public let pulled: Int
    public let conflicts: Int
    public let errorMessage: String?

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date, outcome: Outcome, pushed: Int, pulled: Int, conflicts: Int, errorMessage: String?) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.pushed = pushed
        self.pulled = pulled
        self.conflicts = conflicts
        self.errorMessage = errorMessage
    }
}

public struct SyncStatus: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// No transport configured: everything stays on this device.
        case notConfigured
        case idle
        case syncing
        case offline
        case failed(ErrorPresentation)
    }

    public var state: State
    public var lastSuccess: Date?
    public var pendingChanges: Int
    public var unreviewedConflicts: Int
    public var nextAttempt: Date?

    public init(state: State, lastSuccess: Date? = nil, pendingChanges: Int = 0, unreviewedConflicts: Int = 0, nextAttempt: Date? = nil) {
        self.state = state
        self.lastSuccess = lastSuccess
        self.pendingChanges = pendingChanges
        self.unreviewedConflicts = unreviewedConflicts
        self.nextAttempt = nextAttempt
    }
}
