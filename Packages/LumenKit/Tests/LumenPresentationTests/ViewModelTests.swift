import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenAutomation
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("App model")
struct AppModelTests {
    @Test("launch, deep links received during launch, commands and toasts")
    func launch() async throws {
        let (services, runtime) = try await makeServices()
        let model = AppModel(makeServices: { services })
        model.handle(url: try #require(URL(string: "lumen://tasks/upcoming")))
        await model.launch()
        #expect(model.services != nil)
        #expect(model.router.planPath == [.tasks(.upcoming)])

        await model.runCommand("navigate.insights")
        #expect(model.router.homePath == [.insights])

        _ = try await services.organization.tasks.create(TaskDraft(title: "Late", dueDate: services.today.adding(days: -2)))
        await model.runCommand("tasks.completeOverdueReview")
        #expect(model.toast == "Moved 1 task to today.")
        #expect(model.router.planPath == [.tasks(.today)])

        services.errors.report(ValidationError(field: "x", reason: "y"), context: "Testing banners")
        #expect(await eventually { model.banners.count == 1 })
        await runtime.shutdown()
    }

    @Test("a failing launch is presented and can be retried")
    func failedLaunch() async {
        struct Broken: Error {}
        let model = AppModel(makeServices: { throw Broken() })
        await model.launch()
        guard case .failed = model.phase else {
            Issue.record("expected failure")
            return
        }
    }
}

@MainActor
@Suite("Task view models")
struct TaskViewModelTests {
    @Test("optimistic completion and rollback when the task vanished")
    func optimistic() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let task = try await services.organization.tasks.create(TaskDraft(title: "Water plants", dueDate: services.today))
        clock.advance(by: 1)
        let ghost = try await services.organization.tasks.create(TaskDraft(title: "Ghost", dueDate: services.today))
        let list = TaskListViewModel(source: .smart(.today), services: services, locale: posix)
        await list.load()
        #expect(list.rows.map(\.task.title) == ["Water plants", "Ghost"])
        #expect(list.rows.first?.dueLabel == "Today")

        await list.toggleCompletion(task.id)
        #expect(list.rows.first { $0.id == task.id }?.isDone == true)
        #expect(try await services.organization.tasks.task(task.id)?.status == .done)

        // Delete underneath the list, then try to complete: the row rolls back and the error is reported.
        try await services.organization.tasks.delete(ghost.id)
        await list.toggleCompletion(ghost.id)
        #expect(list.rows.first { $0.id == ghost.id }?.isDone == false)
        #expect(services.errors.recentIssues.last?.context == "Updating a task")
        await runtime.shutdown()
    }

    @Test("completed rows stay checked in place in smart lists until the list is left")
    func completedRowsStay() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let first = try await services.organization.tasks.create(TaskDraft(title: "First"))
        clock.advance(by: 1)
        _ = try await services.organization.tasks.create(TaskDraft(title: "Second"))
        let list = TaskListViewModel(source: .smart(.inbox), services: services, locale: posix)
        await list.start()
        let position = try #require(list.rows.firstIndex { $0.id == first.id })

        await list.toggleCompletion(first.id)
        // Another change reloads the list; the inbox query no longer returns the completed task.
        clock.advance(by: 1)
        _ = try await services.organization.tasks.create(TaskDraft(title: "Third"))
        #expect(await eventually { list.rows.contains { $0.task.title == "Third" } })
        #expect(list.rows.first { $0.id == first.id }?.isDone == true)
        #expect(list.rows.firstIndex { $0.id == first.id } == position)

        // A second tap undoes it.
        await list.toggleCompletion(first.id)
        #expect(try await services.organization.tasks.task(first.id)?.isOpen == true)
        _ = try await services.organization.tasks.complete(first.id)

