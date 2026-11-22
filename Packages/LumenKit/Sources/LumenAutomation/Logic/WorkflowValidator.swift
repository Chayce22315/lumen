import Foundation
import LumenFoundation
import LumenCore

/// Checks a workflow definition before it is saved, enabled or run.
///
/// Structural rules: exactly one trigger node; every edge connects existing nodes; nothing
/// connects into the trigger; end nodes have no outputs; nodes only use their own output ports,
/// at most once each; the graph has no cycles; every node is reachable from the trigger. Content
/// rules (actions, parameters, conditions, delays) live in `WorkflowValidator+Nodes.swift`.
public enum WorkflowValidator {
    /// The longest delay a single node may wait.
    public static let maximumDelay: TimeInterval = 30 * 86_400

    /// Validates the whole workflow.
    ///
    /// - Parameters:
    ///   - actions: descriptors of the actions installed on this device.
    ///   - knownEvents: event names offered by trigger sources; an event trigger outside this set
    ///     is a warning. `nil` skips the check.
    public static func validate(
        _ workflow: Workflow,
        actions: [AutomationActionID: AutomationActionDescriptor],
        knownEvents: Set<EventName>? = nil
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if workflow.name.nonBlank == nil {
            issues.append(ValidationIssue(.missingName, .error, message: "Give the workflow a name."))
        }
        issues += validate(trigger: workflow.trigger, knownEvents: knownEvents)
        issues += validate(graph: workflow.graph, actions: actions)
        return issues
    }

    public static func validate(trigger: TriggerDefinition, knownEvents: Set<EventName>? = nil) -> [ValidationIssue] {
        switch trigger {
        case .manual:
            return []

        case .event(let name, let condition):
            var issues: [ValidationIssue] = []
            if name.rawValue.nonBlank == nil {
                issues.append(ValidationIssue(.invalidTrigger, .error, message: "Choose the event that starts this workflow."))
            } else if let knownEvents, !knownEvents.contains(name) {
                issues.append(ValidationIssue(.unknownEvent, .warning, message: "No installed feature announces “\(name.rawValue)”, so this trigger may never fire."))
            }
            for path in condition?.referencedPaths ?? [] where ContextPath(path) == nil {
                issues.append(ValidationIssue(.invalidPath, .error, message: "The trigger condition uses “\(path)”, which is not a valid path."))
            }
            return issues

        case .schedule(let schedule):
            var issues: [ValidationIssue] = []
            switch schedule.rule.end {
            case .never:
                break
            case .afterOccurrences(let count) where count < 1:
                issues.append(ValidationIssue(.invalidTrigger, .error, message: "The schedule must occur at least once."))
            case .afterOccurrences:
                break
            case .onDate(let end) where end < schedule.anchor:
                issues.append(ValidationIssue(.invalidTrigger, .error, message: "The schedule ends before it starts."))
            case .onDate:
                break
            }
            if schedule.rule.frequency == .monthly, let pattern = schedule.rule.monthlyPattern {
                switch pattern {
                case .dayOfMonth(let day) where !(1...31).contains(day):
                    issues.append(ValidationIssue(.invalidTrigger, .error, message: "Choose a day of the month between 1 and 31."))
                case .weekdayOrdinal(let ordinal, _) where !(ordinal == -1 || (1...5).contains(ordinal)):
                    issues.append(ValidationIssue(.invalidTrigger, .error, message: "Choose the first to fifth or the last weekday of the month."))
                case .dayOfMonth, .weekdayOrdinal, .lastDayOfMonth:
                    break
                }
            }
            return issues
        }
    }

    public static func validate(graph: WorkflowGraph, actions: [AutomationActionID: AutomationActionDescriptor]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let nodes = graph.nodesByID

        var seen = Set<WorkflowNode.ID>()
        for node in graph.nodes where !seen.insert(node.id).inserted {
            issues.append(ValidationIssue(.duplicateNodeID, .error, nodeID: node.id, message: "Two steps share the identifier \(node.id)."))
        }

        let triggers = graph.nodes.filter { $0.kind.isTrigger }
        if triggers.isEmpty {
            issues.append(ValidationIssue(.missingTrigger, .error, message: "Add a trigger step."))
        }
        for extra in triggers.dropFirst() {
            issues.append(ValidationIssue(.multipleTriggers, .error, nodeID: extra.id, message: "A workflow has a single trigger; remove “\(extra.title)”."))
        }

        let edges = structurallyValidEdges(of: graph, nodes: nodes, issues: &issues)
        issues += portUsageIssues(edges: edges, graph: graph)
        issues += cycleIssues(edges: edges, graph: graph)

        if let trigger = triggers.first {
            let reachable = reachableNodes(from: trigger.id, edges: edges)
            for node in graph.nodes where !node.kind.isTrigger && !reachable.contains(node.id) {
                issues.append(ValidationIssue(.unreachableNode, .error, nodeID: node.id, message: "“\(node.title)” isn't connected to the trigger."))
            }
            if !edges.contains(where: { $0.from == trigger.id }) {
                issues.append(ValidationIssue(.emptyWorkflow, .warning, nodeID: trigger.id, message: "Connect a step to the trigger so the workflow does something."))
            }
        }

        for node in graph.nodes {
            issues += validate(node: node, actions: actions)
        }
        return issues
    }

