import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("WorkflowAutoLayout")
struct WorkflowAutoLayoutTests {
    let options = WorkflowLayoutOptions(horizontalSpacing: 200, verticalSpacing: 100)

    @Test("a chain stacks vertically under the trigger")
    func chain() {
        var builder = GraphBuilder()
        let ids = builder.chain([action("a"), action("b"), .end])
        let positions = WorkflowAutoLayout.positions(for: builder.graph, options: options)
        #expect(positions[builder.trigger] == CanvasPoint(x: 0, y: 0))
        #expect(ids.map { positions[$0] } == [CanvasPoint(x: 0, y: 100), CanvasPoint(x: 0, y: 200), CanvasPoint(x: 0, y: 300)])
    }

    @Test("true branches go left and false branches right, and children follow their parents")
    func branches() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        // The false branch is added first; ordering must not depend on insertion order.
        let no = builder.add(.end, after: check, port: .whenFalse)
        let yes = builder.add(action("a"), after: check, port: .whenTrue)
        let afterYes = builder.add(.end, after: yes)
        let positions = WorkflowAutoLayout.positions(for: builder.graph, options: options)
        #expect(positions[check] == CanvasPoint(x: 0, y: 100))
        #expect(positions[yes] == CanvasPoint(x: -100, y: 200))
        #expect(positions[no] == CanvasPoint(x: 100, y: 200))
        #expect(positions[afterYes] == CanvasPoint(x: -100, y: 300))
    }

    @Test("a node's layer is the longest path from the trigger")
    func longestPath() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        let long = builder.add(action("a"), after: check, port: .whenTrue)
        let longer = builder.add(action("b"), after: long)
        let merge = builder.add(.end, after: longer)
        var graph = builder.graph
        graph.edges.append(WorkflowEdge(from: check, to: merge, port: .whenFalse))
        let layers = WorkflowAutoLayout.layers(of: graph)
        #expect(layers[builder.trigger] == 0)
        #expect(layers[check] == 1)
        #expect(layers[merge] == 4)
        let positions = WorkflowAutoLayout.positions(for: graph, options: options)
        #expect(positions[merge]?.y == 400)
    }

    @Test("layout is deterministic and honours spacing and origin")
    func deterministic() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        builder.add(action("a"), after: check, port: .whenTrue)
        builder.add(action("b"), after: check, port: .whenFalse)
        let custom = WorkflowLayoutOptions(horizontalSpacing: 300, verticalSpacing: 50, origin: CanvasPoint(x: 1_000, y: 10))
        let first = WorkflowAutoLayout.positions(for: builder.graph, options: custom)
        var reversedEdges = builder.graph
        reversedEdges.edges.reverse()
        #expect(WorkflowAutoLayout.positions(for: reversedEdges, options: custom) == first)
        #expect(first[builder.trigger] == CanvasPoint(x: 1_000, y: 10))
        #expect(Set(first.values.filter { $0.y == 110 }.map(\.x)) == [850, 1_150])
    }

    @Test("several children of one parent are spread without overlap")
    func spreading() {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        let yes = builder.add(action("a"), after: check, port: .whenTrue)
        let no = builder.add(action("b"), after: check, port: .whenFalse)
        let yesChild = builder.add(.end, after: yes)
        let noChild = builder.add(.end, after: no)
        let positions = WorkflowAutoLayout.positions(for: builder.graph, options: options)
        let xs = [yesChild, noChild].compactMap { positions[$0]?.x }
        #expect(xs.count == 2)
        #expect(abs(xs[0] - xs[1]) >= 200)
    }

    @Test("cycles and unreachable nodes still lay out")
    func robustness() {
        var builder = GraphBuilder()
        let a = builder.add(action("a"), after: builder.trigger)
        let b = builder.add(action("b"), after: a)
        var graph = builder.graph
        graph.edges.append(WorkflowEdge(from: b, to: a))
        let orphan = WorkflowNode(title: "Orphan", kind: .end)
        graph.nodes.append(orphan)
        let positions = WorkflowAutoLayout.positions(for: graph, options: options)
        #expect(positions.count == 4)
        #expect(positions[a]?.y == 100)
        #expect(positions[b]?.y == 200)
        // The unreachable root shares layer 0 with the trigger and sits to its right.
        #expect(positions[orphan.id]?.y == 0)
        #expect((positions[orphan.id]?.x ?? 0) > (positions[builder.trigger]?.x ?? 0))
    }

    @Test("apply moves every node to its position")
    func apply() {
        var builder = GraphBuilder()
        builder.chain([action("a"), .end])
        let laidOut = WorkflowAutoLayout.apply(to: builder.graph, options: options)
        #expect(laidOut.nodes.map(\.position.y) == [0, 100, 200])
        #expect(laidOut.edges == builder.graph.edges)
    }
}
