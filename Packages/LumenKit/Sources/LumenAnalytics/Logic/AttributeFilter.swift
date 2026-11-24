import Foundation
import LumenFoundation

/// Reduces event attributes to what analytics is allowed to keep.
///
/// Rules, applied in order:
/// 1. Only scalars survive: booleans, finite numbers and strings of at most
///    `maximumStringLength` characters. `null`, arrays, objects, non-finite numbers and longer
///    strings are dropped.
/// 2. Keys must be non-empty and at most `maximumKeyLength` characters.
/// 3. At most `maximumKeys` entries are kept: the first ones in ascending key order, so the
///    result does not depend on dictionary ordering.
public enum AttributeFilter {
    public static let maximumKeys = 8
    public static let maximumStringLength = 128
    public static let maximumKeyLength = 128

    public static func filter(_ attributes: [String: JSONValue]) -> [String: JSONValue] {
        let kept = attributes
            .filter { key, value in isAllowedKey(key) && isAllowedValue(value) }
            .sorted { $0.key < $1.key }
            .prefix(maximumKeys)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    public static func isAllowedValue(_ value: JSONValue) -> Bool {
        switch value {
        case .bool:
            return true
        case .number(let number):
            return number.isFinite
        case .string(let text):
            return text.count <= maximumStringLength
        case .null, .array, .object:
            return false
        }
    }

    static func isAllowedKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= maximumKeyLength
    }
}
