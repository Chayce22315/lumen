import Foundation
import LumenFoundation

/// Reads one JSON object strictly: every key must be expected, every value of the expected type
/// and within its limit. Errors name the path (`contributions.commands[2].title`) so a publisher
/// can find the problem. Paths are made of schema keys and indices; unknown keys are reported by
/// path so the message stays useful.
struct StrictJSONObject {
    let path: String
    private let fields: [String: JSONValue]
    private var consumed: Set<String> = []

    init(_ value: JSONValue, path: String) throws {
        guard case .object(let fields) = value else {
            throw PluginPackageError.malformed(path: path, reason: "Expected an object.")
        }
        self.fields = fields
        self.path = path
    }

    static func parse(_ data: Data, path: String) throws -> StrictJSONObject {
        let value: JSONValue
        do {
            value = try JSONCoding.decoder.decode(JSONValue.self, from: data)
        } catch {
            throw PluginPackageError.malformed(path: path, reason: "The file isn't valid JSON.")
        }
        return try StrictJSONObject(value, path: path)
    }

    func childPath(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private mutating func take(_ key: String) -> JSONValue? {
        consumed.insert(key)
        guard let value = fields[key], !value.isNull else { return nil }
        return value
    }

    mutating func string(_ key: String, maxLength: Int, required: Bool = true, allowEmpty: Bool = false) throws -> String? {
        guard let value = take(key) else {
            if required { throw PluginPackageError.malformed(path: childPath(key), reason: "This value is required.") }
            return nil
        }
        guard case .string(let text) = value else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "Expected text.")
        }
        if !allowEmpty, text.nonBlank == nil {
            throw PluginPackageError.malformed(path: childPath(key), reason: "This value can't be empty.")
        }
        guard text.count <= maxLength else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "This value can be at most \(maxLength) characters.")
        }
        return text
    }

    mutating func requiredString(_ key: String, maxLength: Int, allowEmpty: Bool = false) throws -> String {
        // `string` throws for a missing value when `required` is true.
        try string(key, maxLength: maxLength, required: true, allowEmpty: allowEmpty) ?? ""
    }

    mutating func integer(_ key: String) throws -> Int {
        guard let value = take(key) else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "This value is required.")
        }
        guard let integer = value.intValue else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "Expected a whole number.")
        }
        return integer
    }

    mutating func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = take(key) else { return defaultValue }
        guard case .bool(let flag) = value else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "Expected true or false.")
        }
        return flag
    }

    mutating func object(_ key: String, required: Bool = true) throws -> StrictJSONObject? {
        guard let value = take(key) else {
            if required { throw PluginPackageError.malformed(path: childPath(key), reason: "This value is required.") }
            return nil
        }
        return try StrictJSONObject(value, path: childPath(key))
    }

    /// The raw value at `key`, which must be an object (kept for another engine to interpret).
    mutating func rawObject(_ key: String) throws -> JSONValue {
        guard let value = take(key) else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "This value is required.")
        }
        guard case .object = value else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "Expected an object.")
        }
        return value
    }

    mutating func array(_ key: String, maxCount: Int, required: Bool = false) throws -> [(value: JSONValue, path: String)] {
        guard let value = take(key) else {
            if required { throw PluginPackageError.malformed(path: childPath(key), reason: "This value is required.") }
            return []
        }
        guard case .array(let items) = value else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "Expected a list.")
        }
        guard items.count <= maxCount else {
            throw PluginPackageError.malformed(path: childPath(key), reason: "This list can have at most \(maxCount) entries.")
        }
        return items.enumerated().map { (index, item) in (item, "\(childPath(key))[\(index)]") }
    }

    mutating func stringArray(_ key: String, maxCount: Int, maxLength: Int, required: Bool = false) throws -> [String] {
        try array(key, maxCount: maxCount, required: required).map { item in
            guard case .string(let text) = item.value, text.nonBlank != nil else {
                throw PluginPackageError.malformed(path: item.path, reason: "Expected non-empty text.")
            }
            guard text.count <= maxLength else {
                throw PluginPackageError.malformed(path: item.path, reason: "This value can be at most \(maxLength) characters.")
            }
            return text
        }
    }

    /// Throws when the object has keys nothing asked for.
    func finish() throws {
        let unknown = fields.keys.filter { !consumed.contains($0) }.sorted()
        if let first = unknown.first {
            let more = unknown.count > 1 ? " (and \(unknown.count - 1) more)" : ""
            throw PluginPackageError.malformed(path: childPath(first.truncated(to: 40)), reason: "Lumen doesn't know this key\(more).")
        }
    }
}
