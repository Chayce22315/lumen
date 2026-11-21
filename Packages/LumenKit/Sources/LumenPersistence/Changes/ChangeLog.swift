import Foundation
import LumenFoundation

public enum ChangeOperation: String, Sendable, Codable, Hashable {
    case upsert
    case delete
}

/// One entry of the append-only change log. Every repository write records one inside the same
/// transaction, which is what makes the app local-first: the sync engine reads this log and never
/// has to diff tables.
public struct ChangeRecord: Sendable, Hashable, Identifiable {
    public let sequence: Int64
    public let entity: EntityReference
    public let operation: ChangeOperation
    /// Full JSON snapshot of the entity after the change; `nil` for deletions.
    public let payload: JSONValue?
    public let timestamp: HybridTimestamp
    public let origin: ChangeOrigin
    public let recordedAt: Date

    public var id: Int64 { sequence }

    public init(
        sequence: Int64,
        entity: EntityReference,
        operation: ChangeOperation,
        payload: JSONValue?,
        timestamp: HybridTimestamp,
        origin: ChangeOrigin,
        recordedAt: Date
    ) {
        self.sequence = sequence
        self.entity = entity
        self.operation = operation
        self.payload = payload
        self.timestamp = timestamp
        self.origin = origin
        self.recordedAt = recordedAt
    }
}

extension DatabaseConnection {
    /// The replica (device) identifier stamped into every hybrid timestamp.
    public var replicaID: String { clock.replica }

    /// Records an upsert of `entity` with a snapshot of `value`.
    @discardableResult
    public func recordUpsert(_ entity: EntityReference, snapshot value: some Encodable) throws -> HybridTimestamp {
        try recordChange(.upsert, entity: entity, payload: try JSONValue(encoding: value), timestamp: nil)
    }

    /// Records a deletion of `entity`.
    @discardableResult
    public func recordDeletion(_ entity: EntityReference) throws -> HybridTimestamp {
        try recordChange(.delete, entity: entity, payload: nil, timestamp: nil)
    }

    /// Records a change. A `nil` timestamp means a local event and ticks the clock; remote changes pass
    /// their own timestamp, which is merged into the clock so later local edits order after them.
    @discardableResult
    public func recordChange(
        _ operation: ChangeOperation,
        entity: EntityReference,
        payload: JSONValue?,
        timestamp: HybridTimestamp?
    ) throws -> HybridTimestamp {
        let now = timeSource.now()
        let stamped: HybridTimestamp
        if let timestamp {
            _ = clock.receive(timestamp, now: now)
            stamped = timestamp
        } else {
            stamped = clock.tick(now: now)
        }
        let payloadText = try payload.map { try $0.compactString() }
        try execute(
            """
            INSERT INTO lumen_changes (entity_kind, entity_id, operation, payload, timestamp, origin, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [entity.kind, entity.id, operation.rawValue, payloadText, stamped, origin.rawValue, now]
        )
        return stamped
    }

    /// Changes with a sequence greater than `sequence`, oldest first.
    public func changes(after sequence: Int64, origin: ChangeOrigin? = nil, limit: Int = 500) throws -> [ChangeRecord] {
        let rows: [Row]
        if let origin {
            rows = try query(
                "SELECT * FROM lumen_changes WHERE sequence > ? AND origin = ? ORDER BY sequence LIMIT ?",
                [sequence, origin.rawValue, max(1, limit)]
            )
        } else {
            rows = try query(
                "SELECT * FROM lumen_changes WHERE sequence > ? ORDER BY sequence LIMIT ?",
                [sequence, max(1, limit)]
            )
        }
        return try rows.map(ChangeRecord.init(row:))
    }

    /// Full history of one entity, oldest first.
    public func history(of entity: EntityReference, limit: Int = 200) throws -> [ChangeRecord] {
        let rows = try query(
            "SELECT * FROM lumen_changes WHERE entity_kind = ? AND entity_id = ? ORDER BY sequence DESC LIMIT ?",
            [entity.kind, entity.id, max(1, limit)]
        )
        return try rows.map(ChangeRecord.init(row:)).reversed()
    }

    /// Latest recorded timestamp for an entity, used for conflict detection.
    public func latestTimestamp(of entity: EntityReference) throws -> HybridTimestamp? {
        try scalar(
            "SELECT timestamp FROM lumen_changes WHERE entity_kind = ? AND entity_id = ? ORDER BY timestamp DESC LIMIT 1",
            [entity.kind, entity.id]
        )
    }

    /// Highest sequence number in the log, or 0 when empty.
    public func latestChangeSequence() throws -> Int64 {
        try scalar("SELECT coalesce(max(sequence), 0) FROM lumen_changes") ?? 0
    }

    /// Removes acknowledged entries. Only the sync engine calls this, after the server confirmed them.
    public func pruneChanges(throughSequence sequence: Int64, recordedBefore cutoff: Date) throws {
        try execute("DELETE FROM lumen_changes WHERE sequence <= ? AND recorded_at < ?", [sequence, cutoff])
    }
}

extension ChangeRecord {
    init(row: Row) throws {
        let payloadText: String? = try row.get("payload")
        let originText: String = try row.get("origin")
        let operationText: String = try row.get("operation")
        guard let operation = ChangeOperation(rawValue: operationText) else {
            throw DatabaseError.typeMismatch(column: "operation", expected: "ChangeOperation", actual: operationText)
        }
        guard let origin = ChangeOrigin(rawValue: originText) else {
            throw DatabaseError.typeMismatch(column: "origin", expected: "ChangeOrigin", actual: originText)
        }
        self.init(
            sequence: try row.get("sequence"),
            entity: EntityReference(kind: try row.get("entity_kind"), id: try row.get("entity_id", as: UUID.self)),
            operation: operation,
            payload: try payloadText.map { try JSONValue(parsing: $0) },
            timestamp: try row.get("timestamp"),
            origin: origin,
            recordedAt: try row.get("recorded_at")
        )
    }
}
