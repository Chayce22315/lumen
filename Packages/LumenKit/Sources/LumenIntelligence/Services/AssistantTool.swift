import Foundation
import LumenFoundation
import LumenCore

/// What a tool knows about the call it is serving.
public struct ToolContext: Sendable, Hashable {
    public let conversationID: Conversation.ID
    /// Actor `.assistant`, correlated with the conversation turn: pass it to the services the
    /// tool calls so their events are attributed to this assistant turn.
    public let action: ActionContext
    public let turnID: UUID

    public init(conversationID: Conversation.ID, action: ActionContext, turnID: UUID) {
        self.conversationID = conversationID
        self.action = action
        self.turnID = turnID
    }
}

/// What a tool returns to the model.
public struct ToolOutput: Sendable, Hashable {
    /// Sent to the model as the tool result. Keep it short and factual.
    public var text: String
    /// Entities the tool created, changed or found (for the interface to link to).
    public var referencedEntities: [EntityReference]
    /// The call failed in a way the model should know about (it can retry or explain).
    public var isError: Bool

    public init(text: String, referencedEntities: [EntityReference] = [], isError: Bool = false) {
        self.text = text
        self.referencedEntities = referencedEntities
        self.isError = isError
    }

    public static func error(_ text: String) -> ToolOutput {
        ToolOutput(text: text, isError: true)
    }
}

/// A capability the assistant can call. The application layer adapts each engine (create a task,
/// search notes, run an automation) to this protocol; the intelligence engine only sees tools.
public protocol AssistantTool: Sendable {
    var definition: ToolDefinition { get }
    /// Tools that change the user's data require approval while
    /// `AssistantSettings.requireApprovalForMutatingTools` is on.
    var isMutating: Bool { get }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput
}

/// Asks the user whether a mutating tool may run (the interface shows the tool and its input).
public protocol ToolApprovalHandler: Sendable {
    func approve(tool: ToolDefinition, input: JSONValue) async -> Bool
}

/// Supplies a short, current summary of the user's workspace for the system prompt
/// ("3 tasks due today; next event 14:00 Design review").
public protocol AssistantContextProvider: Sendable {
    func contextSummary() async -> String?
}
