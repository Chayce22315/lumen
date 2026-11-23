import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// All projects with progress and health.
struct ProjectsView: View {
    let services: LumenServices
    let model: AppModel
    /// The project shown beside the list on iPad; `nil` where rows push onto a stack.
    let selection: Binding<AppDestination?>?
    @State private var projects: ProjectsViewModel
    @State private var isCreating = false

    init(services: LumenServices, model: AppModel, selection: Binding<AppDestination?>? = nil) {
        self.services = services
        self.model = model
        self.selection = selection
        _projects = State(initialValue: ProjectsViewModel(services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show completed", isOn: $projects.showsCompleted)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter projects")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isCreating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New project")
                }
            }
            .sheet(isPresented: $isCreating) {
                NavigationStack { ProjectCreationView(services: services, model: model) }
                    .presentationDetents([.medium])
            }
            .task { await projects.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch projects.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
        case .loaded(let rows) where rows.isEmpty:
            StateMessage("No projects", message: "A project groups tasks toward an outcome and shows how close you are.", symbolName: "square.stack.3d.up", actionTitle: "New project") {
                isCreating = true
            }
        case .loaded(let rows):
            SelectableList(selection: selection) {
                ForEach(rows) { row in
                    let destination = AppDestination.entity(row.project.reference)
                    NavigationLink(value: destination) {
                        HStack(spacing: LumenSpace.m) {
                            ProgressRing(fraction: row.progress.fractionComplete, tint: LumenColor.identity(row.project.color.rawValue))
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.project.name).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
                                Text(row.progressLabel).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                            }
                            Spacer()
                            HealthBadge(health: row.progress.health)
                        }
                        .padding(.vertical, LumenSpace.xs)
                    }
                    .selectableRow(destination, selection: selection, background: LumenColor.surface)
                    .contextMenu {
                        Button("Mark completed") { Task { await projects.setStatus(.completed, for: row.id) } }
                        Button("Put on hold") { Task { await projects.setStatus(.onHold, for: row.id) } }
                        Button("Archive") { Task { await projects.setStatus(.archived, for: row.id) } }
                        Button("Delete, keep tasks", role: .destructive) {
                            // The detail beside the list would show a deleted project.
                            if selection?.wrappedValue == destination { selection?.wrappedValue = nil }
                            Task { await projects.delete(row.id, deletingTasks: false) }
                        }
                    }
                }
            }
        }
    }
}

struct HealthBadge: View {
    let health: ProjectHealth

    var body: some View {
        switch health {
        case .onTrack, .closed:
            EmptyView()
        case .atRisk:
            Chip("At risk", symbolName: "exclamationmark.triangle", tint: LumenColor.warning)
        case .offTrack:
            Chip("Behind", symbolName: "exclamationmark.octagon", tint: LumenColor.danger)
        }
    }
}

/// A project's tasks under a progress header.
struct ProjectDetailView: View {
    let projectID: Project.ID
    let services: LumenServices
    let model: AppModel
    @State private var progress: ProjectProgress?

    var body: some View {
        TaskListView(source: .project(projectID), services: services, model: model)
            .safeAreaInset(edge: .top) {
                if let progress {
                    HStack(spacing: LumenSpace.m) {
                        ProgressRing(fraction: progress.fractionComplete).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int((progress.fractionComplete * 100).rounded()))% complete").lumenText(.headline)
                            if let days = progress.daysUntilTarget {
                                Text(days >= 0 ? "\(days) days to target" : "\(-days) days past target")
                                    .lumenText(.caption)
                                    .foregroundStyle(days >= 0 ? LumenColor.textSecondary : LumenColor.danger)
                            }
                        }
                        Spacer()
                        HealthBadge(health: progress.health)
                    }
                    .padding(.horizontal, LumenSpace.screen)
                    .padding(.vertical, LumenSpace.m)
                    .background(LumenColor.background)
                }
            }
            .task(id: projectID) {
                progress = try? await services.organization.projects.progress(of: projectID)
            }
    }
}

/// A compact form for a new project.
struct ProjectCreationView: View {
    let services: LumenServices
    let model: AppModel
    @State private var projects: ProjectsViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _projects = State(initialValue: ProjectsViewModel(services: services))
    }

    var body: some View {
        Form {
            TextField("Project name", text: $projects.newName)
            Picker("Color", selection: $projects.newColor) {
                ForEach(ProjectColor.allCases, id: \.self) { color in
                    Label(color.rawValue.capitalized, systemImage: "circle.fill")
                        .foregroundStyle(LumenColor.identity(color.rawValue))
                        .tag(color)
                }
            }
            Toggle("Target date", isOn: Binding(
                get: { projects.newTargetDate != nil },
                set: { projects.newTargetDate = $0 ? services.today.adding(days: 30) : nil }
            ))
            if let target = projects.newTargetDate {
                DatePicker("Target", selection: Binding(
                    get: { target.startDate(in: services.calendar) },
                    set: { projects.newTargetDate = CalendarDate($0, calendar: services.calendar) }
                ), displayedComponents: .date)
            }
            if let error = projects.error {
                Text(error.message).foregroundStyle(LumenColor.danger)
            }
        }
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task {
                        if let project = await projects.create() {
                            dismiss()
                            model.router.dismissSheet()
                            model.router.open(.entity(project.reference))
                        }
                    }
                }
                .disabled(!projects.canCreate)
            }
        }
    }
}
