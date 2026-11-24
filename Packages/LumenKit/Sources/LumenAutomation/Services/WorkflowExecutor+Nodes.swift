import Foundation
import LumenFoundation
import LumenCore

extension WorkflowExecutor {
    enum NodeResult: Sendable {
        /// The run moved on (to a successor, or to no node, which ends it successfully).
        case proceed
        /// The run is parked on a long delay.
        case waiting
        /// A step failed and the policy says stop.
        case stop(String)
    }

    func execute(_ node: WorkflowNode, run: inout WorkflowRun, state: inout RunState, workflow: Workflow) async throws -> NodeResult {
        let graph = workflow.graph
        switch node.kind {
        case .trigger:
            var step = state.makeStep(run: run, node: node, at: timeSource.now())
            step.status = .succeeded
            step.finishedAt = step.startedAt
            step.output = run.triggerPayload
            try await advance(step, to: graph.successor(of: node.id, port: .next), run: &run, state: &state)
            return .proceed

        case .condition(let condition):
            let holds = ConditionEvaluator.evaluate(condition, in: state.context.value)
            var step = state.makeStep(run: run, node: node, at: timeSource.now())
            step.inputs = Self.storable(Self.operands(of: condition, in: state.context.value), warnings: &step.warnings)
            step.status = .succeeded
            step.finishedAt = step.startedAt
            step.output = ["result": .bool(holds)]
            try await advance(step, to: graph.successor(of: node.id, port: holds ? .whenTrue : .whenFalse), run: &run, state: &state)
            return .proceed

        case .end:
            var step = state.makeStep(run: run, node: node, at: timeSource.now())
            step.status = .succeeded
            step.finishedAt = step.startedAt
            try await advance(step, to: nil, run: &run, state: &state)
            return .proceed

        case .delay(let seconds):
            return try await delay(node, seconds: seconds, run: &run, state: &state, graph: graph)

        case .action(let actionID, let parameters):
            return try await perform(node, actionID: actionID, parameters: parameters, run: &run, state: &state, workflow: workflow)
        }
    }

    private func delay(_ node: WorkflowNode, seconds requested: TimeInterval, run: inout WorkflowRun, state: inout RunState, graph: WorkflowGraph) async throws -> NodeResult {
        let seconds = requested.isFinite ? max(0, requested) : 0
        let now = timeSource.now()
        var step = state.makeStep(run: run, node: node, at: now)
        step.inputs = ["seconds": .number(seconds)]

        if seconds <= configuration.inlineDelayThreshold {
            try await journal.record(step, run: run)
            if seconds > 0 {
                try await sleeper(seconds)
            }
            step.status = .succeeded
            step.finishedAt = timeSource.now()
            step.output = ["seconds": .number(seconds)]
            try await advance(step, to: graph.successor(of: node.id, port: .next), run: &run, state: &state)
            return .proceed
        }

        let resumeAt = now.addingTimeInterval(seconds)
        step.status = .waiting
        step.output = ["seconds": .number(seconds), "resumeAt": .string(ExecutionContext.timestamp(resumeAt))]
        run.status = .waiting
        run.resumeAt = resumeAt
        try await journal.record(step, run: run)
        var details = metadata(for: run)
        details["seconds"] = String(Int(seconds))
        logger.info("Workflow run is waiting", metadata: details)
        return .waiting
    }

