import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenApplication

/// The kind of step a run went through, for its icon.
public enum WorkflowStepKind: String, Sendable, Hashable {
    case trigger, action, condition, delay, end
    /// The step has since been removed from the workflow.
    case removed

    public init(_ kind: WorkflowNode.Kind?) {
        switch kind {
        case .trigger: self = .trigger
        case .action: self = .action
        case .condition: self = .condition
        case .delay: self = .delay
        case .end: self = .end
        case nil: self = .removed
        }
    }
}

/// One run of a workflow, step by step: what each step received and produced, how long it took,
/// how often it was retried and why it failed.
@MainActor
@Observable
public final class RunDetailViewModel {
    public struct StepRow: Sendable, Hashable, Identifiable {
        public let id: RunStep.ID
        public let title: String
        public let kind: WorkflowStepKind
        public let status: RunStep.Status
        public let startedAt: Date
        public let finishedAt: Date?
        public let duration: TimeInterval?
        public let attempts: Int
        /// Attempts beyond the first.
        public var retries: Int { max(0, attempts - 1) }
        /// For a condition: which branch the run took.
        public let branch: String?
        public let message: String?
        public let errorMessage: String?
        public let warnings: [String]
        public let inputs: [JSONPreview.Line]
        public let output: [JSONPreview.Line]
    }

    public struct Detail: Sendable, Hashable {
        public let run: WorkflowRun
        public let workflowName: String
        public let steps: [StepRow]
        /// The event, schedule or manual start that began the run.
        public let trigger: [JSONPreview.Line]
        public let input: [JSONPreview.Line]
        public let duration: TimeInterval?
        /// Whether this run replayed another one.
        public let isRerun: Bool
    }

    public let runID: WorkflowRun.ID
    public private(set) var state: LoadState<Detail> = .idle
    public private(set) var isRerunning = false
    /// The run started by the last `rerun()`.
    public private(set) var latestRerun: WorkflowRun?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices, runID: WorkflowRun.ID) {
        self.services = services
        self.runID = runID
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["automation"]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        let engine = services.automation.engine
        do {
            guard let detail = try await engine.runDetail(runID) else {
                state = .failed(AutomationError.runNotFound(runID).presentation)
                return
            }
            let workflow = try await engine.workflow(detail.run.workflowID)
            state = .loaded(Self.detail(detail, workflow: workflow))
        } catch {
            if state.value == nil {
                state = .failed(ErrorPresentation.from(error))
            } else {
                services.errors.report(error, context: "Refreshing an automation run")
            }
        }
    }

    /// Running and waiting runs can be stopped.
    public var canCancel: Bool {
        guard let status = state.value?.run.status else { return false }
        return status == .running || status == .waiting
    }

    public func cancel() async {
        do {
            _ = try await services.automation.engine.cancel(runID)
        } catch {
            services.errors.report(error, context: "Stopping an automation run")
        }
        await load()
    }

    /// Runs the workflow again with this run's trigger and input. Returns the new run.
    @discardableResult
    public func rerun() async -> WorkflowRun? {
        isRerunning = true
        defer { isRerunning = false }
        do {
            let run = try await services.automation.engine.rerun(runID)
            latestRerun = run
            return run
        } catch {
            services.errors.report(error, context: "Running an automation again")
            return nil
        }
    }

    static func detail(_ detail: RunDetail, workflow: Workflow?) -> Detail {
        let nodes = workflow?.graph.nodesByID ?? [:]
        let steps = detail.steps.map { step -> StepRow in
            let node = nodes[step.nodeID]
            var branch: String?
            if case .condition = node?.kind, case .bool(let result)? = step.output?["result"] {
                branch = result ? "Took the “true” branch" : "Took the “false” branch"
            }
            return StepRow(
                id: step.id,
                title: node.map { $0.title.nonBlank ?? defaultTitle(for: $0.kind) } ?? "Removed step",
                kind: WorkflowStepKind(node?.kind),
                status: step.status,
                startedAt: step.startedAt,
                finishedAt: step.finishedAt,
                duration: step.finishedAt.map { max(0, $0.timeIntervalSince(step.startedAt)) },
                attempts: step.attemptCount,
                branch: branch,
                message: step.message,
                errorMessage: step.errorMessage,
                warnings: step.warnings,
                inputs: JSONPreview.lines(step.inputs),
                output: node.map { $0.kind.isTrigger } == true ? [] : JSONPreview.lines(step.output)
            )
        }
        return Detail(
            run: detail.run,
            workflowName: workflow?.name ?? "Deleted automation",
            steps: steps,
            trigger: JSONPreview.lines(detail.run.triggerPayload),
            input: detail.run.input.isNull ? [] : JSONPreview.lines(detail.run.input),
            duration: detail.run.finishedAt.map { max(0, $0.timeIntervalSince(detail.run.startedAt)) },
            isRerun: detail.run.triggerPayload["rerunOf"] != nil
        )
    }

    static func defaultTitle(for kind: WorkflowNode.Kind) -> String {
        switch kind {
        case .trigger: return "Trigger"
        case .action: return "Action"
        case .condition: return "Condition"
        case .delay: return "Wait"
        case .end: return "End"
        }
    }
}
