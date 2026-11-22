import Foundation
import Testing
import LumenFoundation
import LumenAutomation

@Suite("WorkflowGraphEditing")
struct WorkflowGraphEditingTests {
    func node(_ kind: WorkflowNode.Kind, _ title: String = "New") -> WorkflowNode {
        WorkflowNode(title: title, kind: kind)
    }

    func expectEditError(_ expected: WorkflowGraphEditError, _ operation: () throws -> WorkflowGraph) {
        do {
            _ = try operation()
            Issue.record("expected \(expected)")
        } catch let error as WorkflowGraphEditError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("inserting after a connected node splices the new node in")
    func insertSplices() throws {
        var builder = GraphBuilder()
        let end = builder.add(.end, after: builder.trigger)
        let inserted = node(action("test.record"))
        let graph = try WorkflowGraphEditing.insert(inserted, after: builder.trigger, in: builder.graph)
        #expect(graph.successor(of: builder.trigger, port: .next) == inserted.id)
        #expect(graph.successor(of: inserted.id, port: .next) == end)
        #expect(graph.edges.count == 2)
    }

    @Test("inserting after a leaf appends a connection")
    func insertAppends() throws {
        let graph = WorkflowGraph.starter()
        let trigger = try #require(graph.triggerNode).id
        let inserted = node(.end)
        let result = try WorkflowGraphEditing.insert(inserted, after: trigger, in: graph)
        #expect(result.edges == [WorkflowEdge(from: trigger, to: inserted.id, port: .next)])
    }

    @Test("an inserted condition continues on its true branch; branches can be targeted")
    func insertCondition() throws {
        var builder = GraphBuilder()
        let end = builder.add(.end, after: builder.trigger)
        let check = node(.condition(.always))
        let graph = try WorkflowGraphEditing.insert(check, after: builder.trigger, in: builder.graph)
        #expect(graph.successor(of: check.id, port: .whenTrue) == end)
        let otherwise = node(.end, "Otherwise")
        let branched = try WorkflowGraphEditing.insert(otherwise, after: check.id, port: .whenFalse, in: graph)
        #expect(branched.successor(of: check.id, port: .whenFalse) == otherwise.id)
        #expect(branched.successor(of: check.id, port: .whenTrue) == end)
    }

    @Test("an end step can only close a branch")
    func insertEnd() {
        var builder = GraphBuilder()
        builder.add(.end, after: builder.trigger)
        expectEditError(.endCannotContinue) { try WorkflowGraphEditing.insert(node(.end), after: builder.trigger, in: builder.graph) }
    }

    @Test("insertion validates its source, port and node")
    func insertValidation() {
        var builder = GraphBuilder()
        let step = builder.add(action("test.record"), after: builder.trigger)
        let graph = builder.graph
        let missing = WorkflowNode.ID()
        expectEditError(.nodeNotFound(missing)) { try WorkflowGraphEditing.insert(node(.end), after: missing, in: graph) }
        expectEditError(.invalidPort(step, .whenTrue)) { try WorkflowGraphEditing.insert(node(.end), after: step, port: .whenTrue, in: graph) }
        expectEditError(.duplicateNode(step)) { try WorkflowGraphEditing.insert(WorkflowNode(id: step, title: "Again", kind: .end), after: builder.trigger, in: graph) }
        expectEditError(.cannotConnectToTrigger) { try WorkflowGraphEditing.insert(node(.trigger), after: step, in: graph) }
    }

    @Test("removing a step reconnects its predecessor to its successor")
    func removeReconnects() throws {
        var builder = GraphBuilder()
        let ids = builder.chain([action("test.record"), action("test.record"), .end])
        let graph = try WorkflowGraphEditing.remove(ids[1], from: builder.graph)
        #expect(!graph.contains(ids[1]))
        #expect(graph.successor(of: ids[0], port: .next) == ids[2])
        #expect(graph.edges.count == 2)
    }

    @Test("removing a merge step reconnects every predecessor on its own port")
    func removeMerge() throws {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        let merge = builder.add(action("test.record"), after: check, port: .whenTrue)
        var graph = builder.graph
        graph.edges.append(WorkflowEdge(from: check, to: merge, port: .whenFalse))
        let end = WorkflowNode(title: "End", kind: .end)
        graph.nodes.append(end)
        graph.edges.append(WorkflowEdge(from: merge, to: end.id))
        let result = try WorkflowGraphEditing.remove(merge, from: graph)
        #expect(result.successor(of: check, port: .whenTrue) == end.id)
        #expect(result.successor(of: check, port: .whenFalse) == end.id)
        #expect(result.edges.filter { $0.to == end.id }.count == 2)
    }

    @Test("removing a branching condition leaves its branches disconnected")
    func removeBranch() throws {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        let yes = builder.add(.end, after: check, port: .whenTrue)
        let no = builder.add(.end, after: check, port: .whenFalse)
        let result = try WorkflowGraphEditing.remove(check, from: builder.graph)
        #expect(result.edges.isEmpty)
        #expect(result.contains(yes) && result.contains(no))
    }

    @Test("the trigger cannot be removed")
    func removeTrigger() {
        let graph = WorkflowGraph.starter()
        guard let trigger = graph.triggerNode?.id else {
            Issue.record("starter graph has no trigger")
            return
        }
        expectEditError(.cannotRemoveTrigger) { try WorkflowGraphEditing.remove(trigger, from: graph) }
    }

    @Test("connections respect ports, occupancy and acyclicity")
    func connect() throws {
        var builder = GraphBuilder()
        let first = builder.add(action("test.record"), after: builder.trigger)
        let second = builder.add(action("test.record"), after: first)
        var graph = builder.graph
        let loose = WorkflowNode(title: "Loose", kind: .end)
        graph.nodes.append(loose)

        expectEditError(.portOccupied(first, .next)) { try WorkflowGraphEditing.connect(first, to: loose.id, in: graph) }
        expectEditError(.wouldCreateCycle) { try WorkflowGraphEditing.connect(second, to: first, in: graph) }
        expectEditError(.cannotConnectToItself) { try WorkflowGraphEditing.connect(second, to: second, in: graph) }
        expectEditError(.cannotConnectToTrigger) { try WorkflowGraphEditing.connect(second, to: builder.trigger, in: graph) }
        expectEditError(.invalidPort(second, .whenFalse)) { try WorkflowGraphEditing.connect(second, to: loose.id, port: .whenFalse, in: graph) }

        let connected = try WorkflowGraphEditing.connect(second, to: loose.id, in: graph)
        #expect(connected.successor(of: second, port: .next) == loose.id)
    }

    @Test("disconnecting, moving and updating nodes")
    func disconnectMoveUpdate() throws {
        var builder = GraphBuilder()
        let check = builder.add(.condition(.always), after: builder.trigger)
        let yes = builder.add(.end, after: check, port: .whenTrue)
        builder.add(.end, after: check, port: .whenFalse)
        let graph = builder.graph

        #expect(WorkflowGraphEditing.disconnect(check, port: .whenFalse, in: graph).edges.count == 2)
        #expect(WorkflowGraphEditing.disconnect(WorkflowEdge(from: check, to: yes, port: .whenTrue), in: graph).edges.count == 2)

        let moved = try WorkflowGraphEditing.move(yes, to: CanvasPoint(x: 10, y: 20), in: graph)
        #expect(moved.node(yes)?.position == CanvasPoint(x: 10, y: 20))

        // Turning the condition into an action keeps only connections on ports it still has.
        let updated = try WorkflowGraphEditing.update(check, title: "Record", kind: action("test.record"), in: graph)
        #expect(updated.node(check)?.title == "Record")
        #expect(updated.outgoingEdges(from: check).isEmpty)
        #expect(throws: WorkflowGraphEditError.self) { try WorkflowGraphEditing.update(builder.trigger, title: "x", kind: .end, in: graph) }
        #expect(throws: WorkflowGraphEditError.self) { try WorkflowGraphEditing.update(yes, title: "x", kind: .trigger, in: graph) }
    }

    @Test("edit errors are presentable")
    func presentation() {
        #expect(WorkflowGraphEditError.wouldCreateCycle.presentation.message == "That connection would make the workflow loop.")
    }
}
