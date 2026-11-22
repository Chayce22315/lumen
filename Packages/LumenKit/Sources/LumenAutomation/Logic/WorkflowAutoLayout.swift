import Foundation
import LumenFoundation

public struct WorkflowLayoutOptions: Sendable, Hashable {
    /// Minimum distance between node centres within a layer.
    public var horizontalSpacing: Double
    /// Distance between layers.
    public var verticalSpacing: Double
    /// Position of the trigger node.
    public var origin: CanvasPoint

    public init(horizontalSpacing: Double = 240, verticalSpacing: Double = 140, origin: CanvasPoint = .zero) {
        self.horizontalSpacing = max(1, horizontalSpacing)
        self.verticalSpacing = max(1, verticalSpacing)
        self.origin = origin
    }
}

/// Layered top-to-bottom layout for the canvas.
///
/// A node's layer is the length of the longest path from the trigger, so every connection points
/// downward. Within a layer nodes are ordered by the average position of their predecessors
/// (`true` branches lean left, `false` branches right), ties broken by the order of `nodes`, and
/// packed at least `horizontalSpacing` apart. Unreachable nodes are laid out by their own longest
/// paths and placed to the right. Cycles (invalid, but possible while editing) are broken at their
/// back edges, so layout always terminates. The result depends only on the graph.
public enum WorkflowAutoLayout {
    /// Layer index per node.
    public static func layers(of graph: WorkflowGraph) -> [WorkflowNode.ID: Int] {
        Structure(graph).layers
    }

    public static func positions(for graph: WorkflowGraph, options: WorkflowLayoutOptions = WorkflowLayoutOptions()) -> [WorkflowNode.ID: CanvasPoint] {
        let structure = Structure(graph)
        let maxLayer = structure.layers.values.max() ?? 0
        var x: [WorkflowNode.ID: Double] = [:]
        var positions: [WorkflowNode.ID: CanvasPoint] = [:]

        for layer in 0...maxLayer {
            let members = structure.order.filter { structure.layers[$0] == layer }
            let desired: [WorkflowNode.ID: Double] = Dictionary(uniqueKeysWithValues: members.compactMap { node in
                let anchors = structure.predecessors[node, default: []].compactMap { edge -> Double? in
                    guard let base = x[edge.from] else { return nil }
                    return base + offset(edge.port) * options.horizontalSpacing
                }
                guard !anchors.isEmpty else { return nil }
                return (node, anchors.reduce(0, +) / Double(anchors.count))
            })
            let sorted = members.sorted { a, b in
                let ra = structure.reachable.contains(a), rb = structure.reachable.contains(b)
                if ra != rb { return ra }
                let da = desired[a] ?? .infinity, db = desired[b] ?? .infinity
                if da != db { return da < db }
                return (structure.index[a] ?? 0) < (structure.index[b] ?? 0)
            }

            // Pack left to right without overlap, then shift the layer so it is centred on the
            // positions its nodes would like to have.
            var packed: [Double] = []
            for node in sorted {
                let wanted = desired[node]
                guard let previous = packed.last else {
                    packed.append(wanted ?? 0)
                    continue
                }
                packed.append(max(wanted ?? -.infinity, previous + options.horizontalSpacing))
            }
            let anchoredOffsets = zip(sorted, packed).compactMap { node, value in desired[node].map { $0 - value } }
            let shift = anchoredOffsets.isEmpty ? -((packed.first ?? 0) + (packed.last ?? 0)) / 2 : anchoredOffsets.reduce(0, +) / Double(anchoredOffsets.count)
            for (node, value) in zip(sorted, packed) {
                let finalX = value + shift
                x[node] = finalX
                positions[node] = CanvasPoint(
                    x: options.origin.x + finalX,
                    y: options.origin.y + Double(layer) * options.verticalSpacing
                )
            }
        }
        return positions
    }

    /// The graph with every node moved to its laid-out position.
    public static func apply(to graph: WorkflowGraph, options: WorkflowLayoutOptions = WorkflowLayoutOptions()) -> WorkflowGraph {
        let positions = positions(for: graph, options: options)
        var result = graph
        for index in result.nodes.indices {
            if let position = positions[result.nodes[index].id] {
                result.nodes[index].position = position
            }
        }
        return result
    }

