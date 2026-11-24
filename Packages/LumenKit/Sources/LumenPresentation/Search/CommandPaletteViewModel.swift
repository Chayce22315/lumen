import Foundation
import Observation
import LumenFoundation
import LumenSearch
import LumenApplication

/// One row of the command palette.
public enum PaletteItem: Sendable, Hashable, Identifiable {
    case history(SearchHistoryEntry)
    case command(RankedCommand)
    case result(SearchResult)

    public var id: String {
        switch self {
        case .history(let entry): return "history:\(entry.query)"
        case .command(let ranked): return "command:\(ranked.command.id)"
        case .result(let result): return "result:\(result.reference.uri)"
        }
    }
}

/// A titled group of palette rows, in display order.
public struct PaletteSection: Sendable, Hashable, Identifiable {
    public let title: String
    public let items: [PaletteItem]

    public var id: String { title }
}

/// Universal search and the command palette: commands, content and history for one query.
///
/// The palette keeps one highlighted row for the keyboard: ↑ and ↓ move it (`moveHighlight(by:)`)
/// and Return opens it (`activateHighlighted(in:)`). A new query highlights its best match.
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
    /// The row Return opens.
    public private(set) var highlightedID: PaletteItem.ID?

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
            let previousQuery = results?.query
            results = try await services.search.service.palette(query, kinds: kindFilter)
            reconcileHighlight(sameQuery: previousQuery == results?.query)
        } catch {
            services.errors.report(error, context: "Searching")
        }
    }

    // MARK: - Rows and keyboard selection

    /// The palette's rows grouped as shown: recent queries (before typing), commands, results.
    public var sections: [PaletteSection] {
        guard let results else { return [] }
        var sections: [PaletteSection] = []
        if results.query.isEmpty && !results.history.isEmpty {
            sections.append(PaletteSection(title: "Recent", items: results.history.map(PaletteItem.history)))
        }
        if !results.commands.isEmpty {
            sections.append(PaletteSection(title: results.query.isEmpty ? "Suggested" : "Commands", items: results.commands.map(PaletteItem.command)))
        }
        if !results.results.isEmpty {
            sections.append(PaletteSection(title: "Results", items: results.results.map(PaletteItem.result)))
        }
        return sections
    }

    /// Every row in display order.
    public var items: [PaletteItem] {
        sections.flatMap(\.items)
    }

    public var highlightedItem: PaletteItem? {
        guard let highlightedID else { return nil }
        return items.first { $0.id == highlightedID }
    }

    /// Moves the highlight by `offset` rows (negative is up), stopping at the first and last rows.
    public func moveHighlight(by offset: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else {
            highlightedID = nil
            return
        }
        guard let current = highlightedID.flatMap({ ids.firstIndex(of: $0) }) else {
            highlightedID = offset < 0 ? ids.last : ids.first
            return
        }
        highlightedID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    public func highlight(_ item: PaletteItem) {
        highlightedID = item.id
    }

    /// Opens a row: a recent query fills the field, a command runs (closing the palette), a
    /// result opens where the user is.
    public func activate(_ item: PaletteItem, in model: AppModel) async {
        switch item {
        case .history(let entry):
            useHistory(entry)
        case .command(let ranked):
            await model.runCommand(ranked.command.id)
            model.router.dismissCommandPalette()
        case .result(let result):
            await open(result, router: model.router)
        }
    }

    /// Return: opens the highlighted row. False when there is nothing to open.
    @discardableResult
    public func activateHighlighted(in model: AppModel) async -> Bool {
        guard let item = highlightedItem else { return false }
        await activate(item, in: model)
        return true
    }

    // MARK: - Actions

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

    /// A new query highlights its first row; the same query refreshed keeps the highlighted row
    /// while it is still listed.
    private func reconcileHighlight(sameQuery: Bool) {
        let ids = items.map(\.id)
        if sameQuery, let highlightedID, ids.contains(highlightedID) { return }
        highlightedID = ids.first
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
