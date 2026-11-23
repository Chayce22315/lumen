import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenOrganization
import LumenTestSupport

@Suite("Focus session rules")
struct FocusSessionRulesTests {
    let start = ManualTimeSource.referenceDate

    func running(minutes: Int = 25) throws -> FocusSession {
        try FocusSessionRules.started(FocusDraft(plannedMinutes: minutes), at: start)
    }

    @Test("planned durations are bounded and completing a task needs a task")
    func validation() throws {
        #expect(throws: ValidationError.self) { try FocusSessionRules.validate(FocusDraft(plannedMinutes: 0)) }
        #expect(throws: ValidationError.self) { try FocusSessionRules.validate(FocusDraft(plannedMinutes: FocusSessionRules.maximumMinutes + 1)) }
        #expect(throws: ValidationError.self) { try FocusSessionRules.validate(FocusDraft(plannedMinutes: 25, completesTask: true)) }
        try FocusSessionRules.validate(FocusDraft(plannedMinutes: FocusSessionRules.minimumMinutes))
        try FocusSessionRules.validate(FocusDraft(taskID: TaskItem.ID(), plannedMinutes: FocusSessionRules.maximumMinutes, completesTask: true))
        #expect(FocusSessionRules.suggestedMinutes.allSatisfy { (FocusSessionRules.minimumMinutes...FocusSessionRules.maximumMinutes).contains($0) })
    }

    @Test("progress is computed from timestamps alone")
    func derivedProgress() throws {
        let session = try running()
        #expect(session.phase == .running)
        #expect(session.plannedDuration == 1_500)
        #expect(session.countdownEnd == start.addingTimeInterval(1_500))
        #expect(session.focusedDuration(at: start.addingTimeInterval(600)) == 600)
        #expect(session.remainingDuration(at: start.addingTimeInterval(600)) == 900)
        #expect(session.progress(at: start.addingTimeInterval(750)) == 0.5)
        #expect(session.isDue(at: start.addingTimeInterval(1_499)) == false)
        #expect(session.isDue(at: start.addingTimeInterval(1_500)))
        // A clock that moved backwards never yields negative focus.
        #expect(session.focusedDuration(at: start.addingTimeInterval(-60)) == 0)
        #expect(session.remainingDuration(at: start.addingTimeInterval(4_000)) == 0)
    }

    @Test("pauses stop the countdown and accumulate")
    func pauses() throws {
        var session = try running()
        session = try FocusSessionRules.paused(session, at: start.addingTimeInterval(300))
        #expect(session.phase == .paused)
        // Time passes while paused; nothing is focused and nothing becomes due.
        #expect(session.focusedDuration(at: start.addingTimeInterval(5_000)) == 300)
        #expect(session.isDue(at: start.addingTimeInterval(5_000)) == false)
        #expect(try FocusSessionRules.paused(session, at: start.addingTimeInterval(400)) == session)

        session = try FocusSessionRules.resumed(session, at: start.addingTimeInterval(900))
        #expect(session.phase == .running)
        #expect(session.pausedDuration == 600)
        #expect(session.countdownEnd == start.addingTimeInterval(2_100))
        #expect(session.countdownEnd.timeIntervalSince(session.countdownStart) == session.plannedDuration)
        #expect(session.focusedDuration(at: start.addingTimeInterval(1_000)) == 400)
        #expect(try FocusSessionRules.resumed(session, at: start.addingTimeInterval(1_000)) == session)

        session = try FocusSessionRules.paused(session, at: start.addingTimeInterval(1_200))
        session = try FocusSessionRules.resumed(session, at: start.addingTimeInterval(1_260))
        #expect(session.pausedDuration == 660)
    }

    @Test("ending while paused stops focus where the pause began")
    func endWhilePaused() throws {
        var session = try FocusSessionRules.paused(try running(), at: start.addingTimeInterval(600))
        session = try FocusSessionRules.ended(session, as: .completed, at: start.addingTimeInterval(1_000))
        #expect(session.phase == .completed)
        #expect(session.pausedAt == nil)
        #expect(session.pausedDuration == 400)
        #expect(session.endedAt == start.addingTimeInterval(1_000))
        #expect(session.focusedDuration(at: start.addingTimeInterval(9_999)) == 600)
        #expect(throws: OrganizationError.focusSessionEnded) { try FocusSessionRules.paused(session, at: start.addingTimeInterval(1_100)) }
        #expect(throws: OrganizationError.focusSessionEnded) { try FocusSessionRules.resumed(session, at: start.addingTimeInterval(1_100)) }
        #expect(throws: OrganizationError.focusSessionEnded) { try FocusSessionRules.ended(session, as: .cancelled, at: start.addingTimeInterval(1_100)) }
    }

