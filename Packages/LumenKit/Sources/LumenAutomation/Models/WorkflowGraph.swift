import Foundation
import LumenFoundation

/// A position on the workflow canvas, in canvas points.
public struct CanvasPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = CanvasPoint(x: 0, y: 0)
}

/// The output a connection leaves from. Actions, delays and the trigger continue on `.next`;
/// conditions branch on `.whenTrue` / `.whenFalse`; end nodes have no outputs.
public enum EdgePort: String, Sendable, Hashable, Codable, CaseIterable {
    case next
    case whenTrue
    case whenFalse
}

/// A directed connection between two nodes.
public struct WorkflowEdge: Sendable, Hashable, Codable, Identifiable {
    public var from: WorkflowNode.ID
    public var to: WorkflowNode.ID
    public var port: EdgePort

    public init(from: WorkflowNode.ID, to: WorkflowNode.ID, port: EdgePort = .next) {
        self.from = from
        self.to = to
        self.port = port
    }

    /// Stable identity for rendering: an edge is defined by its endpoints and port.
    public var id: String {
        "\(from.uuidString)>\(port.rawValue)>\(to.uuidString)"
    }
}

/// The visual and executable structure of a workflow: a directed acyclic graph rooted at a single
/// trigger node.
public struct WorkflowGraph: Sendable, Hashable, Codable {
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]

    public init(nodes: [WorkflowNode] = [], edges: [WorkflowEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    /// A new graph holding only a trigger node, the starting point of the editor.
    public static func starter(triggerID: WorkflowNode.ID = WorkflowNode.ID(), title: String = "Trigger") -> WorkflowGraph {
        WorkflowGraph(nodes: [WorkflowNode(id: triggerID, title: title, kind: .trigger)])
    }

    public func node(_ id: WorkflowNode.ID) -> WorkflowNode? {
        nodes.first { $0.id == id }
    }

    public func index(of id: WorkflowNode.ID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }

    public func contains(_ id: WorkflowNode.ID) -> Bool {
        index(of: id) != nil
    }

    /// The first trigger node. A valid graph has exactly one.
    public var triggerNode: WorkflowNode? {
        nodes.first { $0.kind == .trigger }
    }

    public func outgoingEdges(from id: WorkflowNode.ID) -> [WorkflowEdge] {
        edges.filter { $0.from == id }
    }

    public func incomingEdges(to id: WorkflowNode.ID) -> [WorkflowEdge] {
        edges.filter { $0.to == id }
    }

    /// The node connected to `id`'s output `port`, if any.
    public func successor(of id: WorkflowNode.ID, port: EdgePort) -> WorkflowNode.ID? {
        edges.first { $0.from == id && $0.port == port }?.to
    }

    /// Nodes keyed by identifier; the first node wins when identifiers repeat (an invalid graph).
    public var nodesByID: [WorkflowNode.ID: WorkflowNode] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
