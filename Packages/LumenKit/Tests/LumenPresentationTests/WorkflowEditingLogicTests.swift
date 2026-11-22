import Foundation
import Testing
import LumenFoundation
import LumenAutomation
import LumenPresentation

@Suite("Condition drafts")
struct ConditionDraftTests {
    @Test("a single comparison reads into one rule and builds back unchanged")
    func singleRule() throws {
        let condition = Condition.compare("trigger.attributes.priority", .greaterThan, 2)
        let draft = ConditionDraft(condition)
        #expect(!draft.isAdvanced)
        #expect(draft.rules.count == 1)
        #expect(draft.rules[0].path == "trigger.attributes.priority")
        #expect(draft.rules[0].valueKind == .number)
        #expect(draft.rules[0].value == "2")
        #expect(try draft.condition() == condition)
    }

    @Test("several rules build all or any; no rules build always")
    func groups() throws {
        var draft = ConditionDraft(match: .any, rules: [
            ConditionDraft.Rule(path: "trigger.attributes.status", comparison: .equals, valueKind: .text, value: "done"),
            ConditionDraft.Rule(path: "input.flag", comparison: .equals, valueKind: .boolean, value: "yes"),
            ConditionDraft.Rule(path: "input.note", comparison: .isEmpty, valueKind: .text, value: "ignored"),
        ])
        let expected = Condition.any([
            .compare("trigger.attributes.status", .equals, "done"),
            .compare("input.flag", .equals, true),
            .compare(.path("input.note"), .isEmpty, .literal(.null)),
        ])
        #expect(try draft.condition() == expected)
        #expect(ConditionDraft(expected).match == .any)
        #expect(try ConditionDraft(expected).condition() == expected)

        draft.match = .all
        guard case .all(let parts) = try draft.condition() else {
            Issue.record("Expected an all group")
            return
        }
        #expect(parts.count == 3)
        #expect(try ConditionDraft().condition() == .always)
        #expect(ConditionDraft(.always).rules.isEmpty)
    }

    @Test("values are typed exactly: numbers, booleans and text")
    func typedValues() throws {
        let number = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.count", comparison: .lessThan, valueKind: .number, value: " 2.5 ")])
        #expect(try number.condition() == .compare("input.count", .lessThan, 2.5))
        let text = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.count", comparison: .equals, valueKind: .text, value: "2")])
        #expect(try text.condition() == .compare("input.count", .equals, "2"))
        let flag = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.on", comparison: .equals, valueKind: .boolean, value: "False")])
        #expect(try flag.condition() == .compare("input.on", .equals, false))
    }

    @Test("problems name the rule that can't be built")
    func problems() {
        let badNumber = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.count", comparison: .equals, valueKind: .number, value: "two")])
        #expect(badNumber.problem == "“two” isn't a number.")
        #expect(throws: NodeDraftError("“two” isn't a number.")) { try badNumber.condition() }
        let noPath = ConditionDraft(rules: [ConditionDraft.Rule(path: "  ", comparison: .equals, value: "x")])
        #expect(noPath.problem == "Choose the field each rule tests.")
        let badPath = ConditionDraft(rules: [ConditionDraft.Rule(path: "a..b", comparison: .equals, value: "x")])
        #expect(badPath.problem == "“a..b” isn't a valid field path.")
        let badFlag = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.on", comparison: .equals, valueKind: .boolean, value: "maybe")])
        #expect(badFlag.problem == "Choose yes or no.")
        #expect(ConditionDraft().problem == nil)
    }

    @Test("conditions the rules can't express are kept until replaced")
    func advanced() throws {
        let negated = Condition.not(.compare("input.count", .equals, 1))
        var draft = ConditionDraft(negated)
        #expect(draft.isAdvanced)
        #expect(try draft.condition() == negated)
        for condition in [
            Condition.exists("input.x"),
            .compare(.path("input.a"), .equals, .path("input.b")),
            .compare("input.list", .equals, .array([1])),
            .all([.compare("input.a", .equals, 1), .not(.always)]),
        ] {
            #expect(ConditionDraft(condition).isAdvanced)
        }
        draft.replaceAdvanced(with: ConditionField(path: "trigger.attributes.priority", title: "Priority", valueKind: .number))
        #expect(!draft.isAdvanced)
        #expect(draft.rules.map(\.path) == ["trigger.attributes.priority"])
        #expect(draft.rules.map(\.valueKind) == [.number])
    }

