import Foundation
import LumenFoundation

/// A problem found while resolving a template placeholder or a reference. Missing values render as
/// empty text, so these are warnings recorded with the step rather than failures.
public struct ResolutionWarning: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The path is well-formed but nothing is there.
        case missingValue
        /// The placeholder is not a valid path (`{{ }}`, `{{ a..b }}`).
        case invalidPath
        /// `{{` without a closing `}}`; the text is kept as written.
        case unterminatedPlaceholder
    }

    public var kind: Kind
    /// The placeholder or reference text as written (trimmed).
    public var path: String
    /// The parameter being resolved, when known.
    public var parameter: String?

    public init(kind: Kind, path: String, parameter: String? = nil) {
        self.kind = kind
        self.path = path
        self.parameter = parameter
    }

    public var message: String {
        let subject = parameter.map { "Parameter “\($0)”: " } ?? ""
        switch kind {
        case .missingValue: return subject + "“\(path)” has no value"
        case .invalidPath: return subject + "“\(path)” is not a valid path"
        case .unterminatedPlaceholder: return subject + "a “{{” placeholder is not closed"
        }
    }

    public var description: String { message }
}

/// Renders `{{ path }}` placeholders against a run context.
///
/// - Whitespace inside the braces is ignored: `{{trigger.name}}` and `{{ trigger.name }}` are equal.
/// - `\{{` produces a literal `{{`.
/// - Values render with `JSONValue.displayString`: strings unquoted, whole numbers without a
///   fraction, objects and arrays as compact JSON, `null` as empty text.
/// - Missing or invalid paths render as empty text and are reported as warnings.
public enum TemplateRenderer {
    public struct Result: Sendable, Hashable {
        public var text: String
        public var warnings: [ResolutionWarning]

        public init(text: String, warnings: [ResolutionWarning] = []) {
            self.text = text
            self.warnings = warnings
        }
    }

    enum Segment: Hashable {
        case text(String)
        case placeholder(String)
        case unterminated(String)
    }

    public static func render(_ template: String, in context: JSONValue) -> Result {
        var text = ""
        var warnings: [ResolutionWarning] = []
        for segment in segments(of: template) {
            switch segment {
            case .text(let literal):
                text += literal
            case .unterminated(let rest):
                text += rest
                warnings.append(ResolutionWarning(kind: .unterminatedPlaceholder, path: rest))
            case .placeholder(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let path = ContextPath(trimmed) else {
                    warnings.append(ResolutionWarning(kind: .invalidPath, path: trimmed))
                    continue
                }
                guard let value = path.resolve(in: context) else {
                    warnings.append(ResolutionWarning(kind: .missingValue, path: trimmed))
                    continue
                }
                text += value.displayString
            }
        }
        return Result(text: text, warnings: warnings)
    }

    /// The trimmed placeholder texts in order of appearance (for highlighting and validation).
    public static func placeholders(in template: String) -> [String] {
        segments(of: template).compactMap { segment in
            if case .placeholder(let raw) = segment { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
    }

    /// Problems detectable without a context: unterminated placeholders and invalid paths.
    public static func syntaxWarnings(in template: String) -> [ResolutionWarning] {
        segments(of: template).compactMap { segment in
            switch segment {
            case .text: return nil
            case .unterminated(let rest): return ResolutionWarning(kind: .unterminatedPlaceholder, path: rest)
            case .placeholder(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return ContextPath(trimmed) == nil ? ResolutionWarning(kind: .invalidPath, path: trimmed) : nil
            }
        }
    }

    /// Escapes literal text so it renders verbatim inside a template.
    public static func escape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "{{", with: "\\{{")
    }

    static func segments(of template: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var index = template.startIndex
        let end = template.endIndex

        func flush() {
            if !literal.isEmpty {
                segments.append(.text(literal))
                literal = ""
            }
        }

        while index < end {
            let rest = template[index...]
            if rest.hasPrefix("\\{{") {
                literal += "{{"
                index = template.index(index, offsetBy: 3)
            } else if rest.hasPrefix("{{") {
                let bodyStart = template.index(index, offsetBy: 2)
                guard let close = template[bodyStart...].range(of: "}}") else {
                    flush()
                    segments.append(.unterminated(String(rest)))
                    break
                }
                flush()
                segments.append(.placeholder(String(template[bodyStart..<close.lowerBound])))
                index = close.upperBound
            } else {
                literal.append(template[index])
                index = template.index(after: index)
            }
        }
        flush()
        return segments
    }
}
