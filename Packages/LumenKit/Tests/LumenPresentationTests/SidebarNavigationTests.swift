import Foundation
import Testing
import LumenFoundation
import LumenKnowledge
import LumenApplication
import LumenPresentation

private func task() -> AppDestination {
    .entity(EntityReference(kind: "task", id: UUID()))
}

private func note() -> AppDestination {
    .entity(EntityReference(kind: "note", id: UUID()))
}

@MainActor
private func sidebarRouter() -> Router {
    let router = Router()
    router.setLayout(.sidebar)
    return router
}

@MainActor
@Suite("Router in the sidebar")
struct SidebarRouterTests {
    @Test("destinations select their own sidebar items, opened at their root")
    func open() {
        let router = sidebarRouter()
        router.open(.tasks(.inbox))
        #expect(router.selection == .tasks(.inbox))
        #expect(router.selectedTab == .plan)
        #expect(router.planPath.isEmpty)
        router.open(.tasks(.projects))
        #expect(router.selection == .tasks(.projects))
        router.open(.calendar)
        #expect(router.selection == .calendar)
        router.open(.automations)
        #expect(router.selection == .automations)
        #expect(router.homePath.isEmpty)
        router.open(.insights)
        #expect(router.selection == .insights)
        #expect(router.selectedTab == .home)
        router.open(.notifications)
        #expect(router.selection == .home)
        #expect(router.homePath == [.notifications])
        router.open(.library)
        #expect(router.selection == .library)
        router.open(.search(query: "budget"))
        #expect(router.selection == .search)
        #expect(router.pendingSearchQuery == "budget")
    }

    @Test("opening a sidebar item resets it, like a tab's destination")
    func openResets() {
        let router = sidebarRouter()
        router.open(.tasks(.today))
        router.push(task())
        router.open(.home)
        router.open(.tasks(.today))
        #expect(router.path(for: .tasks(.today)).isEmpty)
    }

    @Test("each sidebar item keeps its own place")
    func perSectionState() {
        let router = sidebarRouter()
        let first = task()
        let second = task()
        router.open(.tasks(.today))
        router.push(first)
        router.select(section: .tasks(.inbox))
        router.push(second)
        router.select(section: .tasks(.today))
        #expect(router.listSelection(in: .tasks(.today)) == first)
        #expect(router.listSelection(in: .tasks(.inbox)) == second)
        // Re-selecting the current item pops it to its root.
        router.select(section: .tasks(.today))
        #expect(router.listSelection(in: .tasks(.today)) == nil)
        #expect(router.listSelection(in: .tasks(.inbox)) == second)
    }

    @Test("a list/detail section keeps the selection first and the detail stack after it")
    func listAndDetail() {
        let router = sidebarRouter()
        router.select(section: .library)
        let selected = note()
        let linked = note()
        let other = note()
        router.setListSelection(selected, in: .library)
        #expect(router.libraryPath == [selected])
        // A link followed in the detail column pushes there.
        router.push(linked)
        #expect(router.listSelection(in: .library) == selected)
        #expect(router.detailPath(in: .library) == [linked])
        // Back in the detail column.
        router.setDetailPath([], in: .library)
        #expect(router.libraryPath == [selected])
        // Choosing the same row again keeps the detail; another row replaces it.
        router.push(linked)
        router.setListSelection(selected, in: .library)
        #expect(router.detailPath(in: .library) == [linked])
        router.setListSelection(other, in: .library)
        #expect(router.libraryPath == [other])
        router.setListSelection(nil, in: .library)
        #expect(router.libraryPath.isEmpty)
        // With nothing selected, a pushed screen becomes the selection.
        router.setDetailPath([linked], in: .library)
        #expect(router.listSelection(in: .library) == linked)
    }

    @Test("Plan's tab returns to the Plan item last used")
    func lastPlanSection() {
        let router = sidebarRouter()
        router.select(.plan)
        #expect(router.selection == .tasks(.today))
        router.select(section: .calendar)
        router.select(section: .home)
        router.select(.plan)
        #expect(router.selection == .calendar)
        router.selectedTab = .library
        #expect(router.selection == .library)
        router.selectedTab = .plan
        #expect(router.selection == .calendar)
    }

