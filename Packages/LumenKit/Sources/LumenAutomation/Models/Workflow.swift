import Foundation
import LumenFoundation

/// A saved automation: a trigger, a graph of steps and the rules for handling failures.
///
/// Workflows are synchronized entities. Their `Codable` form is the change-log snapshot, so every
/// field added after the first release must decode with a default.
public struct Workflow: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<Workflow>

    public let id: ID
    public var name: String
    public var summary: String
    /// Disabled workflows ignore their event and schedule triggers. They can still be run by hand.
    public var isEnabled: Bool
    public var trigger: TriggerDefinition
    public var graph: WorkflowGraph
    public var failurePolicy: FailurePolicy
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        name: String,
        summary: String = "",
        isEnabled: Bool = true,
        trigger: TriggerDefinition = .manual,
        graph: WorkflowGraph = .starter(),
        failurePolicy: FailurePolicy = .standard,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.graph = graph
        self.failurePolicy = failurePolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var reference: EntityReference {
        EntityReference(kind: .workflow, id: id)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, isEnabled, trigger, graph, failurePolicy, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.trigger = try container.decodeIfPresent(TriggerDefinition.self, forKey: .trigger) ?? .manual
        self.graph = try container.decodeIfPresent(WorkflowGraph.self, forKey: .graph) ?? WorkflowGraph()
        self.failurePolicy = try container.decodeIfPresent(FailurePolicy.self, forKey: .failurePolicy) ?? .standard
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// How a workflow reacts when a step fails or the app stops mid-run.
public struct FailurePolicy: Sendable, Hashable, Codable {
    public enum OnFailure: String, Sendable, Hashable, Codable, CaseIterable {
        /// End the run as failed at the failing step.
        case stop
        /// Record the failure and carry on with the step's successor.
        case `continue`
    }

    /// Retries for a failing action step. `AutomationActionError.permanent` is never retried.
    public var retry: RetryPolicy
    public var onFailure: OnFailure
    /// When the app was terminated during a run, re-execute it from the step that was in progress
    /// at the next launch. That step may then run twice, so mutating actions should be idempotent.
    public var resumeInterruptedRuns: Bool

    public init(retry: RetryPolicy = .standard, onFailure: OnFailure = .stop, resumeInterruptedRuns: Bool = true) {
        self.retry = retry
        self.onFailure = onFailure
        self.resumeInterruptedRuns = resumeInterruptedRuns
    }

    public static let standard = FailurePolicy()

    enum CodingKeys: String, CodingKey {
        case retry, onFailure, resumeInterruptedRuns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.retry = try container.decodeIfPresent(RetryPolicy.self, forKey: .retry) ?? .standard
        self.onFailure = try container.decodeIfPresent(OnFailure.self, forKey: .onFailure) ?? .stop
        self.resumeInterruptedRuns = try container.decodeIfPresent(Bool.self, forKey: .resumeInterruptedRuns) ?? true
    }
}

/// The user-editable part of a workflow, used to create one.
public struct WorkflowDraft: Sendable, Hashable {
    public var name: String
    public var summary: String
    public var isEnabled: Bool
    public var trigger: TriggerDefinition
    public var graph: WorkflowGraph
    public var failurePolicy: FailurePolicy

    public init(
        name: String,
        summary: String = "",
        isEnabled: Bool = true,
        trigger: TriggerDefinition = .manual,
        graph: WorkflowGraph = .starter(),
        failurePolicy: FailurePolicy = .standard
    ) {
        self.name = name
        self.summary = summary
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.graph = graph
        self.failurePolicy = failurePolicy
    }
}
