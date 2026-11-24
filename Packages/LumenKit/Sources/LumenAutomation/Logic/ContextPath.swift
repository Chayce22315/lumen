import Foundation
import LumenFoundation

/// A dotted path into the run context: `trigger.attributes.priority`, `steps.<node id>.output.id`,
/// `input.items.0`.
///
/// A component selects an object key, or an array element when the current value is an array and
/// the component is a non-negative decimal integer. Keys containing dots cannot be addressed.
public struct ContextPath: Sendable, Hashable, CustomStringConvertible {
    public let components: [String]

    /// Parses a path. Surrounding whitespace is ignored; an empty path or an empty component
    /// (`a..b`, `.a`, `a.`) is invalid.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.components = parts.map(String.init)
    }

    /// A path from explicit components; `nil` when empty or when a component is empty or contains a dot.
    public init?(components: [String]) {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && !$0.contains(".") }) else { return nil }
        self.components = components
    }

    public var description: String {
        components.joined(separator: ".")
    }

    /// The value at this path, or `nil` when any component is missing.
    public func resolve(in root: JSONValue) -> JSONValue? {
        var current = root
        for component in components {
            switch current {
            case .object(let object):
                guard let next = object[component] else { return nil }
                current = next
            case .array(let array):
                guard let index = Self.index(component), array.indices.contains(index) else { return nil }
                current = array[index]
            case .null, .bool, .number, .string:
                return nil
            }
        }
        return current
    }

    /// Parses and resolves in one step; `nil` for invalid or missing paths.
    public static func resolve(_ path: String, in root: JSONValue) -> JSONValue? {
        ContextPath(path)?.resolve(in: root)
    }

    private static func index(_ component: String) -> Int? {
        guard component.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return Int(component)
    }
}
