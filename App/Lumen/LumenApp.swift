import SwiftUI
import LumenUI
import LumenPresentation
import LumenApplication
import LumenPlatform

@main
struct LumenApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel(makeServices: makeSharedServices))
    }

    var body: some Scene {
        WindowGroup {
            LumenRootView(model: model)
        }
    }
}

/// The process-wide services, shared with App Intents. Nonisolated so the app model can call it
/// from any context.
@Sendable
private func makeSharedServices() async throws -> LumenServices {
    try await SharedServices.shared.services()
}
