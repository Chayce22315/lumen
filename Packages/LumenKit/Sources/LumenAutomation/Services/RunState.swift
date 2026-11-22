import Foundation
import LumenFoundation

/// Mutable bookkeeping of one run while it executes.
struct RunState: Sendable {
    var context: ExecutionContext
    /// Steps recorded for the run so far, across all of its segments (before and after waiting).
    var stepCount: Int
    var failedSteps: Int

    init(run: WorkflowRun, steps: [RunStep] = []) {
        self.context = ExecutionContext(run: run, steps: steps)
        self.stepCount = steps.count
        self.failedSteps = steps.filter { $0.status == .failed }.count
    }

    /// A new running step for `node`, numbered after every step so far.
    mutating func makeStep(run: WorkflowRun, node: WorkflowNode, at date: Date) -> RunStep {
        let step = RunStep(runID: run.id, nodeID: node.id, sequence: stepCount, status: .running, startedAt: date)
        stepCount += 1
        return step
    }
}
