import Foundation
import Testing
import LumenFoundation
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("Router")
struct RouterTests {
    @Test("destinations select the right tab, stack or sheet")
    func open() {
        let router = Router()
        router.open(.tasks(.overdue))
        #expect(router.selectedTab == .plan)
        #expect(router.planPath == [.tasks(.overdue)])
        router.open(.insights)
        #expect(router.selectedTab == .home)
        #expect(router.homePath == [.insights])
        router.open(.capture(text: "Milk"))
        #expect(router.sheet == .capture(text: "Milk"))
        router.open(.settings(.sync))
        #expect(router.sheet == .settings(.sync))
        router.open(.search(query: "budget"))
        #expect(router.sheet == nil)
        #expect(router.selectedTab == .search)
        #expect(router.pendingSearchQuery == "budget")
        let entity = AppDestination.entity(EntityReference(kind: "note", id: UUID()))
        router.open(entity)
        #expect(router.searchPath == [entity])
    }

    @Test("re-selecting the current tab pops to its root")
    func reselect() {
        let router = Router()
        router.open(.calendar)
        router.select(.plan)
        #expect(router.planPath.isEmpty)
        router.select(.library)
        #expect(router.selectedTab == .library)
    }
}

@Suite("Date labels")
struct DateLabelTests {
    let labels = DateLabels(calendar: .testUTC, locale: posix)
    let today = CalendarDate(year: 2026, month: 11, day: 21) ?? CalendarDate(Date(), calendar: .testUTC)

    @Test("relative day names")
    func days() {
        #expect(labels.dayLabel(today, today: today) == "Today")
        #expect(labels.dayLabel(today.adding(days: 1), today: today) == "Tomorrow")
        #expect(labels.dayLabel(today.adding(days: -1), today: today) == "Yesterday")
        #expect(labels.dayLabel(today.adding(days: 3), today: today) == "Tuesday")
        #expect(labels.dayLabel(today.adding(days: 12), today: today) == "Dec 3")
        #expect(labels.dayLabel(today.adding(days: 60), today: today) == "Jan 20, 2027")
    }

    @Test("due labels include the time")
    func due() throws {
        let time = try #require(TimeOfDay(hour: 15, minute: 30))
        // ICU separates "PM" with a narrow no-break space (U+202F); compare on plain spaces.
        #expect(labels.dueLabel(day: today, time: time, today: today).replacingOccurrences(of: "\u{202F}", with: " ") == "Today, 3:30 PM")
        #expect(labels.dueLabel(day: today, time: nil, today: today) == "Today")
    }

    @Test("relative instants")
    func relative() {
        let now = ManualTimeSource.referenceDate
        #expect(labels.relativeLabel(now.addingTimeInterval(-20), now: now) == "Just now")
        #expect(labels.relativeLabel(now.addingTimeInterval(-600), now: now) == "10 min ago")
        #expect(labels.relativeLabel(now.addingTimeInterval(-7_200), now: now) == "2 h ago")
        #expect(labels.relativeLabel(now.addingTimeInterval(-86_400), now: now) == "Yesterday")
    }
}