    /// The edges whose endpoints exist and whose source may use the port. Problems are appended to `issues`.
    static func structurallyValidEdges(
        of graph: WorkflowGraph,
        nodes: [WorkflowNode.ID: WorkflowNode],
        issues: inout [ValidationIssue]
    ) -> [WorkflowEdge] {
        var valid: [WorkflowEdge] = []
        for edge in graph.edges {
            guard let source = nodes[edge.from] else {
                issues.append(ValidationIssue(.danglingEdge, .error, message: "A connection starts at a step that doesn't exist."))
                continue
            }
            guard let target = nodes[edge.to] else {
                issues.append(ValidationIssue(.danglingEdge, .error, nodeID: source.id, message: "A connection from “\(source.title)” leads to a step that doesn't exist."))
                continue
            }
            if target.kind.isTrigger {
                issues.append(ValidationIssue(.triggerHasIncomingEdge, .error, nodeID: target.id, message: "Nothing can connect into the trigger."))
                continue
            }
            if case .end = source.kind {
                issues.append(ValidationIssue(.endHasOutgoingEdge, .error, nodeID: source.id, message: "“\(source.title)” ends the workflow, so it can't continue to another step."))
                continue
            }
            guard source.kind.outputPorts.contains(edge.port) else {
                issues.append(ValidationIssue(.invalidPort, .error, nodeID: source.id, message: "“\(source.title)” has no “\(edge.port.rawValue)” output."))
                continue
            }
            valid.append(edge)
        }
        return valid
    }

    static func portUsageIssues(edges: [WorkflowEdge], graph: WorkflowGraph) -> [ValidationIssue] {
        var usage: [WorkflowNode.ID: [EdgePort: Int]] = [:]
        for edge in edges {
            usage[edge.from, default: [:]][edge.port, default: 0] += 1
        }
        var issues: [ValidationIssue] = []
        var visited = Set<WorkflowNode.ID>()
        for node in graph.nodes where visited.insert(node.id).inserted {
            for port in node.kind.outputPorts where (usage[node.id]?[port] ?? 0) > 1 {
                if port == .next {
                    issues.append(ValidationIssue(.multipleNextEdges, .error, nodeID: node.id, message: "“\(node.title)” can continue to only one step."))
                } else {
                    let branch = port == .whenTrue ? "true" : "false"
                    issues.append(ValidationIssue(.duplicateBranch, .error, nodeID: node.id, message: "“\(node.title)” has more than one “\(branch)” branch."))
                }
            }
        }
        return issues
    }

    /// One issue per node that closes a cycle (the target of a back edge), found by iterative DFS.
    static func cycleIssues(edges: [WorkflowEdge], graph: WorkflowGraph) -> [ValidationIssue] {
        enum Mark { case visiting, done }
        var adjacency: [WorkflowNode.ID: [WorkflowNode.ID]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }
        let nodes = graph.nodesByID
        var marks: [WorkflowNode.ID: Mark] = [:]
        var reported = Set<WorkflowNode.ID>()
        var issues: [ValidationIssue] = []

        for start in graph.nodes where marks[start.id] == nil {
            var stack: [(node: WorkflowNode.ID, next: Int)] = [(start.id, 0)]
            marks[start.id] = .visiting
            while let top = stack.last {
                let successors = adjacency[top.node] ?? []
                guard top.next < successors.count else {
                    marks[top.node] = .done
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let successor = successors[top.next]
                switch marks[successor] {
                case .visiting:
                    if reported.insert(successor).inserted {
                        let title = nodes[successor]?.title ?? "A step"
                        issues.append(ValidationIssue(.cycle, .error, nodeID: successor, message: "“\(title)” is part of a loop. Workflows can't repeat steps."))
                    }
                case .done:
                    break
                case nil:
                    marks[successor] = .visiting
                    stack.append((successor, 0))
                }
            }
        }
        return issues
    }

    static func reachableNodes(from start: WorkflowNode.ID, edges: [WorkflowEdge]) -> Set<WorkflowNode.ID> {
        var adjacency: [WorkflowNode.ID: [WorkflowNode.ID]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }
        var reachable: Set<WorkflowNode.ID> = [start]
        var queue = [start]
        while let node = queue.popLast() {
            for successor in adjacency[node] ?? [] where reachable.insert(successor).inserted {
                queue.append(successor)
            }
        }
        return reachable
    }
}
