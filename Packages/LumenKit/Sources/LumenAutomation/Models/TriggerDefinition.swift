import Foundation
import LumenFoundation
import LumenCore

/// A repeating wall-clock schedule: the days of `rule` starting at `anchor`, each at `time` in the
/// calendar the engine is configured with.
public struct ScheduleTrigger: Sendable, Hashable, Codable {
    public var rule: RecurrenceRule
    /// The first day of the series.
    public var anchor: CalendarDate
    public var time: TimeOfDay

    public init(rule: RecurrenceRule, anchor: CalendarDate, time: TimeOfDay) {
        self.rule = rule
        self.anchor = anchor
        self.time = time
    }

    /// "Every day at 09:00".
    public var summary: String {
        "\(rule.summary) at \(time)"
    }
}

/// What starts a workflow.
public enum TriggerDefinition: Sendable, Hashable {
    /// Only when the user (or another automation) runs it explicitly.
    case manual
    /// When a domain event with this name is published and, if given, the condition holds. The
    /// condition sees the event as `trigger.*` (`trigger.attributes.priority`).
    case event(name: EventName, condition: Condition?)
    /// At the occurrences of a schedule. Missed occurrences are coalesced into one run.
    case schedule(ScheduleTrigger)

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case manual
        case event
        case schedule
    }

    public var kind: Kind {
        switch self {
        case .manual: return .manual
        case .event: return .event
        case .schedule: return .schedule
        }
    }

    public var eventName: EventName? {
        if case .event(let name, _) = self { return name }
        return nil
    }

    public var schedule: ScheduleTrigger? {
        if case .schedule(let schedule) = self { return schedule }
        return nil
    }

    /// A short description for the trigger node on the canvas.
    public var summary: String {
        switch self {
        case .manual: return "Run manually"
        case .event(let name, let condition):
            return condition == nil ? "When \(name.rawValue)" : "When \(name.rawValue), if conditions match"
        case .schedule(let schedule): return schedule.summary
        }
    }
}

extension TriggerDefinition: Codable {
    enum CodingKeys: String, CodingKey {
        case type, name, condition, schedule
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch Kind(rawValue: type) {
        case .manual:
            self = .manual
        case .event:
            self = .event(
                name: try container.decode(EventName.self, forKey: .name),
                condition: try container.decodeIfPresent(Condition.self, forKey: .condition)
            )
        case .schedule:
            self = .schedule(try container.decode(ScheduleTrigger.self, forKey: .schedule))
        case nil:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown trigger type '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .manual:
            break
        case .event(let name, let condition):
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(condition, forKey: .condition)
        case .schedule(let schedule):
            try container.encode(schedule, forKey: .schedule)
        }
    }
}
