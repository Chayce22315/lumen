import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for run history. Runs and steps are device-local, so nothing here records changes.
enum RunRepository {
    static func insert(_ run: WorkflowRun, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO automation_runs
                (id, workflow_id, status, trigger_payload, input, causation_depth, correlation_id,
                 started_at, finished_at, resume_at, current_node_id, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                run.id, run.workflowID, run.status, try JSONText.encode(run.triggerPayload), try JSONText.encode(run.input),
                run.causationDepth, run.correlationID, run.startedAt, run.finishedAt, run.resumeAt, run.currentNodeID, run.errorMessage,
            ]
        )
    }

    /// Updates the mutable fields of a run. Throws `notFound` when the run no longer exists (its
    /// workflow was deleted while it executed).
    static func update(_ run: WorkflowRun, in db: DatabaseConnection) throws {
        try db.execute(
            """
            UPDATE automation_runs
            SET status = ?, finished_at = ?, resume_at = ?, current_node_id = ?, error_message = ?
            WHERE id = ?
            """,
            [run.status, run.finishedAt, run.resumeAt, run.currentNodeID, run.errorMessage, run.id]
        )
        guard db.changes > 0 else { throw DatabaseError.notFound(run.reference) }
    }

    static func upsertStep(_ step: RunStep, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO automation_run_steps
                (id, run_id, sequence, node_id, status, attempt_count, started_at, finished_at, output, message, error_message, warnings)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                status = excluded.status,
                attempt_count = excluded.attempt_count,
                finished_at = excluded.finished_at,
                output = excluded.output,
                message = excluded.message,
                error_message = excluded.error_message,
                warnings = excluded.warnings
            """,
            [
                step.id, step.runID, step.sequence, step.nodeID, step.status, step.attemptCount, step.startedAt, step.finishedAt,
                try step.output.map { try JSONText.encode($0) }, step.message, step.errorMessage, try JSONText.encode(step.warnings),
            ]
        )
    }

    /// Ends steps left running or waiting (cancellation, interruption).
    static func closeOpenSteps(of runID: WorkflowRun.ID, as status: RunStep.Status, at date: Date, in db: DatabaseConnection) throws {
        try db.execute(
            "UPDATE automation_run_steps SET status = ?, finished_at = ? WHERE run_id = ? AND status IN ('running', 'waiting')",
            [status, date, runID]
        )
    }

    static func fetch(_ id: WorkflowRun.ID, in db: DatabaseConnection) throws -> WorkflowRun? {
        try db.queryFirst("SELECT * FROM automation_runs WHERE id = ?", [id]).map(WorkflowRun.init(row:))
    }

    static func exists(_ id: WorkflowRun.ID, in db: DatabaseConnection) throws -> Bool {
        let count: Int = try db.scalar("SELECT count(*) FROM automation_runs WHERE id = ?", [id]) ?? 0
        return count > 0
    }

    static func steps(of runID: WorkflowRun.ID, in db: DatabaseConnection) throws -> [RunStep] {
        try db.query("SELECT * FROM automation_run_steps WHERE run_id = ? ORDER BY sequence", [runID]).map(RunStep.init(row:))
    }

    /// Runs of one workflow, newest first.
    static func runs(of workflowID: Workflow.ID, limit: Int, in db: DatabaseConnection) throws -> [WorkflowRun] {
        try db.query(
            "SELECT * FROM automation_runs WHERE workflow_id = ? ORDER BY started_at DESC, rowid DESC LIMIT ?",
            [workflowID, max(1, limit)]
        ).map(WorkflowRun.init(row:))
    }

    /// Runs of every workflow, newest first.
    static func recentRuns(limit: Int, in db: DatabaseConnection) throws -> [WorkflowRun] {
        try db.query("SELECT * FROM automation_runs ORDER BY started_at DESC, rowid DESC LIMIT ?", [max(1, limit)]).map(WorkflowRun.init(row:))
    }

    static func runs(withStatus status: WorkflowRun.Status, in db: DatabaseConnection) throws -> [WorkflowRun] {
        try db.query("SELECT * FROM automation_runs WHERE status = ? ORDER BY started_at, rowid", [status]).map(WorkflowRun.init(row:))
    }

    /// Waiting runs whose delay has elapsed, soonest first.
    static func waitingRuns(dueBy date: Date, in db: DatabaseConnection) throws -> [WorkflowRun] {
        try db.query(
            "SELECT * FROM automation_runs WHERE status = 'waiting' AND resume_at <= ? ORDER BY resume_at, rowid",
            [date]
        ).map(WorkflowRun.init(row:))
    }

    static func earliestResumeDate(in db: DatabaseConnection) throws -> Date? {
        // `min` yields one row holding NULL when nothing waits, hence the optional column type.
        let value: Date?? = try db.scalar("SELECT min(resume_at) FROM automation_runs WHERE status = 'waiting'")
        return value.flatMap { $0 }
    }

    /// Whether a run of `workflowID` carries `correlationID`, i.e. an event came from that run.
    static func hasRun(of workflowID: Workflow.ID, correlationID: UUID, in db: DatabaseConnection) throws -> Bool {
        let count: Int = try db.scalar(
            "SELECT count(*) FROM automation_runs WHERE correlation_id = ? AND workflow_id = ?",
            [correlationID, workflowID]
        ) ?? 0
        return count > 0
    }

    /// Deletes finished runs (and their steps) that ended before `cutoff`. Returns the number of runs deleted.
    static func purge(finishedBefore cutoff: Date, in db: DatabaseConnection) throws -> Int {
        try db.execute(
            """
            DELETE FROM automation_runs
            WHERE status IN ('succeeded', 'failed', 'cancelled', 'interrupted') AND finished_at IS NOT NULL AND finished_at < ?
            """,
            [cutoff]
        )
        return db.changes
    }
}
