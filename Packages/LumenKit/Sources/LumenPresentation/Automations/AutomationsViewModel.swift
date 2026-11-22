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

/// Building a workflow as a trigger followed by a sequence of steps. The underlying graph is
/// what the visual canvas renders; this editor keeps it linear, which covers most automations.
@MainActor
@Observable
public final class WorkflowEditorViewModel {
    public struct Step: Sendable, Hashable, Identifiable {
        public let id: WorkflowNode.ID
        public var actionID: AutomationActionID
        public var parameters: [String: String]

        public init(id: WorkflowNode.ID = WorkflowNode.ID(), actionID: AutomationActionID, parameters: [String: String] = [:]) {
            self.id = id
            self.actionID = actionID
            self.parameters = parameters
        }
    }

    public enum TriggerChoice: Sendable, Hashable {
        case manual
        case event(EventName)
        case daily(TimeOfDay)
    }

    public let workflowID: Workflow.ID?
    public var name = ""
    public var summary = ""
    public var trigger: TriggerChoice = .manual
    public var steps: [Step] = []
    public private(set) var issues: [ValidationIssue] = []
    public private(set) var error: ErrorPresentation?

    private let services: LumenServices

    public init(services: LumenServices, workflowID: Workflow.ID? = nil) {
        self.services = services
        self.workflowID = workflowID
    }

    public var actions: [AutomationActionDescriptor] { services.automation.catalog.descriptors }
    public var triggers: [AutomationTriggerDescriptor] { services.automation.catalog.triggerDescriptors }

    public func addStep(_ actionID: AutomationActionID) {
        steps.append(Step(actionID: actionID))
    }

    public func removeStep(_ id: WorkflowNode.ID) {
        steps.removeAll { $0.id == id }
    }

    public func moveSteps(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { steps[$0] }
        let base = destination - source.filter { $0 < destination }.count
        steps.removeAll { step in moving.contains(step) }
        steps.insert(contentsOf: moving, at: min(max(base, 0), steps.count))
    }

    /// The graph the steps describe: trigger → step₁ → … → stepₙ, laid out top to bottom.
    public func graph() -> WorkflowGraph {
        let trigger = WorkflowNode(title: "Trigger", position: CanvasPoint(x: 0, y: 0), kind: .trigger)
        var nodes = [trigger]
        var edges: [WorkflowEdge] = []
        var previous = trigger.id
        for (index, step) in steps.enumerated() {
            let title = services.automation.catalog.descriptor(step.actionID)?.title ?? step.actionID.rawValue
            let parameters = step.parameters.compactMapValues { value -> ParameterValue? in
                guard !value.isEmpty else { return nil }
                return value.contains("{{") ? .template(value) : .literal(.string(value))
            }
            let node = WorkflowNode(id: step.id, title: title, position: CanvasPoint(x: 0, y: Double(index + 1) * 120), kind: .action(actionID: step.actionID, parameters: parameters))
            nodes.append(node)
            edges.append(WorkflowEdge(from: previous, to: node.id))
            previous = node.id
        }
        return WorkflowGraph(nodes: nodes, edges: edges)
    }

    public func triggerDefinition() -> TriggerDefinition {
        switch trigger {
        case .manual:
            return .manual
        case .event(let name):
            return .event(name: name, condition: nil)
        case .daily(let time):
            return .schedule(ScheduleTrigger(rule: .daily, anchor: services.today, time: time))
        }
    }

    /// Validates and saves. Returns the workflow on success; `issues` explains failures.
    @discardableResult
    public func save() async -> Workflow? {
        error = nil
        let draft = WorkflowDraft(name: name, summary: summary, trigger: triggerDefinition(), graph: graph())
        do {
            let workflow: Workflow
            if let workflowID, var existing = try await services.automation.engine.workflow(workflowID) {
                existing.name = draft.name
                existing.summary = draft.summary
                existing.trigger = draft.trigger
                existing.graph = draft.graph
                workflow = try await services.automation.engine.update(existing)
            } else {
                workflow = try await services.automation.engine.create(draft)
            }
            issues = []
            return workflow
        } catch let failure as AutomationError {
            if case .invalidWorkflow(let found) = failure { issues = found }
            error = failure.presentation
            return nil
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }
}
