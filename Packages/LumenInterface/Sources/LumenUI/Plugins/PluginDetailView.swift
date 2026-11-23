import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenPlugins

/// One installed plugin: on/off, its permissions reviewed again, what it adds, where it came
/// from, its signature and manifest, and uninstalling it.
struct PluginDetailView: View {
    @State private var detail: PluginDetailViewModel
    @State private var confirmsUninstall = false
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, pluginID: String) {
        _detail = State(initialValue: PluginDetailViewModel(services: services, pluginID: pluginID))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: detail.stateText)
                if detail.status != nil, !detail.isBuiltIn {
                    Toggle("On", isOn: Binding(
                        get: { detail.status?.state != .disabled },
                        set: { value in Task { await detail.setEnabled(value) } }
                    ))
                }
            } header: {
                Text(detail.name)
            } footer: {
                if let manifest = detail.installed?.manifest, !manifest.description.isEmpty {
                    Text(manifest.description)
                }
            }

            if let installed = detail.installed, let content = detail.content {
                permissions(content)
                PluginContributionSections(content: content)
                source(installed)
                PluginSignatureSection(signature: content.signature)
            }

            if detail.status != nil, !detail.isBuiltIn {
                Section {
                    Button("Uninstall", role: .destructive) { confirmsUninstall = true }
                        .accessibilityIdentifier("pluginDetail.uninstall")
                } footer: {
                    Text(detail.uninstallConsequence)
                }
            }
        }
        .navigationTitle(detail.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await detail.load() }
        .confirmationDialog("Uninstall \(detail.name)?", isPresented: $confirmsUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                Task {
                    if await detail.uninstall() { dismiss() }
                }
            }
        } message: {
            Text(detail.uninstallConsequence)
        }
    }

    @ViewBuilder
    private func permissions(_ content: PluginReviewContent) -> some View {
        Section {
            ForEach(content.capabilities) { row in
                PluginCapabilityToggle(row: row, isOn: Binding(
                    get: { detail.grantedCapabilities.contains(row.capability) },
                    set: { detail.setGranted($0, row.capability) }
                ))
            }
            ForEach(content.hosts) { row in
                PluginHostToggle(row: row, isOn: Binding(
                    get: { detail.grantedHosts.contains(row.host) },
                    set: { detail.setAllowed($0, host: row.host) }
                ))
            }
            if detail.hasChanges {
                Button("Apply changes") { Task { await detail.savePermissions() } }
                    .disabled(detail.isSaving)
                Button("Discard changes", role: .cancel) { detail.discardChanges() }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Applying restarts the plugin with exactly these permissions. What needs a permission you turn off disappears until you allow it again.")
        }
    }

    @ViewBuilder
    private func source(_ installed: InstalledPlugin) -> some View {
        Section("Source") {
            LabeledContent("Publisher", value: installed.manifest.publisher.name)
            if let url = installed.manifest.publisher.url {
                Link(destination: url) {
                    Label(url.host ?? url.absoluteString, systemImage: "safari")
                }
            }
            LabeledContent("Version", value: installed.manifest.version.description)
            if let source = detail.sourceText {
                LabeledContent("From", value: source)
            }
            if let address = installed.source.downloadURL {
                Text(address.absoluteString)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                    .textSelection(.enabled)
            }
            if let updated = detail.updatedAt {
                LabeledContent("Installed or updated") {
                    Text(updated, style: .date)
                }
            }
            LabeledContent("Identifier", value: installed.id)
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                Text("SHA-256").lumenText(.subheadline)
                Text(installed.package.sha256)
                    .lumenText(.monospaced)
                    .foregroundStyle(LumenColor.textSecondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            if let manifest = detail.manifestSource {
                NavigationLink("View manifest") {
                    PluginManifestSourceView(source: manifest)
                }
            }
        }
    }
}
