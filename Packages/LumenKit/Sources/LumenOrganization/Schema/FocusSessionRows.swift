import Foundation
import LumenFoundation
import LumenPersistence

/// Row ⇄ model mapping for `organization_focus_sessions` (created by migration `0002_focus_sessions`).
extension FocusSession {
    init(row: Row) throws {
        let outcome: String? = try row.get("outcome")
        self.init(
            id: try row.get("id"),
            taskID: try row.get("task_id"),
            plannedDuration: try row.get("planned_seconds"),
            startedAt: try row.get("started_at"),
            pausedAt: try row.get("paused_at"),
            pausedDuration: try row.get("paused_seconds"),
            endedAt: try row.get("ended_at"),
            outcome: try outcome.map { raw in
                guard let value = FocusOutcome(rawValue: raw) else {
                    throw DatabaseError.typeMismatch(column: "outcome", expected: "FocusOutcome", actual: raw)
                }
                return value
            },
            completesTask: try row.get("completes_task")
        )
    }

    var rowArguments: [any DatabaseValueConvertible] {
        [id, taskID, plannedDuration, startedAt, pausedAt, pausedDuration, endedAt, outcome?.rawValue, completesTask]
    }
}
