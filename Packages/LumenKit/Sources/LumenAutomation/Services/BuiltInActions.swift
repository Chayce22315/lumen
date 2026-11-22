import Foundation
import LumenFoundation
import LumenCore

/// Actions the engine provides itself. They only transform run data; anything that touches tasks,
/// notes or notifications is provided by the application layer.
public enum BuiltInActions {
    public static var all: [any AutomationAction] {
        [FormatTextAction(), SetVariableAction(), StopRunAction()]
    }
}

/// Renders text — usually a template combining earlier outputs — into `{ text, length }`.
public struct FormatTextAction: AutomationAction {
    public static let id: AutomationActionID = "automation.formatText"
    public static let caseOptions = ["none", "uppercase", "lowercase", "capitalized"]

    public init() {}

    public var descriptor: AutomationActionDescriptor {
        AutomationActionDescriptor(
            id: Self.id,
            title: "Format Text",
            summary: "Combines text and values from earlier steps into one piece of text.",
            symbolName: "textformat",
            category: "Text",
            parameters: [
                ActionParameterSpec(name: "text", title: "Text", kind: .multilineText, isRequired: true),
                ActionParameterSpec(name: "case", title: "Change Case", kind: .choice(Self.caseOptions), defaultValue: "none"),
                ActionParameterSpec(name: "trimWhitespace", title: "Trim Whitespace", kind: .boolean, defaultValue: true),
            ],
            isMutating: false
        )
    }

    public func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let value = invocation.parameters["text"] else {
            throw AutomationActionError.permanent("Format Text needs text.")
        }
        var text = value.displayString
        switch invocation.string("case") ?? "none" {
        case "none": break
        case "uppercase": text = text.uppercased()
        case "lowercase": text = text.lowercased()
        case "capitalized": text = text.capitalized
        case let other: throw AutomationActionError.permanent("“\(other)” is not a case option.")
        }
        if invocation.bool("trimWhitespace") ?? true {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ActionOutcome(
            output: ["text": .string(text), "length": .number(Double(text.count))],
            message: "Formatted \(text.count) characters"
        )
    }
}

/// Outputs a value (a literal, rendered template or structured reference) for later steps to read
/// as `steps.<node id>.output`.
public struct SetVariableAction: AutomationAction {
    public static let id: AutomationActionID = "automation.setVariable"

    public init() {}

    public var descriptor: AutomationActionDescriptor {
        AutomationActionDescriptor(
            id: Self.id,
            title: "Set Variable",
            summary: "Keeps a value so later steps can use it.",
            symbolName: "curlybraces",
            category: "Flow",
            parameters: [ActionParameterSpec(name: "value", title: "Value", kind: .text, isRequired: true)],
            isMutating: false
        )
    }

    public func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let value = invocation.parameters["value"] else {
            throw AutomationActionError.permanent("Set Variable needs a value.")
        }
        return ActionOutcome(output: value, message: "Value set")
    }
}

/// Ends the run successfully, skipping the remaining steps.
public struct StopRunAction: AutomationAction {
    public static let id: AutomationActionID = "automation.stopRun"

    public init() {}

    public var descriptor: AutomationActionDescriptor {
        AutomationActionDescriptor(
            id: Self.id,
            title: "Stop Workflow",
            summary: "Ends this run successfully without running the remaining steps.",
            symbolName: "stop.circle",
            category: "Flow",
            parameters: [ActionParameterSpec(name: "reason", title: "Reason", kind: .text)],
            isMutating: false
        )
    }

    public func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        let reason = invocation.parameters["reason"]?.displayString.nonBlank
        return ActionOutcome(
            output: reason.map { ["reason": .string($0)] } ?? .null,
            message: reason ?? "Run stopped",
            flow: .finishRun
        )
    }
}

/// Triggers for the engine's own run outcomes ("when a workflow fails, notify me").
public struct BuiltInAutomationTriggers: AutomationTriggerSource {
    public init() {}

    public var triggers: [AutomationTriggerDescriptor] {
        let attributes = [
            TriggerAttributeSpec(name: "workflowID", title: "Workflow", valueType: .identifier),
            TriggerAttributeSpec(name: "runID", title: "Run", valueType: .identifier),
            TriggerAttributeSpec(name: "status", title: "Status", valueType: .string),
            TriggerAttributeSpec(name: "steps", title: "Steps", valueType: .number),
            TriggerAttributeSpec(name: "failedSteps", title: "Failed Steps", valueType: .number),
        ]
        return [
            AutomationTriggerDescriptor(
                eventName: AutomationEvents.runSucceeded,
                title: "Workflow Succeeded",
                summary: "When a workflow run finishes successfully.",
                symbolName: "checkmark.circle",
                category: "Automation",
                attributes: attributes
            ),
            AutomationTriggerDescriptor(
                eventName: AutomationEvents.runFailed,
                title: "Workflow Failed",
                summary: "When a workflow run fails or is interrupted.",
                symbolName: "exclamationmark.triangle",
                category: "Automation",
                attributes: attributes
            ),
        ]
    }
}
