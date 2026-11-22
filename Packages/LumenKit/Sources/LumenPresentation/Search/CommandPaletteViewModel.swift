import Foundation
import Observation
import LumenFoundation
import LumenSearch
import LumenApplication

/// Universal search and the command palette: commands, content and history for one query.
@MainActor
@Observable
public final class CommandPaletteViewModel {
    public var query = "" {
        didSet { scheduleSearch() }
    }
    public var kindFilter: Set<EntityKind>? {
        didSet { scheduleSearch() }
    }
    public private(set) var results: PaletteResults?
    public private(set) var isSearching = false

    private let services: LumenServices
    private let debounce: TimeInterval
    private let pending = ObservationHandle()

    public init(services: LumenServices, debounce: TimeInterval = 0.12) {
        self.services = services
        self.debounce = debounce
    }

    public func start() async {
        await search()
    }

    /// Runs the current query immediately.
    public func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await services.search.service.palette(query, kinds: kindFilter)
        } catch {
            services.errors.report(error, context: "Searching")
        }
    }

    /// The user committed to a result: remember the query and navigate.
    public func open(_ result: SearchResult, router: Router) async {
        await remember()
        router.open(.entity(result.reference))
    }

    public func useHistory(_ entry: SearchHistoryEntry) {
        query = entry.query
    }

    public func removeHistory(_ entry: SearchHistoryEntry) async {
        do {
            try await services.search.service.removeHistoryEntry(entry.query)
            await search()
        } catch {
            services.errors.report(error, context: "Editing search history")
        }
    }

    public func clearHistory() async {
        do {
            try await services.search.service.clearHistory()
            await search()
        } catch {
            services.errors.report(error, context: "Clearing search history")
        }
    }

    public func remember() async {
        do {
            try await services.search.service.recordSearch(query)
        } catch {
            services.errors.report(error, context: "Saving search history")
        }
    }

    private func scheduleSearch() {
        let delay = UInt64(debounce * 1_000_000_000)
        pending.replace(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.search()
        })
    }
}
