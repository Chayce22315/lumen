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
        .commands {
            // ⌘N and ⌘⇧N create in Lumen rather than opening another window.
            CommandGroup(replacing: .newItem) {
                commandButton(.quickCapture)
                commandButton(.newNote)
            }
            CommandGroup(replacing: .appSettings) {
                commandButton(.settings)
            }
            CommandMenu("Go") {
                commandButton(.commandPalette)
                commandButton(.find)
                Divider()
                ForEach(AppTab.allCases) { tab in
                    commandButton(.showSection(tab))
                }
            }
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

    /// A menu item for a command, with its shortcut: listed in the menu bar and in iPad's ⌘-hold
    /// overlay, and performed through the app model so it is tested with the router.
    @MainActor
    private func commandButton(_ command: AppCommand) -> some View {
        Button(command.title) { model.perform(command) }
            .keyboardShortcut(KeyEquivalent(command.shortcut.key), modifiers: EventModifiers(command.shortcut.modifiers))
    }
}

private extension EventModifiers {
    init(_ modifiers: Set<CommandShortcut.Modifier>) {
        self = []
        for modifier in modifiers {
            switch modifier {
            case .command: insert(.command)
            case .shift: insert(.shift)
            case .option: insert(.option)
            case .control: insert(.control)
            }
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
