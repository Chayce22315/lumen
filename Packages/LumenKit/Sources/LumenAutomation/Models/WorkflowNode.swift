import Foundation
import LumenFoundation

/// One step of a workflow, placed on the canvas.
public struct WorkflowNode: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<WorkflowNode>

    public enum Kind: Sendable, Hashable {
        /// The entry point. Its step output is the trigger payload.
        case trigger
        /// Runs a catalog action with parameters resolved against the run context.
        case action(actionID: AutomationActionID, parameters: [String: ParameterValue])
        /// Branches on `.whenTrue` / `.whenFalse`.
        case condition(Condition)
        /// Waits. Short delays sleep inline; long ones park the run until `tick` resumes it.
        case delay(seconds: TimeInterval)
        /// Ends the run successfully.
        case end
    }

    public let id: ID
    public var title: String
    public var position: CanvasPoint
    public var kind: Kind

    public init(id: ID = ID(), title: String, position: CanvasPoint = .zero, kind: Kind) {
        self.id = id
        self.title = title
        self.position = position
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, title, position, kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ID.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.position = try container.decodeIfPresent(CanvasPoint.self, forKey: .position) ?? .zero
        self.kind = try container.decode(Kind.self, forKey: .kind)
    }
}

extension WorkflowNode.Kind {
    /// Stable discriminator used in the persisted form.
    public var typeName: String {
        switch self {
        case .trigger: return "trigger"
        case .action: return "action"
        case .condition: return "condition"
        case .delay: return "delay"
        case .end: return "end"
        }
    }

    /// The output ports a node of this kind may use.
    public var outputPorts: [EdgePort] {
        switch self {
        case .trigger, .action, .delay: return [.next]
        case .condition: return [.whenTrue, .whenFalse]
        case .end: return []
        }
    }

    /// The port a newly inserted node continues on toward the node it was inserted before.
    public var continuationPort: EdgePort? {
        switch self {
        case .trigger, .action, .delay: return .next
        case .condition: return .whenTrue
        case .end: return nil
        }
    }

    public var isTrigger: Bool {
        if case .trigger = self { return true }
        return false
    }
}

extension WorkflowNode.Kind: Codable {
    enum CodingKeys: String, CodingKey {
        case type, actionID, parameters, condition, seconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "trigger":
            self = .trigger
        case "action":
            self = .action(
                actionID: try container.decode(AutomationActionID.self, forKey: .actionID),
                parameters: try container.decodeIfPresent([String: ParameterValue].self, forKey: .parameters) ?? [:]
            )
        case "condition":
            self = .condition(try container.decode(Condition.self, forKey: .condition))
        case "delay":
            self = .delay(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
        case "end":
            self = .end
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown node type '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .trigger, .end:
            break
        case .action(let actionID, let parameters):
            try container.encode(actionID, forKey: .actionID)
            try container.encode(parameters, forKey: .parameters)
        case .condition(let condition):
            try container.encode(condition, forKey: .condition)
        case .delay(let seconds):
            try container.encode(seconds, forKey: .seconds)
        }
    }
}
