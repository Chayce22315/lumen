import Foundation
import LumenFoundation

/// Errors raised by the automation engine's public API.
public enum AutomationError: Error, Sendable, Hashable, PresentableError, CustomStringConvertible {
    /// The workflow has validation errors (warnings never block saving).
    case invalidWorkflow([ValidationIssue])
    case workflowNotFound(Workflow.ID)
    case runNotFound(WorkflowRun.ID)
    /// The run is executing in this process already.
    case runAlreadyActive(WorkflowRun.ID)
    /// Only waiting and interrupted runs can be resumed.
    case runNotResumable(WorkflowRun.ID)
    /// A run was requested from a context that is already this many automation hops deep.
    case causationLimitReached(depth: Int)
    case duplicateAction(AutomationActionID)

    public var description: String {
        switch self {
        case .invalidWorkflow(let issues):
            return "Invalid workflow: " + issues.errors.map(\.message).joined(separator: "; ")
        case .workflowNotFound(let id): return "No workflow \(id)"
        case .runNotFound(let id): return "No workflow run \(id)"
        case .runAlreadyActive(let id): return "Workflow run \(id) is already executing"
        case .runNotResumable(let id): return "Workflow run \(id) cannot be resumed"
        case .causationLimitReached(let depth): return "Automation causation depth \(depth) reached"
        case .duplicateAction(let id): return "Action \(id) is already registered"
        }
    }

    public var presentation: ErrorPresentation {
        switch self {
        case .invalidWorkflow(let issues):
            let errors = issues.errors
            var message = errors.first?.message ?? "The workflow has problems."
            if errors.count > 1 {
                message += " (\(errors.count - 1) more \(errors.count == 2 ? "problem" : "problems"))"
            }
            return ErrorPresentation(
                title: "Workflow can't be saved",
                message: message,
                recoverySuggestion: "Fix the highlighted steps and try again."
            )
        case .workflowNotFound:
            return ErrorPresentation(title: "Workflow not found", message: "This workflow no longer exists. It may have been deleted on another device.")
        case .runNotFound:
            return ErrorPresentation(title: "Run not found", message: "This run is no longer in the history.")
        case .runAlreadyActive:
            return ErrorPresentation(title: "Already running", message: "This run is in progress.", isRetryable: true)
        case .runNotResumable:
            return ErrorPresentation(title: "Can't resume", message: "Only waiting or interrupted runs can be resumed.")
        case .causationLimitReached:
            return ErrorPresentation(
                title: "Automation loop stopped",
                message: "Automations triggered each other too many times in a row, so this run was not started."
            )
        case .duplicateAction:
            return ErrorPresentation(title: "Action unavailable", message: "Another action with the same identifier is already installed.")
        }
    }
}
