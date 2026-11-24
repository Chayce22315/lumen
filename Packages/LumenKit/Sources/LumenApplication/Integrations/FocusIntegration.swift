import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenAnalytics
import LumenIntelligence
import LumenAutomation

/// Focus sessions wired into analytics, the assistant and automations.
public enum FocusIntegration {
    /// Minutes of completed focus per day, summed from `organization.focus.completed`.
    public static let minutesMeasure = AnalyticsMeasure(
        id: "focus.minutes",
        events: [OrganizationEvent.focusCompleted],
        attribute: "focusedMinutes"
    )

    /// "25 minutes", "1 hour 30 minutes" — whole minutes, rounded.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        let minuteText = rest == 1 ? "1 minute" : "\(rest) minutes"
        guard hours > 0 else { return minuteText }
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? hourText : "\(hourText) \(minuteText)"
    }
}

/// Resolves an entity given as `kind:UUID` or a bare UUID.
private func referencedID(_ value: String?) -> UUID? {
    guard let value = value?.nonBlank else { return nil }
    return EntityReference(uri: value)?.id ?? UUID(uuidString: value)
}

// MARK: - Assistant

struct StartFocusTool: AssistantTool {
    let focus: FocusService
    let tasks: TaskService

    let definition = ToolDefinition(
        name: "start_focus",
        description: "Starts a focus session (a countdown timer), optionally on one task. Only one session can run at a time.",
        inputSchema: Schema.object([
            "minutes": Schema.integer("Length of the session.", minimum: FocusSessionRules.minimumMinutes, maximum: FocusSessionRules.maximumMinutes),
            "task_id": Schema.string("Optional task reference (task:UUID) or UUID from list_tasks or search_lumen."),
            "complete_task": ["type": "boolean", "description": "Mark the task done when the session completes (requires task_id)."],
        ], required: [])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let minutes = input["minutes"]?.intValue ?? FocusSessionRules.defaultMinutes
        var draft = FocusDraft(plannedMinutes: minutes, completesTask: input["complete_task"]?.boolValue ?? false)
        if let raw = input["task_id"]?.stringValue {
            guard let id = referencedID(raw) else { return .error("Not a task id.") }
            draft.taskID = TaskItem.ID(id)
        }
        let session: FocusSession
        do {
            session = try await focus.start(draft, context: context.action)
        } catch let error as OrganizationError {
            return .error(error.presentation.message)
        } catch let error as ValidationError {
            return .error(error.reason)
        }
        var text = "Started focusing for \(FocusIntegration.durationText(session.plannedDuration))"
        var references = [session.reference]
        if let taskID = session.taskID, let task = try await tasks.task(taskID) {
            text += " on “\(task.title)”"
            references.append(task.reference)
        }
        if session.completesTask { text += "; the task will be marked done when the session completes" }
        return ToolOutput(text: text + ".", referencedEntities: references)
    }
}

struct StopFocusTool: AssistantTool {
    let focus: FocusService

    let definition = ToolDefinition(
        name: "stop_focus",
        description: "Ends the running focus session: 'finish' counts the time focused so far, 'cancel' discards it.",
        inputSchema: Schema.object([
            "outcome": Schema.string("How to end it (default finish).", enum: ["finish", "cancel"]),
        ], required: [])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let outcome = input["outcome"]?.stringValue ?? "finish"
        guard outcome == "finish" || outcome == "cancel" else { return .error("outcome must be finish or cancel.") }
        guard let active = try await focus.activeSession() else { return ToolOutput(text: "No focus session is running.") }
        let ended: FocusSession
        if outcome == "cancel" {
            ended = try await focus.cancel(active.id, context: context.action)
        } else {
            ended = try await focus.finish(active.id, context: context.action).session
        }
        let focused = FocusIntegration.durationText(ended.focusedDuration(at: ended.endedAt ?? ended.startedAt))
        let text = ended.phase == .cancelled
            ? "Cancelled the focus session after \(focused)."
            : "Finished the focus session: \(focused) of focus."
        return ToolOutput(text: text, referencedEntities: [ended.reference])
    }
}