    static func offset(_ port: EdgePort) -> Double {
        switch port {
        case .next: return 0
        case .whenTrue: return -0.25
        case .whenFalse: return 0.25
        }
    }

    /// The acyclic skeleton of a graph and its longest-path layering.
    struct Structure {
        var order: [WorkflowNode.ID] = []
        var index: [WorkflowNode.ID: Int] = [:]
        var predecessors: [WorkflowNode.ID: [WorkflowEdge]] = [:]
        var reachable: Set<WorkflowNode.ID> = []
        var layers: [WorkflowNode.ID: Int] = [:]

        init(_ graph: WorkflowGraph) {
            for node in graph.nodes where index[node.id] == nil {
                index[node.id] = order.count
                order.append(node.id)
            }
            let edges = graph.edges.filter { index[$0.from] != nil && index[$0.to] != nil && $0.from != $0.to }
            let dag = Self.removingBackEdges(edges, order: order, start: graph.triggerNode?.id)
            var successors: [WorkflowNode.ID: [WorkflowNode.ID]] = [:]
            for edge in dag {
                successors[edge.from, default: []].append(edge.to)
                predecessors[edge.to, default: []].append(edge)
            }
            if let trigger = graph.triggerNode?.id {
                reachable = WorkflowValidator.reachableNodes(from: trigger, edges: dag)
            }
            for node in Self.topologicalOrder(order: order, index: index, successors: successors, predecessors: predecessors) {
                let isReachable = reachable.contains(node)
                let parents = predecessors[node, default: []].filter { reachable.contains($0.from) == isReachable }
                layers[node] = parents.compactMap { layers[$0.from].map { $0 + 1 } }.max() ?? 0
            }
        }

        /// Drops edges that close a cycle, exploring from the trigger first.
        static func removingBackEdges(_ edges: [WorkflowEdge], order: [WorkflowNode.ID], start: WorkflowNode.ID?) -> [WorkflowEdge] {
            enum Mark { case visiting, done }
            var outgoing: [WorkflowNode.ID: [WorkflowEdge]] = [:]
            for edge in edges {
                outgoing[edge.from, default: []].append(edge)
            }
            var marks: [WorkflowNode.ID: Mark] = [:]
            var back = Set<WorkflowEdge>()
            let roots = (start.map { [$0] } ?? []) + order
            for root in roots where marks[root] == nil {
                var stack: [(node: WorkflowNode.ID, next: Int)] = [(root, 0)]
                marks[root] = .visiting
                while let top = stack.last {
                    let leaving = outgoing[top.node] ?? []
                    guard top.next < leaving.count else {
                        marks[top.node] = .done
                        stack.removeLast()
                        continue
                    }
                    stack[stack.count - 1].next += 1
                    let edge = leaving[top.next]
                    switch marks[edge.to] {
                    case .visiting: back.insert(edge)
                    case .done: break
                    case nil:
                        marks[edge.to] = .visiting
                        stack.append((edge.to, 0))
                    }
                }
            }
            return edges.filter { !back.contains($0) }
        }

        /// Kahn's algorithm, always taking the earliest node (by `order`) whose predecessors are placed.
        static func topologicalOrder(
            order: [WorkflowNode.ID],
            index: [WorkflowNode.ID: Int],
            successors: [WorkflowNode.ID: [WorkflowNode.ID]],
            predecessors: [WorkflowNode.ID: [WorkflowEdge]]
        ) -> [WorkflowNode.ID] {
            var remaining = Dictionary(uniqueKeysWithValues: order.map { ($0, predecessors[$0, default: []].count) })
            var ready = order.filter { remaining[$0] == 0 }
            var result: [WorkflowNode.ID] = []
            while !ready.isEmpty {
                ready.sort { (index[$0] ?? 0) < (index[$1] ?? 0) }
                let node = ready.removeFirst()
                result.append(node)
                for successor in successors[node] ?? [] {
                    remaining[successor, default: 0] -= 1
                    if remaining[successor] == 0 { ready.append(successor) }
                }
            }
            return result
        }
    }
}
