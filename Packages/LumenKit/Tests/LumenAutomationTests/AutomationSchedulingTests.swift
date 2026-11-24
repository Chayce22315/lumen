import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
@testable import LumenAutomation
import LumenTestSupport

/// The clock starts on Saturday 21 November 2026, 09:00 UTC.
@Suite("AutomationEngine scheduling and recovery")
struct AutomationSchedulingTests {
    func dailyTrigger(at hour: Int, _ minute: Int) throws -> TriggerDefinition {
        .schedule(ScheduleTrigger(rule: .daily, anchor: try day(2026, 11, 21), time: try time(hour, minute)))
    }

    func recordGraph() -> WorkflowGraph {
        var builder = GraphBuilder()
        builder.add(action("test.record"), after: builder.trigger)
        return builder.graph
    }

    @Test("a schedule missed several times fires once, then continues from now")
    func catchUpOnce() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = try await harness.create(recordGraph(), trigger: try dailyTrigger(at: 9, 30))
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 21, 9, 30)))

        harness.clock.set(try utc(2026, 11, 24, 10, 0))
        let report = try await harness.engine.tick()
        #expect(report.firedRuns.count == 1)
        #expect(report.coalescedOccurrences[workflow.id] == 4)
        #expect(recorder.count == 1)
        let run = try #require(report.firedRuns.first)
        #expect(run.status == .succeeded)
        #expect(run.triggerPayload["type"] == "schedule")
        #expect(run.triggerPayload["attributes"]?["scheduledFor"] == "2026-11-21T09:30:00Z")
        #expect(run.triggerPayload["attributes"]?["coalescedOccurrences"] == 4)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 25, 9, 30)))
        #expect(report.nextWakeDate == (try utc(2026, 11, 25, 9, 30)))

        #expect(try await harness.engine.tick().firedRuns.isEmpty)
        #expect(recorder.count == 1)

        harness.clock.set(try utc(2026, 11, 25, 9, 30))
        let onTime = try await harness.engine.tick()
        #expect(onTime.coalescedOccurrences[workflow.id] == 1)
        #expect(recorder.count == 2)
    }

    @Test("nothing fires before the schedule is due; the wake date says when")
    func notDue() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        try await harness.create(recordGraph(), trigger: try dailyTrigger(at: 18, 0))
        let report = try await harness.engine.tick()
        #expect(report.firedRuns.isEmpty && report.resumedRuns.isEmpty && report.failures.isEmpty)
        #expect(report.nextWakeDate == (try utc(2026, 11, 21, 18, 0)))
        #expect(recorder.count == 0)
    }

    @Test("editing the schedule reschedules from now; other edits keep the pending occurrence")
    func edits() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        var workflow = try await harness.create(recordGraph(), trigger: try dailyTrigger(at: 9, 30))

        harness.clock.set(try utc(2026, 11, 21, 10, 0))
        workflow.name = "Renamed"
        workflow = try await harness.engine.update(workflow)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 21, 9, 30)))

        workflow.trigger = try dailyTrigger(at: 11, 0)
        workflow = try await harness.engine.update(workflow)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 21, 11, 0)))
        #expect(try await harness.engine.tick().firedRuns.isEmpty)

        workflow.trigger = .manual
        try await harness.engine.update(workflow)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == nil)
    }

    @Test("occurrences missed while disabled are not caught up after re-enabling")
    func reenable() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = try await harness.create(recordGraph(), trigger: try dailyTrigger(at: 9, 30))
        try await harness.engine.setEnabled(workflow.id, false)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == nil)

        harness.clock.set(try utc(2026, 11, 24, 12, 0))
        #expect(try await harness.engine.tick().firedRuns.isEmpty)
        try await harness.engine.setEnabled(workflow.id, true)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 25, 9, 30)))
        #expect(try await harness.engine.tick().firedRuns.isEmpty)
        #expect(recorder.count == 0)
    }

    @Test("schedules that arrive through sync are scheduled on the next tick without firing")
    func syncedSchedule() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        let workflow = Workflow(name: "Remote", trigger: try dailyTrigger(at: 8, 0), graph: recordGraph(), createdAt: try utc(2026, 11, 1))
        try await harness.database.write(origin: .remote) { db in try WorkflowRepository.upsertRow(workflow, in: db) }

        #expect(try await harness.engine.tick().firedRuns.isEmpty)
        #expect(try await harness.engine.nextFireDate(for: workflow.id) == (try utc(2026, 11, 22, 8, 0)))
        harness.clock.set(try utc(2026, 11, 22, 8, 0))
        #expect(try await harness.engine.tick().firedRuns.count == 1)
        #expect(recorder.count == 1)
    }

    /// Stores a run as a previous process would have left it: executing `actionNode`.
    func stageInterruptedRun(_ workflow: Workflow, actionNode: WorkflowNode.ID, harness: AutomationHarness) async throws -> WorkflowRun {
        let started = harness.clock.now()
        let run = WorkflowRun(
            workflowID: workflow.id,
            status: .running,
            triggerPayload: TriggerPayload.manual(at: started, actor: .user),
            startedAt: started,
            currentNodeID: actionNode
        )
        let trigger = RunStep(runID: run.id, nodeID: workflow.graph.triggerNode?.id ?? actionNode, sequence: 0, status: .succeeded, startedAt: started, finishedAt: started)
        let inFlight = RunStep(runID: run.id, nodeID: actionNode, sequence: 1, status: .running, startedAt: started)
        try await harness.database.write { db in
            try RunRepository.insert(run, in: db)
            try RunRepository.upsertStep(trigger, in: db)
            try RunRepository.upsertStep(inFlight, in: db)
        }
        return run
    }

    @Test("interrupted runs are resumed from the step in progress when the policy allows")
    func recoverAndResume() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let ids = builder.chain([action("test.record"), .end])
        let workflow = try await harness.create(builder.graph, policy: FailurePolicy(retry: .never, resumeInterruptedRuns: true))
        let staged = try await stageInterruptedRun(workflow, actionNode: ids[0], harness: harness)
        harness.clock.advance(by: 300)

        let report = try await harness.engine.recoverInterruptedRuns()
        #expect(report.interruptedRuns.map(\.id) == [staged.id])
        #expect(report.interruptedRuns.first?.status == .interrupted)
        #expect(report.resumedRuns.map(\.status) == [.succeeded])
        #expect(recorder.count == 1)
        let steps = try #require(try await harness.engine.runDetail(staged.id)).steps
        #expect(steps.map(\.status) == [.succeeded, .interrupted, .succeeded, .succeeded])
        #expect(steps.map(\.nodeID) == [builder.trigger, ids[0], ids[0], ids[1]])
        #expect(try await harness.engine.recoverInterruptedRuns().interruptedRuns.isEmpty)
    }

    @Test("interrupted runs stay interrupted and are reported when the policy forbids resuming")
    func recoverWithoutResume() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let ids = builder.chain([action("test.record")])
        let workflow = try await harness.create(builder.graph, policy: FailurePolicy(retry: .never, resumeInterruptedRuns: false))
        let staged = try await stageInterruptedRun(workflow, actionNode: ids[0], harness: harness)
        let events = EventRecorder(bus: harness.events, filter: EventFilter(names: [AutomationEvents.runFailed]))

        let report = try await harness.engine.recoverInterruptedRuns()
        #expect(report.resumedRuns.isEmpty)
        #expect(recorder.count == 0)
        let detail = try #require(try await harness.engine.runDetail(staged.id))
        #expect(detail.run.status == .interrupted)
        #expect(detail.run.finishedAt == harness.clock.now())
        #expect(detail.run.errorMessage == "Lumen stopped while this run was in progress.")
        #expect(detail.steps.last?.status == .interrupted)
        let failed = await events.waitForEvents(1)
        #expect(failed.first?.attributes["status"] == "interrupted")
        #expect(failed.first?.entity == staged.reference)

        // An interrupted run can still be dismissed by cancelling it.
        #expect(try await harness.engine.cancel(staged.id))
        #expect(try await harness.engine.runDetail(staged.id)?.run.status == .cancelled)
    }

    @Test("recovery leaves runs executing in this process alone")
    func recoverSkipsActiveRuns() async throws {
        let blocking = BlockingAction()
        let harness = try await AutomationHarness.make(actions: [blocking])
        var builder = GraphBuilder()
        builder.add(action("test.block"), after: builder.trigger)
        let workflow = try await harness.create(builder.graph)
        let engine = harness.engine
        let execution = Task { try await engine.run(workflow.id) }
        #expect(await eventually { blocking.hasStarted })

        #expect(try await engine.recoverInterruptedRuns().interruptedRuns.isEmpty)
        let active = try #require(try await engine.runs(workflowID: workflow.id).first)
        #expect(active.status == .running)
        try await engine.cancel(active.id)
        #expect(try await execution.value.status == .cancelled)
    }
}
