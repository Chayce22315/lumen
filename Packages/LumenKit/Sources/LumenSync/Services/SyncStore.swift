import Foundation
import LumenFoundation
import LumenPersistence

/// The last synchronized state of an entity plus, per replica, the newest timestamp observed
/// from that replica for this entity. The latter tells genuinely new remote writes apart from
/// old values that merely ride along in a full-state envelope.
struct ShadowRecord: Sendable, Hashable, Codable {
    var state: EntityState
    var observed: [String: HybridTimestamp]

    static let empty = ShadowRecord(state: .empty, observed: [:])

    func observing(_ incoming: EntityState) -> ShadowRecord {
        var observed = self.observed
        let stamps = incoming.fields.values.map(\.timestamp) + [incoming.tombstone].compactMap { $0 }
        for stamp in stamps where stamp > (observed[stamp.replica] ?? .zero) {
            observed[stamp.replica] = stamp
        }
        return ShadowRecord(state: state.merged(with: incoming), observed: observed)
    }
}

/// Bookkeeping SQL for the sync engine: cursor, push position, shadows, conflicts and runs.
struct SyncStore: Sendable {
    static let cursorKey = "cursor"
    static let pushedSequenceKey = "pushed_sequence"
    static let lastSuccessKey = "last_success"

    func value(_ key: String, in db: DatabaseConnection) throws -> String? {
        try db.scalar("SELECT value FROM sync_state WHERE key = ?", [key])
    }

    func setValue(_ value: String?, for key: String, in db: DatabaseConnection) throws {
        if let value {
            try db.execute(
                "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [key, value]
            )
        } else {
            try db.execute("DELETE FROM sync_state WHERE key = ?", [key])
        }
    }

    func pushedSequence(in db: DatabaseConnection) throws -> Int64 {
        Int64(try value(Self.pushedSequenceKey, in: db) ?? "0") ?? 0
    }

    func shadow(of entity: EntityReference, in db: DatabaseConnection) throws -> ShadowRecord? {
        guard let text: String = try db.scalar(
            "SELECT state FROM sync_shadows WHERE entity_kind = ? AND entity_id = ?",
            [entity.kind, entity.id]
        ) else { return nil }
        return try JSONCoding.decode(ShadowRecord.self, from: text)
    }

    func saveShadow(_ record: ShadowRecord, of entity: EntityReference, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO sync_shadows (entity_kind, entity_id, state) VALUES (?, ?, ?)
            ON CONFLICT(entity_kind, entity_id) DO UPDATE SET state = excluded.state
            """,
            [entity.kind, entity.id, try JSONCoding.encodeString(record)]
        )
    }

    func insert(_ conflict: SyncConflict, in db: DatabaseConnection) throws {
        try db.execute(
            "INSERT INTO sync_conflicts (id, entity_kind, entity_id, fields, detected_at, reviewed_at) VALUES (?, ?, ?, ?, ?, ?)",
            [conflict.id, conflict.entity.kind, conflict.entity.id, JSONColumn(conflict.fields), conflict.detectedAt, conflict.reviewedAt]
        )
    }

    func conflicts(includeReviewed: Bool, in db: DatabaseConnection) throws -> [SyncConflict] {
        let sql = includeReviewed
            ? "SELECT * FROM sync_conflicts ORDER BY detected_at DESC"
            : "SELECT * FROM sync_conflicts WHERE reviewed_at IS NULL ORDER BY detected_at DESC"
        return try db.query(sql).map { row in
            SyncConflict(
                id: try row.get("id"),
                entity: EntityReference(kind: try row.get("entity_kind"), id: try row.get("entity_id", as: UUID.self)),
                fields: try row.json("fields"),
                detectedAt: try row.get("detected_at"),
                reviewedAt: try row.get("reviewed_at")
            )
        }
    }

    func insert(_ run: SyncRun, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO sync_runs (id, started_at, finished_at, outcome, pushed, pulled, conflicts, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [run.id, run.startedAt, run.finishedAt, run.outcome.rawValue, run.pushed, run.pulled, run.conflicts, run.errorMessage]
        )
        // Keep the most recent 200 runs.
        try db.execute("DELETE FROM sync_runs WHERE id NOT IN (SELECT id FROM sync_runs ORDER BY started_at DESC LIMIT 200)")
    }

    func runs(limit: Int, in db: DatabaseConnection) throws -> [SyncRun] {
        try db.query("SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT ?", [max(1, limit)]).map { row in
            let outcomeText: String = try row.get("outcome")
            return SyncRun(
                id: try row.get("id"),
                startedAt: try row.get("started_at"),
                finishedAt: try row.get("finished_at"),
                outcome: SyncRun.Outcome(rawValue: outcomeText) ?? .failed,
                pushed: try row.get("pushed"),
                pulled: try row.get("pulled"),
                conflicts: try row.get("conflicts"),
                errorMessage: try row.get("error_message")
            )
        }
    }

    /// The change records of `entity` from its first unpushed local change onwards (remote merges
    /// applied in between included, in order), plus the snapshot just before them. Empty when the
    /// entity has no unpushed local change.
    func pendingChanges(for entity: EntityReference, after pushed: Int64, in db: DatabaseConnection) throws -> (previous: JSONValue??, pending: [ChangeRecord]) {
        let history = try db.history(of: entity, limit: 500)
        guard let first = history.first(where: { $0.origin == .local && $0.sequence > pushed }) else { return (nil, []) }
        let pending = history.filter { $0.sequence >= first.sequence }
        let previous: JSONValue??
        if let earlier = history.last(where: { $0.sequence < first.sequence }) {
            previous = .some(earlier.operation == .delete ? nil : earlier.payload)
        } else {
            previous = nil
        }
        return (previous, pending)
    }
}
