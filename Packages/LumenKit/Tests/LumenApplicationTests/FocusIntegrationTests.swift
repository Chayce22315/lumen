import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenAnalytics
import LumenIntelligence
import LumenAutomation
import LumenWidgetData
import LumenApplication
import LumenTestSupport

/// Records what the coordinator asked the Live Activity to show.
final class RecordingFocusPresenter: FocusActivityPresenting {
    private let storage = Mutex<[FocusActivityContent?]>([])

    func present(_ content: FocusActivityContent?) async throws {
        storage.withLock { $0.append(content) }
    }

    var presented: [FocusActivityContent?] { storage.withLock { $0 } }
    var last: FocusActivityContent?? { storage.withLock { $0.last } }
    /// The most recent content shown (ignoring "nothing is active").
    var lastShown: FocusActivityContent? { storage.withLock { $0.compactMap { $0 }.last } }
}

/// Records system notifications scheduled and cancelled.
final class RecordingScheduler: SystemNotificationScheduling {
    let scheduled = Mutex<[SystemNotificationRequest]>([])
    let cancelled = Mutex<[String]>([])
    func authorization() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ request: SystemNotificationRequest) async throws { scheduled.withLock { $0.append(request) } }
    func cancel(identifiers: [String]) async { cancelled.withLock { $0.append(contentsOf: identifiers) } }
}

struct FocusApp {
    let services: LumenServices
    let runtime: LumenRuntime
    let clock: ManualTimeSource
    let presenter: RecordingFocusPresenter
    let scheduler: RecordingScheduler
    let directory: URL

    static func make(started: Bool = true) async throws -> FocusApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-focus-\(UUID().uuidString)")
        let clock = ManualTimeSource()
        let presenter = RecordingFocusPresenter()
        let scheduler = RecordingScheduler()
        var platform = PlatformServices(secrets: InMemorySecretStore(), notificationScheduler: scheduler)
        platform.focusActivities = presenter
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: clock,
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        if started { await runtime.start() }
        return FocusApp(services: services, runtime: runtime, clock: clock, presenter: presenter, scheduler: scheduler, directory: directory)
    }

    func tearDown() async {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory) // best-effort cleanup of a scratch directory
    }

    var focus: FocusService { services.focus.service }
}

@Suite("Focus sessions in the app")
struct FocusIntegrationTests {
    @Test("Live Activity content is computed from the session's timestamps")
    func activityContent() throws {
        let start = ManualTimeSource.referenceDate
        var session = try FocusSessionRules.started(FocusDraft(plannedMinutes: 25), at: start)
        let running = FocusActivityContent(session: session, title: "Write")
        #expect(running.sessionID == session.id.rawValue)
        #expect(running.state.phase == .running)
        #expect(running.state.countdownRange == start...start.addingTimeInterval(1_500))
        #expect(running.state.staleDate == start.addingTimeInterval(1_500))
        #expect(running.state.remaining(at: start.addingTimeInterval(500)) == 1_000)

        session = try FocusSessionRules.paused(session, at: start.addingTimeInterval(600))
        let paused = FocusActivityContent(session: session, title: nil).state
        #expect(paused.phase == .paused)
        #expect(paused.staleDate == nil)
        // Frozen while paused, however much later it is read.
        #expect(paused.remaining(at: start.addingTimeInterval(5_000)) == 900)
        #expect(paused.progress(at: start.addingTimeInterval(5_000)) == 0.4)

        session = try FocusSessionRules.resumed(session, at: start.addingTimeInterval(700))
        session = try FocusSessionRules.ended(session, as: .completed, at: start.addingTimeInterval(1_000))
        let ended = FocusActivityContent(session: session, title: nil).state
        #expect(ended.phase == .completed)
        #expect(ended.focusedDuration == 900)
        #expect(ended.focusedMinutes == 15)
        #expect(!ended.isActive)
        #expect(FocusActivityLink.url(sessionID: session.id.rawValue).flatMap(DeepLink.destination(from:)) == .entity(session.reference))
        #expect(FocusIntegration.durationText(5_400) == "1 hour 30 minutes")
        #expect(FocusIntegration.durationText(60) == "1 minute")
        #expect(FocusIntegration.durationText(7_200) == "2 hours")
    }

