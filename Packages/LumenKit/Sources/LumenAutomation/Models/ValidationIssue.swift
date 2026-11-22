import Foundation
import LumenFoundation

/// A problem found in a workflow definition. Errors block saving; warnings are shown in the editor.
public struct ValidationIssue: Sendable, Hashable, Codable, Identifiable {
    public enum Severity: String, Sendable, Hashable, Codable, Comparable {
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    /// Machine-readable category, so the editor can highlight the right control.
    public enum Code: String, Sendable, Hashable, Codable, CaseIterable {
        case missingName
        case invalidTrigger
        case unknownEvent
        case missingTrigger
        case multipleTriggers
        case duplicateNodeID
        case danglingEdge
        case triggerHasIncomingEdge
        case invalidPort
        case multipleNextEdges
        case duplicateBranch
        case endHasOutgoingEdge
        case cycle
        case unreachableNode
        case unknownAction
        case missingParameter
        case invalidParameter
        case unknownParameter
        case invalidPath
        case invalidTemplate
        case delayOutOfRange
        case emptyWorkflow
    }

    public var code: Code
    public var severity: Severity
    /// The node the issue is about; `nil` for workflow-level issues.
    public var nodeID: WorkflowNode.ID?
    public var message: String

    public init(_ code: Code, _ severity: Severity, nodeID: WorkflowNode.ID? = nil, message: String) {
        self.code = code
        self.severity = severity
        self.nodeID = nodeID
        self.message = message
    }

    public var id: String {
        "\(code.rawValue)|\(nodeID?.uuidString ?? "workflow")|\(message)"
    }
}

extension Array where Element == ValidationIssue {
    /// The issues that block saving.
    public var errors: [ValidationIssue] {
        filter { $0.severity == .error }
    }

    public var hasErrors: Bool {
        contains { $0.severity == .error }
    }

    public func issues(for nodeID: WorkflowNode.ID) -> [ValidationIssue] {
        filter { $0.nodeID == nodeID }
    }
}
