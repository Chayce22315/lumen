import Foundation
import LumenFoundation

/// Flattens JSON from run history into short `path: value` lines for display.
///
/// Bounded so a huge output can't flood the screen: long strings are cut, and past `maxLines` a
/// final line says how many were left out. Values under keys that look like credentials
/// (`password`, `token`, `secret`, `apiKey`, `authorization`) are masked; nothing in Lumen should
/// put them there, but run history must never be the place they leak from.
public enum JSONPreview {
    public struct Line: Sendable, Hashable, Identifiable {
        /// Dotted path from the root (`items.0.title`); `value` for a scalar root.
        public let path: String
        public let value: String

        public init(path: String, value: String) {
            self.path = path
            self.value = value
        }

        public var id: String { path }
    }

    public static func lines(_ value: JSONValue?, maxLines: Int = 40, maxStringLength: Int = 280) -> [Line] {
        guard let value else { return [] }
        var lines: [Line] = []
        var omitted = 0
        let limit = max(1, maxLines)

        func emit(_ path: String, _ text: String) {
            if lines.count < limit {
                lines.append(Line(path: path.isEmpty ? "value" : path, value: text))
            } else {
                omitted += 1
            }
        }

        func walk(_ value: JSONValue, path: String, masked: Bool) {
            switch value {
            case .object(let object) where !object.isEmpty:
                for key in object.keys.sorted() {
                    guard let child = object[key] else { continue }
                    walk(child, path: path.isEmpty ? key : "\(path).\(key)", masked: masked || isSensitive(key))
                }
            case .array(let array) where !array.isEmpty:
                for (index, child) in array.enumerated() {
                    walk(child, path: path.isEmpty ? String(index) : "\(path).\(index)", masked: masked)
                }
            default:
                emit(path, masked ? "••••" : render(value, maxStringLength: maxStringLength))
            }
        }

        walk(value, path: "", masked: false)
        if omitted > 0 {
            lines.append(Line(path: "…", value: "\(omitted) more \(omitted == 1 ? "value" : "values")"))
        }
        return lines
    }

    static func render(_ value: JSONValue, maxStringLength: Int) -> String {
        switch value {
        case .null: return "—"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return ConditionDraft.formatNumber(number)
        case .string(let text):
            let limit = max(1, maxStringLength)
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        case .array: return "[]"
        case .object: return "{}"
        }
    }

    static func isSensitive(_ key: String) -> Bool {
        let folded = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return ["password", "secret", "token", "apikey", "authorization"].contains { folded.contains($0) }
    }
}
