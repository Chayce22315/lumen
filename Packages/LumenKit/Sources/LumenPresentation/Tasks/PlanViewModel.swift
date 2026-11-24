import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// The Plan screen: the smart lists with their live counts.
@MainActor
@Observable
public final class PlanViewModel {
    /// The smart lists in display order.
    public static let lists: [SmartList] = [.today, .upcoming, .overdue, .inbox, .anytime, .completed]

    /// Open tasks per list. `nil` until the first load; Completed is not counted.
    public private(set) var counts: [SmartList: Int]?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    /// Loads the counts and keeps them current as tasks change anywhere (capture, sync, the
    /// assistant, automations).
    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["organization", "sync"], entityKinds: [.task]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        do {
            var result: [SmartList: Int] = [:]
            for list in Self.lists where list != .completed {
                result[list] = try await services.organization.tasks.list(list).count
            }
            counts = result
        } catch {
            services.errors.report(error, context: "Counting tasks")
        }
    }

    /// The badge for a list, or `nil` when there is nothing to show.
    public func badge(for list: SmartList) -> Int? {
        guard list != .completed, let count = counts?[list], count > 0 else { return nil }
        return count
    }

    /// Overdue work is highlighted.
    public func isAlerting(_ list: SmartList) -> Bool {
        list == .overdue && badge(for: list) != nil
    }
}