    private func perform(
        _ node: WorkflowNode,
        actionID: AutomationActionID,
        parameters: [String: ParameterValue],
        run: inout WorkflowRun,
        state: inout RunState,
        workflow: Workflow
    ) async throws -> NodeResult {
        var step = state.makeStep(run: run, node: node, at: timeSource.now())
        step.attemptCount = 0
        try await journal.record(step, run: run)

        guard let action = catalog.action(actionID) else {
            let message = "The action “\(actionID.rawValue)” isn't available on this device."
            return try await fail(step, message: message, error: nil, node: node, run: &run, state: &state, workflow: workflow)
        }
        let descriptor = action.descriptor
        let resolved = ParameterResolver.resolve(parameters, specs: descriptor.parameters, in: state.context.value)
        step.warnings = resolved.warnings.map(\.message)
        step.inputs = Self.storable(.object(resolved.values), warnings: &step.warnings)
        guard resolved.missingRequired.isEmpty else {
            let names = resolved.missingRequired.map { "“\(descriptor.parameter(named: $0)?.title ?? $0)”" }
            let message = "No value for \(names.joined(separator: ", "))."
            return try await fail(step, message: message, error: nil, node: node, run: &run, state: &state, workflow: workflow)
        }

        let context = ActionContext(actor: .automation, correlationID: run.correlationID, causationDepth: run.causationDepth + 1)
        let values = resolved.values
        let runID = run.id
        let nodeID = node.id
        var details = metadata(for: run)
        details["node"] = nodeID.uuidString
        let retryDetails = details
        let logger = self.logger
        var attempts = 0

        let outcome: ActionOutcome
        do {
            outcome = try await withRetry(
                policy: workflow.failurePolicy.retry,
                classify: Self.retryDecision(for:),
                sleep: sleeper,
                randomUnit: randomUnit,
                onRetry: { attempt, error, delay in
                    var metadata = retryDetails
                    metadata["attempt"] = String(attempt)
                    metadata["delay"] = String(delay)
                    metadata["error.type"] = String(describing: type(of: error))
                    logger.warning("Workflow step failed; retrying", metadata: metadata)
                },
                operation: {
                    attempts += 1
                    let invocation = ActionInvocation(
                        parameters: values,
                        context: context,
                        runID: runID,
                        workflowID: workflow.id,
                        nodeID: nodeID,
                        attempt: attempts
                    )
                    return try await action.perform(invocation)
                }
            )
            try Self.requireStorable(outcome.output)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            step.attemptCount = max(1, attempts)
            return try await fail(step, message: Self.describe(error), error: error, node: node, run: &run, state: &state, workflow: workflow)
        }

        step.status = .succeeded
        step.attemptCount = attempts
        step.finishedAt = timeSource.now()
        step.output = outcome.output
        step.message = outcome.message
        let next = outcome.flow == .finishRun ? nil : workflow.graph.successor(of: node.id, port: .next)
        try await advance(step, to: next, run: &run, state: &state)
        return .proceed
    }

    /// Records a failed step, then stops the run or continues per the failure policy.
    private func fail(
        _ step: RunStep,
        message: String,
        error: (any Error)?,
        node: WorkflowNode,
        run: inout WorkflowRun,
        state: inout RunState,
        workflow: Workflow
    ) async throws -> NodeResult {
        var failed = step
        failed.status = .failed
        failed.finishedAt = timeSource.now()
        failed.errorMessage = message
        var details = metadata(for: run)
        details["node"] = node.id.uuidString
        details["attempts"] = String(failed.attemptCount)
        details["policy"] = workflow.failurePolicy.onFailure.rawValue
        if let error {
            details["error.type"] = String(describing: type(of: error))
        }
        logger.error("Workflow step failed", metadata: details)

        switch workflow.failurePolicy.onFailure {
        case .stop:
            // The run keeps pointing at the failing node so history shows where it stopped.
            try await advance(failed, to: node.id, run: &run, state: &state)
            return .stop("“\(node.title)” failed: \(message)")
        case .continue:
            try await advance(failed, to: workflow.graph.successor(of: node.id, port: .next), run: &run, state: &state)
            return .proceed
        }
    }

    static func retryDecision(for error: any Error) -> RetryDecision {
        if let actionError = error as? AutomationActionError {
            return actionError.isRetryable ? .retry : .fail
        }
        // Unknown errors (I/O, networking) are assumed transient.
        return .retry
    }

    static func describe(_ error: any Error) -> String {
        if let actionError = error as? AutomationActionError {
            return actionError.message
        }
        if let presentable = error as? any PresentableError {
            return presentable.presentation.message
        }
        return String(describing: error)
    }

    /// The value of every path a condition reads, keyed by path (`null` when missing), so the run
    /// history shows what the branch decision was based on.
    static func operands(of condition: Condition, in context: JSONValue) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for path in condition.referencedPaths {
            values[path] = ContextPath.resolve(path, in: context) ?? .null
        }
        return .object(values)
    }

    /// Inputs are kept for history only, so a value JSON can't represent is dropped with a warning
    /// instead of failing the step (unlike outputs, which later steps depend on).
    static func storable(_ inputs: JSONValue, warnings: inout [String]) -> JSONValue? {
        do {
            _ = try JSONText.encode(inputs)
            return inputs
        } catch {
            warnings.append("The step's inputs couldn't be saved to the run history.")
            return nil
        }
    }

    /// Outputs are stored as JSON; a value JSON cannot represent (a non-finite number) fails the step.
    static func requireStorable(_ output: JSONValue) throws {
        do {
            _ = try JSONText.encode(output)
        } catch {
            throw AutomationActionError.permanent("The action returned a value that can't be saved.")
        }
    }
}
