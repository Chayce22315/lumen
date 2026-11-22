import Foundation
import LumenFoundation

/// One side of a comparison.
public enum ValueExpression: Sendable, Hashable {
    case literal(JSONValue)
    /// A context path such as `trigger.attributes.priority` or `steps.<node id>.output.count`.
    case path(String)
}

public enum ComparisonOperator: String, Sendable, Hashable, Codable, CaseIterable {
    case equals
    case notEquals
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    /// Substring of a string (case- and diacritic-insensitive), element of an array, or key of an object.
    case contains
    /// String prefix (case- and diacritic-insensitive).
    case hasPrefix
    /// String suffix (case- and diacritic-insensitive).
    case hasSuffix
    /// Unary: missing, null, blank string, empty array or empty object.
    case isEmpty
    /// Unary: the negation of `isEmpty`.
    case isNotEmpty

    /// Unary operators ignore their right-hand side.
    public var isUnary: Bool {
        self == .isEmpty || self == .isNotEmpty
    }

    public var title: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .lessThan: return "is less than"
        case .lessThanOrEqual: return "is at most"
        case .greaterThan: return "is greater than"
        case .greaterThanOrEqual: return "is at least"
        case .contains: return "contains"
        case .hasPrefix: return "starts with"
        case .hasSuffix: return "ends with"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }
}

/// A boolean expression over the run context, used by condition nodes and event-trigger filters.
public indirect enum Condition: Sendable, Hashable {
    case always
    case compare(ValueExpression, ComparisonOperator, ValueExpression)
    /// True when every condition holds; true for an empty list.
    case all([Condition])
    /// True when at least one condition holds; false for an empty list.
    case any([Condition])
    case not(Condition)
    /// True when the path resolves to a value other than `null`.
    case exists(String)

    /// Compares the value at `path` with a literal.
    public static func compare(_ path: String, _ comparison: ComparisonOperator, _ value: JSONValue = .null) -> Condition {
        .compare(.path(path), comparison, .literal(value))
    }

    /// Every context path the condition reads, in order of appearance.
    public var referencedPaths: [String] {
        switch self {
        case .always: return []
        case .compare(let lhs, let comparison, let rhs):
            var paths: [String] = []
            if case .path(let path) = lhs { paths.append(path) }
            if !comparison.isUnary, case .path(let path) = rhs { paths.append(path) }
            return paths
        case .all(let conditions), .any(let conditions):
            return conditions.flatMap(\.referencedPaths)
        case .not(let condition):
            return condition.referencedPaths
        case .exists(let path):
            return [path]
        }
    }

    /// A compact description for the canvas: `trigger.attributes.priority is greater than 2`.
    public var summary: String {
        switch self {
        case .always: return "Always"
        case .compare(let lhs, let comparison, let rhs):
            if comparison.isUnary { return "\(Self.describe(lhs)) \(comparison.title)" }
            return "\(Self.describe(lhs)) \(comparison.title) \(Self.describe(rhs))"
        case .all(let conditions):
            return conditions.isEmpty ? "Always" : conditions.map(\.summary).joined(separator: " and ")
        case .any(let conditions):
            return conditions.isEmpty ? "Never" : conditions.map(\.summary).joined(separator: " or ")
        case .not(let condition):
            return "not (\(condition.summary))"
        case .exists(let path):
            return "\(path) exists"
        }
    }

    private static func describe(_ expression: ValueExpression) -> String {
        switch expression {
        case .path(let path): return path
        case .literal(.string(let text)): return "“\(text)”"
        case .literal(let value): return value.displayString.isEmpty ? "null" : value.displayString
        }
    }
}

// MARK: - Codable

extension ValueExpression: Codable {
    enum CodingKeys: String, CodingKey {
        case type, value, path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "literal": self = .literal(try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null)
        case "path": self = .path(try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value expression '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value):
            try container.encode("literal", forKey: .type)
            try container.encode(value, forKey: .value)
        case .path(let path):
            try container.encode("path", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

extension Condition: Codable {
    enum CodingKeys: String, CodingKey {
        case type, left, comparison = "operator", right, conditions, condition, path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "always":
            self = .always
        case "compare":
            self = .compare(
                try container.decode(ValueExpression.self, forKey: .left),
                try container.decode(ComparisonOperator.self, forKey: .comparison),
                try container.decodeIfPresent(ValueExpression.self, forKey: .right) ?? .literal(.null)
            )
        case "all":
            self = .all(try container.decode([Condition].self, forKey: .conditions))
        case "any":
            self = .any(try container.decode([Condition].self, forKey: .conditions))
        case "not":
            self = .not(try container.decode(Condition.self, forKey: .condition))
        case "exists":
            self = .exists(try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown condition '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try container.encode("always", forKey: .type)
        case .compare(let lhs, let comparison, let rhs):
            try container.encode("compare", forKey: .type)
            try container.encode(lhs, forKey: .left)
            try container.encode(comparison, forKey: .comparison)
            try container.encode(rhs, forKey: .right)
        case .all(let conditions):
            try container.encode("all", forKey: .type)
            try container.encode(conditions, forKey: .conditions)
        case .any(let conditions):
            try container.encode("any", forKey: .type)
            try container.encode(conditions, forKey: .conditions)
        case .not(let condition):
            try container.encode("not", forKey: .type)
            try container.encode(condition, forKey: .condition)
        case .exists(let path):
            try container.encode("exists", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}
