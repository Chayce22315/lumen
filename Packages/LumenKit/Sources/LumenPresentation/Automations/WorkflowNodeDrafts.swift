import Foundation
import LumenFoundation
import LumenAutomation

/// Why a step's settings can't be applied. Shown next to the field.
public struct NodeDraftError: Error, Sendable, Hashable, PresentableError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var presentation: ErrorPresentation {
        ErrorPresentation(title: "Check this step", message: message)
    }
}

// MARK: - Conditions

/// A field a condition can test, offered by the editor.
public struct ConditionField: Sendable, Hashable, Identifiable {
    public let path: String
    public let title: String
    public let valueKind: ConditionDraft.ValueKind

    public init(path: String, title: String, valueKind: ConditionDraft.ValueKind) {
        self.path = path
        self.title = title
        self.valueKind = valueKind
    }

    public var id: String { path }
}

/// The editable form of a condition step: rules comparing a context field with a value, joined by
/// "all" or "any". It maps one to one onto `Condition`: one rule is a `compare`, several are an
/// `all`/`any` of compares, none is `always`. Conditions the rules can't express (negation, nested
/// groups, field-to-field comparisons, list values) are kept as they are until replaced.
public struct ConditionDraft: Sendable, Hashable {
    public enum Match: String, Sendable, Hashable, CaseIterable {
        case all
        case any

        public var title: String {
            switch self {
            case .all: return "All rules match"
            case .any: return "Any rule matches"
            }
        }
    }

    /// How the value text is read. Comparisons are type-exact: the number 2 never equals the text "2".
    public enum ValueKind: String, Sendable, Hashable, CaseIterable {
        case text
        case number
        case boolean

        public var title: String {
            switch self {
            case .text: return "Text"
            case .number: return "Number"
            case .boolean: return "Yes or no"
            }
        }

        public init(_ type: TriggerAttributeSpec.ValueType) {
            switch type {
            case .number: self = .number
            case .boolean: self = .boolean
            case .string, .date, .identifier: self = .text
            }
        }
    }

    public struct Rule: Sendable, Hashable, Identifiable {
        public typealias ID = Identifier<Rule>

        public let id: ID
        /// A context path such as `trigger.attributes.priority`.
        public var path: String
        public var comparison: ComparisonOperator
        public var valueKind: ValueKind
        /// The value as typed. Booleans use `true` / `false`. Ignored by unary comparisons.
        public var value: String

        public init(id: ID = ID(), path: String = "", comparison: ComparisonOperator = .equals, valueKind: ValueKind = .text, value: String = "") {
            self.id = id
            self.path = path
            self.comparison = comparison
            self.valueKind = valueKind
            self.value = value
        }
    }

    public var match: Match
    public var rules: [Rule]
    /// The original condition when the rules can't express it. Building returns it unchanged until
    /// `replaceAdvanced()` switches to rules.
    public private(set) var advanced: Condition?

    public init(match: Match = .all, rules: [Rule] = []) {
        self.match = match
        self.rules = rules
        self.advanced = nil
    }

    /// Reads a condition into rules, or keeps it as `advanced` when rules can't express it.
    public init(_ condition: Condition) {
        switch condition {
        case .always:
            self.init()
        case .compare:
            if let rule = Self.rule(from: condition) {
                self.init(rules: [rule])
            } else {
                self.init(advanced: condition)
            }
        case .all(let conditions), .any(let conditions):
            let rules = conditions.compactMap(Self.rule(from:))
            if rules.count == conditions.count, !rules.isEmpty {
                var match = Match.all
                if case .any = condition { match = .any }
                self.init(match: match, rules: rules)
            } else {
                self.init(advanced: condition)
            }
        case .not, .exists:
            self.init(advanced: condition)
        }
    }

    private init(advanced: Condition) {
        self.match = .all
        self.rules = []
        self.advanced = advanced
    }

    public var isAdvanced: Bool { advanced != nil }

    /// Drops the advanced condition and starts over with one empty rule.
    public mutating func replaceAdvanced(with field: ConditionField? = nil) {
        advanced = nil
        rules = [Rule(path: field?.path ?? "", valueKind: field?.valueKind ?? .text)]
    }

    /// The condition the engine evaluates, or the first problem.
    public func condition() throws -> Condition {
        if let advanced { return advanced }
        let compares = try rules.map(Self.compare(for:))
        switch compares.count {
        case 0: return .always
        case 1: return compares[0]
        default: return match == .all ? .all(compares) : .any(compares)
        }
    }

    /// The first problem with the rules, for showing while editing; `nil` when they build.
    public var problem: String? {
        do {
            _ = try condition()
            return nil
        } catch let error as NodeDraftError {
            return error.message
        } catch {
            return ErrorPresentation.from(error).message
        }
    }

    /// The comparisons that make sense for a kind of value.
    public static func comparisons(for kind: ValueKind) -> [ComparisonOperator] {
        switch kind {
        case .text:
            return [.equals, .notEquals, .contains, .hasPrefix, .hasSuffix, .isEmpty, .isNotEmpty]
        case .number:
            return [.equals, .notEquals, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .isEmpty, .isNotEmpty]
        case .boolean:
            return [.equals, .notEquals, .isEmpty, .isNotEmpty]
        }
    }

