import Foundation
import LumenFoundation

/// Evaluates `Condition`s against a run context.
///
/// Comparisons are type-sensible and total: numbers compare numerically, strings lexically (so ISO
/// 8601 dates order correctly), and any other pairing — mismatched types, arrays, objects, missing
/// values — makes an ordering comparison false instead of failing. A missing path behaves like `null`.
public enum ConditionEvaluator {
    public static func evaluate(_ condition: Condition, in context: JSONValue) -> Bool {
        switch condition {
        case .always:
            return true
        case .all(let conditions):
            return conditions.allSatisfy { evaluate($0, in: context) }
        case .any(let conditions):
            return conditions.contains { evaluate($0, in: context) }
        case .not(let condition):
            return !evaluate(condition, in: context)
        case .exists(let path):
            guard let value = ContextPath.resolve(path, in: context) else { return false }
            return !value.isNull
        case .compare(let lhs, let comparison, let rhs):
            return compare(value(of: lhs, in: context), comparison, value(of: rhs, in: context))
        }
    }

    /// The value an expression denotes; `nil` for a missing or invalid path.
    public static func value(of expression: ValueExpression, in context: JSONValue) -> JSONValue? {
        switch expression {
        case .literal(let value): return value
        case .path(let path): return ContextPath.resolve(path, in: context)
        }
    }

    public static func compare(_ lhs: JSONValue?, _ comparison: ComparisonOperator, _ rhs: JSONValue?) -> Bool {
        let left = lhs ?? .null
        let right = rhs ?? .null
        switch comparison {
        case .equals: return left == right
        case .notEquals: return left != right
        case .lessThan: return order(left, right) == .orderedAscending
        case .lessThanOrEqual: return order(left, right).map { $0 != .orderedDescending } ?? false
        case .greaterThan: return order(left, right) == .orderedDescending
        case .greaterThanOrEqual: return order(left, right).map { $0 != .orderedAscending } ?? false
        case .contains: return contains(left, right)
        case .hasPrefix:
            guard case .string(let text) = left, case .string(let prefix) = right else { return false }
            return text.foldedForMatching.hasPrefix(prefix.foldedForMatching)
        case .hasSuffix:
            guard case .string(let text) = left, case .string(let suffix) = right else { return false }
            return text.foldedForMatching.hasSuffix(suffix.foldedForMatching)
        case .isEmpty: return isEmpty(left)
        case .isNotEmpty: return !isEmpty(left)
        }
    }

    /// Ordering of two comparable values; `nil` when they cannot be ordered.
    static func order(_ lhs: JSONValue, _ rhs: JSONValue) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            if a == b { return .orderedSame }
            return nil // NaN
        case (.string(let a), .string(let b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        default:
            return nil
        }
    }

    static func contains(_ container: JSONValue, _ element: JSONValue) -> Bool {
        switch (container, element) {
        case (.string(let text), .string(let needle)):
            let folded = needle.foldedForMatching
            guard !folded.isEmpty else { return true }
            return text.foldedForMatching.range(of: folded) != nil
        case (.array(let values), _):
            return values.contains(element)
        case (.object(let object), .string(let key)):
            return object[key] != nil
        default:
            return false
        }
    }

    static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let values): return values.isEmpty
        case .object(let object): return object.isEmpty
        case .bool, .number: return false
        }
    }
}
