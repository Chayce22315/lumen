import Foundation
import LumenFoundation
import LumenCore

/// Decides whether a domain event starts a workflow. Pure: loop protection, which needs run
/// history, is applied by the engine on top of this.
public enum TriggerMatcher {
    /// Why an event did or did not start a workflow.
    public enum Decision: Sendable, Hashable {
        case matches
        case notAnEventTrigger
        case differentEvent
        case conditionFailed
        /// The event is too many automation hops deep.
        case causationLimit
    }

    public static func decide(_ trigger: TriggerDefinition, for event: DomainEvent, maxCausationDepth: Int) -> Decision {
        guard case .event(let name, let condition) = trigger else { return .notAnEventTrigger }
        guard name == event.name else { return .differentEvent }
        guard event.causationDepth < maxCausationDepth else { return .causationLimit }
        guard let condition else { return .matches }
        return conditionHolds(condition, payload: TriggerPayload.event(event)) ? .matches : .conditionFailed
    }

    /// Evaluates a trigger condition against a trigger payload, exposed as `trigger.*`.
    public static func conditionHolds(_ condition: Condition, payload: JSONValue) -> Bool {
        ConditionEvaluator.evaluate(condition, in: ExecutionContext(trigger: payload).value)
    }
}