    @Test("starting, pausing and finishing drive the Live Activity and the end-of-session alert")
    func liveActivityAndAlert() async throws {
        let app = try await FocusApp.make()
        let task = try await app.services.organization.tasks.create(TaskDraft(title: "Write report"))
        let session = try await app.focus.start(FocusDraft(taskID: task.id, plannedMinutes: 25))
        await app.services.focus.coordinator.waitForHandledEvents(1)
        let shown = try #require(app.presenter.lastShown)
        #expect(shown.sessionID == session.id.rawValue)
        #expect(shown.state.phase == .running)
        #expect(shown.state.title == "Write report")
        let alert = try #require(try await app.services.notifications.upcoming().first)
        #expect(alert.entity == session.reference)
        #expect(alert.deliverAt == session.countdownEnd)
        #expect(alert.title == "Focus session complete")
        #expect(app.scheduler.scheduled.withLock { $0.last?.deepLink } == "lumen://entity/\(session.reference.uri)")

        app.clock.advance(by: 300)
        try await app.focus.pause(session.id)
        await app.services.focus.coordinator.waitForHandledEvents(2)
        #expect(app.presenter.lastShown?.state.phase == .paused)
        #expect(try await app.services.notifications.upcoming().isEmpty)

        app.clock.advance(by: 60)
        try await app.focus.resume(session.id)
        await app.services.focus.coordinator.waitForHandledEvents(3)
        let resumedAlert = try #require(try await app.services.notifications.upcoming().first)
        #expect(resumedAlert.deliverAt == session.countdownEnd.addingTimeInterval(60))

        app.clock.advance(by: 120)
        try await app.focus.finish(session.id)
        await app.services.focus.coordinator.waitForHandledEvents(4)
        let final = try #require(app.presenter.lastShown)
        #expect(final.state.phase == .completed)
        #expect(final.state.focusedDuration == 420)
        #expect(try await app.services.notifications.upcoming().isEmpty)
        await app.tearDown()
    }