// MARK: - Automations

struct StartFocusAction: AutomationAction {
    let focus: FocusService

    let descriptor = AutomationActionDescriptor(
        id: "organization.startFocus",
        title: "Start focus session",
        summary: "Starts a focus countdown, optionally on a task. Does nothing while another session runs.",
        symbolName: "timer",
        category: "Focus",
        parameters: [
            ActionParameterSpec(name: "minutes", title: "Minutes", kind: .number, defaultValue: .number(Double(FocusSessionRules.defaultMinutes))),
            ActionParameterSpec(name: "task", title: "Task", kind: .entity(.task)),
            ActionParameterSpec(name: "completeTask", title: "Complete the task when done", kind: .boolean, defaultValue: false),
        ],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        let minutes = invocation.number("minutes") ?? invocation.string("minutes").flatMap(Double.init) ?? Double(FocusSessionRules.defaultMinutes)
        let bounds = Double(FocusSessionRules.minimumMinutes)...Double(FocusSessionRules.maximumMinutes)
        guard minutes.rounded() == minutes, bounds.contains(minutes) else {
            throw AutomationActionError.permanent("Minutes must be a whole number from \(FocusSessionRules.minimumMinutes) to \(FocusSessionRules.maximumMinutes).")
        }
        let completes = invocation.bool("completeTask") ?? (invocation.string("completeTask")?.lowercased() == "true")
        var draft = FocusDraft(plannedMinutes: Int(minutes), completesTask: completes)
        if let raw = invocation.string("task")?.nonBlank {
            guard let id = referencedID(raw) else { throw AutomationActionError.permanent("Choose a task.") }
            draft.taskID = TaskItem.ID(id)
        }
        do {
            let session = try await focus.start(draft, context: invocation.context)
            return ActionOutcome(
                output: ["id": .string(session.id.uuidString), "reference": .string(session.reference.uri), "minutes": .number(Double(session.plannedMinutes))],
                message: "Started focusing for \(FocusIntegration.durationText(session.plannedDuration))"
            )
        } catch OrganizationError.focusSessionAlreadyActive {
            // Not a failure of the workflow: the user is already focusing.
            return ActionOutcome(output: ["started": false], message: "A focus session is already running")
        } catch let error as ValidationError {
            throw AutomationActionError.permanent(error.reason)
        } catch let error as OrganizationError {
            throw AutomationActionError.permanent(error.presentation.message)
        }
    }
}

struct StopFocusAction: AutomationAction {
    let focus: FocusService

    let descriptor = AutomationActionDescriptor(
        id: "organization.stopFocus",
        title: "End focus session",
        summary: "Finishes (counting the time so far) or cancels the running focus session.",
        symbolName: "stop.circle",
        category: "Focus",
        parameters: [
            ActionParameterSpec(name: "outcome", title: "Outcome", kind: .choice(["finish", "cancel"]), defaultValue: "finish"),
        ],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        let outcome = invocation.string("outcome")?.nonBlank ?? "finish"
        guard outcome == "finish" || outcome == "cancel" else { throw AutomationActionError.permanent("Outcome must be finish or cancel.") }
        guard let active = try await focus.activeSession() else {
            return ActionOutcome(output: ["ended": false], message: "No focus session was running")
        }
        let ended = outcome == "cancel"
            ? try await focus.cancel(active.id, context: invocation.context)
            : try await focus.finish(active.id, context: invocation.context).session
        let focused = ended.focusedDuration(at: ended.endedAt ?? ended.startedAt)
        return ActionOutcome(
            output: ["ended": true, "outcome": .string(ended.phase.rawValue), "focusedMinutes": .number((focused / 60).rounded())],
            message: ended.phase == .cancelled ? "Cancelled the focus session" : "Finished the focus session"
        )
    }
}
