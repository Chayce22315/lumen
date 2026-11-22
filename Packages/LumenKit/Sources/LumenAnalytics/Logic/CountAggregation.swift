import Foundation
import LumenFoundation
import LumenCore

/// Filtering and summing of daily counts, shared by insights, reports and the service.
extension Array where Element == DailyCount {
    /// Counts matching `names` (all names when `nil`), `range` (all days when `nil`) and `actors`
    /// (all actors when `nil`).
    func matching(names: Set<EventName>?, in range: DayRange? = nil, actors: Set<EventActor>? = nil) -> [DailyCount] {
        filter { count in
            (names?.contains(count.name) ?? true)
                && (range?.contains(count.day) ?? true)
                && (actors?.contains(count.actor) ?? true)
        }
    }

    func total(names: Set<EventName>?, in range: DayRange? = nil, actors: Set<EventActor>? = nil) -> Int {
        matching(names: names, in: range, actors: actors).reduce(0) { $0 + $1.count }
    }

    func countsByDay(names: Set<EventName>?, in range: DayRange? = nil, actors: Set<EventActor>? = nil) -> [CalendarDate: Int] {
        var result: [CalendarDate: Int] = [:]
        for count in matching(names: names, in: range, actors: actors) {
            result[count.day, default: 0] += count.count
        }
        return result
    }

    func valuesByDay(names: Set<EventName>?, in range: DayRange? = nil, actors: Set<EventActor>? = nil) -> [CalendarDate: Double] {
        countsByDay(names: names, in: range, actors: actors).mapValues(Double.init)
    }

    func activeDays(names: Set<EventName>?, in range: DayRange? = nil, actors: Set<EventActor>? = nil) -> Set<CalendarDate> {
        Set(matching(names: names, in: range, actors: actors).filter { $0.count > 0 }.map(\.day))
    }
}

/// Builds usage summaries and per-module counts from daily counts.
public enum UsageSummaryBuilder {
    /// Per-module event counts in `range`, most used first; ties by module name.
    public static func modules(_ counts: [DailyCount], in range: DayRange, signals: ProductivitySignals) -> [ModuleUsage] {
        var perModule: [String: Int] = [:]
        for count in counts.matching(names: nil, in: range) {
            perModule[count.name.module, default: 0] += count.count
        }
        return perModule
            .filter { $0.value > 0 }
            .map { ModuleUsage(module: $0.key, displayName: signals.displayName(forModule: $0.key), count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.module < rhs.module
            }
    }

    /// Per-actor event counts in `range`, most frequent first; ties in `EventActor.allCases` order.
    public static func actors(_ counts: [DailyCount], in range: DayRange) -> [ActorUsage] {
        var perActor: [EventActor: Int] = [:]
        for count in counts.matching(names: nil, in: range) {
            perActor[count.actor, default: 0] += count.count
        }
        let order = Dictionary(uniqueKeysWithValues: EventActor.allCases.enumerated().map { ($1, $0) })
        return perActor
            .filter { $0.value > 0 }
            .map { ActorUsage(actor: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : (order[lhs.actor] ?? 0) < (order[rhs.actor] ?? 0)
            }
    }

    /// The usage summary of `range`. Active days are days with at least one event caused by the user.
    public static func summary(_ counts: [DailyCount], in range: DayRange, signals: ProductivitySignals) -> UsageSummary {
        UsageSummary(
            range: range,
            totalEvents: counts.total(names: nil, in: range),
            activeDays: counts.activeDays(names: nil, in: range, actors: [.user]).count,
            modules: modules(counts, in: range, signals: signals),
            actors: actors(counts, in: range)
        )
    }
}
