import Foundation
import LumenFoundation
import LumenCore

/// One domain event as analytics keeps it: device-local, never synchronized, never sent anywhere.
///
/// The day and hour are resolved once, when the event is recorded, in the calendar the collector
/// was given, so that "what did I do on Tuesday" keeps meaning the Tuesday the user lived through
/// even if they later travel to another time zone.
public struct AnalyticsEventRecord: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<AnalyticsEventRecord>

    /// The originating `DomainEvent.id`; recording the same event twice is therefore a no-op.
    public let id: ID
    public var name: EventName
    public var entityKind: EntityKind?
    public var entityID: UUID?
    public var actor: EventActor
    public var occurredAt: Date
    /// The calendar day the event happened on, in the recording calendar's time zone.
    public var day: CalendarDate
    /// Hour of day, 0–23, in the recording calendar's time zone.
    public var hour: Int
    /// Small scalar attributes only; see `AttributeFilter`.
    public var attributes: [String: JSONValue]

    public init(
        id: ID = ID(),
        name: EventName,
        entityKind: EntityKind? = nil,
        entityID: UUID? = nil,
        actor: EventActor,
        occurredAt: Date,
        day: CalendarDate,
        hour: Int,
        attributes: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.entityKind = entityKind
        self.entityID = entityID
        self.actor = actor
        self.occurredAt = occurredAt
        self.day = day
        self.hour = min(23, max(0, hour))
        self.attributes = attributes
    }

    /// The record for `event`, with its day and hour resolved in `calendar` and its attributes
    /// reduced by `AttributeFilter`.
    public init(event: DomainEvent, calendar: Calendar) {
        self.init(
            id: ID(event.id),
            name: event.name,
            entityKind: event.entity?.kind,
            entityID: event.entity?.id,
            actor: event.actor,
            occurredAt: event.occurredAt,
            day: CalendarDate(event.occurredAt, calendar: calendar),
            hour: calendar.component(.hour, from: event.occurredAt),
            attributes: AttributeFilter.filter(event.attributes)
        )
    }

    /// The entity the event was about, when it named one.
    public var entity: EntityReference? {
        guard let entityKind, let entityID else { return nil }
        return EntityReference(kind: entityKind, id: entityID)
    }

    /// The module that published the event (`organization` for `organization.task.completed`).
    public var module: String { name.module }
}
