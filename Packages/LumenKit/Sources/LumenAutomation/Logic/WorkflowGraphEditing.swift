import Foundation
import LumenFoundation

/// Why an editing operation was refused. Shown to the user by the canvas.
public enum WorkflowGraphEditError: Error, Sendable, Hashable, PresentableError {
    case nodeNotFound(WorkflowNode.ID)
    case duplicateNode(WorkflowNode.ID)
    /// The node has no such output (an action has no `whenTrue`, an end node has no outputs).
    case invalidPort(WorkflowNode.ID, EdgePort)
    /// The output is already connected; disconnect it first.
    case portOccupied(WorkflowNode.ID, EdgePort)
    case cannotConnectToTrigger
    case cannotConnectToItself
    case wouldCreateCycle
    case cannotRemoveTrigger
    /// A workflow has exactly one trigger.
    case triggerAlreadyExists
    /// Inserting an end node before an existing step would cut that step off.
    case endCannotContinue

    public var presentation: ErrorPresentation {
        let message: String
        switch self {
        case .nodeNotFound: message = "That step no longer exists."
        case .duplicateNode: message = "That step is already in the workflow."
        case .invalidPort: message = "That step can't connect from this output."
        case .portOccupied: message = "That output is already connected. Remove the existing connection first."
        case .cannotConnectToTrigger: message = "Nothing can connect into the trigger."
        case .cannotConnectToItself: message = "A step can't connect to itself."
        case .wouldCreateCycle: message = "That connection would make the workflow loop."
        case .cannotRemoveTrigger: message = "Every workflow needs its trigger."
        case .triggerAlreadyExists: message = "A workflow has a single trigger."
        case .endCannotContinue: message = "An end step can only be added at the end of a branch."
        }
        return ErrorPresentation(title: "Can't change the workflow", message: message)
    }
}

/// Pure editing operations for the canvas. Each returns a new graph or throws without changes.
public enum WorkflowGraphEditing {
    /// Adds an unconnected node (dropped onto the canvas).
    public static func add(_ node: WorkflowNode, to graph: WorkflowGraph) throws -> WorkflowGraph {
        guard !graph.contains(node.id) else { throw WorkflowGraphEditError.duplicateNode(node.id) }
        var result = graph
        result.nodes.append(node)
        return result
    }

    /// Inserts `node` after `source` on `port`. If that output already led somewhere, the new node
    /// is spliced in: `source → node → previous target`, continuing on the new node's natural port
    /// (`.next`, or `.whenTrue` for a condition).
    public static func insert(
        _ node: WorkflowNode,
        after source: WorkflowNode.ID,
        port: EdgePort = .next,
        in graph: WorkflowGraph
    ) throws -> WorkflowGraph {
        guard !graph.contains(node.id) else { throw WorkflowGraphEditError.duplicateNode(node.id) }
        guard let sourceNode = graph.node(source) else { throw WorkflowGraphEditError.nodeNotFound(source) }
        guard sourceNode.kind.outputPorts.contains(port) else { throw WorkflowGraphEditError.invalidPort(source, port) }
        if node.kind.isTrigger { throw WorkflowGraphEditError.cannotConnectToTrigger }

        var result = graph
        result.nodes.append(node)
        if let existingIndex = result.edges.firstIndex(where: { $0.from == source && $0.port == port }) {
            let previousTarget = result.edges[existingIndex].to
            guard let continuation = node.kind.continuationPort else { throw WorkflowGraphEditError.endCannotContinue }
            result.edges[existingIndex].to = node.id
            result.edges.insert(WorkflowEdge(from: node.id, to: previousTarget, port: continuation), at: existingIndex + 1)
        } else {
            result.edges.append(WorkflowEdge(from: source, to: node.id, port: port))
        }
        return result
    }

