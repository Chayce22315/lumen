import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication
import LumenWidgetData
import LumenTestSupport

private func scratchQueue() -> WidgetActionQueue {
    WidgetActionQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lumen-queue-\(UUID().uuidString)"))
}

private let referenceDate = Date(timeIntervalSince1970: 1_795_251_600)

@Suite("Widget action queue")
struct WidgetActionQueueTests {
    @Test("actions persist across instances, duplicates are ignored and removal is selective")
    func basics() throws {
        let queue = scratchQueue()
        #expect(try queue.pending().isEmpty)
        let task = UUID()
        let first = WidgetAction(kind: .completeTask, taskID: task, requestedAt: referenceDate)
        #expect(try queue.enqueue(first))
        #expect(try !queue.enqueue(WidgetAction(kind: .completeTask, taskID: task, requestedAt: referenceDate.addingTimeInterval(5))))
        let second = WidgetAction(kind: .completeTask, taskID: UUID(), requestedAt: referenceDate.addingTimeInterval(10))
        #expect(try queue.enqueue(second))

        let reopened = WidgetActionQueue(url: queue.url)
        #expect(try reopened.pending() == [first, second])
        try reopened.remove([first.id])
        #expect(try queue.pending() == [second])
        try queue.remove([])
        try queue.remove([UUID()])
        #expect(try queue.pending() == [second])
    }

    @Test("the queue is bounded: the oldest actions give way")
    func capacity() throws {
        let queue = scratchQueue()
        let actions = (0..<(WidgetActionQueue.capacity + 5)).map {
            WidgetAction(kind: .completeTask, taskID: UUID(), requestedAt: referenceDate.addingTimeInterval(TimeInterval($0)))
        }
        for action in actions { try queue.enqueue(action) }
        let pending = try queue.pending()
        #expect(pending.count == WidgetActionQueue.capacity)
        #expect(pending.first == actions[5])
        #expect(pending.last == actions.last)
    }

    @Test("an unreadable file is replaced instead of blocking later actions")
    func corruptFile() throws {
        let queue = scratchQueue()
        try FileManager.default.createDirectory(at: queue.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: queue.url)
        #expect(try queue.pending().isEmpty)
        #expect(try queue.enqueue(WidgetAction(kind: .completeTask, taskID: UUID(), requestedAt: referenceDate)))
        #expect(try queue.pending().count == 1)
    }

    @Test("concurrent writers never lose each other's actions")
    func concurrentWriters() async throws {
        let queue = scratchQueue()
        let count = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try queue.enqueue(WidgetAction(kind: .completeTask, taskID: UUID(), requestedAt: referenceDate.addingTimeInterval(TimeInterval(index))))
                }
            }
            try await group.waitForAll()
        }
        #expect(try queue.pending().count == count)
    }
}

@Suite("Widget snapshot")
struct WidgetSnapshotCompatibilityTests {
    private func line(_ title: String, overdue: Bool = false, dueToday: Bool = false) -> WidgetSnapshot.TaskLine {
        WidgetSnapshot.TaskLine(id: UUID(), title: title, dueTime: nil, isOverdue: overdue, priority: 0, isDueToday: dueToday)
    }

