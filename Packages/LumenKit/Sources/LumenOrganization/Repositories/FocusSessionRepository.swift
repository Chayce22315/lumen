import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for focus sessions. Sessions are device-local, so writes record no change for sync.
/// Stateless; every function runs inside a `Database` closure.
public struct FocusSessionRepository: Sendable {
    public init() {}

    static let columns = "id, task_id, planned_seconds, started_at, paused_at, paused_seconds, ended_at, outcome, completes_task"

    /// Inserts or updates by id. Not `INSERT OR REPLACE`: that would resolve a clash with the
    /// one-active-session index by deleting the other session instead of failing.
    public func save(_ session: FocusSession, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO organization_focus_sessions (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                task_id = excluded.task_id, planned_seconds = excluded.planned_seconds, started_at = excluded.started_at,
                paused_at = excluded.paused_at, paused_seconds = excluded.paused_seconds, ended_at = excluded.ended_at,
                outcome = excluded.outcome, completes_task = excluded.completes_task
            """,
            session.rowArguments
        )
    }

    public func session(_ id: FocusSession.ID, in db: DatabaseConnection) throws -> FocusSession? {
        try db.queryFirst("SELECT * FROM organization_focus_sessions WHERE id = ?", [id]).map(FocusSession.init(row:))
    }

    /// The session that has not ended, if any (the schema allows at most one).
    public func active(in db: DatabaseConnection) throws -> FocusSession? {
        try db.queryFirst("SELECT * FROM organization_focus_sessions WHERE ended_at IS NULL LIMIT 1").map(FocusSession.init(row:))
    }

    /// Sessions about `taskID`, newest first.
    public func sessions(forTask taskID: TaskItem.ID, in db: DatabaseConnection) throws -> [FocusSession] {
        try db.query(
            "SELECT * FROM organization_focus_sessions WHERE task_id = ? ORDER BY started_at DESC, id",
            [taskID]
        ).map(FocusSession.init(row:))
    }

    /// The most recently started sessions, newest first.
    public func recent(limit: Int, in db: DatabaseConnection) throws -> [FocusSession] {
        try db.query(
            "SELECT * FROM organization_focus_sessions ORDER BY started_at DESC, id LIMIT ?",
            [max(1, limit)]
        ).map(FocusSession.init(row:))
    }

    /// Sessions that ended in `[start, end)`, oldest first.
    public func ended(between start: Date, and end: Date, in db: DatabaseConnection) throws -> [FocusSession] {
        try db.query(
            "SELECT * FROM organization_focus_sessions WHERE ended_at >= ? AND ended_at < ? ORDER BY ended_at, id",
            [start, end]
        ).map(FocusSession.init(row:))
    }
}
