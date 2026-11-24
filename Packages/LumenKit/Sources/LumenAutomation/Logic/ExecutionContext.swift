import Foundation
import LumenFoundation
import LumenCore

/// The JSON tree templates, references and conditions read during a run:
///
/// ```
/// { "trigger": { "name", "entity": { "kind", "id" }, "attributes", "occurredAt", … },
///   "input":   <manual input>,
///   "steps":   { "<node id>": { "output": …, "status": "succeeded", "error": … } },
///   "run":     { "id", "workflowID", "startedAt" } }
/// ```
///
/// Node ids are the uppercase `uuidString` of the node identifier. Instants are ISO 8601 strings,
/// so they compare correctly as text.
public struct ExecutionContext: Sendable, Hashable {
    public private(set) var value: JSONValue

    public init(
        trigger: JSONValue,
        input: JSONValue = .null,
        runID: WorkflowRun.ID? = nil,
        workflowID: Workflow.ID? = nil,
        startedAt: Date? = nil
    ) {
        var run: [String: JSONValue] = [:]
        if let runID { run["id"] = .string(runID.uuidString) }
        if let workflowID { run["workflowID"] = .string(workflowID.uuidString) }
        if let startedAt { run["startedAt"] = .string(Self.timestamp(startedAt)) }
        self.value = .object([
            "trigger": trigger,
            "input": input,
            "steps": .object([:]),
            "run": .object(run),
        ])
    }

    /// The context of `run` after the given steps (in execution order; later steps of the same node win).
    public init(run: WorkflowRun, steps: [RunStep] = []) {
        self.init(trigger: run.triggerPayload, input: run.input, runID: run.id, workflowID: run.workflowID, startedAt: run.startedAt)
        for step in steps {
            record(step)
        }
    }

    /// Makes a step's result visible to later steps as `steps.<node id>`.
    public mutating func record(nodeID: WorkflowNode.ID, status: RunStep.Status, output: JSONValue?, errorMessage: String?) {
        guard case .object(var root) = value else { return }
        var steps = root["steps"]?.objectValue ?? [:]
        var entry: [String: JSONValue] = [
            "output": output ?? .null,
            "status": .string(status.rawValue),
        ]
        if let errorMessage { entry["error"] = .string(errorMessage) }
        steps[nodeID.uuidString] = .object(entry)
        root["steps"] = .object(steps)
        value = .object(root)
    }

    public mutating func record(_ step: RunStep) {
        record(nodeID: step.nodeID, status: step.status, output: step.output, errorMessage: step.errorMessage)
    }

    /// ISO 8601 in UTC (`2026-11-21T09:00:00Z`): deterministic and lexically ordered.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}

/// Builds the `trigger` part of the run context for each kind of trigger.
public enum TriggerPayload {
    /// The payload for a domain event.
    public static func event(_ event: DomainEvent) -> JSONValue {
        var payload: [String: JSONValue] = [
            "type": "event",
            "name": .string(event.name.rawValue),
            "eventID": .string(event.id.uuidString),
            "attributes": .object(event.attributes),
            "actor": .string(event.actor.rawValue),
            "occurredAt": .string(ExecutionContext.timestamp(event.occurredAt)),
            "causationDepth": .number(Double(event.causationDepth)),
        ]
        payload["entity"] = event.entity.map { entity in
            .object(["kind": .string(entity.kind.rawValue), "id": .string(entity.id.uuidString)])
        } ?? .null
        if let correlationID = event.correlationID {
            payload["correlationID"] = .string(correlationID.uuidString)
        }
        return .object(payload)
    }

    /// The payload for a run started by hand.
    public static func manual(at date: Date, actor: EventActor) -> JSONValue {
        .object([
            "type": "manual",
            "name": "manual",
            "entity": .null,
            "attributes": .object([:]),
            "actor": .string(actor.rawValue),
            "occurredAt": .string(ExecutionContext.timestamp(date)),
        ])
    }

    /// The payload for a schedule firing. `coalescedOccurrences` counts the occurrences this one
    /// run stands for (more than 1 after the device was asleep or the app closed).
    public static func schedule(scheduledFor: Date, firedAt: Date, coalescedOccurrences: Int) -> JSONValue {
        .object([
            "type": "schedule",
            "name": "schedule",
            "entity": .null,
            "attributes": .object([
                "scheduledFor": .string(ExecutionContext.timestamp(scheduledFor)),
                "coalescedOccurrences": .number(Double(coalescedOccurrences)),
            ]),
            "actor": .string(EventActor.system.rawValue),
            "occurredAt": .string(ExecutionContext.timestamp(firedAt)),
        ])
    }
}
