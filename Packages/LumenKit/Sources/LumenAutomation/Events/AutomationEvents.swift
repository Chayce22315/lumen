import Foundation
import LumenFoundation
import LumenCore

extension EntityKind {
    /// A workflow definition. Synchronized across devices through the change log.
    public static let workflow: EntityKind = "workflow"
    /// One execution of a workflow. Device-local: runs are history, not shared state.
    public static let workflowRun: EntityKind = "workflow-run"
}

/// Event names owned by the automation engine. They are persisted by analytics and referenced by
/// saved automations, so they never change once shipped.
public enum AutomationEvents {
    public static let workflowCreated: EventName = "automation.workflow.created"
    public static let workflowUpdated: EventName = "automation.workflow.updated"
    public static let workflowDeleted: EventName = "automation.workflow.deleted"
    public static let workflowEnabled: EventName = "automation.workflow.enabled"
    public static let workflowDisabled: EventName = "automation.workflow.disabled"

    public static let runStarted: EventName = "automation.run.started"
    public static let runSucceeded: EventName = "automation.run.succeeded"
    public static let runFailed: EventName = "automation.run.failed"
    public static let runCancelled: EventName = "automation.run.cancelled"

    /// Every event the engine publishes.
    public static let all: [EventName] = [
        workflowCreated, workflowUpdated, workflowDeleted, workflowEnabled, workflowDisabled,
        runStarted, runSucceeded, runFailed, runCancelled,
    ]
}