    @Test("a countdown that ran out completes at the instant it reached zero")
    func settling() throws {
        let session = try running()
        #expect(FocusSessionRules.settled(session, at: start.addingTimeInterval(100)) == session)
        let late = start.addingTimeInterval(7_200)
        let settled = FocusSessionRules.settled(session, at: late)
        #expect(settled.phase == .completed)
        #expect(settled.endedAt == start.addingTimeInterval(1_500))
        #expect(settled.focusedDuration(at: late) == 1_500)
        // Cancelling or pausing after the fact cannot undo a completed countdown.
        #expect(try FocusSessionRules.ended(session, as: .cancelled, at: late) == settled)
        #expect(try FocusSessionRules.paused(session, at: late) == settled)
        #expect(try FocusSessionRules.resumed(session, at: late) == settled)
    }

    @Test("cancelling early records the outcome")
    func cancel() throws {
        let cancelled = try FocusSessionRules.ended(try running(), as: .cancelled, at: start.addingTimeInterval(120))
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.focusedDuration(at: start.addingTimeInterval(500)) == 120)
    }
}

struct FocusHarness {
    let environment: CoreTestEnvironment
    let tasks: TaskService
    let focus: FocusService

    static func make() async throws -> FocusHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [OrganizationSchema.schema])
        let tasks = TaskService(database: environment.database, events: environment.events, timeSource: environment.clock, calendar: environment.calendar, logger: environment.logger("tasks"))
        let focus = FocusService(database: environment.database, events: environment.events, timeSource: environment.clock, tasks: tasks, logger: environment.logger("focus"))
        return FocusHarness(environment: environment, tasks: tasks, focus: focus)
    }
}

