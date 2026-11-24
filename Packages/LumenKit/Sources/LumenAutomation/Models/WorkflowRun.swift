import Foundation
import LumenFoundation

/// One execution of a workflow. Device-local history; never synchronized.
public struct WorkflowRun: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<WorkflowRun>

    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        /// Executing steps now.
        case running
        /// Parked on a long delay until `resumeAt`.
        case waiting
        case succeeded
        case failed
        case cancelled
        /// The app stopped while the run was executing. Resumed at launch when the workflow allows it.
        case interrupted

        /// Whether the run has ended (an interrupted run can still be resumed by recovery).
        public var isFinished: Bool {
            switch self {
            case .running, .waiting: return false
            case .succeeded, .failed, .cancelled, .interrupted: return true
            }
        }
    }

    public let id: ID
    public let workflowID: Workflow.ID
    public var status: Status
    /// The `trigger` part of the run context: `{name, entity, attributes, occurredAt, …}`.
    public var triggerPayload: JSONValue
    /// The `input` part of the run context (manual runs).
    public var input: JSONValue
    /// Causation depth of the triggering event. Actions run at `causationDepth + 1`.
    public var causationDepth: Int
    /// Stamped on every event this run's actions publish, so the engine can recognize them.
    public let correlationID: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    /// When a waiting run continues.
    public var resumeAt: Date?
    /// The node executing next (or, for a finished failed run, the node that failed).
    public var currentNodeID: WorkflowNode.ID?
    public var errorMessage: String?

    public init(
        id: ID = ID(),
        workflowID: Workflow.ID,
        status: Status,
        triggerPayload: JSONValue,
        input: JSONValue = .null,
        causationDepth: Int = 0,
        correlationID: UUID? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        resumeAt: Date? = nil,
        currentNodeID: WorkflowNode.ID? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.workflowID = workflowID
        self.status = status
        self.triggerPayload = triggerPayload
        self.input = input
        self.causationDepth = max(0, causationDepth)
        self.correlationID = correlationID ?? id.rawValue
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resumeAt = resumeAt
        self.currentNodeID = currentNodeID
        self.errorMessage = errorMessage
    }

    public var reference: EntityReference {
        EntityReference(kind: .workflowRun, id: id)
    }
}

/// The record of one node executing within a run.
public struct RunStep: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<RunStep>

    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case running
        /// A long delay the run is parked on.
        case waiting
        case succeeded
        case failed
        case cancelled
        /// The app stopped while this step was executing.
        case interrupted
    }

    public let id: ID
    public let runID: WorkflowRun.ID
    public let nodeID: WorkflowNode.ID
    /// Position within the run, starting at 0.
    public let sequence: Int
    public var status: Status
    public var attemptCount: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var output: JSONValue?
    /// What the step worked with, resolved against the run context: an action's parameter values
    /// after templates and references, a condition's operands, a delay's duration. `nil` for steps
    /// recorded before inputs were kept and for the trigger (its payload is the run's trigger).
    public var inputs: JSONValue?
    /// The action's own summary of what it did.
    public var message: String?
    public var errorMessage: String?
    /// Template and reference problems found while resolving parameters (missing values render empty).
    public var warnings: [String]

    public init(
        id: ID = ID(),
        runID: WorkflowRun.ID,
        nodeID: WorkflowNode.ID,
        sequence: Int,
        status: Status,
        attemptCount: Int = 1,
        startedAt: Date,
        finishedAt: Date? = nil,
        output: JSONValue? = nil,
        inputs: JSONValue? = nil,
        message: String? = nil,
        errorMessage: String? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.runID = runID
        self.nodeID = nodeID
        self.sequence = sequence
        self.status = status
        self.attemptCount = attemptCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.inputs = inputs
        self.message = message
        self.errorMessage = errorMessage
        self.warnings = warnings
    }
}

/// A run with its steps, in execution order.
public struct RunDetail: Sendable, Hashable {
    public var run: WorkflowRun
    public var steps: [RunStep]

    public init(run: WorkflowRun, steps: [RunStep]) {
        self.run = run
        self.steps = steps
    }
}
