import Foundation
import LumenFoundation

/// How an action parameter gets its value when the step runs.
public enum ParameterValue: Sendable, Hashable {
    /// A fixed value.
    case literal(JSONValue)
    /// Text with `{{ path }}` placeholders, rendered against the run context.
    case template(String)
    /// The raw JSON value at a context path (objects and arrays stay structured).
    case reference(path: String)
}

extension ParameterValue: Codable {
    enum CodingKeys: String, CodingKey {
        case type, value, template, path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "literal": self = .literal(try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null)
        case "template": self = .template(try container.decode(String.self, forKey: .template))
        case "reference": self = .reference(path: try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown parameter value '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value):
            try container.encode("literal", forKey: .type)
            try container.encode(value, forKey: .value)
        case .template(let template):
            try container.encode("template", forKey: .type)
            try container.encode(template, forKey: .template)
        case .reference(let path):
            try container.encode("reference", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}