        // Coming back to the list shows open tasks only.
        let revisited = TaskListViewModel(source: .smart(.inbox), services: services, locale: posix)
        await revisited.load()
        #expect(!revisited.rows.contains { $0.id == first.id })
        await runtime.shutdown()
    }

    @Test("Plan counts open tasks per list and follows changes")
    func planCounts() async throws {
        let (services, runtime) = try await makeServices()
        let plan = PlanViewModel(services: services)
        await plan.start()
        #expect(plan.counts == [.today: 0, .upcoming: 0, .overdue: 0, .inbox: 0, .anytime: 0])
        #expect(plan.badge(for: .inbox) == nil)

        let inbox = try await services.organization.tasks.create(TaskDraft(title: "Loose end"))
        _ = try await services.organization.tasks.create(TaskDraft(title: "Late", dueDate: services.today.adding(days: -1)))
        #expect(await eventually { plan.badge(for: .inbox) == 1 && plan.badge(for: .overdue) == 1 })
        #expect(plan.badge(for: .today) == 1) // overdue work is also due today
        #expect(plan.isAlerting(.overdue))
        #expect(!plan.isAlerting(.inbox))

        _ = try await services.organization.tasks.complete(inbox.id)
        #expect(await eventually { plan.badge(for: .inbox) == nil })
        #expect(plan.badge(for: .completed) == nil) // never badged
        await runtime.shutdown()
    }

    @Test("quick capture shows what it understood and creates the task")
    func capture() async throws {
        let (services, runtime) = try await makeServices()
        let capture = QuickCaptureViewModel(services: services, locale: posix)
        capture.text = "Call Sam tomorrow at 5pm !high #family"
        #expect(capture.chips.map { $0.label.replacingOccurrences(of: "\u{202F}", with: " ") } == ["Tomorrow", "5:00 PM", "High", "#family"])
        let task = try #require(await capture.submit())
        #expect(task.title == "Call Sam")
        #expect(capture.text.isEmpty)
        #expect(capture.chips.isEmpty)
        #expect(!capture.canSubmit)
        await runtime.shutdown()
    }

    @Test("the editor tracks changes, saves and manages subtasks")
    func editor() async throws {
        let (services, runtime) = try await makeServices()
        let task = try await services.organization.tasks.create(TaskDraft(title: "Plan trip"))
        let editor = TaskEditorViewModel(taskID: task.id, services: services)
        await editor.load()
        #expect(!editor.hasChanges)
        editor.title = "Plan the trip"
        editor.priority = .high
        editor.dueDate = services.today.adding(days: 3)
        #expect(editor.hasChanges)
        #expect(await editor.save())
        #expect(!editor.hasChanges)
        #expect(try await services.organization.tasks.task(task.id)?.priority == .high)

        editor.newSubtaskTitle = "Book flights"
        await editor.addSubtask()
        #expect(editor.subtasks.map(\.title) == ["Book flights"])
        await editor.toggleSubtask(try #require(editor.subtasks.first?.id))
        #expect(editor.subtasks.first?.status == .done)

        editor.title = "   "
        #expect(await editor.save() == false)
        #expect(editor.error != nil)
        editor.discardChanges()
        #expect(editor.title == "Plan the trip")
        await runtime.shutdown()
    }

    @Test("projects list with progress and creation")
    func projects() async throws {
        let (services, runtime) = try await makeServices()
        let model = ProjectsViewModel(services: services)
        model.newName = "Website"
        #expect(model.canCreate)
        let project = try #require(await model.create())
        _ = try await services.organization.tasks.create(TaskDraft(title: "Copy", projectID: project.id))
        await model.load()
        #expect(model.state.value?.first?.progressLabel == "0 of 1 done")
        await runtime.shutdown()
    }
}

@MainActor
@Suite("Other view models")
struct OtherViewModelTests {
    @Test("Home loads and persists layout edits")
    func home() async throws {
        let (services, runtime) = try await makeServices()
        let home = HomeViewModel(services: services)
        await home.load()
        #expect(home.state.value?.greeting.title == "Good morning")
        #expect(home.state.value?.suggestions.contains { $0.kind == .setUpAssistant } == true)
        home.setVisible(true, for: .activity)
        #expect(await eventually { await services.home.layout().visibleItems.contains { $0.kind == .activity } })
        await runtime.shutdown()
    }

