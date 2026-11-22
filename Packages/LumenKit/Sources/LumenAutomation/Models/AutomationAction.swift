import Foundation
import LumenFoundation
import LumenCore

/// Identifier of a catalog action, namespaced by its provider: `automation.formatText`,
/// `organization.createTask`. Persisted in workflow graphs, so it never changes once shipped.
public struct AutomationActionID: RawRepresentable, Hashable, Sendable, Codable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static func < (lhs: AutomationActionID, rhs: AutomationActionID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }
}

/// Describes one input of an action so the editor can render a field and the validator can check it.
public struct ActionParameterSpec: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable {
        case text
        case multilineText
        case number
        case boolean
        /// One of the given option values.
        case choice([String])
        /// An entity identifier (`UUID` or `kind:UUID`), optionally restricted to one kind.
        case entity(EntityKind?)
        /// A calendar day (`YYYY-MM-DD`) or an ISO 8601 instant.
        case date
    }

    public var name: String
    public var title: String
    public var kind: Kind
    public var isRequired: Bool
    /// Used when the node does not set the parameter.
    public var defaultValue: JSONValue?

    public init(name: String, title: String, kind: Kind = .text, isRequired: Bool = false, defaultValue: JSONValue? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.defaultValue = defaultValue
    }
}

extension ActionParameterSpec.Kind: Codable {
    enum CodingKeys: String, CodingKey {
        case type, options, entityKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text
        case "multilineText": self = .multilineText
        case "number": self = .number
        case "boolean": self = .boolean
        case "choice": self = .choice(try container.decode([String].self, forKey: .options))
        case "entity": self = .entity(try container.decodeIfPresent(EntityKind.self, forKey: .entityKind))
        case "date": self = .date
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown parameter kind '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text: try container.encode("text", forKey: .type)
        case .multilineText: try container.encode("multilineText", forKey: .type)
        case .number: try container.encode("number", forKey: .type)
        case .boolean: try container.encode("boolean", forKey: .type)
        case .choice(let options):
            try container.encode("choice", forKey: .type)
            try container.encode(options, forKey: .options)
        case .entity(let kind):
            try container.encode("entity", forKey: .type)
            try container.encodeIfPresent(kind, forKey: .entityKind)
        case .date: try container.encode("date", forKey: .type)
        }
    }
}

/// What the editor and the validator know about an action.
public struct AutomationActionDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: AutomationActionID
    public var title: String
    public var summary: String
    /// SF Symbol name for the node.
    public var symbolName: String
    /// Groups actions in the picker ("Text", "Flow", "Tasks").
    public var category: String
    public var parameters: [ActionParameterSpec]
    /// Whether the action changes user data. Mutating actions may run twice when an interrupted
    /// run is resumed, so the editor can warn about it.
    public var isMutating: Bool

    public init(
        id: AutomationActionID,
        title: String,
        summary: String,
        symbolName: String,
        category: String,
        parameters: [ActionParameterSpec] = [],
        isMutating: Bool
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.category = category
        self.parameters = parameters
        self.isMutating = isMutating
    }

    public func parameter(named name: String) -> ActionParameterSpec? {
        parameters.first { $0.name == name }
    }
}

/// One execution request for an action.
public struct ActionInvocation: Sendable {
    /// Parameters after defaults, templates and references were resolved.
    public let parameters: [String: JSONValue]
    /// Pass this to the services the action calls, so the events they publish carry actor
    /// `.automation`, this run's correlation and an incremented causation depth.
    public let context: ActionContext
    public let runID: WorkflowRun.ID
    public let workflowID: Workflow.ID
    public let nodeID: WorkflowNode.ID
    /// 1-based attempt number; greater than 1 when the step is being retried.
    public let attempt: Int

    public init(
        parameters: [String: JSONValue],
        context: ActionContext,
        runID: WorkflowRun.ID,
        workflowID: Workflow.ID,
        nodeID: WorkflowNode.ID,
        attempt: Int
    ) {
        self.parameters = parameters
        self.context = context
        self.runID = runID
        self.workflowID = workflowID
        self.nodeID = nodeID
        self.attempt = attempt
    }

    public func string(_ name: String) -> String? {
        parameters[name]?.stringValue
    }

    public func number(_ name: String) -> Double? {
        parameters[name]?.doubleValue
    }

    public func bool(_ name: String) -> Bool? {
        parameters[name]?.boolValue
    }
}

/// The result of a successful action.
public struct ActionOutcome: Sendable, Hashable {
    public enum Flow: Sendable, Hashable {
        /// Continue with the step's successor.
        case proceed
        /// End the run successfully after this step.
        case finishRun
    }

    /// Available to later steps as `steps.<node id>.output`.
    public var output: JSONValue
    /// A short, user-facing summary of what happened, shown in run history.
    public var message: String?
    public var flow: Flow

    public init(output: JSONValue = .null, message: String? = nil, flow: Flow = .proceed) {
        self.output = output
        self.message = message
        self.flow = flow
    }
}

/// Errors actions throw to steer retries. Any other error is treated as transient.
public enum AutomationActionError: Error, Sendable, Hashable, PresentableError, CustomStringConvertible {
    /// Retrying cannot help (invalid input, missing entity, permission denied).
    case permanent(String)
    /// Retrying may help (network unavailable, rate limited, resource busy).
    case transient(String)

    public var message: String {
        switch self {
        case .permanent(let message), .transient(let message): return message
        }
    }

    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }

    public var description: String { message }

    public var presentation: ErrorPresentation {
        ErrorPresentation(title: "Automation step failed", message: message, isRetryable: isRetryable)
    }
}

/// An action that workflows can run. Built-in features and plugins provide implementations through
/// the application layer; the engine only knows this protocol.
public protocol AutomationAction: Sendable {
    var descriptor: AutomationActionDescriptor { get }
    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome
}
