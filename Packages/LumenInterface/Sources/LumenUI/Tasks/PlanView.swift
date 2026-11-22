import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Plan: the task lists, projects and calendar.
struct PlanView: View {
    let model: AppModel
    @State private var plan: PlanViewModel

    init(services: LumenServices, model: AppModel) {
        self.model = model
        _plan = State(initialValue: PlanViewModel(services: services))
    }

    var body: some View {
        List {
            Section {
                ForEach(PlanViewModel.lists) { list in
                    let kind = Self.destination(for: list)
                    NavigationLink(value: AppDestination.tasks(kind)) {
                        HStack(spacing: LumenSpace.m) {
                            IconBadge(Self.symbol(for: list), tint: plan.isAlerting(list) ? LumenColor.danger : LumenColor.accent)
                            Text(list.title).lumenText(.body)
                            Spacer()
                            if let count = plan.badge(for: list) {
                                Text("\(count)")
                                    .lumenText(.subheadline)
                                    .foregroundStyle(LumenColor.textSecondary)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }
                        .lumenAnimation(.lumenSnappy, value: plan.badge(for: list))
                    }
                    .accessibilityIdentifier("plan.list.\(kind.rawValue)")
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
        .task { await plan.start() }
        .refreshable { await plan.load() }
    }

    private static func destination(for list: SmartList) -> AppDestination.TaskListKind {
        switch list {
        case .today: return .today
        case .upcoming: return .upcoming
        case .overdue: return .overdue
        case .inbox: return .inbox
        case .anytime: return .anytime
        case .completed: return .completed
        }
    }

    private static func symbol(for list: SmartList) -> String {
        switch list {
        case .today: return "sun.max"
        case .upcoming: return "calendar.day.timeline.left"
        case .overdue: return "clock.badge.exclamationmark"
        case .inbox: return "tray"
        case .anytime: return "square.grid.2x2"
        case .completed: return "checkmark.circle"
        }
    }
}