    @Test("show(_:in:) selects a section with one screen in front")
    func show() {
        let router = Router()
        let created = note()
        router.sheet = .create(.note)
        router.show(created, in: .library)
        #expect(router.sheet == nil)
        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == [created])
        router.setLayout(.sidebar)
        #expect(router.listSelection(in: .library) == created)
    }

    @Test("deleted collections leave the sidebar")
    func retainCollections() {
        let router = sidebarRouter()
        let kept = NoteCollection.ID()
        let removed = NoteCollection.ID()
        router.select(section: .collection(kept))
        router.push(note())
        router.select(section: .collection(removed))
        router.push(note())
        router.retainCollections([kept])
        #expect(router.selection == .library)
        #expect(router.path(for: .collection(removed)).isEmpty)
        #expect(router.path(for: .collection(kept)).count == 1)
    }
}

@MainActor
@Suite("Router layout changes")
struct RouterLayoutTests {
    @Test("Plan's stack becomes the sidebar item it shows, and comes back")
    func planRoundTrip() {
        let router = Router()
        let opened = task()
        let pushed = task()
        router.open(.tasks(.inbox))
        router.push(opened)
        router.push(pushed)

        router.setLayout(.sidebar)
        #expect(router.layout == .sidebar)
        #expect(router.selection == .tasks(.inbox))
        #expect(router.listSelection(in: .tasks(.inbox)) == opened)
        #expect(router.detailPath(in: .tasks(.inbox)) == [pushed])
        #expect(router.planPath.isEmpty)

        router.setLayout(.tabBar)
        #expect(router.selection == .plan)
        #expect(router.planPath == [.tasks(.inbox), opened, pushed])
        #expect(router.path(for: .tasks(.inbox)).isEmpty)
    }

    @Test("the Plan overview opens the Plan item last used; an unselected Plan keeps its place")
    func planOverview() {
        let router = Router()
        router.select(.plan)
        router.setLayout(.sidebar)
        #expect(router.selection == .tasks(.today))

        let opened = task()
        router.open(.calendar)
        router.push(opened)
        router.select(section: .home)
        router.setLayout(.tabBar)
        #expect(router.selection == .home)
        #expect(router.planPath == [.calendar, opened])

        // Unused, Plan stays on its overview.
        let fresh = Router()
        fresh.setLayout(.sidebar)
        fresh.setLayout(.tabBar)
        #expect(fresh.planPath.isEmpty)
    }

    @Test("a screen pushed straight onto the Plan overview stays in front")
    func entityOnPlanOverview() {
        let router = Router()
        let opened = task()
        router.select(.plan)
        router.push(opened)
        router.setLayout(.sidebar)
        #expect(router.selection == .tasks(.today))
        #expect(router.listSelection(in: .tasks(.today)) == opened)
    }

    @Test("collections and Insights move into their tabs' stacks and back")
    func collectionAndInsights() {
        let router = sidebarRouter()
        let collection = NoteCollection.ID()
        let opened = note()
        router.select(section: .collection(collection))
        router.push(opened)
        router.setLayout(.tabBar)
        #expect(router.selection == .library)
        #expect(router.libraryPath == [.entity(EntityReference(kind: .collection, id: collection)), opened])

        router.setLayout(.sidebar)
        #expect(router.selection == .collection(collection))
        #expect(router.listSelection(in: .collection(collection)) == opened)
        #expect(router.libraryPath.isEmpty)

        router.open(.insights)
        router.setLayout(.tabBar)
        #expect(router.selection == .home)
        #expect(router.homePath == [.insights])
        router.setLayout(.sidebar)
        #expect(router.selection == .insights)
        #expect(router.homePath.isEmpty)
    }

    @Test("sections both layouts share keep their paths")
    func sharedSections() {
        let router = Router()
        let conversation = AppDestination.entity(EntityReference(kind: "conversation", id: UUID()))
        router.select(.assistant)
        router.push(conversation)
        router.homePath = [.automations]
        router.setLayout(.sidebar)
        #expect(router.selection == .assistant)
        #expect(router.listSelection(in: .assistant) == conversation)
        // Automations opened on Home stays there: its sidebar item belongs to Plan.
        #expect(router.homePath == [.automations])
        router.setLayout(.tabBar)
        #expect(router.assistantPath == [conversation])
    }

