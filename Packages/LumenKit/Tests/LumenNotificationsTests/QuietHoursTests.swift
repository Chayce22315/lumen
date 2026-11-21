import Foundation
import Testing
import LumenNotifications
import LumenTestSupport

@Suite("QuietHours")
struct QuietHoursTests {
    let calendar = Calendar.testUTC

    func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let start = calendar.startOfDay(for: ManualTimeSource.referenceDate)
        return start.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3_600 + minute * 60))
    }

    @Test("a same-day window contains only its own minutes")
    func sameDay() {
        let hours = QuietHours(startMinute: 13 * 60, endMinute: 14 * 60)
        #expect(!hours.contains(date(12, 59), calendar: calendar))
        #expect(hours.contains(date(13), calendar: calendar))
        #expect(!hours.contains(date(14), calendar: calendar))
        #expect(hours.nextAllowedDate(onOrAfter: date(13, 30), calendar: calendar) == date(14))
    }

    @Test("a window that wraps midnight defers evening alerts to the next morning")
    func wrapping() {
        let hours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(hours.contains(date(23), calendar: calendar))
        #expect(hours.contains(date(3), calendar: calendar))
        #expect(!hours.contains(date(7), calendar: calendar))
        #expect(!hours.contains(date(12), calendar: calendar))
        #expect(hours.nextAllowedDate(onOrAfter: date(23, 15), calendar: calendar) == date(7, dayOffset: 1))
        #expect(hours.nextAllowedDate(onOrAfter: date(5), calendar: calendar) == date(7))
        #expect(hours.nextAllowedDate(onOrAfter: date(12), calendar: calendar) == date(12))
    }

    @Test("an empty window never applies and inputs are normalised")
    func edges() {
        #expect(!QuietHours(startMinute: 600, endMinute: 600).contains(date(10), calendar: calendar))
        #expect(QuietHours(startMinute: -60, endMinute: 1500).startMinute == 1380)
        #expect(QuietHours(startMinute: -60, endMinute: 1500).endMinute == 60)
    }
}
