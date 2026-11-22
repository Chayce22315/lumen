import Foundation
import LumenFoundation
import LumenCore

/// Builds the run lifecycle events. They carry the run's correlation and one more causation hop
/// than the trigger, like the events its actions publish, so a workflow reacting to run outcomes
/// cannot loop on its own runs.
enum RunEvents {
    static func name(for status: WorkflowRun.Status) -> EventName? {
        switch status {
        case .running, .waiting: return nil
        case .succeeded: return AutomationEvents.runSucceeded
        case .failed, .interrupted: return AutomationEvents.runFailed
        case .cancelled: return AutomationEvents.runCancelled
        }
    }

    static func event(_ name: EventName, for run: WorkflowRun, stepCount: Int, failedSteps: Int, at date: Date) -> DomainEvent {
        let context = ActionContext(actor: .automation, correlationID: run.correlationID, causationDepth: run.causationDepth + 1)
        return context.event(
            name,
            entity: run.reference,
            attributes: [
                "workflowID": .string(run.workflowID.uuidString),
                "runID": .string(run.id.uuidString),
                "status": .string(run.status.rawValue),
                "trigger": .string(run.triggerPayload["type"]?.stringValue ?? "unknown"),
                "steps": .number(Double(stepCount)),
                "failedSteps": .number(Double(failedSteps)),
            ],
            at: date
        )
    }
}
