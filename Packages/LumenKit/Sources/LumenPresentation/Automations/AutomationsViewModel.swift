import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenApplication

/// The automations list with status, last run and next scheduled run.
@MainActor
@Observable
public final class AutomationsViewModel {
    public struct Row: Sendable, Hashable, Identifiable {
        public let workflow: Workflow
        public let lastRun: WorkflowRun?
        public let nextFire: Date?
        public var id: Workflow.ID { workflow.id }
    }

    public private(set) var state: LoadState<[Row]> = .idle
    public private(set) var recentRuns: [WorkflowRun] = []

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["automation", "sync"]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        let engine = services.automation.engine
        do {
            var rows: [Row] = []
            for workflow in try await engine.workflows() {
                let lastRun = try await engine.runs(workflowID: workflow.id, limit: 1).first
                rows.append(Row(workflow: workflow, lastRun: lastRun, nextFire: try await engine.nextFireDate(for: workflow.id)))
            }
            state = .loaded(rows)
            recentRuns = try await engine.recentRuns(limit: 20)
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public func setEnabled(_ enabled: Bool, for id: Workflow.ID) async {
        do {
            _ = try await services.automation.engine.setEnabled(id, enabled)
        } catch {
            services.errors.report(error, context: "Turning an automation \(enabled ? "on" : "off")")
        }
        await load()
    }

    /// Runs a workflow now and returns its final run.
    @discardableResult
    public func runNow(_ id: Workflow.ID) async -> WorkflowRun? {
        do {
            let run = try await services.automation.engine.run(id)
            await load()
            return run
        } catch {
            services.errors.report(error, context: "Running an automation")
            return nil
        }
    }

    public func duplicate(_ id: Workflow.ID) async {
        do {
            _ = try await services.automation.engine.duplicate(id)
        } catch {
            services.errors.report(error, context: "Duplicating an automation")
        }
        await load()
    }

    public func delete(_ id: Workflow.ID) async {
        do {
            try await services.automation.engine.delete(id)
        } catch {
            services.errors.report(error, context: "Deleting an automation")
        }
        await load()
    }
}
