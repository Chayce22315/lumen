import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("AutomationEngine event triggers")
struct AutomationTriggerTests {
    func recordGraph(_ id: AutomationActionID = "test.record", parameters: [String: ParameterValue] = [:]) -> WorkflowGraph {
        var builder = GraphBuilder()
        builder.add(action(id, parameters), after: builder.trigger)
        return builder.graph
    }

    @Test("a matching event starts the workflow with the event as trigger context")
    func eventFires() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "title", title: "Title")])
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = try await harness.create(
            recordGraph(parameters: ["title": .template("{{ trigger.attributes.title }} ({{ trigger.entity.kind }})")]),
            trigger: .event(name: "organization.task.completed", condition: nil)
        )
        await harness.engine.start()
        #expect(await harness.engine.isStarted)
        let task = EntityReference(kind: "task", id: UUID())
        harness.events.publish(DomainEvent(
            name: "organization.task.completed", entity: task, attributes: ["title": "Write report"], occurredAt: harness.clock.now()
        ))

        #expect(await eventually { recorder.count == 1 })
        await harness.engine.waitUntilIdle()
        #expect(recorder.recorded.first?.parameters["title"] == "Write report (task)")
        #expect(recorder.recorded.first?.context.causationDepth == 1)
        let run = try #require(try await harness.engine.runs(workflowID: workflow.id).first)
        #expect(run.status == .succeeded)
        #expect(run.triggerPayload["entity"]?["id"] == .string(task.id.uuidString))
        #expect(run.triggerPayload["occurredAt"] == "2026-11-21T09:00:00Z")
        #expect(await harness.engine.statistics.runsStartedByEvents == 1)
        await harness.engine.stop()
    }

    @Test("trigger conditions filter events")
    func conditions() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = try await harness.create(
            recordGraph(),
            trigger: .event(name: "organization.task.created", condition: .compare("trigger.attributes.priority", .greaterThan, 2))
        )
        await harness.engine.start()
        for priority in [1, 5, 2] {
            harness.events.publish(DomainEvent(name: "organization.task.created", attributes: ["priority": .number(Double(priority))], occurredAt: harness.clock.now()))
        }
        harness.events.publish(DomainEvent(name: "organization.task.deleted", attributes: ["priority": 9], occurredAt: harness.clock.now()))
        #expect(await eventually { await harness.engine.statistics.eventsReceived >= 4 })
        await harness.engine.waitUntilIdle()
        let runs = try await harness.engine.runs(workflowID: workflow.id)
        #expect(runs.count == 1)
        #expect(runs.first?.triggerPayload["attributes"]?["priority"] == 5)
        await harness.engine.stop()
    }

    @Test("disabled workflows ignore their events")
    func disabledIgnored() async throws {
        let ignored = RecordingAction("test.ignored")
        let sentinel = RecordingAction("test.sentinel")
        let harness = try await AutomationHarness.make(actions: [ignored, sentinel])
        let disabled = try await harness.create(recordGraph("test.ignored"), trigger: .event(name: "test.item.created", condition: nil), isEnabled: false)
        try await harness.create(recordGraph("test.sentinel"), trigger: .event(name: "test.sentinel", condition: nil))
        await harness.engine.start()

        harness.events.publish(DomainEvent(name: "test.item.created", occurredAt: harness.clock.now()))
        harness.events.publish(DomainEvent(name: "test.sentinel", occurredAt: harness.clock.now()))
        // Events are handled in order, so once the sentinel ran the first event was handled too.
        #expect(await eventually { sentinel.count == 1 })
        await harness.engine.waitUntilIdle()
        #expect(ignored.count == 0)
        #expect(try await harness.engine.runs(workflowID: disabled.id).isEmpty)
        await harness.engine.stop()
    }

    @Test("events at the causation limit never start workflows")
    func depthLimit() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = try await harness.create(recordGraph(), trigger: .event(name: "test.ping", condition: nil))
        await harness.engine.start()

        harness.events.publish(DomainEvent(name: "test.ping", actor: .automation, occurredAt: harness.clock.now(), causationDepth: 3))
        harness.events.publish(DomainEvent(name: "test.ping", actor: .automation, occurredAt: harness.clock.now(), causationDepth: 2))
        #expect(await eventually { recorder.count == 1 })
        await harness.engine.waitUntilIdle()
        #expect(await harness.engine.statistics.eventsIgnoredForDepth == 1)
        let runs = try await harness.engine.runs(workflowID: workflow.id)
        #expect(runs.map(\.causationDepth) == [2])
        #expect(recorder.recorded.first?.context.causationDepth == 3)
        await harness.engine.stop()
    }

    @Test("a workflow never reacts to events published by its own runs")
    func selfLoop() async throws {
        let environment = try await AutomationHarness.make()
        let publisher = PublishingAction("test.publish", publishing: "test.ping", on: environment.events, clock: environment.clock)
        try environment.catalog.register(publisher)
        let workflow = try await environment.create(recordGraph("test.publish"), trigger: .event(name: "test.ping", condition: nil))
        await environment.engine.start()

        environment.events.publish(DomainEvent(name: "test.ping", occurredAt: environment.clock.now()))
        #expect(await eventually { await environment.engine.statistics.eventsIgnoredForCorrelation == 1 })
        await environment.engine.waitUntilIdle()
        #expect(try await environment.engine.runs(workflowID: workflow.id).count == 1)
        #expect(await environment.engine.statistics.eventsIgnoredForDepth == 0)
        await environment.engine.stop()
    }

    @Test("workflows triggering each other stop at the causation limit")
    func crossWorkflowLoop() async throws {
        let harness = try await AutomationHarness.make()
        try harness.catalog.register(PublishingAction("test.publishB", publishing: "test.b", on: harness.events, clock: harness.clock))
        try harness.catalog.register(PublishingAction("test.publishA", publishing: "test.a", on: harness.events, clock: harness.clock))
        let first = try await harness.create(recordGraph("test.publishB"), name: "A to B", trigger: .event(name: "test.a", condition: nil))
        let second = try await harness.create(recordGraph("test.publishA"), name: "B to A", trigger: .event(name: "test.b", condition: nil))
        await harness.engine.start()

        harness.events.publish(DomainEvent(name: "test.a", occurredAt: harness.clock.now()))
        #expect(await eventually { await harness.engine.statistics.eventsIgnoredForDepth == 1 })
        await harness.engine.waitUntilIdle()
        // a(0) → first run → b(1) → second run → a(2) → first run → b(3) is ignored.
        #expect(try await harness.engine.runs(workflowID: first.id).map(\.causationDepth).sorted() == [0, 2])
        #expect(try await harness.engine.runs(workflowID: second.id).map(\.causationDepth) == [1])
        await harness.engine.stop()
    }

    @Test("events applied by sync do not start workflows")
    func syncedEvents() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        try await harness.create(recordGraph(), trigger: .event(name: "test.item.created", condition: nil))
        await harness.engine.start()
        harness.events.publish(DomainEvent(name: "test.item.created", actor: .sync, occurredAt: harness.clock.now()))
        #expect(await eventually { await harness.engine.statistics.eventsIgnoredFromSync == 1 })
        await harness.engine.waitUntilIdle()
        #expect(recorder.count == 0)
        await harness.engine.stop()
    }

    @Test("stopping the engine unsubscribes from the bus")
    func stop() async throws {
        let harness = try await AutomationHarness.make()
        await harness.engine.start()
        await harness.engine.start()
        #expect(harness.events.subscriberCount == 1)
        await harness.engine.stop()
        #expect(await eventually { harness.events.subscriberCount == 0 })
        #expect(await harness.engine.isStarted == false)
    }

    @Test("the matcher reports why an event does not match")
    func matcher() {
        let event = DomainEvent(name: "a.b.c", attributes: ["n": 1], occurredAt: ManualTimeSource.referenceDate, causationDepth: 1)
        #expect(TriggerMatcher.decide(.manual, for: event, maxCausationDepth: 3) == .notAnEventTrigger)
        #expect(TriggerMatcher.decide(.event(name: "x.y.z", condition: nil), for: event, maxCausationDepth: 3) == .differentEvent)
        #expect(TriggerMatcher.decide(.event(name: "a.b.c", condition: nil), for: event, maxCausationDepth: 1) == .causationLimit)
        #expect(TriggerMatcher.decide(.event(name: "a.b.c", condition: .compare("trigger.attributes.n", .equals, 2)), for: event, maxCausationDepth: 3) == .conditionFailed)
        #expect(TriggerMatcher.decide(.event(name: "a.b.c", condition: .compare("trigger.attributes.n", .equals, 1)), for: event, maxCausationDepth: 3) == .matches)
    }
}
