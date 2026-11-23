import Foundation
import Testing
import LumenFoundation
import LumenOrganization
import LumenKnowledge
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("Command palette keyboard")
struct CommandPaletteKeyboardTests {
    @Test("arrows move the highlight within the rows; a new query highlights its best match")
    func highlight() async throws {
        let (services, runtime) = try await makeServices()
        let palette = CommandPaletteViewModel(services: services, debounce: 0)
        await palette.start()

        // Before typing: suggested commands (no history yet), the first one highlighted.
        #expect(palette.sections.map(\.title) == ["Suggested"])
        let items = palette.items
        try #require(items.count >= 3)
        #expect(palette.highlightedID == items[0].id)
        palette.moveHighlight(by: -1)
        #expect(palette.highlightedID == items[0].id)
        palette.moveHighlight(by: 2)
        #expect(palette.highlightedItem == items[2])
        palette.moveHighlight(by: 100)
        #expect(palette.highlightedID == items.last?.id)

        // Refreshing the same query keeps the row the user moved to.
        await palette.search()
        #expect(palette.highlightedID == items.last?.id)

        palette.query = "Open Insights"
        await palette.search()
        #expect(palette.sections.first?.title == "Commands")
        #expect(palette.highlightedItem?.id == "command:navigate.insights")

        // Nothing to highlight, nothing for Return to open.
        palette.query = "zzqxv"
        await palette.search()
        #expect(palette.items.isEmpty)
        #expect(palette.highlightedID == nil)
        palette.moveHighlight(by: 1)
        #expect(palette.highlightedID == nil)
        await runtime.shutdown()
    }

    @Test("Return runs the highlighted command and closes the palette; a recent query fills the field")
    func activate() async throws {
        let (services, runtime) = try await makeServices()
        let model = AppModel(makeServices: { services })
        await model.launch()
        let palette = CommandPaletteViewModel(services: services, debounce: 0)
        palette.query = "Open Insights"
        await palette.search()
        model.perform(.commandPalette)
        #expect(model.router.sheet == .commandPalette)
        #expect(await palette.activateHighlighted(in: model))
        #expect(model.router.sheet == nil)
        #expect(model.router.homePath == [.insights])

        await palette.remember()
        palette.query = ""
        await palette.search()
        #expect(palette.sections.map(\.title) == ["Recent", "Suggested"])
        let recent = try #require(palette.items.first)
        #expect(recent.id == "history:Open Insights")
        await palette.activate(recent, in: model)
        #expect(palette.query == "Open Insights")

        palette.query = "zzqxv"
        await palette.search()
        #expect(await palette.activateHighlighted(in: model) == false)
        await runtime.shutdown()
    }

    @Test("Return opens the highlighted result where the user is")
    func openResult() async throws {
        let (services, runtime) = try await makeServices()
        let model = AppModel(makeServices: { services })
        await model.launch()
        let created = try await services.organization.tasks.create(TaskDraft(title: "Renew the passport"))
        let palette = CommandPaletteViewModel(services: services, debounce: 0)
        palette.query = "passport"
        #expect(await eventually {
            await palette.search()
            return palette.items.contains { $0.id == "result:\(created.reference.uri)" }
        })
        let result = try #require(palette.items.first { $0.id == "result:\(created.reference.uri)" })
        palette.highlight(result)
        model.router.select(.library)
        model.perform(.commandPalette)
        await palette.activateHighlighted(in: model)
        #expect(model.router.sheet == nil)
        #expect(model.router.libraryPath == [.entity(created.reference)])
        await runtime.shutdown()
    }
}

@MainActor
@Suite("Sidebar model")
struct SidebarViewModelTests {
    @Test("collections in order with their place, smart-list badges, deleted collections leave")
    func collectionsAndBadges() async throws {
        let (services, runtime) = try await makeServices()
        let router = Router()
        router.setLayout(.sidebar)
        let sidebar = SidebarViewModel(services: services, router: router)
        let work = try await services.knowledge.collections.create(name: "Work")
        let meetings = try await services.knowledge.collections.create(name: "Meetings", parentID: work.id)
        _ = try await services.organization.tasks.create(TaskDraft(title: "Water plants", dueDate: services.today))
        await sidebar.start()

        #expect(sidebar.collections.map(\.name) == ["Work", "Meetings"])
        #expect(sidebar.collections.map(\.depth) == [0, 1])
        #expect(sidebar.collections.map(\.accessibilityLabel) == ["Work", "Meetings, in Work"])
        #expect(sidebar.collections.first?.section == .collection(work.id))
        #expect(sidebar.title(for: .collection(work.id)) == "Work")
        #expect(sidebar.title(for: .tasks(.inbox)) == "Inbox")
        #expect(sidebar.badge(for: .tasks(.today)) == 1)
        #expect(sidebar.badge(for: .tasks(.completed)) == nil)
        #expect(sidebar.badge(for: .calendar) == nil)

        router.select(section: .collection(meetings.id))
        try await services.knowledge.collections.delete(meetings.id)
        #expect(await eventually { sidebar.collections.count == 1 })
        #expect(router.selection == .library)
        await runtime.shutdown()
    }
}

@MainActor
@Suite("App model commands")
struct AppModelCommandTests {
    @Test("commands wait for launch, then go to the router")
    func perform() async throws {
        let (services, runtime) = try await makeServices()
        let model = AppModel(makeServices: { services })
        model.perform(.quickCapture)
        #expect(model.router.sheet == nil)
        await model.launch()
        model.perform(.quickCapture)
        #expect(model.router.sheet == .capture(text: nil))
        model.perform(.showSection(.assistant))
        #expect(model.router.sheet == nil)
        #expect(model.router.selectedTab == .assistant)
        await runtime.shutdown()
    }
}