    static func compare(for rule: Rule) throws -> Condition {
        let path = rule.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw NodeDraftError("Choose the field each rule tests.") }
        guard ContextPath(path) != nil else { throw NodeDraftError("“\(path)” isn't a valid field path.") }
        if rule.comparison.isUnary {
            return .compare(.path(path), rule.comparison, .literal(.null))
        }
        return .compare(.path(path), rule.comparison, .literal(try literal(rule.value, as: rule.valueKind)))
    }

    static func literal(_ text: String, as kind: ValueKind) throws -> JSONValue {
        switch kind {
        case .text:
            return .string(text)
        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(trimmed), number.isFinite else {
                throw NodeDraftError("“\(text)” isn't a number.")
            }
            return .number(number)
        case .boolean:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes": return .bool(true)
            case "false", "no": return .bool(false)
            default: throw NodeDraftError("Choose yes or no.")
            }
        }
    }

    /// A rule for `path <comparison> literal` with a scalar literal; `nil` for anything else.
    static func rule(from condition: Condition) -> Rule? {
        guard case .compare(.path(let path), let comparison, let right) = condition else { return nil }
        if comparison.isUnary {
            return Rule(path: path, comparison: comparison)
        }
        guard case .literal(let value) = right else { return nil }
        switch value {
        case .string(let text): return Rule(path: path, comparison: comparison, valueKind: .text, value: text)
        case .number(let number): return Rule(path: path, comparison: comparison, valueKind: .number, value: formatNumber(number))
        case .bool(let flag): return Rule(path: path, comparison: comparison, valueKind: .boolean, value: flag ? "true" : "false")
        case .null, .array, .object: return nil
        }
    }

    static func formatNumber(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }
}

// MARK: - Delays

/// The editable form of a delay step: an amount of a unit, within the engine's 0…30 days.
public struct DelayDraft: Sendable, Hashable {
    public enum Unit: String, Sendable, Hashable, CaseIterable {
        case seconds, minutes, hours, days

        public var seconds: TimeInterval {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3_600
            case .days: return 86_400
            }
        }

        public func title(for amount: Int) -> String {
            let singular = amount == 1
            switch self {
            case .seconds: return singular ? "second" : "seconds"
            case .minutes: return singular ? "minute" : "minutes"
            case .hours: return singular ? "hour" : "hours"
            case .days: return singular ? "day" : "days"
            }
        }
    }

    public var amount: Int
    public var unit: Unit

    public init(amount: Int, unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    /// The largest unit that expresses `seconds` exactly (fractions round to whole seconds).
    public init(seconds: TimeInterval) {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        for unit in [Unit.days, .hours, .minutes] where whole > 0 && whole % Int(unit.seconds) == 0 {
            self.init(amount: whole / Int(unit.seconds), unit: unit)
            return
        }
        self.init(amount: whole, unit: .seconds)
    }

    public var seconds: TimeInterval { Double(amount) * unit.seconds }

    /// The largest amount of the current unit the engine accepts.
    public var maximumAmount: Int { Int(WorkflowValidator.maximumDelay / unit.seconds) }

    public var problem: String? {
        if amount < 0 { return "A delay can't be negative." }
        if seconds > WorkflowValidator.maximumDelay { return "A delay can be at most 30 days." }
        return nil
    }

    /// `Wait 5 minutes`.
    public var summary: String {
        amount == 0 ? "Continue right away" : "Wait \(amount) \(unit.title(for: amount))"
    }

    public func validatedSeconds() throws -> TimeInterval {
        if let problem { throw NodeDraftError(problem) }
        return seconds
    }
}

// MARK: - Actions

/// The editable form of an action step: one text per parameter. Text containing `{{` is a
/// template; other text becomes a value of the parameter's kind, so the validator can point at a
/// number field holding words. Parameters the user didn't touch keep their stored form exactly
/// (including references, which have no text form of their own).
public struct ActionDraft: Sendable, Hashable {
    public let actionID: AutomationActionID
    public var texts: [String: String]
    private let original: [String: ParameterValue]

    public init(actionID: AutomationActionID, parameters: [String: ParameterValue]) {
        self.actionID = actionID
        self.original = parameters
        self.texts = parameters.mapValues(Self.text(for:))
    }

    public static func text(for value: ParameterValue) -> String {
        switch value {
        case .literal(.number(let number)): return ConditionDraft.formatNumber(number)
        case .literal(let json): return json.displayString
        case .template(let text): return text
        case .reference(let path): return "{{\(path)}}"
        }
    }

    /// The parameters to store, given the action's specs (`nil` when the action isn't installed).
    public func parameters(specs: [ActionParameterSpec]?) -> [String: ParameterValue] {
        var result: [String: ParameterValue] = [:]
        for (name, text) in texts {
            if let stored = original[name], Self.text(for: stored) == text {
                result[name] = stored
                continue
            }
            guard !text.isEmpty else { continue }
            if text.contains("{{") {
                result[name] = .template(text)
                continue
            }
            let kind = specs?.first { $0.name == name }?.kind
            result[name] = .literal(Self.literal(text, kind: kind))
        }
        return result
    }

    static func literal(_ text: String, kind: ActionParameterSpec.Kind?) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .number:
            if let number = Double(trimmed), number.isFinite { return .number(number) }
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes": return .bool(true)
            case "false", "no": return .bool(false)
            default: break
            }
        case .text, .multilineText, .choice, .entity, .date, .none:
            break
        }
        // Kept as text: the validator reports a mismatch with the parameter's kind.
        return .string(text)
    }
}
