import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("Focus view models")
struct FocusViewModelTests {
    @Test("setup suggests the task's estimate, clamps the length and starts once")
    func setup() async throws {
        let (services, runtime) = try await makeServices()
        let task = try await services.organization.tasks.create(TaskDraft(title: "Write chapter", estimatedMinutes: 50))
        let setup = FocusSetupViewModel(taskID: task.id, services: services)
        #expect(!setup.canStart)
        await setup.load()
        #expect(setup.taskTitle == "Write chapter")
        #expect(setup.minutes == 50)
        #expect(setup.offersTaskCompletion)
        setup.minutes = 10_000
        #expect(setup.minutes == FocusSessionRules.maximumMinutes)
        setup.minutes = 0
        #expect(setup.minutes == FocusSessionRules.minimumMinutes)
        setup.minutes = 45
        #expect(setup.minutesLabel == "45 minutes")
        setup.completesTask = true

        let session = try #require(await setup.start())
        #expect(session.plannedMinutes == 45)
        #expect(session.completesTask)
        #expect(session.taskID == task.id)

        // A second sheet sees the running session and can't start another.
        let other = FocusSetupViewModel(services: services)
        await other.load()
        #expect(other.activeSession?.id == session.id)
        #expect(!other.offersTaskCompletion)
        #expect(!other.canStart)
        #expect(await other.start() == nil)
        await runtime.shutdown()
    }

    @Test("the Focus screen pauses, resumes and finishes from the session's timestamps")
    func focusScreen() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let task = try await services.organization.tasks.create(TaskDraft(title: "Review PR"))
        let session = try await services.focus.service.start(FocusDraft(taskID: task.id, plannedMinutes: 25, completesTask: true))
        let focus = FocusViewModel(sessionID: session.id, services: services)
        await focus.start()
        #expect(focus.title == "Review PR")
        #expect(focus.phase == .running)
        #expect(focus.countdownRange == session.countdownStart...session.countdownEnd)

        clock.advance(by: 600)
        #expect(focus.remaining(at: clock.now()) == 900)
        #expect(focus.status(at: clock.now()) == "15 minutes left")
        await focus.pause()
        #expect(focus.phase == .paused)
        #expect(focus.pausedAt == clock.now())
        clock.advance(by: 300)
        #expect(focus.status(at: clock.now()) == "Paused, 15 minutes left")
        #expect(focus.progress(at: clock.now()) == 0.4)

        await focus.resume()
        #expect(focus.phase == .running)
        #expect(focus.countdownRange?.upperBound == session.countdownEnd.addingTimeInterval(300))
        clock.advance(by: 30)
        #expect(focus.status(at: clock.now()) == "15 minutes left")

        await focus.finish()
        #expect(focus.phase == .completed)
        #expect(await eventually { focus.isTaskDone })
        #expect(focus.summary == "11 minutes of focus. Task completed.")
        #expect(focus.status(at: clock.now()) == "Completed: 11 minutes of focus")

        await focus.pause()
        #expect(focus.error?.title == "Session ended")
        await runtime.shutdown()
    }

    @Test("changes made elsewhere reach the screen and Home; cancelled time isn't counted")
    func followsChanges() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let active = ActiveFocusViewModel(services: services)
        await active.start()
        #expect(active.session == nil)

        let session = try await services.focus.service.start(FocusDraft(plannedMinutes: 20))
        #expect(await eventually { active.session?.id == session.id })
        #expect(active.title == "Focus session")
        let focus = FocusViewModel(sessionID: session.id, services: services)
        await focus.start()
        #expect(focus.title == "Focus")

        clock.advance(by: 120)
        // As if from a Live Activity button.
        _ = try await services.focus.service.cancel(session.id)
        #expect(await eventually { focus.phase == .cancelled })
        #expect(focus.summary == "Cancelled after 2 minutes. This time isn't counted.")
        #expect(await eventually { active.session == nil })

        let missing = FocusViewModel(sessionID: FocusSession.ID(), services: services)
        await missing.load()
        #expect(missing.state.error?.title == "Session not found")
        await runtime.shutdown()
    }

    @Test("the task editor shows focus totals and Insights the focused minutes")
    func totals() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let task = try await services.organization.tasks.create(TaskDraft(title: "Thesis"))
        for minutes in [25, 50] {
            let session = try await services.focus.service.start(FocusDraft(taskID: task.id, plannedMinutes: minutes))
            clock.advance(by: TimeInterval(minutes * 60))
            try await services.focus.service.finish(session.id)
        }
        let editor = TaskEditorViewModel(taskID: task.id, services: services)
        await editor.load()
        #expect(editor.focusSummary == "2 sessions · 1 hour 15 minutes focused")

        let insights = InsightsViewModel(services: services)
        #expect(await eventually {
            await insights.load()
            return insights.focusMinutes == 75
        })
        #expect(insights.focusLabel == "1 h 15 min")
        await runtime.shutdown()
    }
}

/// A system search index that only counts what it holds.
private final class CountingIndex: SystemSearchIndexing {
    private let identifiers = Mutex<Set<String>>([])
    var count: Int { identifiers.withLock { $0.count } }
    func index(_ items: [SystemSearchItem]) async throws { identifiers.withLock { $0.formUnion(items.map(\.identifier)) } }
    func remove(identifiers removed: [String]) async throws { identifiers.withLock { $0.subtract(removed) } }
    func removeAll() async throws { identifiers.withLock { $0.removeAll() } }
}

@MainActor
@Suite("Spotlight setting")
struct SpotlightSettingsViewModelTests {
    @Test("hidden without a system index")
    func unavailable() async throws {
        let (services, runtime) = try await makeServices()
        #expect(!SpotlightSettingsViewModel(services: services).isAvailable)
        await runtime.shutdown()
    }

    @Test("turning it off empties the index; on fills it again")
    func toggle() async throws {
        let index = CountingIndex()
        var platform = PlatformServices.ephemeral()
        platform.systemSearchIndex = index
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lumen-ui-\(UUID().uuidString)")),
            platform: platform,
            timeSource: ManualTimeSource(),
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        await runtime.start()
        _ = try await services.knowledge.notes.create(title: "Packing list", body: "Socks")
        await services.spotlight.waitUntilIdle(events: 1)
        #expect(index.count == 1)

        let settings = SpotlightSettingsViewModel(services: services)
        #expect(settings.isAvailable)
        await settings.load()
        #expect(settings.isEnabled)
        await settings.setEnabled(false)
        #expect(!settings.isEnabled)
        #expect(index.count == 0)
        await settings.setEnabled(true)
        #expect(settings.isEnabled)
        #expect(index.count == 1)
        await runtime.shutdown()
    }
}
