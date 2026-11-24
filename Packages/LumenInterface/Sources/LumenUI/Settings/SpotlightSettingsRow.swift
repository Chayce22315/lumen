import SwiftUI
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// "Show in Spotlight": open tasks and notes in system search (title and a short snippet, on
/// this device only). Hidden where the device has no system search index.
struct SpotlightSettingsRow: View {
    @State private var spotlight: SpotlightSettingsViewModel

    init(services: LumenServices) {
        _spotlight = State(initialValue: SpotlightSettingsViewModel(services: services))
    }

    var body: some View {
        if spotlight.isAvailable {
            Toggle(isOn: Binding(
                get: { spotlight.isEnabled },
                set: { enabled in Task { await spotlight.setEnabled(enabled) } }
            )) {
                Label { Text("Show in Spotlight") } icon: { IconBadge("magnifyingglass") }
            }
            .disabled(spotlight.isUpdating)
            .accessibilityHint("Lists open tasks and notes in system search on this device")
            .task { await spotlight.load() }
        }
    }
}