    @Test("each kind of value offers the comparisons the engine evaluates for it")
    func comparisons() {
        #expect(ConditionDraft.comparisons(for: .number).contains(.greaterThan))
        #expect(!ConditionDraft.comparisons(for: .number).contains(.contains))
        #expect(ConditionDraft.comparisons(for: .text).contains(.hasPrefix))
        #expect(!ConditionDraft.comparisons(for: .boolean).contains(.lessThan))
        for kind in ConditionDraft.ValueKind.allCases {
            #expect(ConditionDraft.comparisons(for: kind).contains(.isEmpty))
        }
    }
}

@Suite("Delay and action drafts")
struct StepDraftTests {
    @Test("delays read in the largest exact unit and stay within 30 days")
    func delays() throws {
        #expect(DelayDraft(seconds: 300) == DelayDraft(amount: 5, unit: .minutes))
        #expect(DelayDraft(seconds: 7_200) == DelayDraft(amount: 2, unit: .hours))
        #expect(DelayDraft(seconds: 172_800) == DelayDraft(amount: 2, unit: .days))
        #expect(DelayDraft(seconds: 90) == DelayDraft(amount: 90, unit: .seconds))
        #expect(DelayDraft(seconds: 0) == DelayDraft(amount: 0, unit: .seconds))
        #expect(DelayDraft(seconds: .nan) == DelayDraft(amount: 0, unit: .seconds))
        #expect(DelayDraft(amount: 5, unit: .minutes).summary == "Wait 5 minutes")
        #expect(DelayDraft(amount: 1, unit: .hours).summary == "Wait 1 hour")
        #expect(DelayDraft(amount: 0, unit: .days).summary == "Continue right away")

        #expect(try DelayDraft(amount: 30, unit: .days).validatedSeconds() == WorkflowValidator.maximumDelay)
        #expect(DelayDraft(amount: 31, unit: .days).problem == "A delay can be at most 30 days.")
        #expect(DelayDraft(amount: -1, unit: .minutes).problem == "A delay can't be negative.")
        #expect(throws: NodeDraftError("A delay can be at most 30 days.")) { try DelayDraft(amount: 721, unit: .hours).validatedSeconds() }
        #expect(DelayDraft(amount: 1, unit: .hours).maximumAmount == 720)
    }

    @Test("action texts become typed values; untouched parameters keep their stored form")
    func actions() {
        let specs = [
            ActionParameterSpec(name: "title", title: "Title", kind: .text, isRequired: true),
            ActionParameterSpec(name: "count", title: "Count", kind: .number),
            ActionParameterSpec(name: "flag", title: "Flag", kind: .boolean),
            ActionParameterSpec(name: "task", title: "Task", kind: .entity(.task)),
        ]
        var draft = ActionDraft(actionID: "test.action", parameters: [
            "task": .reference(path: "trigger.entity.id"),
            "count": .literal(3),
        ])
        #expect(draft.texts == ["task": "{{trigger.entity.id}}", "count": "3"])

        draft.texts["title"] = "Follow up on {{ trigger.attributes.title }}"
        draft.texts["flag"] = "Yes"
        let parameters = draft.parameters(specs: specs)
        #expect(parameters["task"] == .reference(path: "trigger.entity.id"))
        #expect(parameters["count"] == .literal(3))
        #expect(parameters["title"] == .template("Follow up on {{ trigger.attributes.title }}"))
        #expect(parameters["flag"] == .literal(true))

        draft.texts["count"] = "4.5"
        #expect(draft.parameters(specs: specs)["count"] == .literal(4.5))
        draft.texts["count"] = "several"
        #expect(draft.parameters(specs: specs)["count"] == .literal("several")) // the validator flags it
        draft.texts["count"] = ""
        #expect(draft.parameters(specs: specs)["count"] == nil)
        #expect(draft.parameters(specs: nil)["flag"] == .literal("Yes"))
    }
}

@Suite("Workflow canvas geometry")
struct WorkflowCanvasGeometryTests {
    /// trigger at (0,0) → condition at (0,140) → true: A at (-130,280), false: B at (130,280).
    func branching() -> (graph: WorkflowGraph, trigger: WorkflowNode.ID, check: WorkflowNode.ID, a: WorkflowNode.ID, b: WorkflowNode.ID) {
        let trigger = WorkflowNode(title: "Trigger", position: CanvasPoint(x: 0, y: 0), kind: .trigger)
        let check = WorkflowNode(title: "Check", position: CanvasPoint(x: 0, y: 140), kind: .condition(.always))
        let a = WorkflowNode(title: "A", position: CanvasPoint(x: -130, y: 280), kind: .end)
        let b = WorkflowNode(title: "B", position: CanvasPoint(x: 130, y: 280), kind: .end)
        let graph = WorkflowGraph(nodes: [trigger, check, a, b], edges: [
            WorkflowEdge(from: trigger.id, to: check.id),
            WorkflowEdge(from: check.id, to: a.id, port: .whenTrue),
            WorkflowEdge(from: check.id, to: b.id, port: .whenFalse),
        ])
        return (graph, trigger.id, check.id, a.id, b.id)
    }

