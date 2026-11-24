import Foundation
import Testing
import LumenFoundation
import LumenOrganization
import LumenTestSupport

func makeDay(_ y: Int, _ m: Int, _ d: Int) -> CalendarDate {
    CalendarDate(year: y, month: m, day: d) ?? CalendarDate(Date(timeIntervalSince1970: 0), calendar: .testUTC)
}

func makeTask(
    _ title: String = "Task",
    status: TaskStatus = .todo,
    priority: TaskPriority = .none,
    due: CalendarDate? = nil,
    time: TimeOfDay? = nil,
    start: CalendarDate? = nil,
    project: Project.ID? = nil,
    blockedBy: [TaskItem.ID] = [],
    created: TimeInterval = 0
) -> TaskItem {
    let date = ManualTimeSource.referenceDate.addingTimeInterval(created)
    return TaskItem(
        title: title, status: status, priority: priority, dueDate: due, dueTime: time, startDate: start,
        projectID: project, blockedBy: blockedBy, createdAt: date, updatedAt: date
    )
}

@Suite("Organization logic")
struct OrganizationLogicTests {
    let today = makeDay(2026, 11, 21)

    @Test("validation cleans titles and tags and rejects inconsistent schedules")
    func validation() throws {
        var task = makeTask("  Write   report  ")
        task.tags = ["#Work", "work", " Deep Focus "]
        let cleaned = try TaskValidator.validated(task)
        #expect(cleaned.title == "Write report")
        #expect(cleaned.tags == ["work", "deep-focus"])

        #expect(throws: ValidationError.self) { try TaskValidator.validated(makeTask("   ")) }
        var badTime = makeTask("x")
        badTime.dueTime = TimeOfDay(hour: 9, minute: 0)
        #expect(throws: ValidationError.self) { try TaskValidator.validated(badTime) }
        #expect(throws: ValidationError.self) { try TaskValidator.validated(makeTask("x", due: makeDay(2026, 1, 1), start: makeDay(2026, 2, 1))) }
        var recurringWithoutDue = makeTask("x")
        recurringWithoutDue.recurrence = .daily
        #expect(throws: ValidationError.self) { try TaskValidator.validated(recurringWithoutDue) }
    }

    @Test("dependency graph detects direct and transitive cycles")
    func cycles() {
        let a = TaskItem.ID(), b = TaskItem.ID(), c = TaskItem.ID()
        var graph = DependencyGraph()
        graph.add(task: a, blockedBy: b)
        graph.add(task: b, blockedBy: c)
        #expect(graph.wouldCreateCycle(task: c, blockedBy: a))
        #expect(graph.wouldCreateCycle(task: b, blockedBy: a))
        #expect(graph.wouldCreateCycle(task: a, blockedBy: a))
        #expect(!graph.wouldCreateCycle(task: a, blockedBy: c))
        #expect(graph.dependents(of: b) == [a])
    }

    @Test("blocked state ignores closed and missing blockers; topological order puts blockers first")
    func blocking() {
        let blocker = makeTask("blocker")
        let done = makeTask("done", status: .done)
        let dependent = makeTask("dependent", blockedBy: [blocker.id, done.id, TaskItem.ID()])
        let graph = DependencyGraph(tasks: [blocker, done, dependent])
        let statuses = [blocker.id: TaskStatus.todo, done.id: .done, dependent.id: .todo]
        #expect(graph.isBlocked(dependent.id, statuses: statuses))
        #expect(!graph.isBlocked(dependent.id, statuses: [blocker.id: .done, done.id: .done]))
        let order = graph.topologicalOrder(of: [dependent.id, blocker.id, done.id])
        #expect(order.firstIndex(of: blocker.id).map { $0 < (order.firstIndex(of: dependent.id) ?? 0) } == true)
    }

    @Test("smart lists")
    func smartLists() {
        let overdue = makeTask("overdue", due: makeDay(2026, 11, 19))
        let dueToday = makeTask("today", due: today)
        let started = makeTask("started", start: makeDay(2026, 11, 20))
        let deferred = makeTask("deferred", start: makeDay(2026, 12, 1))
        let upcoming = makeTask("upcoming", due: makeDay(2026, 11, 25))
        let far = makeTask("far", due: makeDay(2026, 12, 25))
        let inbox = makeTask("inbox")
        let done = makeTask("done", status: .done, due: today)
        let all = [overdue, dueToday, started, deferred, upcoming, far, inbox, done]

        #expect(TaskOrdering.list(.today, from: all, today: today).map(\.title) == ["overdue", "today", "started"])
        #expect(TaskOrdering.list(.overdue, from: all, today: today).map(\.title) == ["overdue"])
        #expect(TaskOrdering.list(.upcoming, from: all, today: today).map(\.title) == ["upcoming"])
        #expect(Set(TaskOrdering.list(.inbox, from: all, today: today).map(\.title)) == ["started", "deferred", "inbox"])
        #expect(!TaskOrdering.list(.anytime, from: all, today: today).map(\.title).contains("deferred"))
        #expect(TaskOrdering.list(.completed, from: all, today: today).map(\.title) == ["done"])
    }

