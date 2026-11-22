import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("TemplateRenderer")
struct TemplateRendererTests {
    let context: JSONValue = [
        "trigger": ["name": "organization.task.completed", "attributes": ["title": "Plan", "count": 3, "ratio": 2.5, "done": true, "none": nil]],
        "steps": ["A": ["output": ["tags": ["a", "b"], "meta": ["z": 1, "a": 2]]]],
    ]

    @Test("placeholders resolve with or without inner whitespace")
    func whitespace() {
        let result = TemplateRenderer.render("{{trigger.attributes.title}} / {{ trigger.attributes.title }} / {{\ttrigger.attributes.title\n}}", in: context)
        #expect(result.text == "Plan / Plan / Plan")
        #expect(result.warnings.isEmpty)
    }

    @Test("scalars render naturally")
    func scalars() {
        let result = TemplateRenderer.render("Count {{trigger.attributes.count}}, ratio {{trigger.attributes.ratio}}, done {{trigger.attributes.done}}", in: context)
        #expect(result.text == "Count 3, ratio 2.5, done true")
    }

    @Test("objects and arrays render as compact sorted JSON")
    func structures() {
        #expect(TemplateRenderer.render("{{steps.A.output.tags}}", in: context).text == #"["a","b"]"#)
        #expect(TemplateRenderer.render("{{steps.A.output.meta}}", in: context).text == #"{"a":2,"z":1}"#)
    }

    @Test("missing values render empty and are reported")
    func missing() {
        let result = TemplateRenderer.render("Hi {{ trigger.attributes.owner }}!", in: context)
        #expect(result.text == "Hi !")
        #expect(result.warnings == [ResolutionWarning(kind: .missingValue, path: "trigger.attributes.owner")])
        #expect(result.warnings.first?.message == "“trigger.attributes.owner” has no value")
    }

    @Test("null renders empty without a warning")
    func null() {
        let result = TemplateRenderer.render("[{{trigger.attributes.none}}]", in: context)
        #expect(result.text == "[]")
        #expect(result.warnings.isEmpty)
    }

    @Test("invalid paths render empty and are reported")
    func invalidPaths() {
        let result = TemplateRenderer.render("a{{ }}b{{x..y}}c", in: context)
        #expect(result.text == "abc")
        #expect(result.warnings.map(\.kind) == [.invalidPath, .invalidPath])
        #expect(result.warnings.map(\.path) == ["", "x..y"])
    }

    @Test("a backslash escapes an opening brace pair")
    func escaping() {
        let result = TemplateRenderer.render(#"Use \{{name}} for {{trigger.attributes.title}}"#, in: context)
        #expect(result.text == "Use {{name}} for Plan")
        #expect(TemplateRenderer.escape("a {{b}}") == #"a \{{b}}"#)
        #expect(TemplateRenderer.render(TemplateRenderer.escape("{{literal}}"), in: context).text == "{{literal}}")
    }

    @Test("an unterminated placeholder stays literal and is reported")
    func unterminated() {
        let result = TemplateRenderer.render("Hello {{trigger.name", in: context)
        #expect(result.text == "Hello {{trigger.name")
        #expect(result.warnings.map(\.kind) == [.unterminatedPlaceholder])
    }

    @Test("plain text, single braces and unicode pass through unchanged")
    func passthrough() {
        let text = "Résumé { not a placeholder } ✓ 🎉 }}"
        #expect(TemplateRenderer.render(text, in: context) == TemplateRenderer.Result(text: text, warnings: []))
    }

    @Test("placeholders and syntax problems can be listed without a context")
    func inspection() {
        #expect(TemplateRenderer.placeholders(in: "{{ a.b }} and {{c}} \\{{d}}") == ["a.b", "c"])
        #expect(TemplateRenderer.syntaxWarnings(in: "{{ok.path}}").isEmpty)
        #expect(TemplateRenderer.syntaxWarnings(in: "{{a..b}} {{open").map(\.kind) == [.invalidPath, .unterminatedPlaceholder])
    }
}