    /// Removes a node and its connections. When the node had exactly one successor, every
    /// predecessor is reconnected to it on the port it used, so a chain stays connected. Nodes with
    /// several successors (a condition with both branches) are not reconnected: there is no
    /// unambiguous choice, and the validator reports what became unreachable.
    public static func remove(_ id: WorkflowNode.ID, from graph: WorkflowGraph) throws -> WorkflowGraph {
        guard let node = graph.node(id) else { throw WorkflowGraphEditError.nodeNotFound(id) }
        if node.kind.isTrigger { throw WorkflowGraphEditError.cannotRemoveTrigger }

        let incoming = graph.incomingEdges(to: id).filter { $0.from != id }
        let outgoing = graph.outgoingEdges(from: id).filter { $0.to != id }
        var result = graph
        result.nodes.removeAll { $0.id == id }
        result.edges.removeAll { $0.from == id || $0.to == id }

        if outgoing.count == 1, let successor = outgoing.first?.to {
            for edge in incoming {
                let occupied = result.edges.contains { $0.from == edge.from && $0.port == edge.port }
                guard !occupied, edge.from != successor else { continue }
                result.edges.append(WorkflowEdge(from: edge.from, to: successor, port: edge.port))
            }
        }
        return result
    }

    /// Connects `source`'s `port` to `target`.
    public static func connect(
        _ source: WorkflowNode.ID,
        to target: WorkflowNode.ID,
        port: EdgePort = .next,
        in graph: WorkflowGraph
    ) throws -> WorkflowGraph {
        guard let sourceNode = graph.node(source) else { throw WorkflowGraphEditError.nodeNotFound(source) }
        guard let targetNode = graph.node(target) else { throw WorkflowGraphEditError.nodeNotFound(target) }
        guard source != target else { throw WorkflowGraphEditError.cannotConnectToItself }
        guard sourceNode.kind.outputPorts.contains(port) else { throw WorkflowGraphEditError.invalidPort(source, port) }
        if targetNode.kind.isTrigger { throw WorkflowGraphEditError.cannotConnectToTrigger }
        if graph.edges.contains(where: { $0.from == source && $0.port == port }) {
            throw WorkflowGraphEditError.portOccupied(source, port)
        }
        if WorkflowValidator.reachableNodes(from: target, edges: graph.edges).contains(source) {
            throw WorkflowGraphEditError.wouldCreateCycle
        }
        var result = graph
        result.edges.append(WorkflowEdge(from: source, to: target, port: port))
        return result
    }

    /// Removes the connection leaving `source` on `port`, if any.
    public static func disconnect(_ source: WorkflowNode.ID, port: EdgePort, in graph: WorkflowGraph) -> WorkflowGraph {
        var result = graph
        result.edges.removeAll { $0.from == source && $0.port == port }
        return result
    }

    /// Removes one specific connection, if present.
    public static func disconnect(_ edge: WorkflowEdge, in graph: WorkflowGraph) -> WorkflowGraph {
        var result = graph
        result.edges.removeAll { $0 == edge }
        return result
    }

    /// Moves a node on the canvas.
    public static func move(_ id: WorkflowNode.ID, to position: CanvasPoint, in graph: WorkflowGraph) throws -> WorkflowGraph {
        guard let index = graph.index(of: id) else { throw WorkflowGraphEditError.nodeNotFound(id) }
        var result = graph
        result.nodes[index].position = position
        return result
    }

    /// Replaces a node's title and kind, keeping its identity, position and connections. Connections
    /// on ports the new kind doesn't have are removed.
    public static func update(_ id: WorkflowNode.ID, title: String, kind: WorkflowNode.Kind, in graph: WorkflowGraph) throws -> WorkflowGraph {
        guard let index = graph.index(of: id) else { throw WorkflowGraphEditError.nodeNotFound(id) }
        if graph.nodes[index].kind.isTrigger, !kind.isTrigger { throw WorkflowGraphEditError.cannotRemoveTrigger }
        if kind.isTrigger, !graph.nodes[index].kind.isTrigger { throw WorkflowGraphEditError.triggerAlreadyExists }
        var result = graph
        result.nodes[index].title = title
        result.nodes[index].kind = kind
        let ports = Set(kind.outputPorts)
        result.edges.removeAll { $0.from == id && !ports.contains($0.port) }
        return result
    }
}