@Suite("FocusService")
struct FocusServiceTests {
    @Test("starting publishes after commit and allows one active session")
    func start() async throws {
        let harness = try await FocusHarness.make()
        let recorder = EventRecorder(bus: harness.environment.events, filter: EventFilter(entityKinds: [.focusSession]))
        let task = try await harness.tasks.create(TaskDraft(title: "Write report"))
        let session = try await harness.focus.start(FocusDraft(taskID: task.id, plannedMinutes: 50, completesTask: true), context: ActionContext(actor: .assistant))
        #expect(try await harness.focus.activeSession() == session)
        #expect(session.completesTask)

        await #expect(throws: OrganizationError.focusSessionAlreadyActive) {
            try await harness.focus.start(FocusDraft(plannedMinutes: 10))
        }
        let events = await recorder.waitForEvents(1)
        #expect(events.map(\.name) == [OrganizationEvent.focusStarted])
        #expect(events.first?.actor == .assistant)
        #expect(events.first?.attributes["plannedMinutes"] == .number(50))
        #expect(events.first?.attributes["taskID"] == .string(task.id.uuidString))
        // Sessions are device-local: nothing enters the change log for sync.
        let changes = try await harness.environment.database.read { db in try db.changes(after: 0, limit: 100) }
        #expect(changes.allSatisfy { $0.entity.kind == .task })
    }

    @Test("the schema itself refuses a second active session")
    func uniqueActive() async throws {
        let harness = try await FocusHarness.make()
        let now = harness.environment.clock.now()
        let repository = FocusSessionRepository()
        try await harness.environment.database.write { db in
            try repository.save(FocusSession(plannedDuration: 600, startedAt: now), in: db)
            try repository.save(FocusSession(plannedDuration: 600, startedAt: now, endedAt: now, outcome: .completed), in: db)
        }
        await #expect(throws: (any Error).self) {
            try await harness.environment.database.write { db in
                try repository.save(FocusSession(plannedDuration: 600, startedAt: now), in: db)
            }
        }
    }

    @Test("tasks must exist and be open")
    func taskChecks() async throws {
        let harness = try await FocusHarness.make()
        let missing = TaskItem.ID()
        await #expect(throws: OrganizationError.taskNotFound(missing)) { try await harness.focus.start(FocusDraft(taskID: missing)) }
        let task = try await harness.tasks.create(TaskDraft(title: "Done already"))
        _ = try await harness.tasks.complete(task.id)
        await #expect(throws: OrganizationError.focusTaskClosed) { try await harness.focus.start(FocusDraft(taskID: task.id)) }
        await #expect(throws: ValidationError.self) { try await harness.focus.start(FocusDraft(plannedMinutes: 0)) }
        #expect(try await harness.focus.activeSession() == nil)
    }

    @Test("pause, resume and finish survive a new service on the same database")
    func lifecycle() async throws {
        let harness = try await FocusHarness.make()
        let clock = harness.environment.clock
        let recorder = EventRecorder(bus: harness.environment.events, filter: EventFilter(entityKinds: [.focusSession]))
        let session = try await harness.focus.start(FocusDraft(plannedMinutes: 25))
        clock.advance(by: 300)
        #expect(try await harness.focus.pause(session.id).phase == .paused)
        #expect(try await harness.focus.pause(session.id).phase == .paused)
        clock.advance(by: 600)

        // A relaunch: a fresh service reads the same state, recomputed from timestamps.
        let relaunched = FocusService(database: harness.environment.database, events: harness.environment.events, timeSource: clock, tasks: harness.tasks, logger: harness.environment.logger("focus"))
        let reloaded = try #require(try await relaunched.activeSession())
        #expect(reloaded.phase == .paused)
        #expect(reloaded.remainingDuration(at: clock.now()) == 1_200)

        #expect(try await relaunched.resume(session.id).pausedDuration == 600)
        clock.advance(by: 120)
        let ending = try await relaunched.finish(session.id)
        #expect(ending.session.phase == .completed)
        #expect(ending.session.focusedDuration(at: clock.now()) == 420)
        #expect(ending.completedTask == nil)
        #expect(try await relaunched.activeSession() == nil)
        await #expect(throws: OrganizationError.focusSessionEnded) { try await relaunched.pause(session.id) }
        let unknown = FocusSession.ID()
        await #expect(throws: OrganizationError.focusSessionNotFound(unknown)) { try await relaunched.pause(unknown) }

        let events = await recorder.waitForEvents(4)
        #expect(events.map(\.name) == [OrganizationEvent.focusStarted, OrganizationEvent.focusPaused, OrganizationEvent.focusResumed, OrganizationEvent.focusCompleted])
        #expect(events.last?.attributes["focusedSeconds"] == .number(420))
        #expect(events.last?.attributes["focusedMinutes"] == .number(7))
    }

    @Test("a countdown that ran out while closed completes at its end and completes the task")
    func completeIfDue() async throws {
        let harness = try await FocusHarness.make()
        let clock = harness.environment.clock
        let start = clock.now()
        let recorder = EventRecorder(bus: harness.environment.events, filter: EventFilter(names: [OrganizationEvent.focusCompleted, OrganizationEvent.taskCompleted]))
        let task = try await harness.tasks.create(TaskDraft(title: "Inbox zero"))
        let session = try await harness.focus.start(FocusDraft(taskID: task.id, plannedMinutes: 15, completesTask: true))
        #expect(try await harness.focus.completeIfDue() == nil)

        clock.advance(by: 3 * 3_600)
        let ending = try #require(try await harness.focus.completeIfDue())
        #expect(ending.session.id == session.id)
        #expect(ending.session.endedAt == start.addingTimeInterval(900))
        #expect(ending.completedTask?.status == .done)
        #expect(try await harness.tasks.task(task.id)?.status == .done)
        #expect(try await harness.focus.completeIfDue() == nil)

        let events = await recorder.waitForEvents(2)
        let completed = try #require(events.first { $0.name == OrganizationEvent.focusCompleted })
        #expect(completed.occurredAt == start.addingTimeInterval(900))
        #expect(completed.actor == .system)
        #expect(try await harness.focus.totals(forTask: task.id) == FocusTotals(sessions: 1, focusedDuration: 900))
        #expect(try await harness.focus.focusedDuration(from: start, to: start.addingTimeInterval(86_400)) == 900)
    }

    @Test("a due session never blocks the next one, and cancelling discards the time")
    func dueThenCancel() async throws {
        let harness = try await FocusHarness.make()
        let clock = harness.environment.clock
        let first = try await harness.focus.start(FocusDraft(plannedMinutes: 5))
        clock.advance(by: 600)
        let second = try await harness.focus.start(FocusDraft(plannedMinutes: 10))
        #expect(try await harness.focus.session(first.id)?.phase == .completed)
        clock.advance(by: 60)
        #expect(try await harness.focus.cancel(second.id).phase == .cancelled)
        #expect(try await harness.focus.focusedDuration(from: first.startedAt, to: clock.now().addingTimeInterval(1)) == 300)
        #expect(try await harness.focus.recentSessions().map(\.id) == [second.id, first.id])
    }

    @Test("a deleted task is skipped when the session completes")
    func deletedTask() async throws {
        let harness = try await FocusHarness.make()
        let task = try await harness.tasks.create(TaskDraft(title: "Temporary"))
        let session = try await harness.focus.start(FocusDraft(taskID: task.id, plannedMinutes: 10, completesTask: true))
        try await harness.tasks.delete(task.id)
        let ending = try await harness.focus.finish(session.id)
        #expect(ending.session.phase == .completed)
        #expect(ending.completedTask == nil)
        #expect(try await harness.focus.sessions(forTask: task.id).map(\.id) == [session.id])
    }
}
