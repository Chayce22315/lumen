import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenAutomation
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("Workflow editor")
struct WorkflowEditorViewModelTests {
    @Test("conditions branch to different steps, and the saved workflow runs the right branch")
    func branches() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services, locale: posix)
        editor.name = "Triage"
        let trigger = try #require(editor.graph.triggerNode?.id)

        let check = try #require(editor.add(.condition, after: trigger))
        var condition = try #require(editor.conditionDraft(for: check))
        condition.rules = [ConditionDraft.Rule(path: "input.priority", comparison: .greaterThanOrEqual, valueKind: .number, value: "3")]
        #expect(editor.update(check, title: "Urgent?", condition: condition))
        #expect(editor.summary(of: check) == "input.priority is at least 3")

        let urgent = try #require(editor.add(.action("organization.createTask"), after: check, port: .whenTrue))
        let later = try #require(editor.add(.action("organization.createTask"), after: check, port: .whenFalse))
        for (step, title) in [(urgent, "Do it now"), (later, "Do it later")] {
            var draft = try #require(editor.actionDraft(for: step))
            draft.texts["title"] = title
            #expect(editor.update(step, action: draft))
        }
        #expect(editor.outputs(of: check).map { $0.target } == [urgent, later])
        #expect(editor.outline.map(\.nodeID) == [trigger, check, urgent, later])
        #expect(editor.outline.map(\.depth) == [0, 0, 1, 1])
        #expect(!editor.issues.hasErrors)

        let workflow = try #require(await editor.save())
        #expect(workflow.graph == editor.graph)
        _ = try await services.automation.engine.run(workflow.id, input: ["priority": 4])
        _ = try await services.automation.engine.run(workflow.id, input: ["priority": 1])
        let titles = try await services.organization.tasks.list(.inbox).map(\.title).sorted()
        #expect(titles == ["Do it later", "Do it now"])
        await runtime.shutdown()
    }

    @Test("invalid connections are refused with a reason and change nothing")
    func refusals() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services, locale: posix)
        let trigger = try #require(editor.graph.triggerNode?.id)
        let first = try #require(editor.append(.delay))
        let second = try #require(editor.append(.action("notifications.send")))
        let before = editor.graph

        #expect(!editor.connect(second, port: .next, to: first))
        #expect(editor.rejection?.message == "That connection would make the workflow loop.")
        #expect(!editor.connect(first, port: .next, to: trigger))
        #expect(editor.rejection?.message == "Nothing can connect into the trigger.")
        #expect(!editor.connect(trigger, port: .next, to: second))
        #expect(editor.rejection?.message == "That output is already connected. Remove the existing connection first.")
        #expect(!editor.connect(first, port: .whenTrue, to: second))
        #expect(editor.rejection?.message == "That step can't connect from this output.")
        #expect(!editor.remove(trigger))
        #expect(editor.rejection?.message == "Every workflow needs its trigger.")
        #expect(editor.graph == before)

        // Valid targets offered for a free output exclude the step itself, the trigger and loops.
        let end = try #require(editor.add(.end, after: second))
        #expect(editor.disconnect(second, port: .next))
        #expect(editor.connectionTargets(from: second, port: .next).map(\.id) == [end])
        #expect(editor.connect(second, port: .next, to: end))
        #expect(editor.rejection == nil)

        // End steps have no outputs to add after.
        #expect(editor.add(.condition, after: end) == nil)
        #expect(editor.rejection?.message == "That step can't connect from this output.")
        editor.dismissRejection()
        #expect(editor.rejection == nil)

        // Settings that don't build are refused without touching the graph.
        let check = try #require(editor.add(.condition, after: first))
        let graphBefore = editor.graph
        let bad = ConditionDraft(rules: [ConditionDraft.Rule(path: "input.count", comparison: .equals, valueKind: .number, value: "lots")])
        #expect(!editor.update(check, condition: bad))
        #expect(editor.rejection?.message == "“lots” isn't a number.")
        #expect(!editor.update(first, delay: DelayDraft(amount: 31, unit: .days)))
        #expect(editor.rejection?.message == "A delay can be at most 30 days.")
        #expect(editor.graph == graphBefore)
        await runtime.shutdown()
    }

    @Test("every accepted edit can be undone, newest first")
    func undo() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services, locale: posix)
        let start = editor.graph
        #expect(!editor.canUndo)
        let wait = try #require(editor.append(.delay))
        let afterAdd = editor.graph
        let position = try #require(editor.node(wait)?.position)
        #expect(editor.move(wait, to: CanvasPoint(x: position.x + 47, y: position.y + 3)))
        #expect(editor.node(wait)?.position == WorkflowCanvasGeometry.snap(CanvasPoint(x: position.x + 47, y: position.y + 3)))
        #expect(!editor.move(wait, to: try #require(editor.node(wait)?.position))) // no-op moves aren't edits
        #expect(editor.update(wait, delay: DelayDraft(amount: 2, unit: .hours)))
        #expect(editor.summary(of: wait) == "Wait 2 hours")
        #expect(!editor.connect(wait, port: .next, to: wait)) // refused edits leave nothing to undo

        editor.undo()
        #expect(editor.summary(of: wait) == "Wait 5 minutes")
        editor.undo()
        #expect(editor.graph == afterAdd)
        editor.undo()
        #expect(editor.graph == start)
        #expect(!editor.canUndo)
        editor.undo() // nothing left: no change
        #expect(editor.graph == start)
        await runtime.shutdown()
    }

    @Test("arranging lays branches side by side and is one undoable edit")
    func arrange() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services, locale: posix)
        let trigger = try #require(editor.graph.triggerNode?.id)
        let check = try #require(editor.add(.condition, after: trigger))
        let yes = try #require(editor.add(.end, after: check, port: .whenTrue))
        let no = try #require(editor.add(.end, after: check, port: .whenFalse))
        #expect(editor.move(yes, to: CanvasPoint(x: 900, y: 900)))
        #expect(editor.arrange())
        let positions = WorkflowAutoLayout.positions(for: editor.graph)
        #expect(editor.node(yes)?.position == positions[yes])
        #expect((editor.node(yes)?.position.x ?? 0) < (editor.node(no)?.position.x ?? 0))
        #expect(!editor.arrange()) // already arranged
        editor.undo()
        #expect(editor.node(yes)?.position == CanvasPoint(x: 900, y: 900))
        await runtime.shutdown()
    }

    @Test("editing an existing workflow keeps its branches, positions and custom trigger")
    func loadExisting() async throws {
        let (services, runtime) = try await makeServices()
        var graph = WorkflowGraph.starter()
        let trigger = try #require(graph.triggerNode?.id)
        let check = WorkflowNode(title: "High?", position: CanvasPoint(x: 40, y: 160), kind: .condition(.compare("trigger.attributes.priority", .greaterThan, 2)))
        let yes = WorkflowNode(title: "Ping", position: CanvasPoint(x: -100, y: 300), kind: .action(actionID: "notifications.send", parameters: ["title": .template("{{ trigger.attributes.priority }}")]))
        graph.nodes += [check, yes]
        graph.edges += [WorkflowEdge(from: trigger, to: check.id), WorkflowEdge(from: check.id, to: yes.id, port: .whenTrue)]
        let definition = TriggerDefinition.event(name: OrganizationEvent.taskCompleted, condition: .compare("trigger.attributes.status", .equals, "done"))
        let workflow = try await services.automation.engine.create(WorkflowDraft(name: "Escalate", trigger: definition, graph: graph))

        let editor = WorkflowEditorViewModel(services: services, workflowID: workflow.id, locale: posix)
        #expect(!editor.isLoaded)
        await editor.load()
        #expect(editor.isLoaded)
        #expect(editor.name == "Escalate")
        #expect(editor.graph == graph)
        #expect(editor.trigger == .custom(definition))
        #expect(editor.triggerSummary == "Task completed, with a condition")
        #expect(!editor.canUndo)

        editor.summary = "Pings on important completions"
        let saved = try #require(await editor.save())
        #expect(saved.graph == graph)
        #expect(saved.trigger == definition)
        #expect(saved.summary == "Pings on important completions")

        let missing = WorkflowEditorViewModel(services: services, workflowID: Workflow.ID(), locale: posix)
        await missing.load()
        #expect(missing.error?.title == "Workflow not found")
        #expect(!missing.isLoaded)
        await runtime.shutdown()
    }

    @Test("event triggers offer their attributes as condition fields")
    func conditionFields() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services, locale: posix)
        #expect(editor.conditionFields.map(\.path) == ["trigger.name", "trigger.actor"])
        editor.trigger = .event(OrganizationEvent.taskCompleted)
        let priority = try #require(editor.conditionFields.first { $0.path == "trigger.attributes.priority" })
        #expect(priority.valueKind == .number)
        #expect(editor.triggerSummary == "Task completed")
        editor.trigger = .daily(try #require(TimeOfDay(hour: 7, minute: 30)))
        #expect(editor.triggerSummary.replacingOccurrences(of: "\u{202F}", with: " ") == "Every day at 7:30 AM")
        await runtime.shutdown()
    }
}

