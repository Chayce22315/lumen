import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenOrganization
import LumenTestSupport

struct OrganizationHarness {
    let environment: CoreTestEnvironment
    let tasks: TaskService
    let projects: ProjectService
    let calendars: CalendarService
    let agenda: AgendaService

    static func make(external: (any ExternalCalendarSource)? = nil) async throws -> OrganizationHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [OrganizationSchema.schema])
        let tasks = TaskService(database: environment.database, events: environment.events, timeSource: environment.clock, calendar: environment.calendar, logger: environment.logger("tasks"))
        let projects = ProjectService(database: environment.database, events: environment.events, timeSource: environment.clock, calendar: environment.calendar, logger: environment.logger("projects"))
        let calendars = CalendarService(database: environment.database, events: environment.events, timeSource: environment.clock, calendar: environment.calendar, external: external, logger: environment.logger("calendar"))
        let agenda = AgendaService(tasks: tasks, calendars: calendars, timeSource: environment.clock, calendar: environment.calendar)
        return OrganizationHarness(environment: environment, tasks: tasks, projects: projects, calendars: calendars, agenda: agenda)
    }

    func changes() async throws -> [ChangeRecord] {
        try await environment.database.read { db in try db.changes(after: 0, limit: 10_000) }
    }
}

@Suite("TaskService")
struct TaskServiceTests {
    @Test("creating records a change and publishes an event with the caller's actor")
    func create() async throws {
        let harness = try await OrganizationHarness.make()
        let recorder = EventRecorder(bus: harness.environment.events)
        let task = try await harness.tasks.create(TaskDraft(title: "Draft agenda", priority: .high, tags: ["Work"]), context: ActionContext(actor: .assistant))
        #expect(task.tags == ["work"])
        #expect(try await harness.tasks.task(task.id) == task)
        let changes = try await harness.changes()
        #expect(changes.map(\.entity) == [task.reference])
        #expect(try changes.first?.payload?.decode(as: TaskItem.self) == task)
        let events = await recorder.waitForEvents(1)
        #expect(events.first?.name == OrganizationEvent.taskCreated)
        #expect(events.first?.actor == .assistant)
        #expect(events.first?.attributes["priority"] == .number(3))
    }

