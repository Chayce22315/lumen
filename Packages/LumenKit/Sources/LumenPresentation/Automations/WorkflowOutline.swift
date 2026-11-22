import Foundation
import LumenFoundation
import LumenAutomation

/// The workflow's steps in reading order, for the list form of the editor (and for VoiceOver,
/// which reads it instead of the canvas).
///
/// Starting at the trigger, each step is followed by what its outputs lead to, in port order:
/// `next`, then the `true` branch, then the `false` branch. Branches indent one level. A step
/// reached from several places (branches joining) is listed where it is first reached. Steps not
/// connected to the trigger come last, marked as such.
public enum WorkflowOutline {
    public struct Item: Sendable, Hashable, Identifiable {
        public let nodeID: WorkflowNode.ID
        /// Indentation: 0 for the main path, +1 inside each branch.
        public let depth: Int
        /// The connection this step was reached through (`nil` for the trigger and for unconnected steps).
        public let via: WorkflowEdge?
        public let isConnected: Bool

        public var id: WorkflowNode.ID { nodeID }
    }

    public static func items(for graph: WorkflowGraph) -> [Item] {
        var items: [Item] = []
        var listed = Set<WorkflowNode.ID>()
        if let trigger = graph.triggerNode {
            // Iterative depth-first walk; the stack holds steps still to list, last first.
            var stack: [(id: WorkflowNode.ID, depth: Int, via: WorkflowEdge?)] = [(trigger.id, 0, nil)]
            while let entry = stack.popLast() {
                guard listed.insert(entry.id).inserted, let node = graph.node(entry.id) else { continue }
                items.append(Item(nodeID: entry.id, depth: entry.depth, via: entry.via, isConnected: true))
                let outgoing = node.kind.outputPorts.compactMap { port in
                    graph.edges.first { $0.from == entry.id && $0.port == port }
                }
                for edge in outgoing.reversed() where !listed.contains(edge.to) {
                    let depth = edge.port == .next ? entry.depth : entry.depth + 1
                    stack.append((edge.to, depth, edge))
                }
            }
        }
        for node in graph.nodes where !listed.contains(node.id) {
            listed.insert(node.id)
            items.append(Item(nodeID: node.id, depth: 0, via: nil, isConnected: false))
        }
        return items
    }

    /// Where `add step` continues the main path: the last step reached by following `next` (or a
    /// condition's `true` branch) from the trigger whose continuing output is free. When the path
    /// ends in an end step, the new step goes before it.
    public static func appendPoint(in graph: WorkflowGraph) -> (node: WorkflowNode.ID, port: EdgePort)? {
        guard var current = graph.triggerNode else { return nil }
        var visited: Set<WorkflowNode.ID> = [current.id]
        var arrival: (node: WorkflowNode.ID, port: EdgePort)?
        while true {
            guard let port = current.kind.continuationPort else {
                // An end step: insert on the connection that led to it.
                return arrival
            }
            guard let next = graph.successor(of: current.id, port: port),
                  let node = graph.node(next),
                  visited.insert(next).inserted else {
                return (current.id, port)
            }
            arrival = (current.id, port)
            current = node
        }
    }
}