    @Test("snapshots written before the completion fields still decode")
    func oldSnapshot() throws {
        let json = """
        {"completedToday":1,"dueToday":2,"generatedAt":1795251600,"nextEvent":null,"overdue":0,"projects":[],
         "tasks":[{"id":"7D2B8C1E-2B6A-4C55-9C51-6E3D7B9A1F00","isOverdue":false,"priority":2,"title":"Call Sam"}],"version":1}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-old-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        let snapshot = try #require(try WidgetSnapshotStore(url: url).read())
        #expect(snapshot.tasks.first?.isCompleted == false)
        #expect(snapshot.tasks.first?.isDueToday == false)
        #expect(snapshot.todayProgress == WidgetSnapshot.TodayProgress(completed: 1, remaining: 2))
    }

    @Test("checking a task on the widget updates the line and the counts at once")
    func optimisticCompletion() {
        let late = line("Late", overdue: true)
        let today = line("Today", dueToday: true)
        let started = line("Started")
        let snapshot = WidgetSnapshot(generatedAt: referenceDate, dueToday: 1, overdue: 1, completedToday: 2, tasks: [late, today, started], nextEvent: nil, projects: [])
        #expect(snapshot.todayProgress.fraction == 0.5)
        #expect(snapshot.nextOpenTask == late)

        let afterLate = snapshot.markingCompleted(late.id)
        #expect(afterLate.overdue == 0)
        #expect(afterLate.dueToday == 1)
        #expect(afterLate.completedToday == 3)
        #expect(afterLate.tasks.first?.isCompleted == true)
        #expect(afterLate.nextOpenTask?.id == today.id)

        let afterToday = afterLate.markingCompleted(today.id)
        #expect(afterToday.dueToday == 0)
        #expect(afterToday.todayProgress == WidgetSnapshot.TodayProgress(completed: 4, remaining: 0))
        #expect(afterToday.todayProgress.fraction == 1)

        // Neither due today nor overdue: only the completed count moves. Repeats change nothing.
        let afterStarted = afterToday.markingCompleted(started.id)
        #expect(afterStarted.completedToday == 5)
        #expect(afterStarted.markingCompleted(started.id) == afterStarted)
        #expect(afterStarted.markingCompleted(UUID()) == afterStarted)
        #expect(afterStarted.nextOpenTask == nil)
        #expect(WidgetSnapshot.empty(at: referenceDate).todayProgress.fraction == 0)
    }
}

@Suite("Applying widget actions")
struct ApplyWidgetActionsTests {
    @Test("tasks checked on the widget are completed through the task service and leave the snapshot")
    func completesTasks() async throws {
        let app = try await RunningApp.start()
        let tasks = app.services.organization.tasks
        let water = try await tasks.create(TaskDraft(title: "Water plants", dueDate: app.services.today))
        let call = try await tasks.create(TaskDraft(title: "Call Sam", dueDate: app.services.today))
        let gone = try await tasks.create(TaskDraft(title: "Gone", dueDate: app.services.today))
        let done = try await tasks.create(TaskDraft(title: "Done already", dueDate: app.services.today))
        _ = try await tasks.complete(done.id)
        try await tasks.delete(gone.id)
        await app.services.widgets.refresh()

        let queue = app.services.widgets.actionQueue
        #expect(queue.url.deletingLastPathComponent() == app.services.configuration.widgetSnapshotURL.deletingLastPathComponent())
        let now = app.clock.now()
        for task in [water, gone, done] {
            try queue.enqueue(WidgetAction(kind: .completeTask, taskID: task.id.rawValue, requestedAt: now))
        }

        #expect(await app.runtime.applyWidgetActions() == 1)
        #expect(try await tasks.task(water.id)?.status == .done)
        #expect(try await tasks.task(call.id)?.isOpen == true)
        #expect(try queue.pending().isEmpty)
        let snapshot = try #require(try WidgetSnapshotStore(url: app.services.configuration.widgetSnapshotURL).read())
        #expect(snapshot.tasks.map(\.title) == ["Call Sam"])
        #expect(snapshot.completedToday == 2)
        #expect(snapshot.tasks.first?.isDueToday == true)

        // Nothing pending: nothing to do.
        #expect(await app.runtime.applyWidgetActions() == 0)
        await app.runtime.shutdown()
    }

    @Test("becoming active applies pending widget actions")
    func onActivation() async throws {
        let app = try await RunningApp.start()
        let task = try await app.services.organization.tasks.create(TaskDraft(title: "Stretch", dueDate: app.services.today))
        try app.services.widgets.actionQueue.enqueue(WidgetAction(kind: .completeTask, taskID: task.id.rawValue, requestedAt: app.clock.now()))
        await app.runtime.didBecomeActive()
        #expect(try await app.services.organization.tasks.task(task.id)?.status == .done)
        #expect(try app.services.widgets.actionQueue.pending().isEmpty)
        await app.runtime.shutdown()
    }
}