    @Test("sections are available in the layouts that show them")
    func availability() {
        #expect(NavigationSection.plan.isAvailable(in: .tabBar))
        #expect(!NavigationSection.plan.isAvailable(in: .sidebar))
        for section in NavigationSection.planSections {
            #expect(section.isAvailable(in: .sidebar))
            #expect(!section.isAvailable(in: .tabBar))
            #expect(section.tab == .plan)
            #expect(section.rootDestination.flatMap(NavigationSection.init(root:)) == section)
        }
        for tab in AppTab.allCases {
            #expect(NavigationSection(tab).isAvailable(in: .tabBar))
            #expect(NavigationSection(tab).tab == tab)
        }
        #expect(Set(NavigationSection.planSections.map(\.id)).count == NavigationSection.planSections.count)
    }
}

@MainActor
@Suite("Keyboard commands")
struct KeyboardCommandTests {
    @Test("every command has its own shortcut; ⌘1…⌘5 follow the tabs")
    func shortcuts() {
        let shortcuts = AppCommand.all.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(AppCommand.commandPalette.shortcut == CommandShortcut("k"))
        #expect(AppCommand.quickCapture.shortcut == CommandShortcut("n"))
        #expect(AppCommand.newNote.shortcut == CommandShortcut("n", [.command, .shift]))
        #expect(AppCommand.find.shortcut == CommandShortcut("f"))
        #expect(AppCommand.settings.shortcut == CommandShortcut(","))
        #expect(AppTab.allCases.map { AppCommand.showSection($0).shortcut.key } == ["1", "2", "3", "4", "5"])
    }

    @Test("commands open the palette, capture, a new note and settings")
    func sheets() {
        let router = Router()
        router.perform(.commandPalette)
        #expect(router.sheet == .commandPalette)
        router.perform(.commandPalette)
        #expect(router.sheet == nil)
        router.perform(.quickCapture)
        #expect(router.sheet == .capture(text: nil))
        router.perform(.newNote)
        #expect(router.sheet == .create(.note))
        router.perform(.settings)
        #expect(router.sheet == .settings(.general))
        router.dismissCommandPalette()
        #expect(router.sheet == .settings(.general))
    }

    @Test("⌘1…⌘5 switch sections without popping them and close sheets")
    func showSection() {
        let router = Router()
        let opened = task()
        router.open(.tasks(.today))
        router.push(opened)
        router.sheet = .capture(text: nil)
        router.perform(.showSection(.library))
        #expect(router.sheet == nil)
        #expect(router.selectedTab == .library)
        router.perform(.showSection(.plan))
        router.perform(.showSection(.plan))
        #expect(router.planPath == [.tasks(.today), opened])

        let sidebar = sidebarRouter()
        sidebar.open(.calendar)
        sidebar.perform(.showSection(.home))
        sidebar.perform(.showSection(.plan))
        #expect(sidebar.selection == .calendar)
    }

    @Test("⌘F focuses the current list's search, or universal search")
    func find() {
        let router = Router()
        let conversation = AppDestination.entity(EntityReference(kind: "conversation", id: UUID()))
        router.select(.assistant)
        router.push(conversation)
        router.perform(.find)
        // In the tab bar the list is the root screen, so the stack returns to it.
        #expect(router.assistantPath.isEmpty)
        #expect(router.searchFocusRequest?.section == .assistant)
        #expect(!router.claimSearchFocus(in: .search))
        #expect(router.claimSearchFocus(in: .assistant))
        #expect(router.searchFocusRequest == nil)
        #expect(!router.claimSearchFocus(in: .assistant))

        router.select(.plan)
        router.perform(.find)
        #expect(router.selection == .search)
        #expect(router.claimSearchFocus(in: .search))

        // Beside its detail the list stays visible, so the detail is kept.
        let sidebar = sidebarRouter()
        sidebar.select(.assistant)
        sidebar.push(conversation)
        sidebar.perform(.find)
        #expect(sidebar.listSelection(in: .assistant) == conversation)
        #expect(sidebar.searchFocusRequest?.section == .assistant)

        // Repeated requests are distinct.
        let first = sidebar.searchFocusRequest
        sidebar.perform(.find)
        #expect(sidebar.searchFocusRequest != first)

        // The palette's own field already has focus.
        sidebar.perform(.commandPalette)
        _ = sidebar.claimSearchFocus(in: .assistant)
        sidebar.perform(.find)
        #expect(sidebar.sheet == .commandPalette)
        #expect(sidebar.searchFocusRequest == nil)
    }
}
