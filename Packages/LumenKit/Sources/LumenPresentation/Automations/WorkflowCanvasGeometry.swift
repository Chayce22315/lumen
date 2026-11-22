import Foundation
import LumenFoundation
import LumenAutomation

/// A cubic Bézier from an output port to an input port, as drawn on the canvas.
public struct CanvasCurve: Sendable, Equatable {
    public var start: CGPoint
    public var control1: CGPoint
    public var control2: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    /// The point at `t` in `0...1`.
    public func point(at t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let x = a * Double(start.x) + b * Double(control1.x) + c * Double(control2.x) + d * Double(end.x)
        let y = a * Double(start.y) + b * Double(control1.y) + c * Double(control2.y) + d * Double(end.y)
        return CGPoint(x: x, y: y)
    }

    /// Distance from `point` to the curve, measured against `segments` straight pieces.
    public func distance(to point: CGPoint, segments: Int = 32) -> Double {
        let count = max(1, segments)
        var best = Double.infinity
        var previous = start
        for index in 1...count {
            let next = self.point(at: Double(index) / Double(count))
            best = min(best, CanvasMath.distance(from: point, toSegment: previous, next))
            previous = next
        }
        return best
    }

    /// The curve's midpoint, where a connection's label or delete affordance sits.
    public var midpoint: CGPoint { point(at: 0.5) }
}

enum CanvasMath {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x) - Double(b.x), Double(a.y) - Double(b.y))
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
        let px = Double(point.x), py = Double(point.y)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
        let t = min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}

/// Where everything sits on the workflow canvas, in view points: node frames, ports and the
/// curves between them, plus hit-testing for the gestures that edit the graph.
///
/// A node's `position` is its centre in canvas points. The view shows the bounding box of all nodes
/// with a margin, so view = position − (smallest position) + margin + half a node. Inputs sit at the
/// top centre of a node; outputs along its bottom edge (`next` in the middle, a condition's `true`
/// branch on the left third and `false` on the right third).
public struct WorkflowCanvasGeometry: Sendable {
    public static let nodeSize = CGSize(width: 220, height: 72)
    public static let margin: Double = 48
    /// Spacing positions snap to when a node is dropped.
    public static let grid: Double = 20
    /// How far from a port or connection a touch still hits it (44 pt targets).
    public static let hitTolerance: Double = 22

    public let graph: WorkflowGraph
    private let offset: CGPoint
    public let contentSize: CGSize

    public init(graph: WorkflowGraph) {
        self.graph = graph
        let xs = graph.nodes.map(\.position.x)
        let ys = graph.nodes.map(\.position.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let width = Double(Self.nodeSize.width), height = Double(Self.nodeSize.height)
        self.offset = CGPoint(x: Self.margin + width / 2 - minX, y: Self.margin + height / 2 - minY)
        self.contentSize = CGSize(width: maxX - minX + width + 2 * Self.margin, height: maxY - minY + height + 2 * Self.margin)
    }

    // MARK: Coordinates

    public func viewPoint(_ position: CanvasPoint) -> CGPoint {
        CGPoint(x: position.x + Double(offset.x), y: position.y + Double(offset.y))
    }

    public func canvasPoint(_ point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: Double(point.x) - Double(offset.x), y: Double(point.y) - Double(offset.y))
    }

    public func center(of id: WorkflowNode.ID) -> CGPoint? {
        graph.node(id).map { viewPoint($0.position) }
    }

    public func frame(of id: WorkflowNode.ID) -> CGRect? {
        guard let center = center(of: id) else { return nil }
        let width = Double(Self.nodeSize.width), height = Double(Self.nodeSize.height)
        return CGRect(x: Double(center.x) - width / 2, y: Double(center.y) - height / 2, width: width, height: height)
    }

    public func inputPoint(of id: WorkflowNode.ID) -> CGPoint? {
        guard let frame = frame(of: id) else { return nil }
        return CGPoint(x: Double(frame.midX), y: Double(frame.minY))
    }

    /// Where `port` leaves the node; `nil` when the node has no such output.
    public func outputPoint(of id: WorkflowNode.ID, port: EdgePort) -> CGPoint? {
        guard let node = graph.node(id), node.kind.outputPorts.contains(port), let frame = frame(of: id) else { return nil }
        let fraction: Double
        switch port {
        case .next: fraction = 0.5
        case .whenTrue: fraction = 1.0 / 3
        case .whenFalse: fraction = 2.0 / 3
        }
        return CGPoint(x: Double(frame.minX) + Double(frame.width) * fraction, y: Double(frame.maxY))
    }