    @Test("invalid input is rejected before anything is written")
    func validation() async throws {
        let harness = try await OrganizationHarness.make()
        await #expect(throws: ValidationError.self) { try await harness.tasks.create(TaskDraft(title: " ")) }
        await #expect(throws: OrganizationError.projectNotFound(Project.ID(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()))) {
            try await harness.tasks.create(TaskDraft(title: "x", projectID: Project.ID(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID())))
        }
        #expect(try await harness.changes().isEmpty)
    }

    @Test("quick capture resolves the project by name")
    func capture() async throws {
        let harness = try await OrganizationHarness.make()
        let project = try await harness.projects.create(name: "Home Admin")
        let (task, parsed) = try await harness.tasks.capture("Renew passport next week !urgent +home")
        #expect(task.title == "Renew passport")
        #expect(task.projectID == project.id)
        #expect(task.priority == .urgent)
        #expect(task.dueDate == makeDay(2026, 11, 23))
        #expect(parsed.recognized.contains("+home"))
    }

    @Test("completing a recurring task keeps history and schedules the next instance")
    func completeRecurring() async throws {
        let harness = try await OrganizationHarness.make()
        let recorder = EventRecorder(bus: harness.environment.events)
        let task = try await harness.tasks.create(TaskDraft(title: "Review budget", dueDate: makeDay(2026, 11, 21), recurrence: .weekly))
        let completion = try await harness.tasks.complete(task.id)
        #expect(completion.completed.status == .done)
        #expect(completion.completed.completedAt == harness.environment.clock.now())
        let next = try #require(completion.nextInstance)
        #expect(next.dueDate == makeDay(2026, 11, 28))
        #expect(next.recurrenceAnchor == makeDay(2026, 11, 21))
        #expect(try await harness.tasks.list(.upcoming).map(\.id) == [next.id])
        let names = await recorder.waitForEvents(3).map(\.name)
        #expect(names == [OrganizationEvent.taskCreated, OrganizationEvent.taskCompleted, OrganizationEvent.taskCreated])

        // Completing again is a no-op without new events or instances.
        let again = try await harness.tasks.complete(task.id)
        #expect(again.nextInstance == nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.events.count == 3)
    }

    @Test("completing the last blocker unblocks dependents; cycles are refused")
    func dependencies() async throws {
        let harness = try await OrganizationHarness.make()
        let design = try await harness.tasks.create(TaskDraft(title: "Design"))
        let review = try await harness.tasks.create(TaskDraft(title: "Review"))
        let build = try await harness.tasks.create(TaskDraft(title: "Build"))
        _ = try await harness.tasks.addDependency(build.id, blockedBy: design.id)
        _ = try await harness.tasks.addDependency(build.id, blockedBy: review.id)
        await #expect(throws: OrganizationError.dependencyCycle) {
            try await harness.tasks.addDependency(design.id, blockedBy: build.id)
        }
        #expect(try await harness.tasks.blockedTaskIDs() == [build.id])
        #expect(try await harness.tasks.complete(design.id).unblocked.isEmpty)
        #expect(try await harness.tasks.complete(review.id).unblocked.map(\.id) == [build.id])
        #expect(try await harness.tasks.blockedTaskIDs().isEmpty)
    }

    @Test("deleting cascades to subtasks and detaches dependents")
    func deleteCascade() async throws {
        let harness = try await OrganizationHarness.make()
        let parent = try await harness.tasks.create(TaskDraft(title: "Trip"))
        let child = try await harness.tasks.create(TaskDraft(title: "Book hotel", parentID: parent.id))
        let grandchild = try await harness.tasks.create(TaskDraft(title: "Compare prices", parentID: child.id))
        let dependent = try await harness.tasks.create(TaskDraft(title: "Pack"))
        _ = try await harness.tasks.addDependency(dependent.id, blockedBy: child.id)

        try await harness.tasks.delete(parent.id)
        #expect(try await harness.tasks.task(parent.id) == nil)
        #expect(try await harness.tasks.task(child.id) == nil)
        #expect(try await harness.tasks.task(grandchild.id) == nil)
        #expect(try await harness.tasks.task(dependent.id)?.blockedBy == [])
        let deletions = try await harness.changes().filter { $0.operation == .delete }
        #expect(Set(deletions.map(\.entity.id)) == [parent.id.rawValue, child.id.rawValue, grandchild.id.rawValue])
        await #expect(throws: OrganizationError.taskNotFound(parent.id)) { try await harness.tasks.delete(parent.id) }
    }

    @Test("updates re-anchor recurrence and status changes route through completion")
    func updates() async throws {
        let harness = try await OrganizationHarness.make()
        let task = try await harness.tasks.create(TaskDraft(title: "Water plants", dueDate: makeDay(2026, 11, 21), recurrence: .daily))
        let moved = try await harness.tasks.update(task.id, TaskChanges(dueDate: .some(makeDay(2026, 11, 24))))
        #expect(moved.recurrenceAnchor == makeDay(2026, 11, 24))
        let cleared = try await harness.tasks.update(task.id, TaskChanges(recurrence: .some(nil)))
        #expect(cleared.recurrence == nil)
        #expect(cleared.recurrenceAnchor == nil)
        let done = try await harness.tasks.update(task.id, TaskChanges(status: .done))
        #expect(done.status == .done)
        let reopened = try await harness.tasks.update(task.id, TaskChanges(status: .todo))
        #expect(reopened.status == .todo)
        #expect(reopened.completedAt == nil)
    }

    @Test("summary counts due, overdue and completed-today tasks")
    func summary() async throws {
        let harness = try await OrganizationHarness.make()
        _ = try await harness.tasks.create(TaskDraft(title: "a", dueDate: makeDay(2026, 11, 21)))
        _ = try await harness.tasks.create(TaskDraft(title: "b", dueDate: makeDay(2026, 11, 18)))
        let c = try await harness.tasks.create(TaskDraft(title: "c"))
        _ = try await harness.tasks.complete(c.id)
        let summary = try await harness.tasks.summary()
        #expect(summary == TaskSummary(dueToday: 1, overdue: 1, completedToday: 1, open: 2))
        #expect(try await harness.tasks.list(.completed).map(\.id) == [c.id])
    }
}

@Suite("ProjectService")
struct ProjectServiceTests {
    @Test("progress reflects tasks; deleting can keep tasks")
    func progressAndDelete() async throws {
        let harness = try await OrganizationHarness.make()
        let project = try await harness.projects.create(name: "  Website  ", color: .teal, targetDate: makeDay(2026, 12, 31))
        #expect(project.name == "Website")
        let first = try await harness.tasks.create(TaskDraft(title: "Copy", projectID: project.id))
        _ = try await harness.tasks.create(TaskDraft(title: "Images", projectID: project.id))
        _ = try await harness.tasks.complete(first.id)
        let progress = try await harness.projects.progress(of: project.id)
        #expect(progress.completedTasks == 1)
        #expect(progress.fractionComplete == 0.5)
        #expect(try await harness.projects.liveProjectProgress().map(\.project.id) == [project.id])

        try await harness.projects.delete(project.id, deletingTasks: false)
        #expect(try await harness.projects.project(project.id) == nil)
        #expect(try await harness.tasks.tasks(TaskQuery(projectID: .some(nil))).count == 2)
    }

