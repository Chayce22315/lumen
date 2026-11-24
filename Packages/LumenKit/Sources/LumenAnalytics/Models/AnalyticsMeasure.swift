import Foundation
import LumenCore

/// A quantity summed per day from a numeric event attribute — for example minutes of focus from
/// the `focusedMinutes` attribute of a finished focus session.
///
/// Like `ProductivitySignals`, measures are defined by the application layer: analytics only
/// knows that events named `events` carry a number under `attribute`. The collector adds that
/// number to the measure's daily total in the same transaction as the event itself, so totals
/// outlive raw-event retention exactly as daily counts do.
public struct AnalyticsMeasure: Sendable, Hashable, Codable, Identifiable {
    /// Persisted with every total; never change it once shipped.
    public let id: String
    public let events: Set<EventName>
    public let attribute: String

    public init(id: String, events: Set<EventName>, attribute: String) {
        self.id = id
        self.events = events
        self.attribute = attribute
    }

    /// The amount `event` contributes: the attribute's value when it is a finite, positive number.
    public func amount(in event: DomainEvent) -> Double? {
        guard events.contains(event.name), case .number(let value)? = event.attributes[attribute], value.isFinite, value > 0 else {
            return nil
        }
        return value
    }
}
