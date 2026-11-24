import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("Analytics measures")
struct AnalyticsMeasureTests {
    static let minutes = AnalyticsMeasure(id: "focus.minutes", events: [Fixture.focused], attribute: "focusedMinutes")

    func harness() async throws -> (AnalyticsHarness, AnalyticsCollector) {
        let harness = try await AnalyticsHarness.make()
        let environment = harness.environment
        let collector = AnalyticsCollector(
            database: environment.database,
            events: environment.events,
            settings: environment.settings,
            timeSource: environment.clock,
            calendar: .testUTC,
            logger: environment.logger("analytics"),
            measures: [Self.minutes]
        )
        return (harness, collector)
    }

    @Test("only finite positive numbers of the measured events count")
    func amounts() {
        let at = ManualTimeSource.referenceDate
        #expect(Self.minutes.amount(in: DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 12.5], occurredAt: at)) == 12.5)
        #expect(Self.minutes.amount(in: DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 0], occurredAt: at)) == nil)
        #expect(Self.minutes.amount(in: DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": -3], occurredAt: at)) == nil)
        #expect(Self.minutes.amount(in: DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": "25"], occurredAt: at)) == nil)
        #expect(Self.minutes.amount(in: DomainEvent(name: Fixture.completed, attributes: ["focusedMinutes": 25], occurredAt: at)) == nil)
    }

    @Test("totals are summed per day with the event, once per event, and erased with the data")
    func totals() async throws {
        let (harness, collector) = try await harness()
        let first = DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 25], occurredAt: instant("2026-11-20", hour: 9))
        #expect(try await collector.record(first) == .recorded)
        #expect(try await collector.record(first) == .duplicate)
        try await collector.record(DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 7.5], actor: .assistant, occurredAt: instant("2026-11-20", hour: 15)))
        try await collector.record(DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 50], occurredAt: instant("2026-11-21", hour: 8)))
        try await collector.record(DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-21", hour: 8)))

        let week = DayRange(start: day("2026-11-16"), end: day("2026-11-22"))
        #expect(try await harness.service.total(of: Self.minutes.id, in: week) == 82.5)
        #expect(try await harness.service.total(of: Self.minutes.id, in: DayRange(day: day("2026-11-20"))) == 32.5)
        let series = try await harness.service.dailyTotals(of: Self.minutes.id, in: week)
        #expect(series.points.count == 7)
        #expect(series.value(on: day("2026-11-21")) == 50)
        #expect(series.value(on: day("2026-11-22")) == 0)
        #expect(try await harness.service.total(of: "unknown", in: week) == 0)
        // The event is counted as usual as well.
        #expect(try await harness.service.totalCount(of: [Fixture.focused], in: week) == 3)

        try await harness.service.eraseAllData()
        #expect(try await harness.service.total(of: Self.minutes.id, in: week) == 0)
    }

    @Test("nothing is totalled while collection is off")
    func disabled() async throws {
        let (harness, collector) = try await harness()
        try await harness.service.setCollectionEnabled(false)
        #expect(try await collector.record(DomainEvent(name: Fixture.focused, attributes: ["focusedMinutes": 25], occurredAt: instant("2026-11-20", hour: 9))) == .collectionDisabled)
        #expect(try await harness.service.total(of: Self.minutes.id, in: DayRange(day: day("2026-11-20"))) == 0)
    }
}
