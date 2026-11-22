import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenAutomation

/// The workflow as an editable diagram.
///
/// - Touch and hold a step, then drag, to move it (it snaps to a grid when dropped).
/// - Drag from a step's output dot to another step to connect them; dragging from a used output
///   points it somewhere else.
/// - Tap a connection to remove it; tap a step to edit it.
///
/// Geometry and hit-testing come from `WorkflowCanvasGeometry`, so what is drawn is what is hit.
/// Every change goes through `WorkflowEditorViewModel`, which refuses invalid structure with a
/// message shown as a banner. Each step also carries its menu (context menu and accessibility
/// actions), so nothing here requires dragging.
struct WorkflowCanvasEditor: View {
    let editor: WorkflowEditorViewModel
    @State private var nodeDrag: NodeDrag?
    @State private var wire: Wire?
    @State private var edgeToRemove: WorkflowEdge?
    @State private var inspecting: InspectedStep?
    @Environment(\.dismiss) private var dismiss

    private static let space = "workflowCanvas"

    struct NodeDrag: Equatable {
        let node: WorkflowNode.ID
        var translation: CGSize
    }

    struct Wire: Equatable {
        let node: WorkflowNode.ID
        let port: EdgePort
        let start: CGPoint
        var point: CGPoint
    }

    var body: some View {
        let geometry = WorkflowCanvasGeometry(graph: editor.graph)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                connections(geometry)
                ForEach(editor.graph.nodes) { node in
                    if let center = geometry.center(of: node.id) {
                        CanvasNodeView(
                            node: node,
                            summary: editor.summary(of: node.id),
                            issueCount: editor.issues(for: node.id).count,
                            isLifted: nodeDrag?.node == node.id
                        )
                        .frame(width: WorkflowCanvasGeometry.nodeSize.width, height: WorkflowCanvasGeometry.nodeSize.height)
                        .position(offset(center, for: node.id))
                        .onTapGesture { if !node.kind.isTrigger { inspecting = InspectedStep(id: node.id) } }
                        .gesture(moveGesture(for: node.id, geometry: geometry))
                        .contextMenu { StepMenuItems(node: node, editor: editor, inspect: inspect) }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(WorkflowStyle.kindName(node.kind)): \(node.title)")
                        .accessibilityValue(accessibilityValue(for: node))
                        .accessibilityActions { accessibilityActions(for: node) }
                        ForEach(node.kind.outputPorts, id: \.self) { port in
                            if let point = geometry.outputPoint(of: node.id, port: port) {
                                PortHandle(port: port, isConnected: editor.graph.successor(of: node.id, port: port) != nil)
                                    .position(offset(point, for: node.id))
                                    .highPriorityGesture(wireGesture(from: node.id, port: port, start: point, geometry: geometry))
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
            .coordinateSpace(.named(Self.space))
            .lumenAnimation(.lumenSnappy, value: editor.graph)
        }
        .scrollDisabled(nodeDrag != nil || wire != nil)
        .lumenScreenBackground()
        .overlay(alignment: .top) {
            if let rejection = editor.rejection {
                Banner(title: rejection.title, message: rejection.message, tint: LumenColor.warning) {
                    editor.dismissRejection()
                }
                .padding(.horizontal, LumenSpace.l)
                .padding(.top, LumenSpace.s)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .lumenAnimation(.lumenSmooth, value: editor.rejection)
        .navigationTitle("Diagram")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo)
                Spacer()
                Button { editor.arrange() } label: { Label("Arrange", systemImage: "rectangle.3.group") }
                Spacer()
                Menu {
                    NewStepButtons(actions: editor.actions) { step in
                        if let id = editor.append(step), step != .end { inspecting = InspectedStep(id: id) }
                    }
                } label: {
                    Label("Add step", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(get: { edgeToRemove != nil }, set: { if !$0 { edgeToRemove = nil } }),
            titleVisibility: .visible,
            presenting: edgeToRemove
        ) { edge in
            Button("Remove connection", role: .destructive) { editor.disconnect(edge) }
        } message: { edge in
            Text("From “\(title(of: edge.from))” to “\(title(of: edge.to))”.")
        }
        .sheet(item: $inspecting) { step in
            NavigationStack { WorkflowNodeInspector(editor: editor, nodeID: step.id) }
        }
    }

    // MARK: Drawing

    private func connections(_ geometry: WorkflowCanvasGeometry) -> some View {
        Canvas { context, _ in
            for edge in editor.graph.edges {
                guard let curve = liveCurve(for: edge, geometry: geometry) else { continue }
                let path = Path { path in
                    path.move(to: curve.start)
                    path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
                }
                let isSelected = edge == edgeToRemove
                context.stroke(
                    path,
                    with: .color(isSelected ? LumenColor.accent : WorkflowStyle.tint(for: edge.port).opacity(edge.port == .next ? 0.55 : 0.8)),
                    lineWidth: isSelected ? 3 : 1.5
                )
                if edge.port != .next {
                    let label = Text(edge.port == .whenTrue ? "true" : "false")
                        .font(.caption2)
                        .foregroundStyle(WorkflowStyle.tint(for: edge.port))
                    context.draw(label, at: CGPoint(x: curve.start.x, y: curve.start.y + 16))
                }
            }
            if let wire {
                let curve = WorkflowCanvasGeometry.curve(from: wire.start, to: wire.point)
                let path = Path { path in
                    path.move(to: curve.start)
                    path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
                }
                context.stroke(path, with: .color(LumenColor.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
            }
        }
        .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .named(Self.space))
                .onEnded { value in edgeToRemove = geometry.edge(at: value.location) }
        )
        .accessibilityHidden(true)
    }

    /// An edge's curve, following a step while it is dragged.
    private func liveCurve(for edge: WorkflowEdge, geometry: WorkflowCanvasGeometry) -> CanvasCurve? {
        guard let start = geometry.outputPoint(of: edge.from, port: edge.port), let end = geometry.inputPoint(of: edge.to) else { return nil }
        return WorkflowCanvasGeometry.curve(from: offset(start, for: edge.from), to: offset(end, for: edge.to))
    }

    private func offset(_ point: CGPoint, for node: WorkflowNode.ID) -> CGPoint {
        guard let nodeDrag, nodeDrag.node == node else { return point }
        return CGPoint(x: point.x + nodeDrag.translation.width, y: point.y + nodeDrag.translation.height)
    }

    // MARK: Gestures

    /// Touch and hold, then drag. Holding first leaves plain drags to scrolling.
    private func moveGesture(for id: WorkflowNode.ID, geometry: WorkflowCanvasGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    nodeDrag = NodeDrag(node: id, translation: drag?.translation ?? .zero)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value,
                   let position = geometry.droppedPosition(of: id, translation: drag.translation) {
                    editor.move(id, to: position)
                }
                nodeDrag = nil
            }
    }

    private func wireGesture(from id: WorkflowNode.ID, port: EdgePort, start: CGPoint, geometry: WorkflowCanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                wire = Wire(node: id, port: port, start: start, point: value.location)
            }
            .onEnded { value in
                wire = nil
                guard let target = geometry.dropTarget(at: value.location, from: id) else { return }
                if editor.graph.successor(of: id, port: port) != nil {
                    editor.reconnect(id, port: port, to: target)
                } else {
                    editor.connect(id, port: port, to: target)
                }
            }
    }

    // MARK: Accessibility

    private func accessibilityValue(for node: WorkflowNode) -> String {
        var parts = [editor.summary(of: node.id)]
        for port in node.kind.outputPorts {
            let target = editor.graph.successor(of: node.id, port: port).map { title(of: $0) } ?? "nothing"
            parts.append("\(WorkflowEditorViewModel.title(for: port)): \(target)")
        }
        let issues = editor.issues(for: node.id)
        if !issues.isEmpty {
            parts.append(issues.map(\.message).joined(separator: " "))
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private func accessibilityActions(for node: WorkflowNode) -> some View {
        if !node.kind.isTrigger {
            Button("Edit step") { inspect(node.id) }
        }
        ForEach(node.kind.outputPorts, id: \.self) { port in
            let portTitle = WorkflowEditorViewModel.title(for: port)
            if let target = editor.graph.successor(of: node.id, port: port) {
                Button("Disconnect \(portTitle) from \(title(of: target))") { editor.disconnect(node.id, port: port) }
            } else {
                ForEach(editor.connectionTargets(from: node.id, port: port)) { target in
                    Button("Connect \(portTitle) to \(target.title)") { editor.connect(node.id, port: port, to: target.id) }
                }
            }
        }
        if !node.kind.isTrigger {
            Button("Delete step") { editor.remove(node.id) }
        }
    }

    private func inspect(_ id: WorkflowNode.ID) {
        inspecting = InspectedStep(id: id)
    }

    private func title(of id: WorkflowNode.ID) -> String {
        guard let node = editor.node(id) else { return "a removed step" }
        return node.title.isEmpty ? WorkflowStyle.kindName(node.kind) : node.title
    }
}

/// A step on the canvas.
private struct CanvasNodeView: View {
    let node: WorkflowNode
    let summary: String
    let issueCount: Int
    let isLifted: Bool

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            IconBadge(WorkflowStyle.symbol(for: node.kind), tint: WorkflowStyle.tint(for: node.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title.isEmpty ? WorkflowStyle.kindName(node.kind) : node.title)
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textPrimary)
                    .lineLimit(1)
                Text(summary)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if issueCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LumenColor.danger)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, LumenSpace.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumenColor.surfaceElevated, in: RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous)
                .strokeBorder(issueCount > 0 ? LumenColor.danger.opacity(0.6) : (isLifted ? LumenColor.accent : LumenColor.separator), lineWidth: isLifted ? 2 : LumenLayout.hairline)
        )
        .shadow(color: .black.opacity(isLifted ? 0.3 : 0), radius: isLifted ? 12 : 0, y: isLifted ? 6 : 0)
        .scaleEffect(isLifted ? 1.03 : 1)
        .contentShape(RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous))
    }
}

/// An output dot: filled when connected. The hit area is a full 44 pt.
private struct PortHandle: View {
    let port: EdgePort
    let isConnected: Bool

    var body: some View {
        Circle()
            .fill(isConnected ? WorkflowStyle.tint(for: port) : LumenColor.surfaceElevated)
            .overlay(Circle().strokeBorder(WorkflowStyle.tint(for: port), lineWidth: 2))
            .frame(width: 14, height: 14)
            .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
            .contentShape(Circle())
            .accessibilityHidden(true)
    }
}
