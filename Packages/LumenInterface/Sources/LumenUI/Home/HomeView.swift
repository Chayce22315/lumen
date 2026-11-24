import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Home: greeting and the user's widgets, in their chosen order.
struct HomeView: View {
    let services: LumenServices
    let model: AppModel
    let zoom: Namespace.ID
    @State private var home: HomeViewModel
    @State private var scrollOffset: CGFloat = 0
    @State private var isEditing = false
    @State private var activeFocus: ActiveFocusViewModel
    @State private var isStartingFocus = false

    init(services: LumenServices, model: AppModel, zoom: Namespace.ID) {
        self.services = services
        self.model = model
        self.zoom = zoom
        _home = State(initialValue: HomeViewModel(services: services))
        _activeFocus = State(initialValue: ActiveFocusViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumenSpace.xl) {
                header
                ActiveFocusCard(active: activeFocus, model: model)
                switch home.state {
                case .idle, .loading:
                    SkeletonRows(count: 5).padding(.top, LumenSpace.l)
                case .failed(let error):
                    StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle", actionTitle: "Try again") {
                        Task { await home.load() }
                    }
                case .loaded(let snapshot):
                    ForEach(Array(home.visibleWidgets.enumerated()), id: \.element.id) { index, item in
                        HomeWidgetView(item: item, snapshot: snapshot, home: home, services: services, model: model, zoom: zoom)
                            .staggeredAppearance(index: index)
                    }
                    layoutButton
                }
            }
            .padding(.horizontal, LumenSpace.screen)
            .padding(.bottom, LumenSpace.xxl)
            .frame(maxWidth: LumenLayout.readableWidth * 1.4)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrollOffset = offset
        }
        .lumenScreenBackground()
        .refreshable { await home.load() }
        .toolbar { toolbar }
        .navigationBarTitleDisplayMode(.inline)
        .task { await home.start() }
        .task { await activeFocus.start() }
        .sheet(isPresented: $isEditing) {
            NavigationStack { LayoutEditorView(home: home) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isStartingFocus) {
            FocusSetupView(taskID: nil, services: services) { session in
                model.router.open(.entity(session.reference))
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let greeting = home.state.value?.greeting {
            VStack(alignment: .leading, spacing: LumenSpace.xs) {
                Text(greeting.title)
                    .lumenText(.display)
                    .foregroundStyle(LumenColor.textPrimary)
                Text(greeting.subtitle)
                    .lumenText(.callout)
                    .foregroundStyle(LumenColor.textSecondary)
            }
            .padding(.top, LumenSpace.l)
            .parallax(offset: scrollOffset)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var layoutButton: some View {
        Button("Customize Home") { isEditing = true }
            .buttonStyle(.lumenQuiet)
            .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.router.open(.notifications)
            } label: {
                Image(systemName: "bell")
            }
            .accessibilityLabel("Notifications")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.router.open(.settings(.general))
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            Button {
                if let session = activeFocus.session {
                    model.router.open(.entity(session.reference))
                } else {
                    isStartingFocus = true
                }
            } label: {
                Image(systemName: "timer")
            }
            .accessibilityLabel(activeFocus.session == nil ? "Start focus" : "Open focus timer")
            Button {
                model.router.open(.capture(text: nil))
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New task")
        }
    }
}

/// Reorder, show/hide and resize Home widgets.
struct LayoutEditorView: View {
    let home: HomeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(home.layout.normalized.items) { item in
                    HStack(spacing: LumenSpace.m) {
                        IconBadge(item.kind.symbolName, tint: item.isVisible ? LumenColor.accent : LumenColor.textTertiary)
                        Text(item.kind.title).lumenText(.body)
                        Spacer()
                        Toggle(item.kind.title, isOn: Binding(
                            get: { item.isVisible },
                            set: { home.setVisible($0, for: item.kind) }
                        ))
                        .labelsHidden()
                    }
                }
                .onMove { home.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Drag to reorder. Hidden widgets keep their place.")
            }
            Section {
                Button("Restore default layout", role: .destructive) { home.resetLayout() }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customize Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