    @Test("the palette finds content and commands")
    func palette() async throws {
        let (services, runtime) = try await makeServices()
        _ = try await services.knowledge.notes.create(title: "Quarterly planning", body: "Goals and budget")
        let palette = CommandPaletteViewModel(services: services, debounce: 0)
        palette.query = "quarter"
        #expect(await eventually { palette.results?.results.first?.title == "Quarterly planning" })
        palette.query = "new task"
        #expect(await eventually { palette.results?.commands.first?.command.id == "create.task" })
        await runtime.shutdown()
    }

    @Test("the note editor autosaves and toggles checkboxes")
    func noteEditor() async throws {
        let (services, runtime) = try await makeServices()
        let note = try await services.knowledge.notes.create(title: "Packing", body: "- [ ] Passport\n- [ ] Charger")
        let editor = NoteEditorViewModel(noteID: note.id, services: services, autosaveDelay: 0.05)
        await editor.load()
        #expect(editor.structure.wordCount == 2)
        editor.toggleCheckbox(at: 0)
        #expect(editor.body.hasPrefix("- [x] Passport"))
        #expect(await eventually { (try? await services.knowledge.notes.note(note.id))?.body.hasPrefix("- [x]") == true })
        await runtime.shutdown()
    }

    @Test("chat without a configured model explains what to set up")
    func chatNotConfigured() async throws {
        let (services, runtime) = try await makeServices()
        let conversations = ConversationsViewModel(services: services)
        let conversation = try #require(await conversations.create())
        let chat = ChatViewModel(conversationID: conversation.id, services: services)
        await chat.start()
        #expect(!chat.isConfigured)
        chat.draft = "Plan my day"
        await chat.send()
        #expect(chat.failure != nil)
        #expect(!chat.isResponding)
        await runtime.shutdown()
    }

    @Test("the workflow editor builds a valid linear workflow that runs")
    func workflowEditor() async throws {
        let (services, runtime) = try await makeServices()
        let editor = WorkflowEditorViewModel(services: services)
        editor.name = "Weekly review"
        editor.addStep("organization.createTask")
        editor.steps[0].parameters["title"] = "Review the week"
        let workflow = try #require(await editor.save())
        #expect(workflow.graph.nodes.count == 2)

        let list = AutomationsViewModel(services: services)
        await list.load()
        #expect(list.state.value?.map(\.workflow.name) == ["Weekly review"])
        let run = try #require(await list.runNow(workflow.id))
        #expect(run.status == .succeeded)
        #expect(try await services.organization.tasks.list(.inbox).contains { $0.title == "Review the week" })

        let invalid = WorkflowEditorViewModel(services: services)
        invalid.name = "Broken"
        invalid.addStep("organization.createTask")
        #expect(await invalid.save() == nil)
        #expect(!invalid.issues.isEmpty)
        await runtime.shutdown()
    }

    @Test("settings show sync state, plugins and diagnostics")
    func settings() async throws {
        let (services, runtime) = try await makeServices()
        let settings = SettingsViewModel(services: services)
        await settings.load()
        #expect(settings.syncStatus?.state == .notConfigured)
        #expect(settings.plugins.count == 5)
        await settings.loadDiagnostics()
        #expect(settings.diagnostics?.integrityProblems == [])
        #expect(settings.diagnosticsReport().hasPrefix("Lumen 0.0.0 (0)"))
        settings.displayName = "Riley"
        await settings.saveDisplayName()
        #expect(await services.settings.value(HomeService.displayNameKey) == "Riley")
        await runtime.shutdown()
    }

    @Test("insights and notification preferences load and update")
    func insightsAndInbox() async throws {
        let (services, runtime) = try await makeServices()
        let insights = InsightsViewModel(services: services)
        await insights.load()
        #expect(insights.state.value != nil)
        #expect(insights.markdown?.isEmpty == false)

        let inbox = NotificationInboxViewModel(services: services)
        await inbox.load()
        await inbox.setAlerts(false, for: .automation)
        #expect(inbox.preferences.preference(for: .automation).deliversAlert == false)
        await runtime.shutdown()
    }
}
