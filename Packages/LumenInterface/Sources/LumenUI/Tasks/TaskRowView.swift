import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenOrganization

/// One task in a list.
struct TaskRowView: View {
    let row: TaskRowModel
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            CompletionToggle(
                isComplete: row.isDone,
                tint: row.projectColor.map { LumenColor.identity($0.rawValue) } ?? LumenColor.accent,
                label: row.isDone ? "Mark \(row.task.title) as not done" : "Complete \(row.task.title)",
                action: onToggle
            )
            .padding(.leading, -LumenSpace.s)
            VStack(alignment: .leading, spacing: LumenSpace.xs) {
                Text(row.task.title)
                    .lumenText(.body)
                    .foregroundStyle(row.isDone ? LumenColor.textTertiary : LumenColor.textPrimary)
                    .strikethrough(row.isDone, color: LumenColor.textTertiary)
                metadata
            }
            .padding(.vertical, LumenSpace.s + 2)
            Spacer(minLength: LumenSpace.s)
            if row.task.priority >= .high {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(row.task.priority == .urgent ? LumenColor.danger : LumenColor.warning)
                    .padding(.top, LumenSpace.m)
            }
        }
        .lumenAnimation(.lumenSnappy, value: row.isDone)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAction(named: row.isDone ? "Mark as not done" : "Complete", onToggle)
    }

    @ViewBuilder
    private var metadata: some View {
        let hasMetadata = row.dueLabel != nil || row.projectName != nil || row.isBlocked || row.subtaskSummary != nil || !row.task.tags.isEmpty
        if hasMetadata {
            HStack(spacing: LumenSpace.s) {
                if let due = row.dueLabel {
                    Label(due, systemImage: row.task.recurrence == nil ? "calendar" : "repeat")
                        .foregroundStyle(row.isOverdue ? LumenColor.danger : LumenColor.textSecondary)
                }
                if let project = row.projectName {
                    Text(project).foregroundStyle(row.projectColor.map { LumenColor.identity($0.rawValue) } ?? LumenColor.textSecondary)
                }
                if row.isBlocked {
                    Label("Waiting", systemImage: "hourglass").foregroundStyle(LumenColor.warning)
                }
                if let subtasks = row.subtaskSummary {
                    Label(subtasks, systemImage: "checklist").foregroundStyle(LumenColor.textSecondary)
                }
                ForEach(row.task.tags.prefix(2), id: \.self) { tag in
                    Text("#\(tag)").foregroundStyle(LumenColor.textTertiary)
                }
            }
            .lumenText(.caption)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
    }
}