    @Test("ordering: due date, then priority, then time")
    func ordering() {
        let lowSoon = makeTask("low soon", priority: .low, due: today)
        let highSoon = makeTask("high soon", priority: .high, due: today)
        let timedLate = makeTask("timed", priority: .high, due: today, time: TimeOfDay(hour: 15, minute: 0))
        let later = makeTask("later", priority: .urgent, due: makeDay(2026, 11, 22))
        let undated = makeTask("undated", priority: .urgent)
        let sorted = [undated, later, lowSoon, highSoon, timedLate].sorted(by: TaskOrdering.actionableFirst)
        #expect(sorted.map(\.title) == ["timed", "high soon", "low soon", "later", "undated"])
    }

    @Test("completing a recurring task produces the next instance from the series anchor")
    func recurrenceAdvance() throws {
        var task = makeTask("Pay rent", due: makeDay(2026, 1, 31))
        task.recurrence = .monthly
        task.recurrenceAnchor = makeDay(2026, 1, 31)
        let february = try #require(RecurringTaskAdvancer.nextInstance(after: task, today: makeDay(2026, 1, 30), now: Date()))
        #expect(february.dueDate == makeDay(2026, 2, 28))
        #expect(february.seriesID == task.id.rawValue)
        // From the clamped February instance, March returns to the 31st because the anchor is kept.
        let march = try #require(RecurringTaskAdvancer.nextInstance(after: february, today: makeDay(2026, 2, 27), now: Date()))
        #expect(march.dueDate == makeDay(2026, 3, 31))
        #expect(march.seriesID == task.id.rawValue)
    }

    @Test("an overdue recurring task skips missed occurrences and respects counted series")
    func recurrenceCatchUp() throws {
        var task = makeTask("Stretch", due: makeDay(2026, 11, 10))
        task.recurrence = .daily
        task.recurrenceAnchor = makeDay(2026, 11, 10)
        let next = try #require(RecurringTaskAdvancer.nextInstance(after: task, today: today, now: Date()))
        #expect(next.dueDate == makeDay(2026, 11, 22))

        var counted = makeTask("Course", due: makeDay(2026, 11, 20))
        counted.recurrence = RecurrenceRule(frequency: .daily, end: .afterOccurrences(3))
        counted.recurrenceAnchor = makeDay(2026, 11, 19)
        let last = try #require(RecurringTaskAdvancer.nextInstance(after: counted, today: makeDay(2026, 11, 20), now: Date()))
        #expect(last.dueDate == makeDay(2026, 11, 21))
        #expect(RecurringTaskAdvancer.nextInstance(after: last, today: makeDay(2026, 11, 21), now: Date()) == nil)
        #expect(RecurringTaskAdvancer.nextInstance(after: makeTask("plain", due: today), today: today, now: Date()) == nil)
    }

    @Test("project progress, next action and health")
    func progress() {
        let project = Project(name: "Launch", startDate: makeDay(2026, 11, 1), targetDate: makeDay(2026, 11, 30), createdAt: Date(), updatedAt: Date())
        let blocker = makeTask("design", due: makeDay(2026, 11, 25), project: project.id)
        let tasks = [
            makeTask("done", status: .done, project: project.id),
            makeTask("cancelled", status: .cancelled, project: project.id),
            blocker,
            makeTask("build", priority: .urgent, project: project.id, blockedBy: [blocker.id]),
            makeTask("other project"),
        ]
        let progress = ProjectProgressCalculator.progress(for: project, tasks: tasks, today: today, calendar: .testUTC)
        #expect(progress.totalTasks == 4)
        #expect(progress.completedTasks == 1)
        #expect(progress.openTasks == 2)
        #expect(abs(progress.fractionComplete - 1.0 / 3.0) < 1e-9)
        #expect(progress.nextAction?.title == "design")
        // 20 of 29 days elapsed (69%) with 33% done → at risk.
        #expect(progress.health == .atRisk)
        #expect(progress.daysUntilTarget == 9)

        let late = ProjectProgressCalculator.progress(for: project, tasks: tasks, today: makeDay(2026, 12, 2), calendar: .testUTC)
        #expect(late.health == .offTrack)
        var closed = project
        closed.status = .completed
        #expect(ProjectProgressCalculator.progress(for: closed, tasks: tasks, today: today, calendar: .testUTC).health == .closed)
    }
}
