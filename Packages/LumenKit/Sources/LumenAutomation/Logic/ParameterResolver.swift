import Foundation
import LumenFoundation

/// Turns a node's `ParameterValue`s into the JSON values an action receives.
public enum ParameterResolver {
    public struct Result: Sendable, Hashable {
        public var values: [String: JSONValue]
        public var warnings: [ResolutionWarning]
        /// Required parameters that resolved to nothing (null or blank text).
        public var missingRequired: [String]
    }

    /// Resolves one value. Templates render to text; references yield the raw JSON at the path, or
    /// `null` with a warning when missing.
    public static func resolve(_ value: ParameterValue, in context: JSONValue) -> (value: JSONValue, warnings: [ResolutionWarning]) {
        switch value {
        case .literal(let literal):
            return (literal, [])
        case .template(let template):
            let rendered = TemplateRenderer.render(template, in: context)
            return (.string(rendered.text), rendered.warnings)
        case .reference(let rawPath):
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path = ContextPath(trimmed) else {
                return (.null, [ResolutionWarning(kind: .invalidPath, path: trimmed)])
            }
            guard let resolved = path.resolve(in: context) else {
                return (.null, [ResolutionWarning(kind: .missingValue, path: trimmed)])
            }
            return (resolved, [])
        }
    }

    /// Resolves every parameter of a node against the action's specs: defaults fill unset
    /// parameters, templates feeding number or boolean parameters are converted when the text
    /// parses, and required parameters without a value are reported. Parameters without a spec are
    /// passed through unchanged.
    public static func resolve(
        _ parameters: [String: ParameterValue],
        specs: [ActionParameterSpec],
        in context: JSONValue
    ) -> Result {
        var values: [String: JSONValue] = [:]
        var warnings: [ResolutionWarning] = []
        let specsByName = Dictionary(specs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for name in parameters.keys.sorted() {
            guard let parameter = parameters[name] else { continue }
            let resolved = resolve(parameter, in: context)
            warnings += resolved.warnings.map { warning in
                var warning = warning
                warning.parameter = name
                return warning
            }
            if case .template = parameter, let spec = specsByName[name] {
                values[name] = coerce(resolved.value, to: spec.kind)
            } else {
                values[name] = resolved.value
            }
        }

        var missing: [String] = []
        for spec in specs {
            if isAbsent(values[spec.name]), let defaultValue = spec.defaultValue {
                values[spec.name] = defaultValue
            }
            if spec.isRequired, isAbsent(values[spec.name]) {
                missing.append(spec.name)
            }
        }
        return Result(values: values, warnings: warnings, missingRequired: missing)
    }

    /// Converts rendered template text to the parameter's type when it parses unambiguously.
    static func coerce(_ value: JSONValue, to kind: ActionParameterSpec.Kind) -> JSONValue {
        guard case .string(let text) = value else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .number:
            if let number = Double(trimmed), number.isFinite { return .number(number) }
            return value
        case .boolean:
            switch trimmed.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return value
            }
        case .text, .multilineText, .choice, .entity, .date:
            return value
        }
    }

    static func isAbsent(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .some(.null): return true
        case .some(.string(let text)): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .some: return false
        }
    }
}
