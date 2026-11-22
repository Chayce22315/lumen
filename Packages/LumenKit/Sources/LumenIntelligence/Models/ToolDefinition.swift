import Foundation
import LumenFoundation

/// A tool as the model sees it: a name, what it does and a JSON Schema for its input.
public struct ToolDefinition: Sendable, Hashable, Codable {
    /// `^[a-zA-Z0-9_-]{1,64}$`, unique within a request.
    public var name: String
    public var description: String
    /// JSON Schema (an `object` schema) describing the input.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Whether `name` is acceptable to every supported provider.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }
}

/// Whether the model may call tools in a request.
public enum ToolChoice: String, Sendable, Hashable, Codable {
    /// The model decides.
    case auto
    /// The model must answer in text (tools stay declared because the history references them).
    case none
}
