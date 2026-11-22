import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("ParameterResolver")
struct ParameterResolverTests {
    let context: JSONValue = [
        "trigger": ["attributes": ["title": "Plan", "count": 3, "tags": ["a", "b"]]],
        "input": ["amount": "42", "flag": "TRUE", "word": "many"],
    ]

    @Test("literals pass through, templates render, references keep structure")
    func kinds() {
        #expect(ParameterResolver.resolve(.literal(["x": 1]), in: context).value == ["x": 1])
        #expect(ParameterResolver.resolve(.template("{{trigger.attributes.title}}!"), in: context).value == "Plan!")
        #expect(ParameterResolver.resolve(.reference(path: "trigger.attributes.tags"), in: context).value == ["a", "b"])
        #expect(ParameterResolver.resolve(.reference(path: " trigger.attributes.count "), in: context).value == 3)
    }

    @Test("missing or invalid references resolve to null with a warning")
    func missingReference() {
        let missing = ParameterResolver.resolve(.reference(path: "trigger.attributes.owner"), in: context)
        #expect(missing.value == .null)
        #expect(missing.warnings.map(\.kind) == [.missingValue])
        let invalid = ParameterResolver.resolve(.reference(path: "a..b"), in: context)
        #expect(invalid.value == .null)
        #expect(invalid.warnings.map(\.kind) == [.invalidPath])
    }

    @Test("defaults fill unset parameters and required ones without a value are reported")
    func defaultsAndRequired() {
        let specs = [
            ActionParameterSpec(name: "title", title: "Title", isRequired: true),
            ActionParameterSpec(name: "mode", title: "Mode", kind: .choice(["fast", "slow"]), defaultValue: "fast"),
            ActionParameterSpec(name: "note", title: "Note", isRequired: true),
            ActionParameterSpec(name: "owner", title: "Owner", isRequired: true),
            ActionParameterSpec(name: "limit", title: "Limit", kind: .number, defaultValue: 10),
        ]
        let result = ParameterResolver.resolve(
            [
                "title": .template("{{trigger.attributes.title}}"),
                "note": .template("  {{trigger.attributes.missing}} "),
                "owner": .reference(path: "trigger.attributes.owner"),
                "limit": .literal(nil),
            ],
            specs: specs,
            in: context
        )
        #expect(result.values["title"] == "Plan")
        #expect(result.values["mode"] == "fast")
        #expect(result.values["limit"] == 10)
        #expect(result.missingRequired == ["note", "owner"])
        #expect(result.warnings.map(\.parameter) == ["note", "owner"])
        #expect(result.warnings.first?.message == "Parameter “note”: “trigger.attributes.missing” has no value")
    }

    @Test("templates feeding number and boolean parameters are converted when the text parses")
    func coercion() {
        let specs = [
            ActionParameterSpec(name: "amount", title: "Amount", kind: .number),
            ActionParameterSpec(name: "flag", title: "Flag", kind: .boolean),
            ActionParameterSpec(name: "word", title: "Word", kind: .number),
            ActionParameterSpec(name: "raw", title: "Raw", kind: .number),
            ActionParameterSpec(name: "label", title: "Label", kind: .text),
        ]
        let result = ParameterResolver.resolve(
            [
                "amount": .template("{{input.amount}}"),
                "flag": .template("{{input.flag}}"),
                "word": .template("{{input.word}}"),
                "raw": .reference(path: "input.amount"),
                "label": .template("{{trigger.attributes.count}}"),
            ],
            specs: specs,
            in: context
        )
        #expect(result.values["amount"] == 42)
        #expect(result.values["flag"] == true)
        #expect(result.values["word"] == "many")
        #expect(result.values["raw"] == "42")
        #expect(result.values["label"] == "3")
    }

    @Test("parameters without a spec are passed through")
    func unknownParameters() {
        let result = ParameterResolver.resolve(["extra": .literal(1)], specs: [], in: context)
        #expect(result.values == ["extra": 1])
        #expect(result.missingRequired.isEmpty)
    }
}
