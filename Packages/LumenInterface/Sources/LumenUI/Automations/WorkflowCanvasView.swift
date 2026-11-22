import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenAutomation

/// The workflow graph drawn as nodes and connecting edges at their canvas positions.
struct WorkflowCanvasView: View {
    let graph: WorkflowGraph
    private let nodeSize = CGSize(width: 220, height: 64)

    var body: some View {
        let layout = Layout(graph: graph, nodeSize: nodeSize)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = layout.center(of: edge.from), let to = layout.center(of: edge.to) else { continue }
                        var path = Path()
                        let start = CGPoint(x: from.x, y: from.y + nodeSize.height / 2)
                        let end = CGPoint(x: to.x, y: to.y - nodeSize.height / 2)
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + 30), control2: CGPoint(x: end.x, y: end.y - 30))
                        context.stroke(path, with: .color(LumenColor.border), lineWidth: 1.5)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(graph.nodes, id: \.id) { node in
                    NodeView(node: node)
                        .frame(width: nodeSize.width, height: nodeSize.height)
                        .position(layout.center(of: node.id) ?? .zero)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .padding(LumenSpace.xl)
        }
        .lumenScreenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow diagram with \(graph.nodes.count) steps")
    }

    /// Converts canvas positions to view coordinates with a margin.
    struct Layout {
        let centers: [WorkflowNode.ID: CGPoint]
        let size: CGSize

        init(graph: WorkflowGraph, nodeSize: CGSize) {
            let xs = graph.nodes.map { $0.position.x }
            let ys = graph.nodes.map { $0.position.y }
            let minX = xs.min() ?? 0
            let minY = ys.min() ?? 0
            var centers: [WorkflowNode.ID: CGPoint] = [:]
            for node in graph.nodes {
                centers[node.id] = CGPoint(x: node.position.x - minX + nodeSize.width / 2, y: node.position.y - minY + nodeSize.height / 2)
            }
            self.centers = centers
            self.size = CGSize(
                width: (xs.max() ?? 0) - minX + nodeSize.width,
                height: (ys.max() ?? 0) - minY + nodeSize.height
            )
        }

        func center(of id: WorkflowNode.ID) -> CGPoint? { centers[id] }
    }
}

private struct NodeView: View {
    let node: WorkflowNode

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            IconBadge(symbol, tint: tint)
            Text(node.title)
                .lumenText(.subheadline)
                .foregroundStyle(LumenColor.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LumenSpace.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumenColor.surfaceElevated, in: RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous).strokeBorder(LumenColor.separator, lineWidth: LumenLayout.hairline))
    }

    private var symbol: String {
        switch node.kind {
        case .trigger: return "bolt"
        case .action: return "gearshape"
        case .condition: return "arrow.triangle.branch"
        case .delay: return "hourglass"
        case .end: return "flag.checkered"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .trigger: return LumenColor.accent
        case .condition: return LumenColor.warning
        case .end: return LumenColor.success
        default: return LumenColor.textSecondary
        }
    }
}
