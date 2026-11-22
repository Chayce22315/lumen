import SwiftUI
import LumenUI
import LumenPresentation
import LumenApplication
import LumenPlatform

@main
struct LumenApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = State(initialValue: AppModel(makeServices: makeSharedServices, makeRuntime: makeSharedRuntime))
    }

    var body: some Scene {
        WindowGroup {
            LumenRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundRefresh.schedule()
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.run()
        }
    }
}

/// The process-wide services, shared with App Intents. Nonisolated so the app model can call it
/// from any context.
@Sendable
private func makeSharedServices() async throws -> LumenServices {
    try await SharedServices.shared.services()
}

/// The process-wide runtime, shared with background refresh so engines start once.
@Sendable
private func makeSharedRuntime(_ services: LumenServices) async throws -> LumenRuntime {
    try await SharedServices.shared.runtime()
}