    @Test("positions map to view points inside a margin, and back")
    func coordinates() throws {
        let fixture = branching()
        let geometry = WorkflowCanvasGeometry(graph: fixture.graph)
        // Smallest x is -130, so A's centre sits a margin plus half a node from the left.
        #expect(geometry.center(of: fixture.a) == CGPoint(x: 48 + 110, y: 48 + 36 + 280))
        #expect(geometry.contentSize == CGSize(width: 260 + 220 + 96, height: 280 + 72 + 96))
        let frame = try #require(geometry.frame(of: fixture.trigger))
        #expect(frame.width == 220 && frame.height == 72)
        let back = geometry.canvasPoint(geometry.viewPoint(CanvasPoint(x: 17, y: -3)))
        #expect(back == CanvasPoint(x: 17, y: -3))
    }

    @Test("ports: input at the top centre, outputs along the bottom by branch")
    func ports() throws {
        let fixture = branching()
        let geometry = WorkflowCanvasGeometry(graph: fixture.graph)
        let frame = try #require(geometry.frame(of: fixture.check))
        #expect(geometry.inputPoint(of: fixture.check) == CGPoint(x: frame.midX, y: frame.minY))
        let whenTrue = try #require(geometry.outputPoint(of: fixture.check, port: .whenTrue))
        let whenFalse = try #require(geometry.outputPoint(of: fixture.check, port: .whenFalse))
        #expect(whenTrue.y == frame.maxY && whenFalse.y == frame.maxY)
        #expect(whenTrue.x < frame.midX && whenFalse.x > frame.midX)
        #expect(geometry.outputPoint(of: fixture.check, port: .next) == nil)
        #expect(geometry.outputPoint(of: fixture.a, port: .next) == nil) // end steps have no outputs

        let near = CGPoint(x: whenFalse.x + 5, y: whenFalse.y + 5)
        #expect(geometry.outputPort(at: near).map { $0.node } == fixture.check)
        #expect(geometry.outputPort(at: near).map { $0.port } == .whenFalse)
        #expect(geometry.outputPort(at: CGPoint(x: whenFalse.x + 40, y: whenFalse.y)) == nil)
    }

    @Test("connections are hit along their curve but not over a node")
    func edges() throws {
        let fixture = branching()
        let geometry = WorkflowCanvasGeometry(graph: fixture.graph)
        let edge = WorkflowEdge(from: fixture.check, to: fixture.b, port: .whenFalse)
        let curve = try #require(geometry.curve(for: edge))
        #expect(geometry.edge(at: curve.midpoint) == edge)
        #expect(geometry.edge(at: CGPoint(x: curve.midpoint.x + 8, y: curve.midpoint.y)) == edge)
        #expect(geometry.edge(at: CGPoint(x: 2, y: 2)) == nil)
        let overNode = try #require(geometry.center(of: fixture.check))
        #expect(geometry.edge(at: overNode) == nil)
        #expect(curve.distance(to: curve.start) < 0.001)
        #expect(curve.distance(to: curve.end) < 0.001)
    }

    @Test("drops land on nodes or near their inputs, never on the source")
    func drops() throws {
        let fixture = branching()
        let geometry = WorkflowCanvasGeometry(graph: fixture.graph)
        let centre = try #require(geometry.center(of: fixture.b))
        #expect(geometry.node(at: centre) == fixture.b)
        #expect(geometry.dropTarget(at: centre, from: fixture.check) == fixture.b)
        #expect(geometry.dropTarget(at: centre, from: fixture.b) == nil)
        let input = try #require(geometry.inputPoint(of: fixture.a))
        #expect(geometry.dropTarget(at: CGPoint(x: input.x, y: input.y - 10), from: fixture.check) == fixture.a)
        #expect(geometry.dropTarget(at: CGPoint(x: -500, y: -500), from: fixture.check) == nil)
    }

    @Test("moves snap to the grid and new steps find a free spot")
    func placement() {
        let fixture = branching()
        let geometry = WorkflowCanvasGeometry(graph: fixture.graph)
        #expect(WorkflowCanvasGeometry.snap(CanvasPoint(x: 29, y: -11)) == CanvasPoint(x: 20, y: -20))
        #expect(geometry.droppedPosition(of: fixture.trigger, translation: CGSize(width: 52, height: 9)) == CanvasPoint(x: 60, y: 0))
        #expect(geometry.droppedPosition(of: WorkflowNode.ID(), translation: .zero) == nil)

        // Below the trigger is the condition, so the new step moves right of it.
        let spot = geometry.placement(below: fixture.trigger, port: .next)
        #expect(spot.y == 140)
        #expect(spot.x >= 220)
        // Below A (the true branch's end, x = -130) is free; -130 snaps away from zero to -140.
        #expect(geometry.placement(below: fixture.a, port: .next) == CanvasPoint(x: -140, y: 420))
    }
}

