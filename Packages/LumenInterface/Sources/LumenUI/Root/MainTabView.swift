import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// The root sections; sheets are shared.
///
/// iPhone, and iPad at compact width, show five tabs, each a navigation stack. iPad at regular
/// width shows a sidebar instead: Plan's lists, Projects, Calendar and Automations, the Library's
/// collections and Insights are items of their own, and list/detail screens sit side by side. The
/// router holds every section's place, so moving between the two (Split View, Stage Manager)
/// keeps it.
struct MainTabView: View {
    let services: LumenServices
    @Bindable var model: AppModel
    @Namespace private var zoom
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sidebar: SidebarViewModel

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _sidebar = State(initialValue: SidebarViewModel(services: services, router: model.router))
    }

    var body: some View {
        @Bindable var router = model.router
        // The tabs follow the router's layout, which changes together with the selection and paths.
        let inSidebar = router.layout == .sidebar
        TabView(selection: Binding(get: { router.selection }, set: { router.select(section: $0) })) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbolName, value: NavigationSection.home) {
                stack(.home) { HomeView(services: services, model: model, zoom: zoom) }
            }
            Tab(AppTab.plan.title, systemImage: AppTab.plan.symbolName, value: NavigationSection.plan) {
                stack(.plan) { PlanView(services: services, model: model) }
            }
            .hidden(inSidebar)
            TabSection(AppTab.plan.title) {
                ForEach(NavigationSection.planSections) { section in
                    Tab(section.title, systemImage: section.symbolName, value: section) {
                        planContent(section)
                    }
                    .badge(sidebar.badge(for: section) ?? 0)
                    // With the sidebar collapsed into iPad's tab bar, Today stands in for Plan.
                    .defaultVisibility(section == .tasks(.today) ? .automatic : .hidden, for: .tabBar)
                }
            }
            .hidden(!inSidebar)
            Tab(AppTab.library.title, systemImage: AppTab.library.symbolName, value: NavigationSection.library) {
                libraryContent
            }
            TabSection("Collections") {
                ForEach(sidebar.collections) { item in
                    Tab(item.name, systemImage: item.symbolName, value: item.section) {
                        collectionContent(item)
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
            .hidden(!inSidebar || sidebar.collections.isEmpty)
            Tab(AppTab.assistant.title, systemImage: AppTab.assistant.symbolName, value: NavigationSection.assistant) {
                assistantContent
            }
            Tab(NavigationSection.insights.title, systemImage: NavigationSection.insights.symbolName, value: NavigationSection.insights) {
                stack(.insights) { InsightsView(services: services) }
            }
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(!inSidebar)
            Tab(value: NavigationSection.search, role: .search) {
                stack(.search) { SearchView(services: services, model: model) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            Button {
                model.perform(.settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, LumenSpace.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(LumenColor.textPrimary)
            .hoverEffect(.highlight)
            .accessibilityHint("Opens Settings")
        }
        .sheet(item: $router.sheet) { route in
            SheetView(route: route, services: services, model: model)
        }
        .onChange(of: usesSidebar, initial: true) { _, usesSidebar in
            router.setLayout(usesSidebar ? .sidebar : .tabBar)
        }
        .task(id: inSidebar) {
            // Collections and counts are shown only by the sidebar.
            if inSidebar { await sidebar.start() }
        }
    }

    /// The sidebar is for iPad with room for it. iPhone keeps its tab bar in every orientation,
    /// including the regular width of the largest iPhones in landscape.
    private var usesSidebar: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        return false
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func planContent(_ section: NavigationSection) -> some View {
        switch section {
        case .tasks(.projects):
            split(section, placeholder: .project) { ProjectsView(services: services, model: model, selection: $0) }
        case .tasks(let kind):
            split(section, placeholder: .task) { TaskListView(source: .smart(SmartList(kind)), services: services, model: model, selection: $0) }
        case .automations:
            split(section, placeholder: .automation) { AutomationsView(services: services, model: model, selection: $0) }
        case .calendar:
            stack(section) { CalendarView(services: services, model: model) }
        default:
            // `NavigationSection.planSections` holds only the cases above.
            EmptyView()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if model.router.layout == .sidebar {
            split(.library, placeholder: .note) { LibraryView(services: services, model: model, selection: $0) }
        } else {
            stack(.library) { LibraryView(services: services, model: model) }
        }
    }

    private func collectionContent(_ item: SidebarViewModel.CollectionItem) -> some View {
        split(item.section, placeholder: .note) {
            LibraryView(
                services: services,
                model: model,
                initialFilter: .collection(item.id),
                scope: .collection(item.id, name: item.name),
                selection: $0
            )
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        if model.router.layout == .sidebar {
            split(.assistant, placeholder: .conversation) { AssistantView(services: services, model: model, selection: $0) }
        } else {
            stack(.assistant) { AssistantView(services: services, model: model) }
        }
    }

    /// A section shown as one navigation stack.
    private func stack<Root: View>(_ section: NavigationSection, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: path(section)) {
            root().destinations(services: services, model: model, zoom: zoom)
        }
    }

    /// A section shown as its list beside the selected item.
    private func split<Primary: View>(
        _ section: NavigationSection,
        placeholder: DetailPlaceholder,
        @ViewBuilder primary: @escaping (Binding<AppDestination?>) -> Primary
    ) -> some View {
        SplitSectionView(section: section, services: services, model: model, zoom: zoom, placeholder: placeholder, primary: primary)
    }

    private func path(_ section: NavigationSection) -> Binding<[AppDestination]> {
        @Bindable var router = model.router
        switch section {
        case .home: return $router.homePath
        case .plan: return $router.planPath
        case .library: return $router.libraryPath
        case .assistant: return $router.assistantPath
        case .search: return $router.searchPath
        case .tasks, .calendar, .automations, .collection, .insights:
            return Binding(get: { router.path(for: section) }, set: { router.setPath($0, for: section) })
        }
    }
}

extension View {
    /// Resolves pushed destinations for any section's stack.
    func destinations(services: LumenServices, model: AppModel, zoom: Namespace.ID) -> some View {
        navigationDestination(for: AppDestination.self) { destination in
            DestinationView(destination: destination, services: services, model: model)
                .navigationTransition(.zoom(sourceID: destination, in: zoom))
        }
    }
}
