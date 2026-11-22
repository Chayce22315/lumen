import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("AutomationEngine definitions and history")
struct AutomationEngineTests {
    func simpleGraph() -> WorkflowGraph {
        var builder = GraphBuilder()
        builder.chain([action(SetVariableAction.id, ["value": .literal(1)]), .end])
        return builder.graph
    }

    @Test("creating a workflow saves it, records a change and publishes an event")
    func create() async throws {
        let harness = try await AutomationHarness.make()
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(modules: ["automation"]))
        let workflow = try await harness.engine.create(WorkflowDraft(name: "  Morning review  ", summary: "Daily", graph: simpleGraph()))

        #expect(workflow.name == "Morning review")
        #expect(workflow.createdAt == harness.clock.now() && workflow.updatedAt == workflow.createdAt)
        #expect(try await harness.engine.workflow(workflow.id) == workflow)
        let changes = try await harness.changes()
        #expect(changes.map(\.operation) == [.upsert])
        #expect(changes.first?.entity == workflow.reference)
        #expect(try changes.first?.payload?.decode(as: Workflow.self) == workflow)

        let event = try #require(await recorder.waitForEvents(1).first)
        #expect(event.name == AutomationEvents.workflowCreated)
        #expect(event.entity == EntityReference(kind: .workflow, id: workflow.id))
        #expect(event.actor == .user)
        #expect(event.attributes == ["workflowID": .string(workflow.id.uuidString), "triggerType": "manual", "isEnabled": true])
    }

    @Test("invalid workflows are rejected with their issues and nothing is stored")
    func invalid() async throws {
        let harness = try await AutomationHarness.make()
        var builder = GraphBuilder()
        builder.add(action("plugin.missing"), after: builder.trigger)
        do {
            try await harness.engine.create(WorkflowDraft(name: "", graph: builder.graph))
            Issue.record("expected a validation error")
        } catch let error as AutomationError {
            guard case .invalidWorkflow(let issues) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(issues.errors.map(\.code) == [.missingName, .unknownAction])
            #expect(error.presentation.title == "Workflow can't be saved")
            #expect(error.presentation.message == "Give the workflow a name. (1 more problem)")
        }
        #expect(try await harness.engine.workflows().isEmpty)
        #expect(try await harness.changes().isEmpty)
        #expect(harness.engine.validate(Workflow(name: "Ok", graph: simpleGraph(), createdAt: harness.clock.now())).isEmpty)
    }

    @Test("updating keeps the creation date, records a change and reports enablement changes")
    func update() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "Draft", graph: simpleGraph()))
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(modules: ["automation"]))
        harness.clock.advance(by: 60)

        var edited = workflow
        edited.name = "Final"
        edited.isEnabled = false
        edited.createdAt = .distantPast
        let updated = try await harness.engine.update(edited)
        #expect(updated.name == "Final")
        #expect(updated.createdAt == workflow.createdAt)
        #expect(updated.updatedAt == harness.clock.now())
        #expect(try await harness.engine.workflow(workflow.id) == updated)
        #expect(try await harness.changes().map(\.operation) == [.upsert, .upsert])
        #expect(await recorder.waitForEvents(2).map(\.name) == [AutomationEvents.workflowUpdated, AutomationEvents.workflowDisabled])

        let unknown = Workflow(name: "Ghost", graph: simpleGraph(), createdAt: harness.clock.now())
        await #expect(throws: AutomationError.workflowNotFound(unknown.id)) { try await harness.engine.update(unknown) }
    }

    @Test("deleting removes the workflow and its history and records the deletion")
    func delete() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "Temp", graph: simpleGraph()))
        let run = try await harness.engine.run(workflow.id)
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(names: [AutomationEvents.workflowDeleted]))

        try await harness.engine.delete(workflow.id)
        #expect(try await harness.engine.workflow(workflow.id) == nil)
        #expect(try await harness.engine.runDetail(run.id) == nil)
        #expect(try await harness.changes().map(\.operation) == [.upsert, .delete])
        #expect(await recorder.waitForEvents(1).first?.entity == workflow.reference)
        await #expect(throws: AutomationError.workflowNotFound(workflow.id)) { try await harness.engine.delete(workflow.id) }
    }

    @Test("deleting a workflow cancels its executing runs")
    func deleteWhileRunning() async throws {
        let blocking = BlockingAction()
        let harness = try await AutomationHarness.make(actions: [blocking])
        var builder = GraphBuilder()
        builder.add(action("test.block"), after: builder.trigger)
        let workflow = try await harness.create(builder.graph)
        let engine = harness.engine
        let execution = Task { try await engine.run(workflow.id) }
        #expect(await eventually { blocking.hasStarted })

        try await engine.delete(workflow.id)
        let run = try await execution.value
        #expect(run.status == .cancelled)
        #expect(try await engine.recentRuns().isEmpty)
    }

    @Test("enabling and disabling publish events, and unchanged states are no-ops")
    func enablement() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "Toggle", graph: simpleGraph()))
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(modules: ["automation"]))

        #expect(try await harness.engine.setEnabled(workflow.id, true) == workflow)
        let disabled = try await harness.engine.setEnabled(workflow.id, false, context: ActionContext(actor: .assistant))
        #expect(!disabled.isEnabled)
        #expect(try await harness.engine.setEnabled(workflow.id, true).isEnabled)
        let events = await recorder.waitForEvents(2)
        #expect(events.map(\.name) == [AutomationEvents.workflowDisabled, AutomationEvents.workflowEnabled])
        #expect(events.first?.actor == .assistant)
        #expect(try await harness.changes().count == 3)
    }

    @Test("duplicates are disabled copies with a new identity")
    func duplicate() async throws {
        let harness = try await AutomationHarness.make()
        let original = try await harness.engine.create(WorkflowDraft(name: "Weekly", trigger: .event(name: "x.y.z", condition: nil), graph: simpleGraph()))
        let copy = try await harness.engine.duplicate(original.id)
        #expect(copy.id != original.id)
        #expect(copy.name == "Weekly copy")
        #expect(!copy.isEnabled)
        #expect(copy.graph == original.graph)
        #expect(copy.trigger == original.trigger)
        #expect(try await harness.engine.workflows().map(\.name) == ["Weekly", "Weekly copy"])
    }

    @Test("workflows are listed by name")
    func listing() async throws {
        let harness = try await AutomationHarness.make()
        for name in ["beta", "Alpha", "gamma"] {
            try await harness.engine.create(WorkflowDraft(name: name, graph: simpleGraph()))
        }
        #expect(try await harness.engine.workflows().map(\.name) == ["Alpha", "beta", "gamma"])
    }

    @Test("sync applies rows without change records and keeps run history")
    func syncRows() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "Synced", graph: simpleGraph()))
        try await harness.engine.run(workflow.id)

        var remote = workflow
        remote.name = "Renamed elsewhere"
        let stored = remote
        try await harness.database.write(origin: .remote) { db in try WorkflowRepository.upsertRow(stored, in: db) }
        #expect(try await harness.engine.workflow(workflow.id)?.name == "Renamed elsewhere")
        #expect(try await harness.engine.runs(workflowID: workflow.id).count == 1)
        #expect(try await harness.changes().count == 1)

        let deleted = try await harness.database.write(origin: .remote) { db in try WorkflowRepository.deleteRow(workflow.id, in: db) }
        #expect(deleted)
        #expect(try await harness.engine.workflow(workflow.id) == nil)
        #expect(try await harness.engine.recentRuns().isEmpty)
        #expect(try await harness.changes().count == 1)
    }

    @Test("run history is device-local: runs never produce change records")
    func runsAreLocal() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "Local", graph: simpleGraph()))
        for _ in 0..<3 { try await harness.engine.run(workflow.id) }
        #expect(try await harness.changes().allSatisfy { $0.entity.kind == .workflow })
        #expect(try await harness.changes().count == 1)
    }

    @Test("manual runs receive their input and respect the causation limit")
    func manualRun() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "name", title: "Name")])
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        builder.add(action("test.record", ["name": .template("{{ input.person.name }}")]), after: builder.trigger)
        let workflow = try await harness.create(builder.graph, isEnabled: false)

        let run = try await harness.engine.run(workflow.id, input: ["person": ["name": "Grace"]])
        #expect(run.status == .succeeded)
        #expect(run.input == ["person": ["name": "Grace"]])
        #expect(recorder.recorded.first?.parameters["name"] == "Grace")

        await #expect(throws: AutomationError.causationLimitReached(depth: 3)) {
            try await harness.engine.run(workflow.id, context: ActionContext(actor: .automation, causationDepth: 3))
        }
        let missing = Workflow.ID()
        await #expect(throws: AutomationError.workflowNotFound(missing)) { try await harness.engine.run(missing) }
    }

    @Test("history lists runs newest first and purges only old finished runs")
    func history() async throws {
        let harness = try await AutomationHarness.make()
        let workflow = try await harness.engine.create(WorkflowDraft(name: "History", graph: simpleGraph()))
        var waitBuilder = GraphBuilder()
        waitBuilder.add(.delay(seconds: 86_400), after: waitBuilder.trigger)
        let waiting = try await harness.create(waitBuilder.graph, name: "Waiter")

        let first = try await harness.engine.run(workflow.id)
        harness.clock.advance(by: 60)
        let second = try await harness.engine.run(workflow.id)
        let parked = try await harness.engine.run(waiting.id)
        harness.clock.advance(by: 10 * 86_400)
        let recent = try await harness.engine.run(workflow.id)

        #expect(try await harness.engine.runs(workflowID: workflow.id).map(\.id) == [recent.id, second.id, first.id])
        #expect(try await harness.engine.runs(workflowID: workflow.id, limit: 1).map(\.id) == [recent.id])
        #expect(try await harness.engine.recentRuns(limit: 2).map(\.id) == [recent.id, parked.id])

        #expect(try await harness.engine.purgeHistory(olderThan: 7 * 86_400) == 2)
        #expect(Set(try await harness.engine.recentRuns().map(\.id)) == [recent.id, parked.id])
        #expect(try await harness.engine.runDetail(first.id) == nil)
        #expect(try await harness.engine.runDetail(recent.id)?.steps.count == 3)
    }
}
