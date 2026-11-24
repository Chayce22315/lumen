import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// SQL for workflow definitions. Call inside `Database.write` / `Database.read`.
///
/// `save` and `delete` record the change for sync in the same transaction. `upsertRow` and
/// `deleteRow` touch only the table; the sync engine uses them to apply remote changes.
public enum WorkflowRepository {
    /// Inserts or updates the workflow and records an upsert with its snapshot.
    public static func save(_ workflow: Workflow, in db: DatabaseConnection) throws {
        try db.transaction {
            try upsertRow(workflow, in: db)
            try db.recordUpsert(workflow.reference, snapshot: workflow)
        }
    }

    /// Deletes the workflow (its runs and schedule state cascade) and records the deletion.
    /// Returns `false`, recording nothing, when the workflow did not exist.
    @discardableResult
    public static func delete(_ id: Workflow.ID, in db: DatabaseConnection) throws -> Bool {
        try db.transaction {
            guard try deleteRow(id, in: db) else { return false }
            try db.recordDeletion(EntityReference(kind: .workflow, id: id))
            return true
        }
    }

    /// Writes the row without a change record. Uses an in-place upsert (never delete + insert),
    /// so the workflow's run history and schedule state are kept.
    public static func upsertRow(_ workflow: Workflow, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO automation_workflows
                (id, name, summary, is_enabled, trigger_type, trigger_event, trigger, graph, failure_policy, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                name = excluded.name,
                summary = excluded.summary,
                is_enabled = excluded.is_enabled,
                trigger_type = excluded.trigger_type,
                trigger_event = excluded.trigger_event,
                trigger = excluded.trigger,
                graph = excluded.graph,
                failure_policy = excluded.failure_policy,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
            [
                workflow.id, workflow.name, workflow.summary, workflow.isEnabled,
                workflow.trigger.kind, workflow.trigger.eventName?.rawValue,
                try JSONText.encode(workflow.trigger), try JSONText.encode(workflow.graph), try JSONText.encode(workflow.failurePolicy),
                workflow.createdAt, workflow.updatedAt,
            ]
        )
    }

    /// Deletes the row without a change record. Returns whether a row was deleted.
    @discardableResult
    public static func deleteRow(_ id: Workflow.ID, in db: DatabaseConnection) throws -> Bool {
        try db.execute("DELETE FROM automation_workflows WHERE id = ?", [id])
        return db.changes > 0
    }

    public static func fetch(_ id: Workflow.ID, in db: DatabaseConnection) throws -> Workflow? {
        try db.queryFirst("SELECT * FROM automation_workflows WHERE id = ?", [id]).map(Workflow.init(row:))
    }

    /// Every workflow, by name.
    public static func fetchAll(in db: DatabaseConnection) throws -> [Workflow] {
        try db.query("SELECT * FROM automation_workflows ORDER BY name COLLATE NOCASE, created_at, id").map(Workflow.init(row:))
    }

    /// Enabled workflows started by the event `name`, oldest first.
    public static func fetchEnabled(triggeredBy name: EventName, in db: DatabaseConnection) throws -> [Workflow] {
        try db.query(
            "SELECT * FROM automation_workflows WHERE trigger_type = 'event' AND trigger_event = ? AND is_enabled = 1 ORDER BY created_at, id",
            [name.rawValue]
        ).map(Workflow.init(row:))
    }

    /// Enabled schedule-triggered workflows, oldest first.
    public static func fetchEnabledScheduled(in db: DatabaseConnection) throws -> [Workflow] {
        try db.query(
            "SELECT * FROM automation_workflows WHERE trigger_type = 'schedule' AND is_enabled = 1 ORDER BY created_at, id"
        ).map(Workflow.init(row:))
    }
}
