import Foundation
import LumenPersistence

/// Tables owned by the automation engine. Migrations are append-only.
///
/// - `automation_workflows`: synchronized definitions. The trigger, graph and failure policy are
///   JSON; `trigger_type` and `trigger_event` are denormalized for event lookup.
/// - `automation_schedule_state`: next fire date per schedule-triggered workflow, with the
///   schedule it was computed for so edits (local or synced) are detected.
/// - `automation_runs`, `automation_run_steps`: device-local execution history. Since 0002 a step
///   keeps the inputs it resolved (`inputs`, JSON, NULL for older steps).
public enum AutomationSchema {
    public static let schema = DatabaseSchema(namespace: "automation", migrations: [
        .sql("0001_workflows_runs_schedules", """
            CREATE TABLE automation_workflows (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                trigger_type TEXT NOT NULL CHECK (trigger_type IN ('manual', 'event', 'schedule')),
                trigger_event TEXT,
                trigger TEXT NOT NULL,
                graph TEXT NOT NULL,
                failure_policy TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX automation_workflows_trigger ON automation_workflows (trigger_type, trigger_event, is_enabled);

            CREATE TABLE automation_schedule_state (
                workflow_id TEXT PRIMARY KEY NOT NULL REFERENCES automation_workflows (id) ON DELETE CASCADE,
                schedule TEXT NOT NULL,
                next_fire_at REAL,
                last_fired_at REAL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX automation_schedule_state_next ON automation_schedule_state (next_fire_at);

            CREATE TABLE automation_runs (
                id TEXT PRIMARY KEY NOT NULL,
                workflow_id TEXT NOT NULL REFERENCES automation_workflows (id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK (status IN ('running', 'waiting', 'succeeded', 'failed', 'cancelled', 'interrupted')),
                trigger_payload TEXT NOT NULL,
                input TEXT NOT NULL,
                causation_depth INTEGER NOT NULL DEFAULT 0,
                correlation_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                resume_at REAL,
                current_node_id TEXT,
                error_message TEXT
            );
            CREATE INDEX automation_runs_workflow ON automation_runs (workflow_id, started_at DESC);
            CREATE INDEX automation_runs_status ON automation_runs (status, resume_at);
            CREATE INDEX automation_runs_correlation ON automation_runs (correlation_id, workflow_id);
            CREATE INDEX automation_runs_finished ON automation_runs (finished_at);

            CREATE TABLE automation_run_steps (
                id TEXT PRIMARY KEY NOT NULL,
                run_id TEXT NOT NULL REFERENCES automation_runs (id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                node_id TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('running', 'waiting', 'succeeded', 'failed', 'cancelled', 'interrupted')),
                attempt_count INTEGER NOT NULL DEFAULT 1,
                started_at REAL NOT NULL,
                finished_at REAL,
                output TEXT,
                message TEXT,
                error_message TEXT,
                warnings TEXT NOT NULL DEFAULT '[]'
            );
            CREATE UNIQUE INDEX automation_run_steps_sequence ON automation_run_steps (run_id, sequence);
            """),
        .sql("0002_run_step_inputs", """
            ALTER TABLE automation_run_steps ADD COLUMN inputs TEXT;
            """),
    ])
}
