import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("AnalyticsCollector")
struct AnalyticsCollectorTests {
    let november = DayRange(start: day("2026-11-01"), end: day("2026-11-30"))

    func dailyCount(_ harness: AnalyticsHarness, day dayText: String, name: EventName, actor: EventActor) async throws -> Int? {
        let date = day(dayText)
        return try await harness.environment.database.read { db in
            try db.scalar(
                "SELECT count FROM analytics_daily_counts WHERE day = ? AND name = ? AND actor = ?",
                [date, name.rawValue, actor.rawValue]
            )
        }
    }

    @Test("an event is stored with its day, hour, entity and filtered attributes")
    func recordsEvent() async throws {
        let harness = try await AnalyticsHarness.make()
        let entity = EntityReference(kind: "task", id: UUID())
        let outcome = try await harness.record(
            Fixture.completed,
            at: instant("2026-11-20", hour: 14, minute: 5),
            entity: entity,
            attributes: ["priority": 2, "title": .string(String(repeating: "x", count: 200)), "tags": ["a"]]
        )
        #expect(outcome == .recorded)
        let record = try #require(try await harness.service.recentEvents().first)
        #expect(record.name == Fixture.completed)
        #expect(record.day == day("2026-11-20"))
        #expect(record.hour == 14)
        #expect(record.entity == entity)
        #expect(record.actor == .user)
        #expect(record.attributes == ["priority": 2])
    }

    @Test("daily counts grow with every event of the same day, name and actor")
    func dailyCounts() async throws {
        let harness = try await AnalyticsHarness.make()
        try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 9))
        try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 17))
        try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 18), actor: .automation)
        try await harness.record(Fixture.completed, at: instant("2026-11-21", hour: 8))

        #expect(try await dailyCount(harness, day: "2026-11-20", name: Fixture.completed, actor: .user) == 2)
        #expect(try await dailyCount(harness, day: "2026-11-20", name: Fixture.completed, actor: .automation) == 1)
        #expect(try await dailyCount(harness, day: "2026-11-21", name: Fixture.completed, actor: .user) == 1)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: november) == 4)
    }

    @Test("recording the same event twice stores it once")
    func duplicates() async throws {
        let harness = try await AnalyticsHarness.make()
        let event = DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-20", hour: 9))
        #expect(try await harness.collector.record(event) == .recorded)
        #expect(try await harness.collector.record(event) == .duplicate)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: november) == 1)
        #expect(try await harness.service.recentEvents().count == 1)
        let statistics = await harness.collector.statistics()
        #expect(statistics.recorded == 1)
        #expect(statistics.duplicates == 1)
    }

    @Test("nothing is recorded while collection is disabled")
    func disabledCollection() async throws {
        let harness = try await AnalyticsHarness.make()
        try await harness.service.setCollectionEnabled(false)
        #expect(try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 9)) == .collectionDisabled)
        #expect(try await harness.service.recentEvents().isEmpty)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: november) == 0)
        #expect(await harness.collector.statistics().skippedWhileDisabled == 1)

        try await harness.service.setCollectionEnabled(true)
        #expect(try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 10)) == .recorded)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: november) == 1)
    }

    @Test("analytics' own events are not recorded")
    func ownEventsIgnored() async throws {
        let harness = try await AnalyticsHarness.make()
        #expect(try await harness.record(AnalyticsEvents.dataErased, at: instant("2026-11-20", hour: 9)) == .ignored)
        #expect(try await harness.service.recentEvents().isEmpty)
    }

    @Test("the subscription records published events until stopped")
    func subscription() async throws {
        let harness = try await AnalyticsHarness.make()
        let bus = harness.environment.events
        await harness.collector.start()
        await harness.collector.start() // idempotent
        #expect(await harness.collector.isRunning)
        #expect(bus.subscriberCount == 1)

        bus.publish(DomainEvent(name: Fixture.created, occurredAt: instant("2026-11-20", hour: 9)))
        bus.publish(DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-20", hour: 10)))
        bus.publish(DomainEvent(name: Fixture.completed, actor: .assistant, occurredAt: instant("2026-11-21", hour: 8)))
        let statistics = await harness.waitForProcessed(3)
        #expect(statistics.recorded == 3)
        #expect(try await harness.service.counts(of: [Fixture.completed, Fixture.created], in: november)
            == [Fixture.completed: 2, Fixture.created: 1])

        await harness.collector.stop()
        #expect(!(await harness.collector.isRunning))
        let deadline = Date().addingTimeInterval(2)
        while bus.subscriberCount > 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(bus.subscriberCount == 0)
        bus.publish(DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-21", hour: 9)))
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: november) == 2)
    }

    @Test("a failed write is counted and logged, and the subscription keeps running")
    func failuresAreReported() async throws {
        // An environment without the analytics schema makes every write fail.
        let environment = try await CoreTestEnvironment.make()
        let collector = AnalyticsCollector(
            database: environment.database,
            events: environment.events,
            settings: environment.settings,
            timeSource: environment.clock,
            calendar: environment.calendar,
            logger: environment.logger("analytics")
        )
        await collector.start()
        environment.events.publish(DomainEvent(name: Fixture.completed, occurredAt: environment.clock.now()))
        let deadline = Date().addingTimeInterval(2)
        while await collector.statistics().failed < 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await collector.statistics().failed == 1)
        #expect(await collector.isRunning)
        #expect(environment.logs.entries(atLeast: .error).contains { $0.message == "Analytics event could not be recorded" })
        await collector.stop()
    }

    @Test("purging removes old raw events and keeps daily counts")
    func purge() async throws {
        let harness = try await AnalyticsHarness.make()
        let today = day("2026-11-21")
        for offset in [200, 181, 180, 10] {
            let date = today.adding(days: -offset).startDate(in: .testUTC).addingTimeInterval(12 * 3_600)
            try await harness.record(Fixture.completed, at: date)
        }
        let year = DayRange.lastDays(366, endingOn: today)

        #expect(try await harness.collector.purge() == 2)
        #expect(try await harness.service.recentEvents().map(\.day) == [today.adding(days: -10), today.adding(days: -180)])
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: year) == 4)

        #expect(try await harness.collector.purge(rawEventsOlderThan: 5) == 2)
        #expect(try await harness.service.recentEvents().isEmpty)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: year) == 4)
    }

    @Test("days and hours are resolved in the collector's calendar")
    func calendarTimeZone() async throws {
        let harness = try await AnalyticsHarness.make(calendar: Fixture.calendar(timeZone: "America/Los_Angeles"))
        try await harness.record(Fixture.completed, at: instant("2026-11-21", hour: 3))
        let record = try #require(try await harness.service.recentEvents().first)
        #expect(record.day == day("2026-11-20"))
        #expect(record.hour == 19)
        #expect(try await dailyCount(harness, day: "2026-11-20", name: Fixture.completed, actor: .user) == 1)
    }

    @Test("analytics never writes to the change log")
    func privateData() async throws {
        let harness = try await AnalyticsHarness.make()
        try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 9), entity: EntityReference(kind: "task", id: UUID()))
        let changes: Int? = try await harness.environment.database.read { db in
            try db.scalar("SELECT count(*) FROM lumen_changes")
        }
        #expect(changes == 0)
    }
}
