import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenPlatform

/// Settings, opened as a sheet from anywhere.
struct SettingsView: View {
    let services: LumenServices
    let model: AppModel
    let initialSection: AppDestination.SettingsSection
    @State private var settings: SettingsViewModel
    @State private var path: [AppDestination.SettingsSection] = []
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, model: AppModel, initialSection: AppDestination.SettingsSection) {
        self.services = services
        self.model = model
        self.initialSection = initialSection
        _settings = State(initialValue: SettingsViewModel(services: services))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
    }

    private var content: some View {
        List {
            Section {
                TextField("Your name", text: $settings.displayName)
                    .onSubmit { Task { await settings.saveDisplayName() } }
            } header: {
                Text("Profile")
            } footer: {
                Text("Used for the greeting on Home.")
            }
            Section {
                link(.assistant, "Assistant", "sparkles")
                link(.notifications, "Notifications", "bell")
                CalendarAccessRow()
                link(.sync, "Sync", "arrow.triangle.2.circlepath")
                link(.plugins, "Plugins", "puzzlepiece.extension")
                link(.privacy, "Privacy", "hand.raised")
                link(.diagnostics, "Diagnostics", "stethoscope")
            }
            Section {
                LabeledContent("Version", value: "\(services.configuration.appVersion) (\(services.configuration.buildNumber))")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AppDestination.SettingsSection.self) { section in
            SettingsSectionView(section: section, services: services, settings: settings)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task { await settings.saveDisplayName() }
                    dismiss()
                }
            }
        }
        .task {
            await settings.load()
            if initialSection != .general { path = [initialSection] }
        }
    }

    private func link(_ section: AppDestination.SettingsSection, _ title: String, _ symbol: String) -> some View {
        NavigationLink(value: section) {
            Label { Text(title) } icon: { IconBadge(symbol) }
        }
    }
}

/// Connects the system calendar.
private struct CalendarAccessRow: View {
    @State private var access: EventKitCalendarSource.Access = .notDetermined

    var body: some View {
        HStack {
            Label { Text("Calendars") } icon: { IconBadge("calendar") }
            Spacer()
            switch access {
            case .granted:
                Text("Connected").foregroundStyle(LumenColor.textSecondary)
            case .denied:
                Text("Off in Settings").foregroundStyle(LumenColor.textSecondary)
            case .notDetermined:
                Button("Connect") {
                    Task {
                        _ = try? await LivePlatform.calendarSource.requestAccess()
                        access = await LivePlatform.calendarSource.access()
                    }
                }
                .buttonStyle(.lumenQuiet)
            }
        }
        .task { access = await LivePlatform.calendarSource.access() }
    }
}

private struct SettingsSectionView: View {
    let section: AppDestination.SettingsSection
    let services: LumenServices
    let settings: SettingsViewModel

    var body: some View {
        switch section {
        case .general, .assistant: AssistantSetupView(services: services)
        case .notifications: NotificationSettingsView(services: services)
        case .sync: SyncSettingsView(settings: settings)
        case .plugins: PluginsSettingsView(settings: settings)
        case .privacy: PrivacySettingsView(services: services)
        case .diagnostics: DiagnosticsView(settings: settings)
        }
    }
}
