import Foundation
import LumenFoundation

/// Built-in tool: saves a fact to memory. Offered only while memory is enabled.
///
/// Not treated as mutating for approval purposes: it only writes the assistant's own memory,
/// which the user reviews and edits in settings, and it is used when the user asks.
public struct RememberTool: AssistantTool {
    public static let name = "remember"

    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public var isMutating: Bool { false }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Save a short, lasting fact or preference about the user so it can be used in future conversations. Use it only when the user asks you to remember something or clearly states a lasting preference. Write the fact as one self-contained sentence.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "The fact to remember, as one sentence.", "maxLength": .number(Double(MemoryStore.maximumLength))],
                ],
                "required": ["content"],
                "additionalProperties": false,
            ]
        )
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard await store.isMemoryEnabled() else {
            return .error("Memory is turned off, so nothing was saved. The user can turn it on in Settings › Assistant.")
        }
        guard let content = input["content"]?.stringValue else {
            return .error("Provide the fact to remember in `content`.")
        }
        let memory = try await store.add(content, source: .assistant, context: context.action)
        return ToolOutput(text: "Saved to memory.", referencedEntities: [memory.reference])
    }
}

/// Built-in tool: deletes the memory matching a description. Offered only while memory is
/// enabled; mutating, so it asks for approval when approvals are on.
public struct ForgetTool: AssistantTool {
    public static let name = "forget"

    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public var isMutating: Bool { true }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Delete a saved memory when the user asks you to forget something. Pass a distinctive part of the memory's text; exactly one memory must match.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "match": ["type": "string", "description": "Text that appears in the memory to delete.", "minLength": 1],
                ],
                "required": ["match"],
                "additionalProperties": false,
            ]
        )
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard await store.isMemoryEnabled() else {
            return .error("Memory is turned off.")
        }
        guard let query = input["match"]?.stringValue?.nonBlank?.foldedForMatching else {
            return .error("Provide text from the memory to delete in `match`.")
        }
        let matches = try await store.memories().filter { $0.content.foldedForMatching.contains(query) }
        switch matches.count {
        case 0:
            return .error("No saved memory matches that text.")
        case 1:
            try await store.delete(matches[0].id, context: context.action)
            return ToolOutput(text: "Deleted the memory.")
        default:
            return .error("\(matches.count) memories match that text; use a more specific part of the one to delete.")
        }
    }
}
