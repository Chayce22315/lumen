import Foundation
import LumenFoundation
import LumenCore

/// Whether Lumen may use the system calendar store.
public enum ExternalCalendarAccess: String, Sendable, Hashable, Codable {
    /// The user has not been asked yet.
    case notDetermined
    case granted
    /// Denied or restricted; only the user can change it, in the system Settings app.
    case denied
}

/// A calendar in the system store.
public struct ExternalCalendar: Sendable, Hashable, Identifiable {
    /// The store's calendar identifier.
    public let id: String
    public let title: String
    /// The account the calendar belongs to ("iCloud", "Gmail", "On My iPhone").
    public let sourceName: String
    /// Subscribed and birthday calendars are read-only.
    public let isWritable: Bool

    public init(id: String, title: String, sourceName: String, isWritable: Bool) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.isWritable = isWritable
    }
}

/// A repeat rule in the system store's vocabulary (RFC 5545-style), independent of any framework
/// so it can be mapped and tested on every platform. `ExternalRecurrenceMapping` converts it to
/// and from Lumen's `RecurrenceRule`.
public struct ExternalRecurrence: Sendable, Hashable {
    public enum Frequency: String, Sendable, Hashable {
        case daily, weekly, monthly, yearly
    }

    public struct DayOfWeek: Sendable, Hashable {
        public let weekday: Weekday
        /// 0 for every week; 1…5 or -1…-5 for that week of the month (monthly rules).
        public let week: Int

        public init(weekday: Weekday, week: Int = 0) {
            self.weekday = weekday
            self.week = week
        }
    }

    public enum End: Sendable, Hashable {
        case never
        /// Total number of occurrences.
        case count(Int)
        /// The last instant an occurrence may start.
        case until(Date)
    }

    public var frequency: Frequency
    public var interval: Int
    public var daysOfWeek: [DayOfWeek]
    /// 1…31, or -1…-31 counting from the end of the month.
    public var daysOfMonth: [Int]
    public var monthsOfYear: [Int]
    public var weeksOfYear: [Int]
    public var daysOfYear: [Int]
    public var setPositions: [Int]
    public var end: End

    public init(
        frequency: Frequency,
        interval: Int = 1,
        daysOfWeek: [DayOfWeek] = [],
        daysOfMonth: [Int] = [],
        monthsOfYear: [Int] = [],
        weeksOfYear: [Int] = [],
        daysOfYear: [Int] = [],
        setPositions: [Int] = [],
        end: End = .never
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.weeksOfYear = weeksOfYear
        self.daysOfYear = daysOfYear
        self.setPositions = setPositions
        self.end = end
    }
}

/// An event in the system store, as Lumen reads and writes it.
public struct ExternalEventRecord: Sendable, Hashable {
    /// `nil` for an event that does not exist yet.
    public var identifier: String?
    public var calendarID: String
    public var title: String
    public var notes: String
    public var location: String
    public var timing: EventTiming
    public var recurrence: ExternalRecurrence?
    /// When `false`, saving leaves the stored repeat rule as it is (used when Lumen can't show the
    /// rule and the user did not change it).
    public var replacesRecurrence: Bool
    /// Alerts relative to the start, in minutes before it.
    public var alertOffsets: [Int]
    /// Alerts Lumen can't edit (at a fixed date and time, or after the start); saving keeps them.
    public var fixedAlertCount: Int

    public init(
        identifier: String? = nil,
        calendarID: String,
        title: String,
        notes: String = "",
        location: String = "",
        timing: EventTiming,
        recurrence: ExternalRecurrence? = nil,
        replacesRecurrence: Bool = true,
        alertOffsets: [Int] = [],
        fixedAlertCount: Int = 0
    ) {
        self.identifier = identifier
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.location = location
        self.timing = timing
        self.recurrence = recurrence
        self.replacesRecurrence = replacesRecurrence
        self.alertOffsets = alertOffsets
        self.fixedAlertCount = fixedAlertCount
    }
}

/// Writing support for `ExternalCalendarSource`. Read-only sources get these defaults: no
/// calendars to write to, and every write fails with `systemCalendarReadOnly`.
extension ExternalCalendarSource {
    public func authorization() async -> ExternalCalendarAccess {
        await isAuthorized() ? .granted : .denied
    }

    public func requestAuthorization() async throws -> Bool {
        await isAuthorized()
    }

    public func calendars() async throws -> [ExternalCalendar] { [] }

    public func event(identifier: String) async throws -> ExternalEventRecord? { nil }

    public func save(_ event: ExternalEventRecord) async throws -> String {
        throw OrganizationError.systemCalendarReadOnly
    }

    public func deleteEvent(identifier: String) async throws {
        throw OrganizationError.systemCalendarReadOnly
    }
}

/// Entity references for events that live in the system store, so changes to them flow through
/// the event bus like Lumen's own events. The identifier is mapped to a stable UUID.
public enum SystemCalendarEventReference {
    public static func reference(for identifier: String) -> EntityReference {
        EntityReference(kind: .systemCalendarEvent, id: stableUUID(identifier))
    }

    /// A deterministic, version-8 UUID from two FNV-1a hashes of the identifier.
    static func stableUUID(_ identifier: String) -> UUID {
        func fnv1a(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in identifier.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
            return hash
        }
        let high = fnv1a(0xCBF2_9CE4_8422_2325)
        let low = fnv1a(0x8422_2325_CBF2_9CE4 ^ UInt64(identifier.utf8.count))
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
