import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("ConditionEvaluator")
struct ConditionEvaluatorTests {
    let context: JSONValue = [
        "trigger": [
            "name": "organization.task.completed",
            "occurredAt": "2026-11-21T09:00:00Z",
            "attributes": [
                "priority": 3,
                "estimate": 2.5,
                "title": "Write Café Report",
                "tags": ["work", "urgent"],
                "due": "2026-11-21",
                "done": true,
                "meta": ["owner": "me"],
                "empty": "",
                "blank": "   ",
                "none": nil,
                "list": [],
                "object": [:],
                "zero": 0,
            ],
        ],
        "input": ["threshold": 2],
    ]

    func holds(_ condition: Condition) -> Bool {
        ConditionEvaluator.evaluate(condition, in: context)
    }

    @Test("numbers compare numerically")
    func numbers() {
        #expect(holds(.compare("trigger.attributes.priority", .greaterThan, 2)))
        #expect(holds(.compare("trigger.attributes.priority", .greaterThanOrEqual, 3)))
        #expect(holds(.compare("trigger.attributes.priority", .lessThan, 10)))
        #expect(holds(.compare("trigger.attributes.estimate", .lessThanOrEqual, 2.5)))
        #expect(!holds(.compare("trigger.attributes.priority", .lessThan, 3)))
        #expect(holds(.compare("trigger.attributes.priority", .equals, 3.0)))
    }

    @Test("strings compare lexically, so ISO dates order correctly")
    func strings() {
        #expect(holds(.compare("trigger.attributes.due", .lessThan, "2026-12-01")))
        #expect(holds(.compare("trigger.attributes.due", .greaterThanOrEqual, "2026-11-21")))
        #expect(holds(.compare("trigger.occurredAt", .greaterThan, "2026-11-21T08:59:59Z")))
        #expect(holds(.compare(.literal("apple"), .lessThan, .literal("banana"))))
        // Lexical, not numeric: "10" sorts before "9".
        #expect(holds(.compare(.literal("10"), .lessThan, .literal("9"))))
    }

    @Test("mismatched types never compare and are not equal")
    func mismatchedTypes() {
        #expect(!holds(.compare("trigger.attributes.priority", .equals, "3")))
        #expect(holds(.compare("trigger.attributes.priority", .notEquals, "3")))
        #expect(!holds(.compare("trigger.attributes.priority", .greaterThan, "2")))
        #expect(!holds(.compare("trigger.attributes.priority", .lessThan, "4")))
        #expect(!holds(.compare("trigger.attributes.tags", .greaterThan, 1)))
        #expect(!holds(.compare("trigger.attributes.done", .greaterThan, false)))
    }

    @Test("missing values behave like null")
    func missing() {
        #expect(holds(.compare("trigger.attributes.absent", .equals, nil)))
        #expect(holds(.compare("trigger.attributes.none", .equals, nil)))
        #expect(!holds(.compare("trigger.attributes.absent", .equals, 0)))
        #expect(!holds(.compare("trigger.attributes.absent", .lessThan, 5)))
        #expect(!holds(.compare("trigger.attributes.absent", .greaterThanOrEqual, 5)))
        #expect(holds(.compare("trigger.attributes.absent", .notEquals, "x")))
    }

    @Test("equality is deep for arrays and objects")
    func structures() {
        #expect(holds(.compare("trigger.attributes.tags", .equals, ["work", "urgent"])))
        #expect(!holds(.compare("trigger.attributes.tags", .equals, ["urgent", "work"])))
        #expect(holds(.compare("trigger.attributes.meta", .equals, ["owner": "me"])))
    }

    @Test("contains matches substrings case- and diacritic-insensitively, array elements and object keys")
    func contains() {
        #expect(holds(.compare("trigger.attributes.title", .contains, "cafe report")))
        #expect(holds(.compare("trigger.attributes.title", .contains, "")))
        #expect(!holds(.compare("trigger.attributes.title", .contains, "memo")))
        #expect(holds(.compare("trigger.attributes.tags", .contains, "urgent")))
        #expect(!holds(.compare("trigger.attributes.tags", .contains, "home")))
        #expect(holds(.compare("trigger.attributes.meta", .contains, "owner")))
        #expect(!holds(.compare("trigger.attributes.priority", .contains, 3)))
        #expect(!holds(.compare("trigger.attributes.title", .contains, 3)))
    }

