import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("Run history detail")
struct RunHistoryDetailTests {
    @Test("steps keep the inputs they resolved: parameters, condition operands and delays")
    func stepInputs() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "name", title: "Name")])
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let check = builder.add(.condition(.compare("input.priority", .greaterThan, 2)), title: "Urgent?", after: builder.trigger)
        let wait = builder.add(.delay(seconds: 5), title: "Wait", after: check, port: .whenTrue)
        builder.add(action("test.record", ["name": .template("Hello {{ input.name }}")]), title: "Record", after: wait)
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id, input: ["name": "Ada", "priority": 3])
        #expect(run.status == .succeeded)
        let steps = try await harness.steps(of: run)
        #expect(steps.count == 4)
        #expect(steps[0].inputs == nil) // the trigger: its payload is the run's trigger
        #expect(steps[1].inputs == ["input.priority": 3])
        #expect(steps[1].output == ["result": true])
        #expect(steps[2].inputs == ["seconds": 5])
        #expect(steps[3].inputs == ["name": "Hello Ada"])
    }

    @Test("a missing condition operand is recorded as null")
    func missingOperand() async throws {
        let harness = try await AutomationHarness.make()
        var builder = GraphBuilder()
        builder.add(.condition(.compare("input.missing", .equals, "x")), after: builder.trigger)
        let workflow = try await harness.create(builder.graph)
        let run = try await harness.engine.run(workflow.id)
        let steps = try await harness.steps(of: run)
        #expect(steps[1].inputs == ["input.missing": .null])
        #expect(steps[1].output == ["result": false])
    }

    @Test("rerun replays the trigger payload and input with the current definition")
    func rerun() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "name", title: "Name")])
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let step = builder.add(action("test.record", ["name": .template("{{ input.name }}")]), title: "Record", after: builder.trigger)
        var workflow = try await harness.create(builder.graph, isEnabled: false)
        let first = try await harness.engine.run(workflow.id, input: ["name": "Grace"])

        // Edit the workflow: the rerun uses the definition as it is now.
        let index = try #require(workflow.graph.index(of: step))
        workflow.graph.nodes[index].kind = action("test.record", ["name": .template("Again, {{ input.name }}")])
        workflow = try await harness.engine.update(workflow)

        harness.clock.advance(by: 60)
        let second = try await harness.engine.rerun(first.id)
        #expect(second.id != first.id)
        #expect(second.status == .succeeded)
        #expect(second.input == first.input)
        guard case .object(var replayed) = second.triggerPayload, case .object(let original) = first.triggerPayload else {
            Issue.record("Trigger payloads are objects")
            return
        }
        #expect(replayed.removeValue(forKey: "rerunOf") == .string(first.id.uuidString))
        #expect(replayed == original)
        #expect(recorder.recorded.map { $0.parameters["name"] } == ["Grace", "Again, Grace"])
        #expect(try await harness.engine.runs(workflowID: workflow.id).map(\.id) == [second.id, first.id])

        let unknown = WorkflowRun.ID()
        await #expect(throws: AutomationError.runNotFound(unknown)) { try await harness.engine.rerun(unknown) }
        await #expect(throws: AutomationError.causationLimitReached(depth: 3)) {
            try await harness.engine.rerun(first.id, context: ActionContext(actor: .automation, causationDepth: 3))
        }
    }
}
