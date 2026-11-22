import Foundation
import Synchronization
import LumenFoundation

public enum ToolRegistryError: PresentableError, Hashable {
    case invalidName(String)
    case duplicateName(String)
    case reservedName(String)

    public var presentation: ErrorPresentation {
        switch self {
        case .invalidName(let name):
            return ErrorPresentation(title: "Invalid tool", message: "“\(name)” is not a valid tool name (letters, digits, _ and -, at most 64).")
        case .duplicateName(let name):
            return ErrorPresentation(title: "Duplicate tool", message: "A tool named “\(name)” is already registered.")
        case .reservedName(let name):
            return ErrorPresentation(title: "Reserved tool name", message: "“\(name)” is reserved for a built-in assistant tool.")
        }
    }
}

/// Tools the application makes available to the assistant.
public final class ToolRegistry: Sendable {
    /// Names used by the engine's built-in tools.
    public static let reservedNames: Set<String> = [RememberTool.name, ForgetTool.name]

    private let tools = Mutex<[String: any AssistantTool]>([:])

    public init() {}

    public func register(_ tool: any AssistantTool) throws {
        let name = tool.definition.name
        guard ToolDefinition.isValidName(name) else { throw ToolRegistryError.invalidName(name) }
        guard !Self.reservedNames.contains(name) else { throw ToolRegistryError.reservedName(name) }
        try tools.withLock { tools in
            guard tools[name] == nil else { throw ToolRegistryError.duplicateName(name) }
            tools[name] = tool
        }
    }

    public func unregister(named name: String) {
        _ = tools.withLock { $0.removeValue(forKey: name) }
    }

    public func tool(named name: String) -> (any AssistantTool)? {
        tools.withLock { $0[name] }
    }

    /// Every registered tool, sorted by name so requests (and provider prompt caches) are stable.
    public var all: [any AssistantTool] {
        tools.withLock { tools in tools.keys.sorted().compactMap { tools[$0] } }
    }

    public var definitions: [ToolDefinition] {
        all.map(\.definition)
    }
}
