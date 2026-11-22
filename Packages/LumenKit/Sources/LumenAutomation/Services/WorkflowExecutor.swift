import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Suspends for a number of seconds; throws `CancellationError` when the task is cancelled.
/// Injected so tests (and previews) never wait on the wall clock.
public typealias AutomationSleeper = @Sendable (TimeInterval) async throws -> Void

public enum AutomationSleepers {
    /// `Task.sleep`, clamped to a year so absurd values cannot overflow.
    public static let system: AutomationSleeper = { seconds in
        let clamped = seconds.isFinite ? min(max(0, seconds), 365 * 86_400) : 0
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

/// Executes workflow runs and records every step.
///
/// - Actions are retried per the workflow's `FailurePolicy` (`AutomationActionError.permanent`
///   is never retried); a final failure stops the run or continues, as the policy says.
/// - Conditions branch on `.whenTrue` / `.whenFalse`.
/// - Delays up to `inlineDelayThreshold` sleep through the injected sleeper; longer delays park
///   the run as `.waiting` with `resumeAt` and return. `resume` continues it later.
/// - A run stops as failed after `maximumStepsPerRun` steps (a safety net; graphs are acyclic).
/// - `cancel` ends a run as `.cancelled`, interrupting sleeps and cooperative actions.
public actor WorkflowExecutor {
    public struct Configuration: Sendable, Hashable {
        public var inlineDelayThreshold: TimeInterval
        public var maximumStepsPerRun: Int

        public init(inlineDelayThreshold: TimeInterval = 60, maximumStepsPerRun: Int = 500) {
            self.inlineDelayThreshold = max(0, inlineDelayThreshold)
            self.maximumStepsPerRun = max(1, maximumStepsPerRun)
        }
    }

    struct ActiveRun {
        let workflowID: Workflow.ID
        let task: Task<WorkflowRun, any Error>
    }

    enum StartPoint: Sendable {
        case beginning
        case resumption
    }

    let journal: RunJournal
    let catalog: AutomationCatalog
    let events: EventBus
    let timeSource: any TimeSource
    let logger: Logger
    let sleeper: AutomationSleeper
    let randomUnit: @Sendable () -> Double
    public nonisolated let configuration: Configuration
    private var active: [WorkflowRun.ID: ActiveRun] = [:]

    public init(
        database: Database,
        catalog: AutomationCatalog,
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger,
        sleeper: @escaping AutomationSleeper = AutomationSleepers.system,
        configuration: Configuration = Configuration(),
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.journal = RunJournal(database: database)
        self.catalog = catalog
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
        self.sleeper = sleeper
        self.configuration = configuration
        self.randomUnit = randomUnit
    }

    /// Runs executing in this process.
    public var activeRunIDs: Set<WorkflowRun.ID> {
        Set(active.keys)
    }

    /// Starts a new run of `workflow` and executes it until it finishes or parks on a long delay.
    ///
    /// - Parameters:
    ///   - trigger: the `trigger` part of the context (see `TriggerPayload`).
    ///   - causationDepth: depth of the triggering event; actions run one level deeper.
    /// - Returns: the run in its final (or waiting) state.
    /// - Throws: only when the run cannot be recorded; step failures are part of the returned run.
    @discardableResult
    public func start(_ workflow: Workflow, trigger: JSONValue, input: JSONValue = .null, causationDepth: Int = 0) async throws -> WorkflowRun {
        let id = WorkflowRun.ID()
        let run = WorkflowRun(
            id: id,
            workflowID: workflow.id,
            status: .running,
            triggerPayload: trigger,
            input: input,
            causationDepth: causationDepth,
            correlationID: id.rawValue,
            startedAt: timeSource.now(),
            currentNodeID: workflow.graph.triggerNode?.id
        )
        // Registered before the first suspension, so `cancel` always finds the run.
        let task = Task { try await self.drive(run, workflow: workflow, from: .beginning) }
        active[id] = ActiveRun(workflowID: workflow.id, task: task)
        return try await completion(of: task, runID: id)
    }

    /// Continues a waiting run after its delay, or re-executes an interrupted run from the step
    /// that was in progress. A run whose stored status is no longer resumable is returned as stored.
    @discardableResult
    public func resume(_ run: WorkflowRun, workflow: Workflow) async throws -> WorkflowRun {
        guard active[run.id] == nil else { throw AutomationError.runAlreadyActive(run.id) }
        guard run.workflowID == workflow.id, run.status == .waiting || run.status == .interrupted else {
            throw AutomationError.runNotResumable(run.id)
        }
        let task = Task { try await self.drive(run, workflow: workflow, from: .resumption) }
        active[run.id] = ActiveRun(workflowID: workflow.id, task: task)
        return try await completion(of: task, runID: run.id)
    }

    /// Cancels a run. An executing run stops at its next suspension point; a waiting or
    /// interrupted run is marked cancelled at once. Returns `false` for runs that already ended.
    @discardableResult
    public func cancel(_ runID: WorkflowRun.ID) async throws -> Bool {
        if let entry = active[runID] {
            entry.task.cancel()
            return true
        }
        guard var run = try await journal.run(runID) else { throw AutomationError.runNotFound(runID) }
        // The run may have been resumed while the history was read.
        if let entry = active[runID] {
            entry.task.cancel()
            return true
        }
        switch run.status {
        case .running, .waiting, .interrupted: break
        case .succeeded, .failed, .cancelled: return false
        }
        let now = timeSource.now()
        run.status = .cancelled
        run.finishedAt = now
        run.resumeAt = nil
        try await journal.finish(run, openStepsAs: .cancelled, at: now)
        let steps = try await journal.steps(of: runID)
        events.publish(RunEvents.event(
            AutomationEvents.runCancelled,
            for: run,
            stepCount: steps.count,
            failedSteps: steps.filter { $0.status == .failed }.count,
            at: now
        ))
        logger.info("Workflow run cancelled", metadata: metadata(for: run))
        return true
    }

    /// Cancels every executing run of a workflow (before it is deleted). Returns how many.
    @discardableResult
    public func cancelRuns(of workflowID: Workflow.ID) -> Int {
        let matching = active.values.filter { $0.workflowID == workflowID }
        for entry in matching {
            entry.task.cancel()
        }
        return matching.count
    }

    private func completion(of task: Task<WorkflowRun, any Error>, runID: WorkflowRun.ID) async throws -> WorkflowRun {
        defer { active[runID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Driving a run

    func drive(_ initial: WorkflowRun, workflow: Workflow, from start: StartPoint) async throws -> WorkflowRun {
        var run = initial
        var state = RunState(run: initial)
        var persisted = false
        do {
            switch start {
            case .beginning:
                try await journal.insert(run)
                persisted = true
                events.publish(RunEvents.event(AutomationEvents.runStarted, for: run, stepCount: 0, failedSteps: 0, at: run.startedAt))
                logger.info("Workflow run started", metadata: metadata(for: run))
                guard run.currentNodeID != nil else {
                    return try await conclude(&run, state: state, status: .failed, message: "The workflow has no trigger step.")
                }

            case .resumption:
                guard let stored = try await journal.run(run.id) else { throw AutomationError.runNotFound(run.id) }
                guard stored.status == .waiting || stored.status == .interrupted else { return stored }
                run = stored
                persisted = true
                let steps = try await journal.steps(of: run.id)
                state = RunState(run: run, steps: steps)
                run.status = .running
                run.finishedAt = nil
                run.resumeAt = nil
                run.errorMessage = nil
                if var waiting = steps.last, waiting.status == .waiting, waiting.nodeID == run.currentNodeID {
                    waiting.status = .succeeded
                    waiting.finishedAt = timeSource.now()
                    try await advance(waiting, to: workflow.graph.successor(of: waiting.nodeID, port: .next), run: &run, state: &state)
                } else {
                    try await journal.update(run)
                }
                logger.info("Workflow run resumed", metadata: metadata(for: run))
            }
            return try await loop(&run, state: &state, workflow: workflow)
        } catch {
            guard persisted, !(try await journal.runExists(run.id)) else {
                logger.error("Workflow run could not be recorded", error: error, metadata: metadata(for: run))
                throw error
            }
            // Recovery: the workflow was deleted while this run executed and its history went with
            // it, so there is nothing left to record.
            logger.notice("Workflow run discarded because its workflow was deleted", metadata: metadata(for: run))
            run.status = .cancelled
            run.finishedAt = timeSource.now()
            return run
        }
    }

    private func loop(_ run: inout WorkflowRun, state: inout RunState, workflow: Workflow) async throws -> WorkflowRun {
        let nodes = workflow.graph.nodesByID
        while let nodeID = run.currentNodeID {
            if Task.isCancelled {
                return try await conclude(&run, state: state, status: .cancelled, message: nil)
            }
            guard state.stepCount < configuration.maximumStepsPerRun else {
                let message = "The run stopped after \(configuration.maximumStepsPerRun) steps, the limit for a single run."
                return try await conclude(&run, state: state, status: .failed, message: message)
            }
            guard let node = nodes[nodeID] else {
                return try await conclude(&run, state: state, status: .failed, message: "The workflow was changed and the next step no longer exists.")
            }
            let result: NodeResult
            do {
                result = try await execute(node, run: &run, state: &state, workflow: workflow)
            } catch is CancellationError {
                return try await conclude(&run, state: state, status: .cancelled, message: nil)
            }
            switch result {
            case .proceed: continue
            case .waiting: return run
            case .stop(let message): return try await conclude(&run, state: state, status: .failed, message: message)
            }
        }
        return try await conclude(&run, state: state, status: .succeeded, message: nil)
    }

    /// Saves a finished step and moves the run to `next` in one transaction.
    func advance(_ step: RunStep, to next: WorkflowNode.ID?, run: inout WorkflowRun, state: inout RunState) async throws {
        run.currentNodeID = next
        try await journal.record(step, run: run)
        state.context.record(step)
        if step.status == .failed {
            state.failedSteps += 1
        }
    }

    private func conclude(_ run: inout WorkflowRun, state: RunState, status: WorkflowRun.Status, message: String?) async throws -> WorkflowRun {
        let now = timeSource.now()
        run.status = status
        run.finishedAt = now
        run.resumeAt = nil
        run.errorMessage = message
        if status == .succeeded {
            run.currentNodeID = nil
        }
        try await journal.finish(run, openStepsAs: status == .cancelled ? .cancelled : .failed, at: now)
        if let name = RunEvents.name(for: status) {
            events.publish(RunEvents.event(name, for: run, stepCount: state.stepCount, failedSteps: state.failedSteps, at: now))
        }
        var details = metadata(for: run)
        details["status"] = status.rawValue
        details["steps"] = String(state.stepCount)
        logger.info("Workflow run finished", metadata: details)
        return run
    }

    func metadata(for run: WorkflowRun) -> [String: String] {
        ["workflow": run.workflowID.uuidString, "run": run.id.uuidString]
    }
}