@MainActor
@Suite("Run detail")
struct RunDetailViewModelTests {
    @Test("each step shows its title, branch, inputs and output; a rerun starts a new run")
    func detail() async throws {
        let (services, runtime) = try await makeServices()
        var graph = WorkflowGraph.starter()
        let trigger = try #require(graph.triggerNode?.id)
        let check = WorkflowNode(title: "Big?", kind: .condition(.compare("input.size", .greaterThan, 10)))
        let create = WorkflowNode(title: "Make a task", kind: .action(actionID: "organization.createTask", parameters: ["title": .template("Size {{ input.size }}")]))
        graph.nodes += [check, create]
        graph.edges += [WorkflowEdge(from: trigger, to: check.id), WorkflowEdge(from: check.id, to: create.id, port: .whenTrue)]
        let workflow = try await services.automation.engine.create(WorkflowDraft(name: "Sizes", graph: graph))
        let run = try await services.automation.engine.run(workflow.id, input: ["size": 12])

        let model = RunDetailViewModel(services: services, runID: run.id)
        await model.load()
        let detail = try #require(model.state.value)
        #expect(detail.workflowName == "Sizes")
        #expect(detail.run.status == .succeeded)
        #expect(!detail.isRerun)
        #expect(detail.input == [JSONPreview.Line(path: "size", value: "12")])
        #expect(detail.steps.map(\.title) == ["Trigger", "Big?", "Make a task"])
        #expect(detail.steps.map(\.kind) == [.trigger, .condition, .action])
        #expect(detail.steps[0].output.isEmpty) // the trigger's payload is shown once, as the run's trigger
        #expect(detail.steps[1].branch == "Took the “true” branch")
        #expect(detail.steps[1].inputs == [JSONPreview.Line(path: "input.size", value: "12")])
        #expect(detail.steps[2].inputs.contains(JSONPreview.Line(path: "title", value: "Size 12")))
        #expect(detail.steps[2].attempts == 1 && detail.steps[2].retries == 0)
        #expect(detail.steps.allSatisfy { $0.duration != nil })
        #expect(!model.canCancel)

        let again = try #require(await model.rerun())
        #expect(again.id != run.id)
        #expect(model.latestRerun?.id == again.id)
        let replay = RunDetailViewModel(services: services, runID: again.id)
        await replay.load()
        #expect(replay.state.value?.isRerun == true)
        #expect(try await services.organization.tasks.list(.inbox).filter { $0.title == "Size 12" }.count == 2)

        let gone = RunDetailViewModel(services: services, runID: WorkflowRun.ID())
        await gone.load()
        #expect(gone.state.error?.title == "Run not found")
        await runtime.shutdown()
    }

