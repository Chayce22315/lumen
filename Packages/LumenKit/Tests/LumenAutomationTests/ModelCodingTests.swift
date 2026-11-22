import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("Model coding")
struct ModelCodingTests {
    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONCoding.decode(T.self, from: try JSONCoding.encodeString(value))
    }

    @Test("triggers encode with a stable type discriminator")
    func triggerDiscriminator() throws {
        let schedule = ScheduleTrigger(rule: .weekdaysOnly, anchor: try day(2026, 11, 23), time: try time(7, 30))
        #expect(try JSONValue(encoding: TriggerDefinition.manual) == ["type": "manual"])
        #expect(try JSONValue(encoding: TriggerDefinition.event(name: "organization.task.completed", condition: nil)) == [
            "type": "event", "name": "organization.task.completed",
        ])
        let encoded = try JSONValue(encoding: TriggerDefinition.schedule(schedule))
        #expect(encoded["type"] == "schedule")
        #expect(encoded["schedule"]?["anchor"] == "2026-11-23")
        for trigger in [TriggerDefinition.manual, .event(name: "a.b.c", condition: .exists("trigger.entity")), .schedule(schedule)] {
            #expect(try roundTrip(trigger) == trigger)
        }
        #expect(throws: DecodingError.self) { try JSONCoding.decode(TriggerDefinition.self, from: #"{"type":"webhook"}"#) }
    }

    @Test("conditions round-trip, including null literals")
    func conditions() throws {
        let condition = Condition.any([
            .all([.compare("trigger.attributes.priority", .greaterThanOrEqual, 2), .not(.exists("trigger.attributes.done"))]),
            .compare(.path("trigger.attributes.owner"), .equals, .literal(nil)),
            .compare(.path("trigger.attributes.title"), .isEmpty, .literal(nil)),
            .always,
        ])
        #expect(try roundTrip(condition) == condition)
        let encoded = try JSONValue(encoding: Condition.compare("x", .equals, 1))
        #expect(encoded == ["type": "compare", "left": ["type": "path", "path": "x"], "operator": "equals", "right": ["type": "literal", "value": 1]])
    }

    @Test("node kinds and parameter values round-trip; unknown kinds fail")
    func nodes() throws {
        let kinds: [WorkflowNode.Kind] = [
            .trigger,
            .action(actionID: "automation.formatText", parameters: [
                "text": .template("Hi {{trigger.name}}"), "case": .literal("uppercase"), "source": .reference(path: "input.items"), "none": .literal(nil),
            ]),
            .condition(.always),
            .delay(seconds: 90),
            .end,
        ]
        for kind in kinds {
            let node = WorkflowNode(title: "Step", position: CanvasPoint(x: 12.5, y: -4), kind: kind)
            #expect(try roundTrip(node) == node)
        }
        #expect(throws: DecodingError.self) { try JSONCoding.decode(WorkflowNode.Kind.self, from: #"{"type":"loop"}"#) }
    }

    @Test("parameter specs round-trip every kind")
    func parameterSpecs() throws {
        let kinds: [ActionParameterSpec.Kind] = [.text, .multilineText, .number, .boolean, .choice(["a", "b"]), .entity("task"), .entity(nil), .date]
        for kind in kinds {
            let spec = ActionParameterSpec(name: "p", title: "P", kind: kind, isRequired: true, defaultValue: "x")
            #expect(try roundTrip(spec) == spec)
        }
    }

    @Test("workflows survive the change-log snapshot form")
    func workflowSnapshot() throws {
        var builder = GraphBuilder()
        builder.chain([action("automation.setVariable", ["value": .literal(1)]), .delay(seconds: 120), .end])
        let workflow = Workflow(
            name: "Snapshot",
            summary: "Round trip",
            isEnabled: false,
            trigger: .event(name: "x.y.z", condition: .compare("trigger.attributes.n", .lessThan, 3)),
            graph: builder.graph,
            failurePolicy: FailurePolicy(retry: RetryPolicy(maxAttempts: 2, initialDelay: 5), onFailure: .continue, resumeInterruptedRuns: false),
            createdAt: ManualTimeSource.referenceDate,
            updatedAt: ManualTimeSource.referenceDate.addingTimeInterval(60)
        )
        let snapshot = try JSONValue(encoding: workflow)
        #expect(try snapshot.decode(as: Workflow.self) == workflow)
    }

    @Test("older snapshots without newer fields decode with defaults")
    func defaults() throws {
        let id = UUID()
        let minimal = #"{"id":"\#(id.uuidString)","name":"Old","createdAt":1795251600}"#
        let workflow = try JSONCoding.decode(Workflow.self, from: minimal)
        #expect(workflow.id.rawValue == id)
        #expect(workflow.summary == "")
        #expect(workflow.isEnabled)
        #expect(workflow.trigger == .manual)
        #expect(workflow.graph == WorkflowGraph())
        #expect(workflow.failurePolicy == .standard)
        #expect(workflow.updatedAt == workflow.createdAt)
        #expect(try JSONCoding.decode(FailurePolicy.self, from: "{}") == .standard)
        let node = try JSONCoding.decode(WorkflowNode.self, from: #"{"id":"\#(id.uuidString)","kind":{"type":"end"}}"#)
        #expect(node.title == "" && node.position == .zero)
    }

    @Test("descriptions summarise triggers for the canvas")
    func summaries() throws {
        #expect(TriggerDefinition.manual.summary == "Run manually")
        #expect(TriggerDefinition.event(name: "a.b.c", condition: nil).summary == "When a.b.c")
        let schedule = ScheduleTrigger(rule: .daily, anchor: try day(2026, 11, 21), time: try time(9, 5))
        #expect(TriggerDefinition.schedule(schedule).summary == "Every day at 09:05")
    }
}
