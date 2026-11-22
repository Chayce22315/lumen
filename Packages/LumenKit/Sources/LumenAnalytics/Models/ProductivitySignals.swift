import Foundation
import LumenCore

/// How the application layer tells analytics what its events mean.
///
/// Analytics is generic over event names: it never knows which module completes tasks or
/// creates notes. The composition root builds one `ProductivitySignals` value (for example,
/// `completionEvents: ["organization.task.completed"]`) and passes it to insight and report
/// queries. An empty set means the corresponding insights are simply not produced.
public struct ProductivitySignals: Sendable, Hashable, Codable {
    /// Events that mean a piece of work was finished.
    public var completionEvents: Set<EventName>
    /// Events that mean a new piece of work was added.
    public var creationEvents: Set<EventName>
    /// Events that mean focused work happened (for example a finished focus session).
    public var focusEvents: Set<EventName>
    /// Display names for event modules (`["organization": "Tasks"]`). Modules without an entry
    /// are shown with their capitalized module name.
    public var moduleDisplayNames: [String: String]
    /// What a completion or creation counts, used in insight and report text ("14 tasks").
    public var unit: WorkUnit

    public init(
        completionEvents: Set<EventName> = [],
        creationEvents: Set<EventName> = [],
        focusEvents: Set<EventName> = [],
        moduleDisplayNames: [String: String] = [:],
        unit: WorkUnit = .item
    ) {
        self.completionEvents = completionEvents
        self.creationEvents = creationEvents
        self.focusEvents = focusEvents
        self.moduleDisplayNames = moduleDisplayNames
        self.unit = unit
    }

    /// Every event name the signals refer to.
    public var allEvents: Set<EventName> {
        completionEvents.union(creationEvents).union(focusEvents)
    }

    /// The display name for an event module.
    public func displayName(forModule module: String) -> String {
        if let name = moduleDisplayNames[module], !name.isEmpty { return name }
        guard let first = module.first else { return module }
        return first.uppercased() + module.dropFirst()
    }
}

/// The noun for one unit of work, singular and plural ("task" / "tasks").
public struct WorkUnit: Sendable, Hashable, Codable {
    public var singular: String
    public var plural: String

    public init(singular: String, plural: String) {
        self.singular = singular
        self.plural = plural
    }

    /// The neutral default when the application has not named its unit.
    public static let item = WorkUnit(singular: "item", plural: "items")

    /// `singular` for exactly one, `plural` otherwise.
    public func noun(for count: Int) -> String {
        count == 1 ? singular : plural
    }
}
