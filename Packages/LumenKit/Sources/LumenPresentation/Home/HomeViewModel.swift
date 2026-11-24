import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// Home: the dashboard, its live refresh, and layout customization.
@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var state: LoadState<HomeSnapshot> = .idle
    public private(set) var layout: DashboardLayout = .standard
    public var isEditingLayout = false
    public private(set) var isRefreshing = false

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    /// Loads once and then follows changes to tasks, events, notes, notifications and sync.
    public func start() async {
        await load()
        services.events.observe(
            EventFilter(modules: ["organization", "knowledge", "notifications", "sync", "core", "intelligence"]),
            debounce: 0.3,
            into: observation
        ) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await services.home.snapshot(assistantConfigured: await services.isAssistantConfigured())
            layout = snapshot.layout
            state = .loaded(snapshot)
        } catch {
            if state.value == nil {
                state = .failed(ErrorPresentation.from(error))
            } else {
                services.errors.report(error, context: "Refreshing Home")
            }
        }
    }

    public var visibleWidgets: [DashboardItem] {
        layout.visibleItems
    }

    // MARK: - Actions

    public func complete(_ taskID: TaskItem.ID) async {
        do {
            _ = try await services.organization.tasks.complete(taskID)
        } catch {
            services.errors.report(error, context: "Completing a task")
        }
    }

    // MARK: - Layout editing

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        layout.move(fromOffsets: source, toOffset: destination)
        persistLayout()
    }

    public func setVisible(_ visible: Bool, for kind: DashboardWidgetKind) {
        layout.setVisible(visible, for: kind)
        persistLayout()
    }

    public func setSize(_ size: DashboardItem.Size, for kind: DashboardWidgetKind) {
        layout.setSize(size, for: kind)
        persistLayout()
    }

    public func resetLayout() {
        layout = .standard
        persistLayout()
    }

    private func persistLayout() {
        let layout = self.layout
        let services = self.services
        Task {
            do {
                try await services.home.saveLayout(layout)
            } catch {
                services.errors.report(error, context: "Saving the Home layout")
            }
        }
    }
}