    @Test("a countdown that ran out while closed completes on launch: analytics, task and activity")
    func completesOnLaunch() async throws {
        let app = try await FocusApp.make(started: false)
        let task = try await app.services.organization.tasks.create(TaskDraft(title: "Deep work"))
        let session = try await app.focus.start(FocusDraft(taskID: task.id, plannedMinutes: 45, completesTask: true))
        app.clock.advance(by: 4 * 3_600)

        await app.runtime.start()
        #expect(try await app.focus.session(session.id)?.phase == .completed)
        #expect(try await app.services.organization.tasks.task(task.id)?.status == .done)
        #expect(app.presenter.lastShown?.state.phase == .completed)

        let today = DayRange(day: app.services.today)
        #expect(try await eventually {
            try await app.services.analytics.service.total(of: FocusIntegration.minutesMeasure.id, in: today) == 45
        })
        #expect(try await eventually {
            try await app.services.analytics.service.report(signals: app.services.analytics.signals, range: today).focus == 1
        })

        // Nothing is active any more: a later reconcile ends any activity that is still running.
        await app.services.focus.coordinator.reconcile()
        #expect(app.presenter.last == .some(nil))
        await app.tearDown()
    }

    @Test("a session started right after another ended keeps its activity and alert")
    func backToBack() async throws {
        let app = try await FocusApp.make()
        let first = try await app.focus.start(FocusDraft(plannedMinutes: 5))
        await app.services.focus.coordinator.waitForHandledEvents(1)
        app.clock.advance(by: 360)
        // Starting completes the due session first: two events, completed then started.
        let second = try await app.focus.start(FocusDraft(plannedMinutes: 20))
        await app.services.focus.coordinator.reconcile()
        await app.services.focus.coordinator.waitForHandledEvents(3)
        #expect(try await app.focus.session(first.id)?.phase == .completed)
        #expect(app.presenter.presented.contains { $0?.sessionID == first.id.rawValue && $0?.state.phase == .completed })
        #expect(app.presenter.lastShown?.sessionID == second.id.rawValue)
        #expect(app.presenter.lastShown?.state.phase == .running)
        #expect(try await app.services.notifications.upcoming().map(\.entity) == [second.reference])
        await app.tearDown()
    }

    @Test("background refresh completes a due session")
    func backgroundRefresh() async throws {
        let app = try await FocusApp.make(started: false)
        let session = try await app.focus.start(FocusDraft(plannedMinutes: 10))
        app.clock.advance(by: 900)
        let report = await app.runtime.performBackgroundRefresh()
        #expect(report.completed.contains(.focus))
        #expect(try await app.focus.session(session.id)?.endedAt == session.countdownEnd)
        await app.tearDown()
    }

    @Test("the assistant starts and stops focus with its own actor")
    func assistantTools() async throws {
        let app = try await FocusApp.make()
        let registry = app.services.intelligence.tools
        let start = try #require(registry.tool(named: "start_focus"))
        let stop = try #require(registry.tool(named: "stop_focus"))
        let context = ToolContext(conversationID: Conversation.ID(), action: ActionContext(actor: .assistant), turnID: UUID())
        let recorder = EventRecorder(bus: app.services.events, filter: EventFilter(names: [OrganizationEvent.focusStarted]))
        let task = try await app.services.organization.tasks.create(TaskDraft(title: "Plan sprint"))

        #expect(try await stop.execute([:], context: context).text == "No focus session is running.")
        let started = try await start.execute(["minutes": 50, "task_id": .string(task.reference.uri), "complete_task": true], context: context)
        #expect(!started.isError)
        #expect(started.text == "Started focusing for 50 minutes on “Plan sprint”; the task will be marked done when the session completes.")
        #expect(await recorder.waitForEvents(1).first?.actor == .assistant)
        #expect(try await start.execute(["minutes": 10], context: context).isError)
        #expect(try await start.execute(["minutes": 500], context: context).isError)

        app.clock.advance(by: 600)
        #expect(try await stop.execute(["outcome": "finish"], context: context).text == "Finished the focus session: 10 minutes of focus.")
        #expect(try await app.services.organization.tasks.task(task.id)?.status == .done)
        #expect(try await app.focus.activeSession() == nil)
        await app.tearDown()
    }

    @Test("automations start and end focus; a running session is not an error")
    func automationActions() async throws {
        let app = try await FocusApp.make()
        let catalog = app.services.automation.catalog
        let start = try #require(catalog.action("organization.startFocus"))
        let stop = try #require(catalog.action("organization.stopFocus"))
        func invocation(_ parameters: [String: JSONValue]) -> ActionInvocation {
            ActionInvocation(parameters: parameters, context: ActionContext(actor: .automation), runID: WorkflowRun.ID(), workflowID: Workflow.ID(), nodeID: WorkflowNode.ID(), attempt: 1)
        }

        let started = try await start.perform(invocation(["minutes": "30"]))
        #expect(started.message == "Started focusing for 30 minutes")
        #expect(try await app.focus.activeSession()?.plannedMinutes == 30)
        #expect(try await start.perform(invocation(["minutes": 30])).message == "A focus session is already running")
        await #expect(throws: AutomationActionError.self) { try await start.perform(invocation(["minutes": 0])) }

        let cancelled = try await stop.perform(invocation(["outcome": "cancel"]))
        #expect(cancelled.output["outcome"] == .string("cancelled"))
        #expect(try await stop.perform(invocation([:])).message == "No focus session was running")
        #expect(catalog.triggerDescriptor(for: OrganizationEvent.focusCompleted) != nil)
        await app.tearDown()
    }
}
