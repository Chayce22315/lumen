import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("WorkflowExecutor")
struct WorkflowExecutorTests {
    let noRetry = FailurePolicy(retry: .never)

    @Test("a linear run executes every step in order and feeds outputs forward")
    func linear() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "greeting", title: "Greeting", isRequired: true)])
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let format = builder.add(action(FormatTextAction.id, ["text": .template("hello {{ input.name }}"), "case": .literal("uppercase")]), after: builder.trigger)
        let record = builder.add(action("test.record", ["greeting": .template("{{ \(stepPath(format, ".text")) }}!")]), after: format)
        let end = builder.add(.end, after: record)
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id, input: ["name": "Ada"])

        #expect(run.status == .succeeded)
        #expect(run.finishedAt == harness.clock.now())
        #expect(run.currentNodeID == nil)
        #expect(recorder.recorded.map { $0.parameters["greeting"] } == ["HELLO ADA!"])
        let steps = try await harness.steps(of: run)
        #expect(steps.map(\.nodeID) == [builder.trigger, format, record, end])
        #expect(steps.map(\.sequence) == [0, 1, 2, 3])
        #expect(steps.allSatisfy { $0.status == .succeeded && $0.finishedAt != nil })
        #expect(steps[0].output?["type"] == "manual")
        #expect(steps[1].output == ["text": "HELLO ADA", "length": 9])
        #expect(steps[1].message == "Formatted 9 characters")
        #expect(steps[1].attemptCount == 1)
    }

    @Test("conditions follow the true branch")
    func trueBranch() async throws {
        let yes = RecordingAction("test.yes")
        let no = RecordingAction("test.no")
        let harness = try await AutomationHarness.make(actions: [yes, no])
        var builder = GraphBuilder()
        let check = builder.add(.condition(.compare("input.priority", .greaterThan, 2)), after: builder.trigger)
        builder.add(action("test.yes"), after: check, port: .whenTrue)
        builder.add(action("test.no"), after: check, port: .whenFalse)
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id, input: ["priority": 3])
        #expect(run.status == .succeeded)
        #expect((yes.count, no.count) == (1, 0))
        let steps = try await harness.steps(of: run)
        #expect(steps.first { $0.nodeID == check }?.output == ["result": true])
    }

    @Test("conditions follow the false branch, and a missing branch ends the run")
    func falseBranch() async throws {
        let yes = RecordingAction("test.yes")
        let no = RecordingAction("test.no")
        let harness = try await AutomationHarness.make(actions: [yes, no])
        var builder = GraphBuilder()
        let check = builder.add(.condition(.compare("input.priority", .greaterThan, 2)), after: builder.trigger)
        builder.add(action("test.yes"), after: check, port: .whenTrue)
        builder.add(action("test.no"), after: check, port: .whenFalse)
        let workflow = try await harness.create(builder.graph)

        let low = try await harness.engine.run(workflow.id, input: ["priority": 1])
        #expect(low.status == .succeeded)
        #expect((yes.count, no.count) == (0, 1))

        var onlyTrue = GraphBuilder()
        let gate = onlyTrue.add(.condition(.exists("input.flag")), after: onlyTrue.trigger)
        onlyTrue.add(action("test.yes"), after: gate, port: .whenTrue)
        let gated = try await harness.create(onlyTrue.graph)
        let skipped = try await harness.engine.run(gated.id)
        #expect(skipped.status == .succeeded)
        #expect(try await harness.steps(of: skipped).count == 2)
        #expect(yes.count == 0)
    }

    @Test("transient failures are retried with backoff until the action succeeds")
    func retryThenSuccess() async throws {
        let flaky = FlakyAction(failures: 2, error: AutomationActionError.transient("busy"))
        let harness = try await AutomationHarness.make(actions: [flaky])
        var builder = GraphBuilder()
        let step = builder.add(action("test.flaky"), after: builder.trigger)
        let policy = FailurePolicy(retry: RetryPolicy(maxAttempts: 3, initialDelay: 1, multiplier: 2, maxDelay: 30, jitter: 0))
        let workflow = try await harness.create(builder.graph, policy: policy)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .succeeded)
        #expect(flaky.attemptCount == 3)
        #expect(harness.sleeper.recorded == [1, 2])
        let recorded = try await harness.steps(of: run).first { $0.nodeID == step }
        #expect(recorded?.attemptCount == 3)
        #expect(recorded?.output == ["attempt": 3])
        #expect(harness.environment.logs.entries(atLeast: .warning).filter { $0.message == "Workflow step failed; retrying" }.count == 2)
    }

    @Test("unknown errors count as transient; retries stop at the policy's limit")
    func retryExhaustion() async throws {
        let flaky = FlakyAction(failures: 5, error: Glitch())
        let harness = try await AutomationHarness.make(actions: [flaky])
        var builder = GraphBuilder()
        builder.add(action("test.flaky"), after: builder.trigger)
        let workflow = try await harness.create(builder.graph, policy: FailurePolicy(retry: RetryPolicy(maxAttempts: 2, initialDelay: 4, jitter: 0)))

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .failed)
        #expect(flaky.attemptCount == 2)
        #expect(harness.sleeper.recorded == [4])
        #expect(try await harness.steps(of: run).last?.attemptCount == 2)
    }

    @Test("a permanent failure is not retried and stops the run where it failed")
    func permanentStop() async throws {
        let failing = FlakyAction(failures: 10, error: AutomationActionError.permanent("The list is gone."))
        let after = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [failing, after])
        var builder = GraphBuilder()
        let step = builder.add(action("test.flaky"), title: "Add to list", after: builder.trigger)
        builder.add(action("test.record"), after: step)
        let workflow = try await harness.create(builder.graph, policy: FailurePolicy(retry: .standard, onFailure: .stop))
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(modules: ["automation"]))

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .failed)
        #expect(run.errorMessage == "“Add to list” failed: The list is gone.")
        #expect(run.currentNodeID == step)
        #expect(failing.attemptCount == 1)
        #expect(harness.sleeper.recorded.isEmpty)
        #expect(after.count == 0)
        let steps = try await harness.steps(of: run)
        #expect(steps.map(\.status) == [.succeeded, .failed])
        #expect(steps.last?.errorMessage == "The list is gone.")
        #expect(!harness.environment.logs.entries(atLeast: .error).isEmpty)

        let events = await recorder.waitForEvents(2)
        #expect(events.map(\.name) == [AutomationEvents.runStarted, AutomationEvents.runFailed])
        #expect(events.last?.attributes["failedSteps"] == 1)
    }

    @Test("with onFailure continue, the run carries on and later steps can see the error")
    func permanentContinue() async throws {
        let failing = FlakyAction(failures: 10, error: AutomationActionError.permanent("Nope"))
        let after = RecordingAction(parameters: [ActionParameterSpec(name: "error", title: "Error")])
        let harness = try await AutomationHarness.make(actions: [failing, after])
        var builder = GraphBuilder()
        let step = builder.add(action("test.flaky"), after: builder.trigger)
        builder.add(action("test.record", ["error": .template("{{ steps.\(step.uuidString).error }}")]), after: step)
        let workflow = try await harness.create(builder.graph, policy: FailurePolicy(retry: .never, onFailure: .continue))
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(names: [AutomationEvents.runSucceeded]))

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .succeeded)
        #expect(run.errorMessage == nil)
        #expect(after.recorded.first?.parameters["error"] == "Nope")
        #expect(try await harness.steps(of: run).map(\.status) == [.succeeded, .failed, .succeeded])
        #expect(await recorder.waitForEvents(1).first?.attributes["failedSteps"] == 1)
    }

    @Test("short delays sleep inline through the injected sleeper")
    func inlineDelay() async throws {
        let harness = try await AutomationHarness.make()
        var builder = GraphBuilder()
        let ids = builder.chain([.delay(seconds: 45), .delay(seconds: 0), .end])
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .succeeded)
        #expect(harness.sleeper.recorded == [45])
        let steps = try await harness.steps(of: run)
        #expect(steps.first { $0.nodeID == ids[0] }?.output == ["seconds": 45])
    }

    @Test("a long delay parks the run, and tick resumes it once the delay has passed")
    func longDelay() async throws {
        let before = RecordingAction("test.before")
        let after = RecordingAction("test.after")
        let harness = try await AutomationHarness.make(actions: [before, after])
        var builder = GraphBuilder()
        let ids = builder.chain([action("test.before"), .delay(seconds: 3_600), action("test.after"), .end])
        let workflow = try await harness.create(builder.graph)
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(names: [AutomationEvents.runStarted, AutomationEvents.runSucceeded]))
        let start = harness.clock.now()

        let parked = try await harness.engine.run(workflow.id)
        #expect(parked.status == .waiting)
        #expect(parked.resumeAt == start.addingTimeInterval(3_600))
        #expect(parked.currentNodeID == ids[1])
        #expect(parked.finishedAt == nil)
        #expect((before.count, after.count) == (1, 0))
        #expect(harness.sleeper.recorded.isEmpty)
        #expect(try await harness.steps(of: parked).map(\.status) == [.succeeded, .succeeded, .waiting])
        #expect(try await harness.engine.nextWakeDate() == parked.resumeAt)

        harness.clock.advance(by: 1_800)
        #expect(try await harness.engine.tick().resumedRuns.isEmpty)
        #expect(after.count == 0)

        harness.clock.advance(by: 1_800)
        let report = try await harness.engine.tick()
        #expect(report.resumedRuns.map(\.id) == [parked.id])
        #expect(report.resumedRuns.first?.status == .succeeded)
        #expect(report.nextWakeDate == nil)
        #expect((before.count, after.count) == (1, 1))
        let steps = try await harness.steps(of: parked)
        #expect(steps.map(\.nodeID) == [builder.trigger] + ids)
        #expect(steps.allSatisfy { $0.status == .succeeded })
        #expect(steps.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(await recorder.waitForEvents(2).map(\.name) == [AutomationEvents.runStarted, AutomationEvents.runSucceeded])
    }

    @Test("an executing run can be cancelled")
    func cancelExecuting() async throws {
        let blocking = BlockingAction()
        let after = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [blocking, after])
        var builder = GraphBuilder()
        builder.chain([action("test.block"), action("test.record")])
        let workflow = try await harness.create(builder.graph)
        let recorder = EventRecorder(bus: harness.events, filter: EventFilter(names: [AutomationEvents.runCancelled]))

        let engine = harness.engine
        let execution = Task { try await engine.run(workflow.id) }
        #expect(await eventually { blocking.hasStarted })
        let active = try #require(try await engine.runs(workflowID: workflow.id).first)
        #expect(active.status == .running)
        #expect(await engine.executor.activeRunIDs == [active.id])
        #expect(try await engine.cancel(active.id))

        let run = try await execution.value
        #expect(run.status == .cancelled)
        #expect(after.count == 0)
        #expect(try await harness.steps(of: run).map(\.status) == [.succeeded, .cancelled])
        #expect(await recorder.waitForEvents(1).map(\.entity) == [run.reference])
        #expect(await engine.executor.activeRunIDs.isEmpty)
        #expect(try await engine.cancel(run.id) == false)
    }

    @Test("a waiting run can be cancelled and is never resumed")
    func cancelWaiting() async throws {
        let after = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [after])
        var builder = GraphBuilder()
        builder.chain([.delay(seconds: 7_200), action("test.record")])
        let workflow = try await harness.create(builder.graph)

        let parked = try await harness.engine.run(workflow.id)
        #expect(try await harness.engine.cancel(parked.id))
        let detail = try #require(try await harness.engine.runDetail(parked.id))
        #expect(detail.run.status == .cancelled)
        #expect(detail.run.resumeAt == nil)
        #expect(detail.steps.last?.status == .cancelled)

        harness.clock.advance(by: 10_000)
        #expect(try await harness.engine.tick().resumedRuns.isEmpty)
        #expect(after.count == 0)
        let unknown = WorkflowRun.ID()
        await #expect(throws: AutomationError.runNotFound(unknown)) { try await harness.engine.cancel(unknown) }
    }

    @Test("runs stop at the configured step limit")
    func stepLimit() async throws {
        let harness = try await AutomationHarness.make(configuration: AutomationEngine.Configuration(execution: WorkflowExecutor.Configuration(maximumStepsPerRun: 5)))
        var builder = GraphBuilder()
        builder.chain(Array(repeating: action(SetVariableAction.id, ["value": .literal(1)]), count: 8))
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .failed)
        #expect(run.errorMessage == "The run stopped after 5 steps, the limit for a single run.")
        #expect(try await harness.steps(of: run).count == 5)
    }

    @Test("the default safety net is 500 steps")
    func defaultStepLimit() async throws {
        let harness = try await AutomationHarness.make()
        var builder = GraphBuilder()
        builder.chain(Array(repeating: action(SetVariableAction.id, ["value": .literal(1)]), count: 520))
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .failed)
        #expect(try await harness.steps(of: run).count == 500)
    }

    @Test("Stop Workflow ends the run successfully without the remaining steps")
    func stopRun() async throws {
        let after = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [after])
        var builder = GraphBuilder()
        let ids = builder.chain([action(StopRunAction.id, ["reason": .literal("Nothing to do")]), action("test.record")])
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .succeeded)
        #expect(after.count == 0)
        let steps = try await harness.steps(of: run)
        #expect(steps.map(\.nodeID) == [builder.trigger, ids[0]])
        #expect(steps.last?.message == "Nothing to do")
    }

    @Test("actions receive an automation context correlated with the run")
    func invocationContext() async throws {
        let recorder = RecordingAction()
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        let step = builder.add(action("test.record"), after: builder.trigger)
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id, context: ActionContext(actor: .assistant, causationDepth: 1))
        let invocation = try #require(recorder.recorded.first)
        #expect(invocation.context == ActionContext(actor: .automation, correlationID: run.id.rawValue, causationDepth: 2))
        #expect(invocation.runID == run.id)
        #expect(invocation.workflowID == workflow.id)
        #expect(invocation.nodeID == step)
        #expect(invocation.attempt == 1)
        #expect(run.correlationID == run.id.rawValue)
        #expect(run.causationDepth == 1)
        #expect(run.triggerPayload["actor"] == "assistant")
    }

    @Test("a required parameter that resolves to nothing fails the step without calling the action")
    func missingRuntimeValue() async throws {
        let recorder = RecordingAction(parameters: [ActionParameterSpec(name: "title", title: "Title", isRequired: true)])
        let harness = try await AutomationHarness.make(actions: [recorder])
        var builder = GraphBuilder()
        builder.add(action("test.record", ["title": .template("{{ input.title }}")]), after: builder.trigger)
        let workflow = try await harness.create(builder.graph)

        let run = try await harness.engine.run(workflow.id)
        #expect(run.status == .failed)
        #expect(recorder.count == 0)
        let step = try #require(try await harness.steps(of: run).last)
        #expect(step.errorMessage == "No value for “Title”.")
        #expect(step.attemptCount == 0)
        #expect(step.warnings == ["Parameter “title”: “input.title” has no value"])
    }

    @Test("the executor runs saved workflows directly and reports unavailable actions as step failures")
    func directExecutor() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [AutomationEngine.schema])
        let executor = WorkflowExecutor(
            database: environment.database,
            catalog: AutomationCatalog(),
            events: environment.events,
            timeSource: environment.clock,
            logger: environment.logger("automation"),
            sleeper: { _ in }
        )
        var builder = GraphBuilder()
        builder.chain([action(SetVariableAction.id, ["value": .literal("kept")]), action("plugin.uninstalled")])
        let workflow = Workflow(name: "Direct", graph: builder.graph, failurePolicy: FailurePolicy(retry: .never), createdAt: environment.clock.now())
        try await environment.database.write { db in try WorkflowRepository.save(workflow, in: db) }

        let run = try await executor.start(workflow, trigger: TriggerPayload.manual(at: environment.clock.now(), actor: .user))
        #expect(run.status == .failed)
        #expect(run.errorMessage == "“Step 2” failed: The action “plugin.uninstalled” isn't available on this device.")
        #expect(await executor.activeRunIDs.isEmpty)
        await #expect(throws: AutomationError.runNotResumable(run.id)) { try await executor.resume(run, workflow: workflow) }

        let noTrigger = Workflow(name: "Empty", graph: WorkflowGraph(), createdAt: environment.clock.now())
        try await environment.database.write { db in try WorkflowRepository.save(noTrigger, in: db) }
        let failed = try await executor.start(noTrigger, trigger: .null)
        #expect(failed.status == .failed)
        #expect(failed.errorMessage == "The workflow has no trigger step.")
    }
}