    @Test("status changes stamp completion")
    func status() async throws {
        let harness = try await OrganizationHarness.make()
        let project = try await harness.projects.create(name: "Move")
        let completed = try await harness.projects.setStatus(project.id, .completed)
        #expect(completed.completedAt != nil)
        #expect(try await harness.projects.setStatus(project.id, .active).completedAt == nil)
        await #expect(throws: ValidationError.self) {
            try await harness.projects.update(project.id, ProjectChanges(startDate: .some(makeDay(2027, 1, 2)), targetDate: .some(makeDay(2027, 1, 1))))
        }
    }
}

final class FakeExternalCalendar: ExternalCalendarSource {
    let authorized: Bool
    let failure: (any Error)?
    let items: [EventOccurrence]

    init(authorized: Bool = true, failure: (any Error)? = nil, items: [EventOccurrence] = []) {
        self.authorized = authorized
        self.failure = failure
        self.items = items
    }

    func isAuthorized() async -> Bool { authorized }

    func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence] {
        if let failure { throw failure }
        return items.filter { $0.end > start && $0.start < end }
    }
}

@Suite("CalendarService and AgendaService")
struct CalendarServiceTests {
    @Test("a default calendar is created once")
    func defaultCalendar() async throws {
        let harness = try await OrganizationHarness.make()
        let first = try await harness.calendars.ensureDefaultCalendar()
        let second = try await harness.calendars.ensureDefaultCalendar()
        #expect(first == second)
        #expect(try await harness.calendars.calendars().count == 1)
        await #expect(throws: OrganizationError.lastCalendar) { try await harness.calendars.deleteCalendar(first.id) }
    }

    @Test("events are validated, hidden calendars are filtered, external events merge in")
    func occurrences() async throws {
        let now = ManualTimeSource.referenceDate
        let external = EventOccurrence(
            source: .external(identifier: "ext-1", calendarName: "Work"), title: "Imported", location: "",
            start: now.addingTimeInterval(7_200), end: now.addingTimeInterval(9_000), isAllDay: false,
            firstDay: makeDay(2026, 11, 21), lastDay: makeDay(2026, 11, 21), color: .slate)
        let harness = try await OrganizationHarness.make(external: FakeExternalCalendar(items: [external]))
        let personal = try await harness.calendars.ensureDefaultCalendar()
        let hidden = try await harness.calendars.createCalendar(name: "Hidden", color: .rose)
        _ = try await harness.calendars.updateCalendar(hidden.id, isVisible: false)

        await #expect(throws: ValidationError.self) {
            try await harness.calendars.createEvent(EventDraft(title: "Bad", timing: .timed(start: now, end: now.addingTimeInterval(-1), timeZoneIdentifier: "UTC")))
        }
        _ = try await harness.calendars.createEvent(EventDraft(calendarID: personal.id, title: "Standup", timing: .timed(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(5_400), timeZoneIdentifier: "UTC"), recurrence: .daily))
        _ = try await harness.calendars.createEvent(EventDraft(calendarID: hidden.id, title: "Secret", timing: .timed(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(5_400), timeZoneIdentifier: "UTC")))

        let window = try await harness.calendars.occurrences(from: now, to: now.addingTimeInterval(3 * 86_400))
        #expect(window.filter { $0.title == "Standup" }.count == 3)
        #expect(!window.contains { $0.title == "Secret" })
        #expect(window.contains { $0.title == "Imported" })
    }

    @Test("a failing external source is logged and skipped")
    func externalFailure() async throws {
        struct Denied: Error {}
        let harness = try await OrganizationHarness.make(external: FakeExternalCalendar(failure: Denied()))
        let now = ManualTimeSource.referenceDate
        _ = try await harness.calendars.createEvent(EventDraft(title: "Local", timing: .timed(start: now.addingTimeInterval(60), end: now.addingTimeInterval(120), timeZoneIdentifier: "UTC")))
        let window = try await harness.calendars.occurrences(from: now, to: now.addingTimeInterval(86_400))
        #expect(window.map(\.title) == ["Local"])
        #expect(harness.environment.logs.entries(atLeast: .error).count == 1)
    }

    @Test("today overview combines tasks and events")
    func todayOverview() async throws {
        let harness = try await OrganizationHarness.make()
        let now = ManualTimeSource.referenceDate
        _ = try await harness.calendars.createEvent(EventDraft(title: "Lunch", timing: .timed(start: now.addingTimeInterval(3 * 3_600), end: now.addingTimeInterval(4 * 3_600), timeZoneIdentifier: "UTC")))
        _ = try await harness.tasks.create(TaskDraft(title: "Overdue", dueDate: makeDay(2026, 11, 19)))
        _ = try await harness.tasks.create(TaskDraft(title: "Today", priority: .high, dueDate: makeDay(2026, 11, 21)))
        let overview = try await harness.agenda.todayOverview()
        #expect(overview.summary.overdue == 1)
        #expect(overview.nextEvent?.title == "Lunch")
        #expect(overview.focusTasks.map(\.title) == ["Overdue", "Today"])
        #expect(overview.agenda.entryCount == 3)
    }
}