@Suite("Workflow outline")
struct WorkflowOutlineTests {
    @Test("steps read in port order with branches indented, unconnected steps last")
    func order() {
        let trigger = WorkflowNode(title: "Trigger", kind: .trigger)
        let check = WorkflowNode(title: "Check", kind: .condition(.always))
        let yes = WorkflowNode(title: "Yes", kind: .delay(seconds: 1))
        let no = WorkflowNode(title: "No", kind: .delay(seconds: 1))
        let join = WorkflowNode(title: "Join", kind: .end)
        let loose = WorkflowNode(title: "Loose", kind: .end)
        let graph = WorkflowGraph(nodes: [trigger, loose, join, no, yes, check], edges: [
            WorkflowEdge(from: trigger.id, to: check.id),
            WorkflowEdge(from: check.id, to: no.id, port: .whenFalse),
            WorkflowEdge(from: check.id, to: yes.id, port: .whenTrue),
            WorkflowEdge(from: yes.id, to: join.id),
            WorkflowEdge(from: no.id, to: join.id),
        ])
        let items = WorkflowOutline.items(for: graph)
        #expect(items.map(\.nodeID) == [trigger.id, check.id, yes.id, join.id, no.id, loose.id])
        #expect(items.map(\.depth) == [0, 0, 1, 1, 1, 0])
        #expect(items.map(\.isConnected) == [true, true, true, true, true, false])
        #expect(items[2].via == WorkflowEdge(from: check.id, to: yes.id, port: .whenTrue))
        #expect(items[0].via == nil)
    }

    @Test("adding to the main path continues after the last step, before a final end")
    func appendPoint() throws {
        var graph = WorkflowGraph.starter()
        let trigger = try #require(graph.triggerNode?.id)
        #expect(WorkflowOutline.appendPoint(in: graph)?.node == trigger)

        let step = WorkflowNode(title: "Step", kind: .delay(seconds: 1))
        let end = WorkflowNode(title: "End", kind: .end)
        graph.nodes += [step, end]
        graph.edges += [WorkflowEdge(from: trigger, to: step.id)]
        #expect(WorkflowOutline.appendPoint(in: graph)?.node == step.id)
        graph.edges += [WorkflowEdge(from: step.id, to: end.id)]
        #expect(WorkflowOutline.appendPoint(in: graph)?.node == step.id) // spliced in before the end
        #expect(WorkflowOutline.appendPoint(in: WorkflowGraph()) == nil)
    }
}

@Suite("JSON preview")
struct JSONPreviewTests {
    @Test("nested values flatten to sorted dotted paths")
    func flatten() {
        let value: JSONValue = ["b": [1, ["c": true]], "a": "text", "n": .null, "empty": .object([:])]
        let lines = JSONPreview.lines(value)
        #expect(lines.map(\.path) == ["a", "b.0", "b.1.c", "empty", "n"])
        #expect(lines.map(\.value) == ["text", "1", "true", "{}", "—"])
        #expect(JSONPreview.lines(.number(2.5)).map(\.path) == ["value"])
        #expect(JSONPreview.lines(nil).isEmpty)
    }

    @Test("long strings are cut and long outputs end with a count")
    func bounds() {
        let long = String(repeating: "x", count: 400)
        #expect(JSONPreview.lines(["text": .string(long)], maxStringLength: 10).first?.value == "xxxxxxxxxx…")
        let many = JSONValue.array((0..<10).map { JSONValue.number(Double($0)) })
        let lines = JSONPreview.lines(many, maxLines: 4)
        #expect(lines.count == 5)
        #expect(lines.last == JSONPreview.Line(path: "…", value: "6 more values"))
    }

    @Test("values under credential-like keys are masked")
    func masking() {
        let value: JSONValue = ["apiKey": "sk-123", "auth": ["Authorization": "Bearer x"], "access_token": ["value": "t"], "title": "ok"]
        let lines = Dictionary(uniqueKeysWithValues: JSONPreview.lines(value).map { ($0.path, $0.value) })
        #expect(lines["apiKey"] == "••••")
        #expect(lines["auth.Authorization"] == "••••")
        #expect(lines["access_token.value"] == "••••")
        #expect(lines["title"] == "ok")
    }
}
