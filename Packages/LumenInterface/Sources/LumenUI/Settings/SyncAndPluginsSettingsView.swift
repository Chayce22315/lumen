import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenSync
import LumenPlugins

struct SyncSettingsView: View {
    let settings: SettingsViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: statusText)
                if let status = settings.syncStatus {
                    LabeledContent("Changes waiting", value: "\(status.pendingChanges)")
                    if let last = status.lastSuccess {
                        LabeledContent("Last synced") { Text(last, style: .relative) }
                    }
                }
                if settings.syncStatus?.state != .notConfigured {
                    Button("Sync now") { Task { await settings.syncNow() } }
                        .disabled(settings.isSyncing)
                }
            } footer: {
                Text(settings.syncStatus?.state == .notConfigured
                    ? "Everything is stored on this device. iCloud sync turns on in builds configured with an iCloud container. Lumen records every change, so nothing is lost when it does."
                    : "Changes made offline are kept and sent when you're back online.")
            }
            if !settings.conflicts.isEmpty {
                Section("Conflicts to review") {
                    ForEach(settings.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: LumenSpace.s) {
                            Text(conflict.fields.map(\.field).joined(separator: ", ")).lumenText(.headline)
                            Text("Two devices changed this at the same time. The newer change was kept.")
                                .lumenText(.caption)
                                .foregroundStyle(LumenColor.textSecondary)
                            HStack {
                                Button("Keep current") { Task { await settings.keep(conflict) } }
                                Button("Use the other version") { Task { await settings.restoreOtherVersion(conflict) } }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !settings.syncHistory.isEmpty {
                Section("History") {
                    ForEach(settings.syncHistory) { run in
                        HStack {
                            Text(run.startedAt, style: .relative)
                            Spacer()
                            Text("\(run.outcome.rawValue) · ↑\(run.pushed) ↓\(run.pulled)").foregroundStyle(LumenColor.textSecondary)
                        }
                        .lumenText(.caption)
                    }
                }
            }
        }
        .navigationTitle("Sync")
        .task { await settings.loadSync() }
    }

    private var statusText: String {
        guard let state = settings.syncStatus?.state else { return "…" }
        switch state {
        case .notConfigured: return "Not connected"
        case .idle: return "Up to date"
        case .syncing: return "Syncing"
        case .offline: return "Offline"
        case .failed(let error): return error.title
        }
    }
}

struct PluginsSettingsView: View {
    let settings: SettingsViewModel

    var body: some View {
        Form {
            ForEach(settings.plugins) { plugin in
                Section {
                    LabeledContent("Status", value: stateText(plugin.state))
                    ForEach(plugin.manifest.capabilities.sorted(), id: \.self) { capability in
                        if plugin.isBuiltIn {
                            Label(capability.title, systemImage: "checkmark").lumenText(.subheadline)
                        } else {
                            Toggle(capability.title, isOn: Binding(
                                get: { plugin.grantedCapabilities.contains(capability) },
                                set: { granted in
                                    Task {
                                        if granted { await settings.grant([capability], to: plugin.id) } else { await settings.revoke([capability], from: plugin.id) }
                                    }
                                }
                            ))
                            .tint(capability.risk == .high ? LumenColor.warning : LumenColor.accent)
                        }
                    }
                    if !plugin.isBuiltIn {
                        Toggle("Enabled", isOn: Binding(
                            get: { plugin.state != .disabled },
                            set: { value in Task { await settings.setEnabled(value, plugin: plugin.id) } }
                        ))
                    }
                } header: {
                    Text(plugin.manifest.name)
                } footer: {
                    Text("\(plugin.manifest.summary) Version \(plugin.manifest.version.description)\(plugin.isBuiltIn ? " · Built in" : "").")
                }
            }
        }
        .navigationTitle("Plugins")
    }

    private func stateText(_ state: PluginState) -> String {
        switch state {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .disabled: return "Off"
        case .needsPermission: return "Needs permission"
        case .failed(let message): return "Failed: \(message)"
        case .incompatible: return "Needs a newer Lumen"
        case .blocked: return "Not allowed in this build"
        }
    }
}

struct PrivacySettingsView: View {
    let services: LumenServices
    @State private var insights: InsightsViewModel
    @State private var confirmErase = false

    init(services: LumenServices) {
        self.services = services
        _insights = State(initialValue: InsightsViewModel(services: services))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Collect activity for insights", isOn: Binding(
                    get: { insights.isCollectionEnabled },
                    set: { value in Task { await insights.setCollectionEnabled(value) } }
                ))
                Button("Erase activity history", role: .destructive) { confirmErase = true }
            } footer: {
                Text("Activity stays on this device and is never sent anywhere. Erasing it resets insights and streaks.")
            }
        }
        .navigationTitle("Privacy")
        .task { await insights.load() }
        .confirmationDialog("Erase all activity history?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { Task { await insights.eraseAllData() } }
        }
    }
}

struct DiagnosticsView: View {
    let settings: SettingsViewModel
    @State private var rebuilt: Int?

    var body: some View {
        Form {
            if let diagnostics = settings.diagnostics {
                Section {
                    LabeledContent("Version", value: diagnostics.appVersion)
                    LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: diagnostics.databaseBytes, countStyle: .file))
                    LabeledContent("Integrity", value: diagnostics.integrityProblems.isEmpty ? "OK" : "\(diagnostics.integrityProblems.count) problems")
                    LabeledContent("Search index", value: "\(diagnostics.searchDocuments) items")
                    Button(rebuilt.map { "Rebuilt \($0) items" } ?? "Rebuild search index") {
                        Task { rebuilt = await settings.rebuildSearchIndex() }
                    }
                    ShareLink(item: settings.diagnosticsReport()) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                } footer: {
                    Text("Diagnostics contain system messages only, never your content.")
                }
                if !diagnostics.issues.isEmpty {
                    Section("Recent problems") {
                        ForEach(diagnostics.issues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.context).lumenText(.subheadline)
                                Text(issue.technicalDescription).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                            }
                        }
                    }
                }
                Section("Log") {
                    ForEach(diagnostics.recentLogs.prefix(100)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.level.label.uppercased()) · \(entry.category)").lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
                            Text(entry.message).lumenText(.footnote)
                        }
                    }
                }
            } else {
                SkeletonRows(count: 3)
            }
        }
        .navigationTitle("Diagnostics")
        .task { await settings.loadDiagnostics() }
    }
}
