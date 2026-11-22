import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("AttributeFilter and records")
struct AttributeFilterTests {
    @Test("only scalar attributes survive")
    func scalarsOnly() {
        let filtered = AttributeFilter.filter([
            "done": true,
            "count": 3,
            "status": "open",
            "missing": nil,
            "tags": ["a", "b"],
            "nested": ["key": "value"],
        ])
        #expect(filtered == ["done": true, "count": 3, "status": "open"])
    }

    @Test("strings longer than 128 characters are dropped")
    func stringLength() {
        let limit = String(repeating: "é", count: 128)
        let tooLong = String(repeating: "a", count: 129)
        let filtered = AttributeFilter.filter(["fits": .string(limit), "long": .string(tooLong)])
        #expect(filtered == ["fits": .string(limit)])
    }

    @Test("non-finite numbers and unusable keys are dropped")
    func numbersAndKeys() {
        let filtered = AttributeFilter.filter([
            "nan": .number(.nan),
            "infinite": .number(.infinity),
            "ok": 1.5,
            "": "empty key",
            String(repeating: "k", count: 129): "long key",
        ])
        #expect(filtered == ["ok": 1.5])
    }

    @Test("at most eight keys are kept, the first in key order")
    func keyLimit() {
        let attributes = Dictionary(uniqueKeysWithValues: (0..<12).map { (String(format: "k%02d", $0), JSONValue.number(Double($0))) })
        let filtered = AttributeFilter.filter(attributes)
        #expect(filtered.count == AttributeFilter.maximumKeys)
        #expect(filtered.keys.sorted() == (0..<8).map { String(format: "k%02d", $0) })
        #expect(AttributeFilter.filter(attributes) == filtered)
    }

    @Test("a record keeps the event's identity, entity and actor and resolves day and hour in the calendar")
    func recordFromEvent() {
        let entity = EntityReference(kind: "task", id: UUID())
        let event = DomainEvent(
            name: Fixture.completed,
            entity: entity,
            attributes: ["priority": 2, "body": .string(String(repeating: "x", count: 500))],
            actor: .automation,
            occurredAt: instant("2026-11-21", hour: 23, minute: 30)
        )
        let utc = AnalyticsEventRecord(event: event, calendar: .testUTC)
        #expect(utc.id.rawValue == event.id)
        #expect(utc.entity == entity)
        #expect(utc.actor == .automation)
        #expect(utc.module == "organization")
        #expect(utc.day == day("2026-11-21"))
        #expect(utc.hour == 23)
        #expect(utc.attributes == ["priority": 2])

        let tokyo = AnalyticsEventRecord(event: event, calendar: Fixture.calendar(timeZone: "Asia/Tokyo"))
        #expect(tokyo.day == day("2026-11-22"))
        #expect(tokyo.hour == 8)
    }
}
