import Foundation
import LumenFoundation
import LumenPersistence

/// The stored next fire date of a schedule-triggered workflow.
struct ScheduleState: Sendable, Hashable {
    let workflowID: Workflow.ID
    /// The schedule `nextFireAt` was computed for; a different schedule means the workflow changed.
    var schedule: ScheduleTrigger
    /// `nil` when the series has ended.
    var nextFireAt: Date?
    var lastFiredAt: Date?
    var updatedAt: Date
}

/// SQL for schedule state. Device-local: every device computes its own fire dates.
enum ScheduleStateRepository {
    static func fetch(_ workflowID: Workflow.ID, in db: DatabaseConnection) throws -> ScheduleState? {
        try db.queryFirst("SELECT * FROM automation_schedule_state WHERE workflow_id = ?", [workflowID]).map(ScheduleState.init(row:))
    }

    static func fetchAll(in db: DatabaseConnection) throws -> [Workflow.ID: ScheduleState] {
        let states = try db.query("SELECT * FROM automation_schedule_state").map(ScheduleState.init(row:))
        return Dictionary(states.map { ($0.workflowID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func upsert(_ state: ScheduleState, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO automation_schedule_state (workflow_id, schedule, next_fire_at, last_fired_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (workflow_id) DO UPDATE SET
                schedule = excluded.schedule,
                next_fire_at = excluded.next_fire_at,
                last_fired_at = excluded.last_fired_at,
                updated_at = excluded.updated_at
            """,
            [state.workflowID, try JSONText.encode(state.schedule), state.nextFireAt, state.lastFiredAt, state.updatedAt]
        )
    }

    static func delete(_ workflowID: Workflow.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM automation_schedule_state WHERE workflow_id = ?", [workflowID])
    }

    /// The earliest pending fire date among enabled workflows.
    static func earliestFireDate(in db: DatabaseConnection) throws -> Date? {
        // `min` yields one row holding NULL when nothing is scheduled, hence the optional column type.
        let value: Date?? = try db.scalar(
            """
            SELECT min(s.next_fire_at) FROM automation_schedule_state s
            JOIN automation_workflows w ON w.id = s.workflow_id
            WHERE w.is_enabled = 1 AND w.trigger_type = 'schedule'
            """
        )
        return value.flatMap { $0 }
    }
}

extension ScheduleState {
    init(row: Row) throws {
        self.init(
            workflowID: try row.get("workflow_id"),
            schedule: try JSONText.decode(ScheduleTrigger.self, column: "schedule", in: row),
            nextFireAt: try row.get("next_fire_at"),
            lastFiredAt: try row.get("last_fired_at"),
            updatedAt: try row.get("updated_at")
        )
    }
}