    // MARK: Connections

    /// The curve for an edge; `nil` when an endpoint is missing or the port doesn't exist.
    public func curve(for edge: WorkflowEdge) -> CanvasCurve? {
        guard let start = outputPoint(of: edge.from, port: edge.port), let end = inputPoint(of: edge.to) else { return nil }
        return Self.curve(from: start, to: end)
    }

    /// A vertical S-curve; it bends further when the target sits above the source.
    public static func curve(from start: CGPoint, to end: CGPoint) -> CanvasCurve {
        let vertical = Double(end.y) - Double(start.y)
        let bend = max(40, min(160, abs(vertical) / 2 + (vertical < 0 ? 80 : 0)))
        return CanvasCurve(
            start: start,
            control1: CGPoint(x: Double(start.x), y: Double(start.y) + bend),
            control2: CGPoint(x: Double(end.x), y: Double(end.y) - bend),
            end: end
        )
    }

    // MARK: Hit-testing

    /// The topmost node whose frame contains `point` (later nodes draw on top).
    public func node(at point: CGPoint) -> WorkflowNode.ID? {
        graph.nodes.reversed().first { node in frame(of: node.id)?.contains(point) ?? false }?.id
    }

    /// The output port nearest to `point` within `tolerance`.
    public func outputPort(at point: CGPoint, tolerance: Double = hitTolerance) -> (node: WorkflowNode.ID, port: EdgePort)? {
        var best: (node: WorkflowNode.ID, port: EdgePort, distance: Double)?
        for node in graph.nodes {
            for port in node.kind.outputPorts {
                guard let position = outputPoint(of: node.id, port: port) else { continue }
                let distance = CanvasMath.distance(point, position)
                if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                    best = (node.id, port, distance)
                }
            }
        }
        return best.map { ($0.node, $0.port) }
    }

    /// The connection nearest to `point` within `tolerance`, ignoring points over a node (a touch
    /// there belongs to the node).
    public func edge(at point: CGPoint, tolerance: Double = hitTolerance) -> WorkflowEdge? {
        guard node(at: point) == nil else { return nil }
        var best: (edge: WorkflowEdge, distance: Double)?
        for edge in graph.edges {
            guard let curve = curve(for: edge) else { continue }
            let distance = curve.distance(to: point)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (edge, distance)
            }
        }
        return best?.edge
    }

    /// The node a connection dragged to `point` would end on: the node under it, else a node whose
    /// input port is within `tolerance`. Never `source` itself.
    public func dropTarget(at point: CGPoint, from source: WorkflowNode.ID, tolerance: Double = hitTolerance) -> WorkflowNode.ID? {
        if let id = node(at: point), id != source { return id }
        var best: (id: WorkflowNode.ID, distance: Double)?
        for node in graph.nodes where node.id != source {
            guard let input = inputPoint(of: node.id) else { continue }
            let distance = CanvasMath.distance(point, input)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    // MARK: Moving

    /// Rounds a position to the grid.
    public static func snap(_ position: CanvasPoint, grid: Double = grid) -> CanvasPoint {
        guard grid > 0 else { return position }
        return CanvasPoint(x: (position.x / grid).rounded() * grid, y: (position.y / grid).rounded() * grid)
    }

    /// Where a node lands after being dragged by `translation` view points, snapped to the grid.
    public func droppedPosition(of id: WorkflowNode.ID, translation: CGSize) -> CanvasPoint? {
        guard let node = graph.node(id) else { return nil }
        let moved = CanvasPoint(x: node.position.x + Double(translation.width), y: node.position.y + Double(translation.height))
        return Self.snap(moved)
    }

    /// A free spot for a new node below `source` (offset toward its branch side), moving right
    /// until it doesn't overlap another node.
    public func placement(below source: WorkflowNode.ID, port: EdgePort) -> CanvasPoint {
        let base = graph.node(source)?.position ?? .zero
        let sideways: Double
        switch port {
        case .next: sideways = 0
        case .whenTrue: sideways = -130
        case .whenFalse: sideways = 130
        }
        var candidate = Self.snap(CanvasPoint(x: base.x + sideways, y: base.y + 140))
        let width = Double(Self.nodeSize.width), height = Double(Self.nodeSize.height)
        for _ in 0..<50 {
            let overlaps = graph.nodes.contains { node in
                abs(node.position.x - candidate.x) < width && abs(node.position.y - candidate.y) < height
            }
            guard overlaps else { break }
            candidate.x += width + Self.grid
        }
        return candidate
    }
}
