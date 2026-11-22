import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Plan: the task lists, projects and calendar.
struct PlanView: View {
    let services: LumenServices
    let model: AppModel
    @State private var summary: TaskSummary?
    @State private var counts: [SmartList: Int] = [:]

    private let lists: [(AppDestination.TaskListKind, SmartList, String)] = [
        (.today, .today, "sun.max"),
        (.upcoming, .upcoming, "calendar.day.timeline.left"),
        (.overdue, .overdue, "clock.badge.exclamationmark"),
        (.inbox, .inbox, "tray"),
        (.anytime, .anytime, "square.grid.2x2"),
        (.completed, .completed, "checkmark.circle"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(lists, id: \.0) { kind, list, symbol in
                    NavigationLink(value: AppDestination.tasks(kind)) {
                        HStack(spacing: LumenSpace.m) {
                            IconBadge(symbol, tint: kind == .overdue && (counts[list] ?? 0) > 0 ? LumenColor.danger : LumenColor.accent)
                            Text(list.title).lumenText(.body)
                            Spacer()
                            if let count = counts[list], count > 0, list != .completed {
                                Text("\(count)").lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: AppDestination.tasks(.projects)) {
                    Label { Text("Projects").lumenText(.body) } icon: { IconBadge("square.stack.3d.up") }
                }
                NavigationLink(value: AppDestination.calendar) {
                    Label { Text("Calendar").lumenText(.body) } icon: { IconBadge("calendar") }
                }
                NavigationLink(value: AppDestination.automations) {
                    Label { Text("Automations").lumenText(.body) } icon: { IconBadge("point.3.connected.trianglepath.dotted") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle("Plan")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.router.open(.capture(text: nil)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New task")
            }
        }
        .task { await loadCounts() }
        .refreshable { await loadCounts() }
    }

    private func loadCounts() async {
        var result: [SmartList: Int] = [:]
        for (_, list, _) in lists where list != .completed {
            result[list] = (try? await services.organization.tasks.list(list).count) ?? 0
        }
        counts = result
    }
}
