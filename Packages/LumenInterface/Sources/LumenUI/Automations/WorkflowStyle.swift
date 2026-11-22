import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenAutomation

/// Symbols and colors for workflow steps, branches and runs, shared by the step list, the canvas
/// and run history.
enum WorkflowStyle {
    static func symbol(_ kind: WorkflowStepKind) -> String {
        switch kind {
        case .trigger: return "bolt"
        case .action: return "gearshape"
        case .condition: return "arrow.triangle.branch"
        case .delay: return "hourglass"
        case .end: return "flag.checkered"
        case .removed: return "questionmark.square.dashed"
        }
    }

    static func symbol(for kind: WorkflowNode.Kind) -> String {
        symbol(WorkflowStepKind(kind))
    }

    static func tint(_ kind: WorkflowStepKind) -> Color {
        switch kind {
        case .trigger: return LumenColor.accent
        case .condition: return LumenColor.warning
        case .end: return LumenColor.success
        case .action, .delay, .removed: return LumenColor.textSecondary
        }
    }

    static func tint(for kind: WorkflowNode.Kind) -> Color {
        tint(WorkflowStepKind(kind))
    }

    /// What a kind of step is called, for VoiceOver.
    static func kindName(_ kind: WorkflowNode.Kind) -> String {
        switch kind {
        case .trigger: return "Trigger"
        case .action: return "Action"
        case .condition: return "Condition"
        case .delay: return "Wait"
        case .end: return "End"
        }
    }

    static func tint(for port: EdgePort) -> Color {
        switch port {
        case .next: return LumenColor.accent
        case .whenTrue: return LumenColor.success
        case .whenFalse: return LumenColor.danger
        }
    }

    // MARK: Runs

    static func symbol(_ status: WorkflowRun.Status) -> String {
        switch status {
        case .running: return "play.circle"
        case .waiting: return "hourglass.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .interrupted: return "pause.circle"
        }
    }

    static func tint(_ status: WorkflowRun.Status) -> Color {
        switch status {
        case .running, .waiting: return LumenColor.accent
        case .succeeded: return LumenColor.success
        case .failed: return LumenColor.danger
        case .cancelled, .interrupted: return LumenColor.textTertiary
        }
    }

    static func title(_ status: WorkflowRun.Status) -> String {
        switch status {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        }
    }

    static func symbol(_ status: RunStep.Status) -> String {
        switch status {
        case .running: return "play.circle"
        case .waiting: return "hourglass.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .interrupted: return "pause.circle"
        }
    }

    static func tint(_ status: RunStep.Status) -> Color {
        switch status {
        case .running, .waiting: return LumenColor.accent
        case .succeeded: return LumenColor.success
        case .failed: return LumenColor.danger
        case .cancelled, .interrupted: return LumenColor.textTertiary
        }
    }

    static func title(_ status: RunStep.Status) -> String {
        switch status {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        }
    }

    /// `1.2 s`, `3 min 5 s`.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// One run in a list: status, when it started and how long it took.
struct RunSummaryRow: View {
    let run: WorkflowRun
    var workflowName: String?

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            Image(systemName: WorkflowStyle.symbol(run.status))
                .foregroundStyle(WorkflowStyle.tint(run.status))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflowName ?? WorkflowStyle.title(run.status)).lumenText(.body)
                Text(detail).lumenText(.caption).foregroundStyle(LumenColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if workflowName != nil { parts.append(WorkflowStyle.title(run.status)) }
        parts.append(run.startedAt.formatted(.relative(presentation: .named)))
        if let finished = run.finishedAt {
            parts.append(WorkflowStyle.duration(max(0, finished.timeIntervalSince(run.startedAt))))
        }
        return parts.joined(separator: " · ")
    }
}
