import Foundation
import LumenFoundation

/// Checks tool input against the tool's JSON Schema before the tool runs.
///
/// Streamed tool inputs are not validated by every provider (Anthropic's eager input streaming
/// hands the client whatever the model produced), so the engine validates. Supported keywords:
/// `type` (string or list), `properties`, `required`, `additionalProperties: false`, `enum`,
/// `items`, `minLength`/`maxLength`, `minimum`/`maximum`. Other keywords are ignored, so a schema
/// using them is checked less strictly, never rejected.
public enum ToolInputValidator {
    /// Problems found, empty when the input is acceptable.
    public static func validate(_ input: JSONValue, against schema: JSONValue) -> [String] {
        var problems: [String] = []
        check(input, schema: schema, path: "input", problems: &problems)
        return problems
    }

    private static func check(_ value: JSONValue, schema: JSONValue, path: String, problems: inout [String]) {
        guard case .object = schema else { return }

        if let types = allowedTypes(schema), !types.contains(where: { matches(value, type: $0) }) {
            problems.append("\(path) must be \(types.joined(separator: " or ")).")
            return
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            let rendered = options.map { $0.compactText }.joined(separator: ", ")
            problems.append("\(path) must be one of \(rendered).")
        }

        switch value {
        case .object(let object):
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                problems.append("\(path).\(name) is required.")
            }
            if schema["additionalProperties"]?.boolValue == false {
                for name in object.keys.sorted() where properties[name] == nil {
                    problems.append("\(path).\(name) is not an accepted property.")
                }
            }
            for (name, propertySchema) in properties.sorted(by: { $0.key < $1.key }) {
                if let propertyValue = object[name] {
                    check(propertyValue, schema: propertySchema, path: "\(path).\(name)", problems: &problems)
                }
            }
        case .array(let items):
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    check(item, schema: itemSchema, path: "\(path)[\(index)]", problems: &problems)
                }
            }
        case .string(let text):
            if let minimum = schema["minLength"]?.intValue, text.count < minimum {
                problems.append("\(path) must be at least \(minimum) characters.")
            }
            if let maximum = schema["maxLength"]?.intValue, text.count > maximum {
                problems.append("\(path) must be at most \(maximum) characters.")
            }
        case .number(let number):
            if let minimum = schema["minimum"]?.doubleValue, number < minimum {
                problems.append("\(path) must be at least \(JSONValue.number(minimum).displayString).")
            }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum {
                problems.append("\(path) must be at most \(JSONValue.number(maximum).displayString).")
            }
        case .null, .bool:
            break
        }
    }

    private static func allowedTypes(_ schema: JSONValue) -> [String]? {
        switch schema["type"] {
        case .string(let type)?: return [type]
        case .array(let types)?: return types.compactMap(\.stringValue)
        default: return nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null):
            return true
        case ("number", .number):
            return true
        case ("integer", .number):
            return value.intValue != nil
        default:
            return false
        }
    }
}
