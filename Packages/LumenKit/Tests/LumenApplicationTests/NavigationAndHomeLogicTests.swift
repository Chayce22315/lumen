import Foundation
import Testing
import LumenFoundation
import LumenApplication
import LumenTestSupport

@Suite("Deep links")
struct DeepLinkTests {
    @Test("every destination round-trips through its URL", arguments: [
        AppDestination.home, .tasks(.overdue), .calendar, .library, .assistant, .automations, .insights,
        .notifications, .settings(.sync), .search(query: "budget review"), .search(query: nil),
        .capture(text: "Call Sam tomorrow"), .create(.note),
        .entity(EntityReference(kind: "task", id: UUID(uuidString: "6F1D2C5A-0C4B-4E0B-9C1F-2B6B3B2A9D11") ?? UUID())),
    ])
    func roundTrip(destination: AppDestination) throws {
        let url = try #require(DeepLink.url(for: destination))
        #expect(DeepLink.destination(from: url) == destination)
    }

    @Test("unknown or malformed links are rejected")
    func rejects() throws {
        #expect(DeepLink.destination(from: try #require(URL(string: "https://example.com/home"))) == nil)
        #expect(DeepLink.destination(from: try #require(URL(string: "lumen://nowhere"))) == nil)
        #expect(DeepLink.destination(from: try #require(URL(string: "lumen://tasks/someday"))) == nil)
        #expect(DeepLink.destination(from: try #require(URL(string: "lumen://entity/not-a-reference"))) == nil)
        #expect(DeepLink.destination(from: try #require(URL(string: "lumen://tasks"))) == .tasks(.today))
    }
}

@Suite("Greeting")
struct GreetingTests {
    let calendar = Calendar.testUTC
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.startOfDay(for: ManualTimeSource.referenceDate).addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    @Test("salutation follows the time of day and includes the name")
    func salutations() {
        #expect(GreetingComposer.greeting(now: at(7), calendar: calendar, name: "Riley", day: DayContext()).title == "Good morning, Riley")
        #expect(GreetingComposer.greeting(now: at(13), calendar: calendar, name: nil, day: DayContext()).title == "Good afternoon")
        #expect(GreetingComposer.greeting(now: at(19), calendar: calendar, name: "  ", day: DayContext()).title == "Good evening")
        #expect(GreetingComposer.greeting(now: at(2), calendar: calendar, name: nil, day: DayContext()).title == "Good night")
    }

    @Test("subtitle summarises the day")
    func subtitles() {
        let busy = GreetingComposer.greeting(now: at(8), calendar: calendar, name: nil, day: DayContext(dueToday: 3, overdue: 1, nextEventTitle: "Standup", nextEventStart: at(9, 30)))
        #expect(busy.subtitle == "3 tasks due today · 1 overdue · next: Standup at 09:30")
        #expect(GreetingComposer.greeting(now: at(8), calendar: calendar, name: nil, day: DayContext(completedToday: 4)).subtitle == "4 tasks done today. Nothing else is due.")
        #expect(GreetingComposer.greeting(now: at(8), calendar: calendar, name: nil, day: DayContext()).subtitle == "Nothing is due today.")
        // A past event is not announced.
        #expect(GreetingComposer.greeting(now: at(10), calendar: calendar, name: nil, day: DayContext(nextEventTitle: "Standup", nextEventStart: at(9))).subtitle == "Nothing is due today.")
    }
}

@Suite("Suggestions")
struct SuggestionTests {
    @Test("an empty, configured day suggests nothing")
    func quiet() {
        #expect(SuggestionEngine.suggestions(for: SuggestionContext(hour: 14)).isEmpty)
    }

    @Test("suggestions are ranked and limited")
    func ranking() {
        let project = SuggestionContext.StalledProject(reference: EntityReference(kind: "project", id: UUID()), name: "Website")
        let context = SuggestionContext(hour: 16, overdue: 2, stalledProjects: [project], unreviewedConflicts: 1, assistantConfigured: false, unreadNotifications: 3, currentStreak: 5)
        let all = SuggestionEngine.suggestions(for: context, limit: 10)
        #expect(all.map(\.kind) == [.reviewSyncConflicts, .reviewOverdue, .projectNeedsNextAction, .keepStreak, .readNotifications, .setUpAssistant])
        #expect(all.first { $0.kind == .projectNeedsNextAction }?.destination == .entity(project.reference))
        #expect(SuggestionEngine.suggestions(for: context).count == 3)
    }

    @Test("morning planning and celebration depend on the day")
    func timeSensitive() {
        #expect(SuggestionEngine.suggestions(for: SuggestionContext(hour: 9, openTasks: 4)).map(\.kind) == [.planToday])
        #expect(SuggestionEngine.suggestions(for: SuggestionContext(hour: 15, openTasks: 4)).isEmpty)
        #expect(SuggestionEngine.suggestions(for: SuggestionContext(hour: 18, completedToday: 3)).map(\.kind) == [.celebrate])
        // A streak is only at risk late in the day with nothing done yet.
        #expect(SuggestionEngine.suggestions(for: SuggestionContext(hour: 10, currentStreak: 4)).isEmpty)
    }
}

@Suite("Dashboard layout")
struct DashboardLayoutTests {
    @Test("normalising removes duplicates and appends missing widgets hidden")
    func normalize() {
        let layout = DashboardLayout(items: [DashboardItem(kind: .agenda), DashboardItem(kind: .agenda, isVisible: false), DashboardItem(kind: .focus)])
        let normalized = layout.normalized
        #expect(normalized.items.count == DashboardWidgetKind.allCases.count)
        #expect(normalized.items.prefix(2).map(\.kind) == [.agenda, .focus])
        #expect(normalized.items.dropFirst(2).allSatisfy { !$0.isVisible })
        #expect(DashboardLayout.standard.normalized == DashboardLayout.standard)
    }

    @Test("moving, hiding and resizing")
    func editing() {
        var layout = DashboardLayout.standard
        let first = layout.items[0].kind
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(layout.items[2].kind == first)
        layout.setVisible(false, for: .agenda)
        #expect(!layout.visibleItems.contains { $0.kind == .agenda })
        layout.setSize(.expanded, for: .projects)
        #expect(layout.items.first { $0.kind == .projects }?.size == .expanded)
        #expect(layout.items.count == DashboardWidgetKind.allCases.count)
    }

    @Test("layouts survive encoding")
    func coding() throws {
        let data = try JSONEncoder().encode(DashboardLayout.standard)
        #expect(try JSONDecoder().decode(DashboardLayout.self, from: data) == DashboardLayout.standard)
    }
}
