import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenIntelligence
import LumenAutomation
import LumenApplication
import LumenTestSupport

@Suite("Assistant and automation integration")
struct AssistantAndAutomationIntegrationTests {
    func toolContext() -> ToolContext {
        ToolContext(conversationID: Conversation.ID(), action: ActionContext(actor: .assistant), turnID: UUID())
    }

    @Test("built-in tools and actions are registered from feature contributions")
    func registration() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let names = Set(app.services.intelligence.tools.all.map(\.definition.name))
        #expect(names.isSuperset(of: ["search_lumen", "list_tasks", "create_task", "complete_task", "get_agenda", "create_note", "read_note", "list_workflows", "run_workflow"]))
        let actions = Set(app.services.automation.catalog.descriptors.map(\.id))
        #expect(actions.isSuperset(of: ["organization.createTask", "organization.completeTask", "knowledge.createNote", "knowledge.appendToNote", "notifications.send"]))
        let statuses = await app.services.plugins.host.statuses()
        #expect(statuses.allSatisfy { $0.state == .active })
        await app.runtime.shutdown()
    }

    @Test("assistant tools act on real data with the assistant as actor")
    func tools() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let services = app.services
        let recorder = EventRecorder(bus: services.events, filter: EventFilter(names: [OrganizationEvent.taskCreated]))
        _ = try await services.organization.projects.create(name: "Launch")
        let registry = services.intelligence.tools
        let create = try #require(registry.tool(named: "create_task"))
        let created = try await create.execute(["title": "Draft press release", "due_date": "2026-11-23", "priority": "high", "project": "launch"], context: toolContext())
        #expect(!created.isError)
        let reference = try #require(created.referencedEntities.first)
        #expect(await recorder.waitForEvents(1).first?.actor == .assistant)

        let list = try #require(registry.tool(named: "list_tasks"))
        #expect(try await list.execute(["list": "upcoming"], context: toolContext()).text.contains("Draft press release"))

        let search = try #require(registry.tool(named: "search_lumen"))
        #expect(try await eventually { try await search.execute(["query": "press"], context: toolContext()).referencedEntities.contains(reference) })

        let complete = try #require(registry.tool(named: "complete_task"))
        #expect(try await complete.execute(["task_id": .string(reference.uri)], context: toolContext()).text.hasPrefix("Completed “Draft press release”"))

        let bad = try await create.execute(["title": "x", "due_date": "next tuesday"], context: toolContext())
        #expect(bad.isError)
        await app.runtime.shutdown()
    }

    @Test("without a model or key the assistant reports it isn't set up")
    func configuration() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        #expect(await app.services.isAssistantConfigured() == false)
        try await app.services.settings.set(ModelSelection(providerID: .anthropic, modelID: "claude-sonnet-5-5"), for: AssistantSettings.defaultModel)
        #expect(await app.services.isAssistantConfigured() == false)
        try app.services.secrets.setSecret("test-key", for: ProviderID.anthropic.apiKeySecret)
        #expect(await app.services.isAssistantConfigured())
        let home = try await app.services.home.snapshot(assistantConfigured: false)
        #expect(home.suggestions.contains { $0.kind == .setUpAssistant })
        await app.runtime.shutdown()
    }

    @Test("the approval broker declines without an interface and relays answers with one")
    func approvals() async throws {
        let broker = ToolApprovalBroker(timeout: 5)
        let definition = ToolDefinition(name: "create_task", description: "", inputSchema: [:])
        #expect(await broker.approve(tool: definition, input: ["title": "x"]) == false)

        let stream = await broker.requests()
        let answer = Task { await broker.approve(tool: definition, input: ["title": "Buy milk"]) }
        var iterator = stream.makeAsyncIterator()
        let request = try #require(await iterator.next())
        #expect(request.summary == "Create the task “Buy milk”")
        await broker.resolve(request.id, approved: true)
        #expect(await answer.value)
    }

    @Test("an event-triggered workflow runs a built-in action end to end")
    func workflow() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let services = app.services
        let trigger = WorkflowNode(title: "When a task is completed", kind: .trigger)
        let action = WorkflowNode(title: "Log it", kind: .action(actionID: "knowledge.createNote", parameters: [
            "title": .literal("Win log"),
            "body": .template("Finished {{trigger.entity.id}}"),
        ]))
        let graph = WorkflowGraph(nodes: [trigger, action], edges: [WorkflowEdge(from: trigger.id, to: action.id)])
        let workflow = try await services.automation.engine.create(WorkflowDraft(
            name: "Celebrate",
            trigger: .event(name: OrganizationEvent.taskCompleted, condition: nil),
            graph: graph
        ))
        let task = try await services.organization.tasks.create(TaskDraft(title: "Ship it"))
        _ = try await services.organization.tasks.complete(task.id)

        #expect(try await eventually { try await services.knowledge.notes.resolveTitle("Win log") != nil })
        let note = try #require(try await services.knowledge.notes.resolveTitle("Win log"))
        #expect(note.body == "Finished \(task.id.uuidString)")
        let runs = try await services.automation.engine.runs(workflowID: workflow.id, limit: 5)
        #expect(runs.first?.status == .succeeded)
        // The note was created by the automation, not the user (analytics records asynchronously).
        #expect(try await eventually {
            try await services.analytics.service.recentEvents(limit: 20, names: [KnowledgeEvents.noteCreated]).first?.actor == .automation
        })
        await app.runtime.shutdown()
    }
}
