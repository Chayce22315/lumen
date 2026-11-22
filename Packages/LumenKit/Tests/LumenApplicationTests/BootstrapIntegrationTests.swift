import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenSearch
import LumenApplication
import LumenWidgetData
import LumenTestSupport

final class CountingScheduler: SystemNotificationScheduling {
    let requests = Mutex<[SystemNotificationRequest]>([])
    func authorization() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ request: SystemNotificationRequest) async throws { requests.withLock { $0.append(request) } }
    func cancel(identifiers: [String]) async {}
}

/// Polls `condition` until it holds (bounded), for effects of asynchronous subscribers.
func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return try await condition()
}

struct RunningApp {
    let services: LumenServices
    let runtime: LumenRuntime
    let clock: ManualTimeSource
    let scheduler: CountingScheduler
    let reloads: ReloadCounter
    let directory: URL

    static func start() async throws -> RunningApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-app-\(UUID().uuidString)")
        let clock = ManualTimeSource()
        let scheduler = CountingScheduler()
        var platform = PlatformServices(secrets: InMemorySecretStore(), notificationScheduler: scheduler)
        let reloadCounter = ReloadCounter()
        platform.reloadWidgets = { reloadCounter.increment() }
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: clock,
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        await runtime.start()
        return RunningApp(services: services, runtime: runtime, clock: clock, scheduler: scheduler, reloads: reloadCounter, directory: directory)
    }
}

final class ReloadCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite("Bootstrap and runtime")
struct BootstrapIntegrationTests {
    @Test("starting activates built-in features, commands and the default calendar")
    func startup() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let statuses = await app.services.plugins.host.statuses()
        #expect(statuses.map(\.id) == ["app.lumen.core", "app.lumen.organization", "app.lumen.knowledge"])
        #expect(statuses.allSatisfy { $0.state == .active })
        #expect(app.services.commands.registry.command(id: "create.task") != nil)
        #expect(app.services.commands.action(for: "navigate.home") != nil)
        #expect(try await app.services.organization.calendars.calendars().count == 1)
        #expect(await app.runtime.isStarted)
        // The widget snapshot exists from the first launch.
        let snapshot = try WidgetSnapshotStore(url: app.services.configuration.widgetSnapshotURL).read()
        #expect(snapshot?.dueToday == 0)
        #expect(app.reloads.value >= 1)
        await app.runtime.shutdown()
    }

    @Test("a captured task flows into search, analytics, reminders, widgets and Home")
    func endToEnd() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let services = app.services

        let (task, _) = try await services.organization.tasks.capture("Prepare quarterly review today at 15:00 !high #work")
        _ = try await services.organization.tasks.update(task.id, TaskChanges(reminder: .some(.minutesBefore(30))))

        #expect(try await eventually { try await services.search.service.search(SearchQuery(text: "quarterly")).first?.reference == task.reference })
        #expect(try await eventually { try await services.analytics.service.recentEvents(limit: 10).contains { $0.entity == task.reference } })
        #expect(await eventually { app.scheduler.requests.withLock { $0.contains { $0.title == "Prepare quarterly review" } } })
        #expect(await eventually {
            (try? WidgetSnapshotStore(url: services.configuration.widgetSnapshotURL).read())?.tasks.contains { $0.id == task.id.rawValue } == true
        })
        // Regression: subscribers must not feed back on their own events (the reminder coordinator
        // once re-triggered itself through notification events forever).
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await services.organization.reminders.handledEvents <= 4)
        #expect(await services.widgets.receivedEvents <= 4)

        let home = try await services.home.snapshot(assistantConfigured: true)
        #expect(home.overview.summary.dueToday == 1)
        #expect(home.greeting.subtitle.hasPrefix("1 task due today"))
        #expect(home.activity.first?.title == "Added “Prepare quarterly review”")

        _ = try await services.organization.tasks.complete(task.id)
        #expect(try await eventually { try await services.home.snapshot(assistantConfigured: true).currentStreak == 1 })
        await app.runtime.shutdown()
    }

    @Test("commands perform real work")
    func performCommand() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let tasks = app.services.organization.tasks
        _ = try await tasks.create(TaskDraft(title: "Late", dueDate: app.services.today.adding(days: -3)))
        guard case .perform(let work)? = app.services.commands.action(for: "tasks.completeOverdueReview") else {
            Issue.record("command missing")
            return
        }
        #expect(try await work() == CommandResult(message: "Moved 1 task to today.", destination: .tasks(.today)))
        #expect(try await tasks.list(.overdue).isEmpty)
        await app.runtime.shutdown()
    }

    @Test("notes are searchable, synchronizable and on Home; the journal command opens today's note")
    func knowledge() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let services = app.services
        let note = try await services.knowledge.notes.create(title: "Garden plan", body: "Plant **tomatoes** in May. #garden")
        #expect(try await eventually { try await services.search.service.search(SearchQuery(text: "tomatoes")).first?.reference == note.reference })
        #expect(try await services.sync.pendingChangeCount() >= 1)
        let home = try await services.home.snapshot(assistantConfigured: true)
        #expect(home.recentNotes.map(\.id) == [note.id])
        #expect(try await eventually { try await services.home.snapshot(assistantConfigured: true).activity.contains { $0.title == "Wrote “Garden plan”" } })

        guard case .perform(let journal)? = services.commands.action(for: "notes.daily") else {
            Issue.record("journal command missing")
            return
        }
        let first = try await journal()
        let second = try await journal()
        #expect(first.message == "Created Journal 2026-11-21.")
        #expect(second.message == nil)
        #expect(first.destination == second.destination)
        await app.runtime.shutdown()
    }

    @Test("Home layout and display name persist")
    func homeSettings() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) }
        var layout = await app.services.home.layout()
        layout.setVisible(true, for: .activity)
        try await app.services.home.saveLayout(layout)
        try await app.services.home.setDisplayName("  Riley  ")
        #expect(await app.services.home.layout().visibleItems.contains { $0.kind == .activity })
        #expect(await app.services.settings.value(HomeService.displayNameKey) == "Riley")
        await app.runtime.shutdown()
    }
}