    @Test("prefix and suffix apply to strings only")
    func prefixSuffix() {
        #expect(holds(.compare("trigger.attributes.title", .hasPrefix, "write")))
        #expect(holds(.compare("trigger.attributes.title", .hasSuffix, "REPORT")))
        #expect(holds(.compare("trigger.name", .hasPrefix, "organization.")))
        #expect(!holds(.compare("trigger.attributes.title", .hasPrefix, "Report")))
        #expect(!holds(.compare("trigger.attributes.tags", .hasPrefix, "work")))
        #expect(!holds(.compare("trigger.attributes.priority", .hasSuffix, "3")))
    }

    @Test("emptiness covers missing, null, blank text and empty collections")
    func emptiness() {
        for path in ["absent", "none", "empty", "blank", "list", "object"] {
            #expect(holds(.compare("trigger.attributes.\(path)", .isEmpty)), "\(path) should be empty")
            #expect(!holds(.compare("trigger.attributes.\(path)", .isNotEmpty)), "\(path) should not be non-empty")
        }
        for path in ["priority", "zero", "done", "title", "tags", "meta"] {
            #expect(holds(.compare("trigger.attributes.\(path)", .isNotEmpty)), "\(path) should be non-empty")
        }
    }

    @Test("unary operators ignore the right-hand side")
    func unary() {
        #expect(holds(.compare(.path("trigger.attributes.title"), .isNotEmpty, .literal("ignored"))))
        #expect(ComparisonOperator.isEmpty.isUnary && ComparisonOperator.isNotEmpty.isUnary)
        #expect(!ComparisonOperator.equals.isUnary)
    }

    @Test("all, any and not combine conditions; empty lists are true and false")
    func logic() {
        let high = Condition.compare("trigger.attributes.priority", .greaterThan, 2)
        let low = Condition.compare("trigger.attributes.priority", .lessThan, 2)
        #expect(holds(.all([high, .always])))
        #expect(!holds(.all([high, low])))
        #expect(holds(.any([low, high])))
        #expect(!holds(.any([low])))
        #expect(holds(.all([])))
        #expect(!holds(.any([])))
        #expect(holds(.not(low)))
        #expect(holds(.not(.not(high))))
        #expect(holds(.always))
    }

    @Test("exists requires a non-null value at a valid path")
    func exists() {
        #expect(holds(.exists("trigger.attributes.priority")))
        #expect(holds(.exists("trigger.attributes.empty")))
        #expect(!holds(.exists("trigger.attributes.none")))
        #expect(!holds(.exists("trigger.attributes.absent")))
        #expect(!holds(.exists("trigger..attributes")))
    }

    @Test("paths can be compared with paths")
    func pathToPath() {
        #expect(holds(.compare(.path("trigger.attributes.priority"), .greaterThan, .path("input.threshold"))))
        #expect(!holds(.compare(.path("trigger.attributes.priority"), .equals, .path("input.threshold"))))
    }

    @Test("NaN never orders or equals")
    func nan() {
        #expect(!ConditionEvaluator.compare(.number(.nan), .lessThan, .number(1)))
        #expect(!ConditionEvaluator.compare(.number(.nan), .greaterThanOrEqual, .number(1)))
        #expect(!ConditionEvaluator.compare(.number(.nan), .equals, .number(.nan)))
    }

    @Test("summaries describe conditions and list referenced paths")
    func summary() {
        let condition = Condition.all([
            .compare("trigger.attributes.priority", .greaterThan, 2),
            .not(.exists("trigger.attributes.done")),
            .compare(.path("trigger.attributes.title"), .isEmpty, .path("ignored.path")),
        ])
        #expect(condition.summary == "trigger.attributes.priority is greater than 2 and not (trigger.attributes.done exists) and trigger.attributes.title is empty")
        #expect(condition.referencedPaths == ["trigger.attributes.priority", "trigger.attributes.done", "trigger.attributes.title"])
    }
}
