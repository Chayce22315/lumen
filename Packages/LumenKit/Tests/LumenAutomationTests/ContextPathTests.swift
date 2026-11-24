import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("ContextPath")
struct ContextPathTests {
    let context: JSONValue = [
        "trigger": ["attributes": ["priority": 3, "title": "Plan", "none": nil]],
        "items": [["name": "first"], ["name": "second"]],
        "numbered": ["0": "zero key"],
    ]

    @Test("resolves nested object keys")
    func nestedKeys() {
        #expect(ContextPath.resolve("trigger.attributes.priority", in: context) == 3)
        #expect(ContextPath.resolve("trigger.attributes.title", in: context) == "Plan")
        #expect(ContextPath.resolve("trigger", in: context)?.objectValue?.keys.sorted() == ["attributes"])
    }

    @Test("numeric components index arrays")
    func arrayIndices() {
        #expect(ContextPath.resolve("items.0.name", in: context) == "first")
        #expect(ContextPath.resolve("items.1.name", in: context) == "second")
        #expect(ContextPath.resolve("items.2.name", in: context) == nil)
    }

    @Test("only plain decimal digits are indices")
    func indexSyntax() {
        #expect(ContextPath.resolve("items.-1", in: context) == nil)
        #expect(ContextPath.resolve("items.+1", in: context) == nil)
        #expect(ContextPath.resolve("items.first", in: context) == nil)
    }

    @Test("numeric components on objects are key lookups")
    func numericKeys() {
        #expect(ContextPath.resolve("numbered.0", in: context) == "zero key")
    }

    @Test("a present null differs from a missing value")
    func nullVersusMissing() {
        #expect(ContextPath.resolve("trigger.attributes.none", in: context) == .null)
        #expect(ContextPath.resolve("trigger.attributes.absent", in: context) == nil)
    }

    @Test("descending into scalars finds nothing")
    func scalars() {
        #expect(ContextPath.resolve("trigger.attributes.priority.value", in: context) == nil)
        #expect(ContextPath.resolve("trigger.attributes.title.0", in: context) == nil)
    }

    @Test("surrounding whitespace is ignored and malformed paths are rejected")
    func parsing() {
        #expect(ContextPath("  trigger.attributes.title \n")?.components == ["trigger", "attributes", "title"])
        for invalid in ["", "   ", "a..b", ".a", "a.", "."] {
            #expect(ContextPath(invalid) == nil, "\(invalid) should be invalid")
        }
        #expect(ContextPath.resolve("a..b", in: context) == nil)
    }

    @Test("component initializer validates and description joins")
    func components() {
        #expect(ContextPath(components: ["steps", "ABC", "output"])?.description == "steps.ABC.output")
        #expect(ContextPath(components: []) == nil)
        #expect(ContextPath(components: ["a.b"]) == nil)
        #expect(ContextPath(components: ["a", ""]) == nil)
    }
}
