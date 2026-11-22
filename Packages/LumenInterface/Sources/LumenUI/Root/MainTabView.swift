import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// Five sections, each with its own navigation stack; sheets are shared.
struct MainTabView: View {
    let services: LumenServices
    @Bindable var model: AppModel
    @Namespace private var zoom

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbolName, value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView(services: services, model: model, zoom: zoom)
                        .destinations(services: services, model: model, zoom: zoom)
                }
            }
            Tab(AppTab.plan.title, systemImage: AppTab.plan.symbolName, value: AppTab.plan) {
                NavigationStack(path: $router.planPath) {
                    PlanView(services: services, model: model)
                        .destinations(services: services, model: model, zoom: zoom)
                }
            }
            Tab(AppTab.library.title, systemImage: AppTab.library.symbolName, value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView(services: services, model: model)
                        .destinations(services: services, model: model, zoom: zoom)
                }
            }
            Tab(AppTab.assistant.title, systemImage: AppTab.assistant.symbolName, value: AppTab.assistant) {
                NavigationStack(path: $router.assistantPath) {
                    AssistantView(services: services, model: model)
                        .destinations(services: services, model: model, zoom: zoom)
                }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView(services: services, model: model)
                        .destinations(services: services, model: model, zoom: zoom)
                }
            }
        }
        .sheet(item: $router.sheet) { route in
            SheetView(route: route, services: services, model: model)
        }
    }
}

extension View {
    /// Resolves pushed destinations for any tab's stack.
    func destinations(services: LumenServices, model: AppModel, zoom: Namespace.ID) -> some View {
        navigationDestination(for: AppDestination.self) { destination in
            DestinationView(destination: destination, services: services, model: model)
                .navigationTransition(.zoom(sourceID: destination, in: zoom))
        }
    }
}
