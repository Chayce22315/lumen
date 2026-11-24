import Foundation
import LumenFoundation

extension WorkflowValidator {
    /// Content rules for one node: known action, required and well-typed parameters, valid paths
    /// and templates, delays within `0...maximumDelay`.
    public static func validate(node: WorkflowNode, actions: [AutomationActionID: AutomationActionDescriptor]) -> [ValidationIssue] {
        switch node.kind {
        case .trigger, .end:
            return []

        case .delay(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= maximumDelay else {
                return [ValidationIssue(.delayOutOfRange, .error, nodeID: node.id, message: "“\(node.title)” must wait between 0 seconds and 30 days.")]
            }
            return []

        case .condition(let condition):
            return condition.referencedPaths.compactMap { path in
                guard ContextPath(path) == nil else { return nil }
                return ValidationIssue(.invalidPath, .error, nodeID: node.id, message: "“\(node.title)” uses “\(path)”, which is not a valid path.")
            }

        case .action(let actionID, let parameters):
            guard let descriptor = actions[actionID] else {
                return [ValidationIssue(.unknownAction, .error, nodeID: node.id, message: "“\(node.title)” uses an action that isn't available on this device (\(actionID.rawValue)).")]
            }
            var issues: [ValidationIssue] = []
            for spec in descriptor.parameters {
                let value = parameters[spec.name]
                if spec.isRequired, spec.defaultValue == nil, isMissing(value) {
                    issues.append(ValidationIssue(.missingParameter, .error, nodeID: node.id, message: "“\(node.title)” needs a value for “\(spec.title)”."))
                }
                if let value {
                    issues += check(value, against: spec, node: node)
                }
            }
            for name in parameters.keys.sorted() where descriptor.parameter(named: name) == nil {
                issues.append(ValidationIssue(.unknownParameter, .warning, nodeID: node.id, message: "“\(node.title)” sets “\(name)”, which the action doesn't use."))
            }
            return issues
        }
    }

    static func isMissing(_ value: ParameterValue?) -> Bool {
        switch value {
        case .none: return true
        case .some(.literal(let literal)): return ParameterResolver.isAbsent(literal)
        case .some(.template(let template)): return template.nonBlank == nil
        case .some(.reference(let path)): return path.nonBlank == nil
        }
    }

    static func check(_ value: ParameterValue, against spec: ActionParameterSpec, node: WorkflowNode) -> [ValidationIssue] {
        switch value {
        case .template(let template):
            return TemplateRenderer.syntaxWarnings(in: template).map { warning in
                ValidationIssue(.invalidTemplate, .warning, nodeID: node.id, message: "“\(node.title)”, “\(spec.title)”: \(warning.message).")
            }
        case .reference(let path):
            guard path.nonBlank == nil || ContextPath(path) != nil else {
                return [ValidationIssue(.invalidPath, .error, nodeID: node.id, message: "“\(node.title)”, “\(spec.title)”: “\(path)” is not a valid path.")]
            }
            return []
        case .literal(let literal):
            guard !ParameterResolver.isAbsent(literal), !literalMatches(literal, spec.kind) else { return [] }
            return [ValidationIssue(.invalidParameter, .error, nodeID: node.id, message: "“\(node.title)”: “\(spec.title)” expects \(describe(spec.kind)).")]
        }
    }

    /// Whether a fixed value fits the parameter kind. Dynamic values are checked when the step runs.
    static func literalMatches(_ value: JSONValue, _ kind: ActionParameterSpec.Kind) -> Bool {
        switch kind {
        case .text, .multilineText:
            switch value {
            case .string, .number, .bool: return true
            case .null, .array, .object: return false
            }
        case .number:
            guard case .number(let number) = value else { return false }
            return number.isFinite
        case .boolean:
            return value.boolValue != nil
        case .choice(let options):
            guard case .string(let text) = value else { return false }
            return options.contains(text)
        case .entity(let entityKind):
            guard case .string(let text) = value else { return false }
            if UUID(uuidString: text) != nil { return true }
            guard let reference = EntityReference(uri: text) else { return false }
            return entityKind.map { $0 == reference.kind } ?? true
        case .date:
            guard case .string(let text) = value else { return false }
            if CalendarDate(text) != nil { return true }
            // Probing: a parse failure simply means the text is not an ISO 8601 instant.
            return (try? Date.ISO8601FormatStyle().parse(text)) != nil
        }
    }

    static func describe(_ kind: ActionParameterSpec.Kind) -> String {
        switch kind {
        case .text, .multilineText: return "text"
        case .number: return "a number"
        case .boolean: return "true or false"
        case .choice(let options): return "one of " + options.map { "“\($0)”" }.joined(separator: ", ")
        case .entity(let entityKind): return entityKind.map { "a \($0.rawValue) reference" } ?? "an item reference"
        case .date: return "a date"
        }
    }
}
