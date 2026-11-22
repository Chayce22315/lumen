import SwiftUI
import LumenUI
import LumenPresentation
import LumenPlatform

@main
struct LumenApp: App {
    @State private var model = AppModel(makeServices: { try await SharedServices.shared.services() })

    var body: some Scene {
        WindowGroup {
            LumenRootView(model: model)
        }
    }
}