    @Test("steps of removed nodes and failures with retries are explained")
    func failures() async throws {
        let (services, runtime) = try await makeServices()
        var graph = WorkflowGraph.starter()
        let trigger = try #require(graph.triggerNode?.id)
        let complete = WorkflowNode(title: "Complete", kind: .action(actionID: "organization.completeTask", parameters: ["task": .literal(.string(UUID().uuidString))]))
        graph.nodes.append(complete)
        graph.edges.append(WorkflowEdge(from: trigger, to: complete.id))
        var workflow = try await services.automation.engine.create(WorkflowDraft(name: "Fails", graph: graph, failurePolicy: FailurePolicy(retry: .never)))
        let run = try await services.automation.engine.run(workflow.id)
        #expect(run.status == .failed)

        // Remove the failing step from the definition: history still shows it.
        workflow.graph = WorkflowGraph(nodes: [try #require(graph.triggerNode)])
        _ = try await services.automation.engine.update(workflow)
        let model = RunDetailViewModel(services: services, runID: run.id)
        await model.load()
        let steps = try #require(model.state.value?.steps)
        #expect(steps.last?.title == "Removed step")
        #expect(steps.last?.kind == .removed)
        #expect(steps.last?.status == .failed)
        #expect(steps.last?.errorMessage?.isEmpty == false)
        await runtime.shutdown()
    }
}
