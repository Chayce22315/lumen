import Foundation
import LumenFoundation

/// Name of a domain event: `<module>.<entity>.<verb>`, e.g. `organization.task.completed`.
/// Names are persisted by analytics and referenced by saved automations, so they never change.
public struct EventName: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: EventName, rhs: EventName) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The module segment (`organization` for `organization.task.completed`).
    public var module: String {
        String(rawValue.prefix(while: { $0 != "." }))
    }
}

extension EventName: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension EventName: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Who caused an event. Automations ignore events caused by themselves beyond a bounded depth,
/// and analytics distinguishes user work from automated work.
public enum EventActor: String, Sendable, Codable, Hashable, CaseIterable {
    case user
    case assistant
    case automation
    case sync
    case plugin
    case system
}

/// Something that happened in Lumen, after it was committed to storage.
public struct DomainEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: EventName
    public let entity: EntityReference?
    /// Small, display-safe attributes (identifiers, statuses, counts). Never full documents.
    public let attributes: [String: JSONValue]
    public let actor: EventActor
    public let occurredAt: Date
    /// Groups events that stem from the same root cause (one automation run, one assistant turn).
    public let correlationID: UUID?
    /// How many automation hops led to this event; automations stop reacting past a limit.
    public let causationDepth: Int

    public init(
        id: UUID = UUID(),
        name: EventName,
        entity: EntityReference? = nil,
        attributes: [String: JSONValue] = [:],
        actor: EventActor = .user,
        occurredAt: Date,
        correlationID: UUID? = nil,
        causationDepth: Int = 0
    ) {
        self.id = id
        self.name = name
        self.entity = entity
        self.attributes = attributes
        self.actor = actor
        self.occurredAt = occurredAt
        self.correlationID = correlationID
        self.causationDepth = max(0, causationDepth)
    }
}

/// Context passed down by callers so that the events a service publishes carry the right actor
/// and causation chain.
public struct ActionContext: Sendable, Hashable {
    public var actor: EventActor
    public var correlationID: UUID?
    public var causationDepth: Int

    public init(actor: EventActor = .user, correlationID: UUID? = nil, causationDepth: Int = 0) {
        self.actor = actor
        self.correlationID = correlationID
        self.causationDepth = causationDepth
    }

    public static let user = ActionContext(actor: .user)
    public static let system = ActionContext(actor: .system)

    /// Builds an event stamped with this context.
    public func event(
        _ name: EventName,
        entity: EntityReference? = nil,
        attributes: [String: JSONValue] = [:],
        at date: Date
    ) -> DomainEvent {
        DomainEvent(
            name: name,
            entity: entity,
            attributes: attributes,
            actor: actor,
            occurredAt: date,
            correlationID: correlationID,
            causationDepth: causationDepth
        )
    }
}
