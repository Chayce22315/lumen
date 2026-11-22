import Foundation
import LumenCore

/// Events recorded for one module.
public struct ModuleUsage: Sendable, Hashable, Codable, Identifiable {
    /// The module segment of the event names (`organization`).
    public let module: String
    public let displayName: String
    public let count: Int

    public init(module: String, displayName: String, count: Int) {
        self.module = module
        self.displayName = displayName
        self.count = count
    }

    public var id: String { module }
}

/// Events recorded for one kind of actor.
public struct ActorUsage: Sendable, Hashable, Codable, Identifiable {
    public let actor: EventActor
    public let count: Int

    public init(actor: EventActor, count: Int) {
        self.actor = actor
        self.count = count
    }

    public var id: EventActor { actor }
}

/// How Lumen was used over a range of days.
public struct UsageSummary: Sendable, Hashable, Codable {
    public let range: DayRange
    public let totalEvents: Int
    /// Days in the range with at least one event caused by the user (actor `.user`).
    public let activeDays: Int
    /// Most used first; ties ordered by module name.
    public let modules: [ModuleUsage]
    /// Most frequent first; ties ordered by `EventActor.allCases`.
    public let actors: [ActorUsage]

    public init(range: DayRange, totalEvents: Int, activeDays: Int, modules: [ModuleUsage], actors: [ActorUsage]) {
        self.range = range
        self.totalEvents = totalEvents
        self.activeDays = activeDays
        self.modules = modules
        self.actors = actors
    }

    public var eventsPerModule: [String: Int] {
        Dictionary(uniqueKeysWithValues: modules.map { ($0.module, $0.count) })
    }

    public var eventsPerActor: [EventActor: Int] {
        Dictionary(uniqueKeysWithValues: actors.map { ($0.actor, $0.count) })
    }

    /// Share of the range's days that were active (0…1).
    public var activeShare: Double {
        Double(activeDays) / Double(range.dayCount)
    }
}
