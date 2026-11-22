import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("WorkflowValidator")
struct WorkflowValidatorTests {
    let actions: [AutomationActionID: AutomationActionDescriptor] = {
        let descriptor = AutomationActionDescriptor(
            id: "test.create",
            title: "Create",
            summary: "",
            symbolName: "plus",
            category: "Test",
            parameters: [
                ActionParameterSpec(name: "title", title: "Title", kind: .text, isRequired: true),
                ActionParameterSpec(name: "count", title: "Count", kind: .number),
                ActionParameterSpec(name: "mode", title: "Mode", kind: .choice(["fast", "slow"])),
                ActionParameterSpec(name: "when", title: "When", kind: .date),
                ActionParameterSpec(name: "task", title: "Task", kind: .entity("task")),
                ActionParameterSpec(name: "flag", title: "Flag", kind: .boolean),
                ActionParameterSpec(name: "list", title: "List", kind: .text, isRequired: true, defaultValue: "Inbox"),
            ],
            isMutating: true
        )
        return [descriptor.id: descriptor]
    }()

    func create(_ parameters: [String: ParameterValue] = ["title": .literal("Task")]) -> WorkflowNode.Kind {
        .action(actionID: "test.create", parameters: parameters)
    }

    func codes(_ graph: WorkflowGraph) -> [ValidationIssue.Code] {
        WorkflowValidator.validate(graph: graph, actions: actions).map(\.code)
    }

    func workflow(_ graph: WorkflowGraph, name: String = "Valid", trigger: TriggerDefinition = .manual) -> Workflow {
        Workflow(name: name, trigger: trigger, graph: graph, createdAt: ManualTimeSource.referenceDate)
    }

    @Test("a branching workflow with valid steps has no issues")
    func valid() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.compare("trigger.attributes.priority", .greaterThan, 2)), after: builder.trigger)
        let yes = builder.add(create(["title": .template("{{trigger.attributes.title}}"), "count": .literal(2)]), after: check, port: .whenTrue)
        builder.add(.delay(seconds: 30 * 86_400), after: yes)
        builder.add(.end, after: check, port: .whenFalse)
        #expect(WorkflowValidator.validate(workflow(builder.graph), actions: actions).isEmpty)
    }

    @Test("exactly one trigger is required")
    func triggers() {
        #expect(codes(WorkflowGraph(nodes: [WorkflowNode(title: "End", kind: .end)])).contains(.missingTrigger))
        var builder = GraphBuilder()
        builder.add(.end, after: builder.trigger)
        var graph = builder.graph
        let second = WorkflowNode(title: "Second", kind: .trigger)
        graph.nodes.append(second)
        let issues = WorkflowValidator.validate(graph: graph, actions: actions)
        #expect(issues.map(\.code) == [.multipleTriggers])
        #expect(issues.first?.nodeID == second.id)
    }

    @Test("edges must connect existing nodes and never enter the trigger")
    func edges() {
        var builder = GraphBuilder()
        let end = builder.add(.end, after: builder.trigger)
        var graph = builder.graph
        graph.edges.append(WorkflowEdge(from: builder.trigger, to: WorkflowNode.ID(), port: .next))
        graph.edges.append(WorkflowEdge(from: WorkflowNode.ID(), to: end, port: .next))
        #expect(codes(graph).filter { $0 == .danglingEdge }.count == 2)

        var intoTrigger = GraphBuilder()
        let step = intoTrigger.add(create(), after: intoTrigger.trigger)
        var looped = intoTrigger.graph
        looped.edges.append(WorkflowEdge(from: step, to: intoTrigger.trigger))
        #expect(codes(looped).contains(.triggerHasIncomingEdge))
    }

    @Test("cycles are rejected once per closing node")
    func cycles() {
        var builder = GraphBuilder()
        let first = builder.add(create(), after: builder.trigger)
        let check = builder.add(.condition(.always), after: first)
        var graph = builder.graph
        graph.edges.append(WorkflowEdge(from: check, to: first, port: .whenTrue))
        let issues = WorkflowValidator.validate(graph: graph, actions: actions)
        #expect(issues.map(\.code) == [.cycle])
        #expect(issues.first?.nodeID == first)
    }

    @Test("actions continue to at most one step")
    func singleNext() {
        var builder = GraphBuilder()
        let step = builder.add(create(), after: builder.trigger)
        builder.add(.end, after: step)
        builder.add(.end, after: step)
        #expect(codes(builder.graph) == [.multipleNextEdges])
    }

    @Test("conditions branch only on true and false, once each; actions have no branches")
    func ports() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        builder.add(.end, after: check, port: .next)
        builder.add(.end, after: check, port: .whenTrue)
        builder.add(.end, after: check, port: .whenTrue)
        let step = builder.add(create(), after: check, port: .whenFalse)
        builder.add(.end, after: step, port: .whenTrue)
        let found = codes(builder.graph)
        #expect(found.filter { $0 == .invalidPort }.count == 2)
        #expect(found.contains(.duplicateBranch))
        // The ends attached through invalid ports are not connected to the trigger.
        #expect(found.filter { $0 == .unreachableNode }.count == 2)
    }

    @Test("end steps cannot continue")
    func endOutgoing() {
        var builder = GraphBuilder()
        let end = builder.add(.end, after: builder.trigger)
        builder.add(create(), after: end)
        let found = codes(builder.graph)
        #expect(found.contains(.endHasOutgoingEdge))
        #expect(found.contains(.unreachableNode))
    }

    @Test("every step must be reachable from the trigger")
    func reachability() {
        var builder = GraphBuilder()
        builder.add(create(), after: builder.trigger)
        var graph = builder.graph
        let orphan = WorkflowNode(title: "Orphan", kind: .end)
        graph.nodes.append(orphan)
        let issues = WorkflowValidator.validate(graph: graph, actions: actions)
        #expect(issues.map(\.code) == [.unreachableNode])
        #expect(issues.first?.nodeID == orphan.id)
        #expect(issues.first?.severity == .error)
    }

    @Test("actions must be installed")
    func unknownAction() {
        var builder = GraphBuilder()
        builder.add(.action(actionID: "plugin.missing", parameters: [:]), after: builder.trigger)
        #expect(codes(builder.graph) == [.unknownAction])
    }

    @Test("required parameters need a value unless the action has a default")
    func requiredParameters() {
        for missing: [String: ParameterValue] in [[:], ["title": .literal(nil)], ["title": .literal("  ")], ["title": .template(" ")]] {
            var builder = GraphBuilder()
            builder.add(create(missing), after: builder.trigger)
            #expect(codes(builder.graph) == [.missingParameter])
        }
        var dynamic = GraphBuilder()
        dynamic.add(create(["title": .reference(path: "trigger.attributes.title")]), after: dynamic.trigger)
        #expect(codes(dynamic.graph).isEmpty)
    }

    @Test("fixed values must fit the parameter kind")
    func literalTypes() {
        let invalid: [String: ParameterValue] = [
            "title": .literal("ok"),
            "count": .literal("three"),
            "mode": .literal("medium"),
            "when": .literal("tomorrow"),
            "task": .literal(.string("note:\(UUID().uuidString)")),
            "flag": .literal(1),
        ]
        var builder = GraphBuilder()
        builder.add(create(invalid), after: builder.trigger)
        #expect(codes(builder.graph) == Array(repeating: .invalidParameter, count: 5))

        let valid: [String: ParameterValue] = [
            "title": .literal(42),
            "count": .literal(3),
            "mode": .literal("slow"),
            "when": .literal("2026-11-21T09:00:00Z"),
            "task": .literal(.string("task:\(UUID().uuidString)")),
            "flag": .literal(false),
        ]
        var accepted = GraphBuilder()
        accepted.add(create(valid), after: accepted.trigger)
        accepted.add(create(["title": .literal("x"), "when": .literal("2026-12-01"), "task": .literal(.string(UUID().uuidString))]), after: accepted.trigger)
        #expect(!codes(accepted.graph).contains(.invalidParameter))
    }

    @Test("unknown parameters and malformed templates are warnings; malformed references are errors")
    func parameterWarnings() {
        var builder = GraphBuilder()
        builder.add(create(["title": .template("Hi {{ name"), "colour": .literal("red"), "count": .reference(path: "a..b")]), after: builder.trigger)
        let issues = WorkflowValidator.validate(graph: builder.graph, actions: actions)
        #expect(issues.map(\.code).sorted { $0.rawValue < $1.rawValue } == [.invalidPath, .invalidTemplate, .unknownParameter])
        #expect(issues.first { $0.code == .invalidTemplate }?.severity == .warning)
        #expect(issues.first { $0.code == .unknownParameter }?.severity == .warning)
        #expect(issues.first { $0.code == .invalidPath }?.severity == .error)
    }

    @Test("delays must be between zero and thirty days")
    func delays() {
        let outOfRange: [TimeInterval] = [-1, 30 * 86_400 + 1, .nan, .infinity]
        for seconds in outOfRange {
            var builder = GraphBuilder()
            builder.add(.delay(seconds: seconds), after: builder.trigger)
            #expect(codes(builder.graph) == [.delayOutOfRange], "\(seconds)")
        }
        var zero = GraphBuilder()
        zero.add(.delay(seconds: 0), after: zero.trigger)
        #expect(codes(zero.graph).isEmpty)
    }

    @Test("condition paths must be valid")
    func conditionPaths() {
        var builder = GraphBuilder()
        builder.add(.condition(.all([.exists("trigger..x"), .compare("ok.path", .equals, 1)])), after: builder.trigger)
        #expect(codes(builder.graph) == [.invalidPath])
    }

    @Test("duplicate node identifiers are rejected")
    func duplicateIDs() {
        var builder = GraphBuilder()
        let step = builder.add(create(), after: builder.trigger)
        var graph = builder.graph
        graph.nodes.append(WorkflowNode(id: step, title: "Copy", kind: .end))
        #expect(codes(graph).contains(.duplicateNodeID))
    }

    @Test("a trigger with nothing after it is only a warning")
    func emptyWorkflow() {
        let issues = WorkflowValidator.validate(graph: .starter(), actions: actions)
        #expect(issues.map(\.code) == [.emptyWorkflow])
        #expect(!issues.hasErrors)
    }

    @Test("workflow names and triggers are checked")
    func workflowLevel() {
        var builder = GraphBuilder()
        builder.add(.end, after: builder.trigger)
        let graph = builder.graph
        #expect(WorkflowValidator.validate(workflow(graph, name: "  "), actions: actions).map(\.code) == [.missingName])
        #expect(WorkflowValidator.validate(workflow(graph, trigger: .event(name: " ", condition: nil)), actions: actions).map(\.code) == [.invalidTrigger])
        #expect(WorkflowValidator.validate(workflow(graph, trigger: .event(name: "x.y.z", condition: .exists("a..b"))), actions: actions).map(\.code) == [.invalidPath])
        let unknown = WorkflowValidator.validate(workflow(graph, trigger: .event(name: "x.y.z", condition: nil)), actions: actions, knownEvents: ["a.b.c"])
        #expect(unknown.map(\.code) == [.unknownEvent])
        #expect(!unknown.hasErrors)
    }

    @Test("schedules must be able to occur")
    func schedules() throws {
        let anchor = try day(2026, 11, 21)
        let nine = try time(9, 0)
        var builder = GraphBuilder()
        builder.add(.end, after: builder.trigger)
        let graph = builder.graph
        func check(_ rule: RecurrenceRule) -> [ValidationIssue.Code] {
            WorkflowValidator.validate(workflow(graph, trigger: .schedule(ScheduleTrigger(rule: rule, anchor: anchor, time: nine))), actions: actions).map(\.code)
        }
        #expect(check(.daily).isEmpty)
        #expect(check(RecurrenceRule(frequency: .daily, end: .afterOccurrences(0))) == [.invalidTrigger])
        #expect(check(RecurrenceRule(frequency: .daily, end: .onDate(anchor.adding(days: -1)))) == [.invalidTrigger])
        #expect(check(RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(32))) == [.invalidTrigger])
        #expect(check(RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: 6, weekday: .monday))) == [.invalidTrigger])
    }
}
