import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenPlugins

/// The install review: shown before any plugin is installed or updated. The user sees who
/// published it, its signature, every permission in plain language, every network address,
/// everything it adds (with automation previews) and, for updates, what changed; then grants or
/// denies each permission and installs or cancels.
struct PluginReviewView: View {
    @State private var review: PluginReviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, request: PluginInstallRequest) {
        _review = State(initialValue: PluginReviewViewModel(services: services, request: request))
    }

    var body: some View {
        content
            .navigationTitle(review.isUpdate ? "Review update" : "Review plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(review.phase == .installing)
                    }
                }
                if review.phase == .ready || review.phase == .installing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(review.installTitle) { Task { await review.install() } }
                            .disabled(!review.canInstall)
                            .accessibilityIdentifier("pluginReview.install")
                    }
                }
            }
            .interactiveDismissDisabled(review.phase == .installing)
            .task { await review.load() }
    }

    private var isFinished: Bool {
        if case .installed = review.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch review.phase {
        case .loading:
            ProgressView("Checking the plugin…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lumenScreenBackground()
        case .refused(let error):
            StateMessage(error.title, message: [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " "), symbolName: "xmark.shield", actionTitle: "Close") {
                dismiss()
            }
            .lumenScreenBackground()
        case .installed(let state):
            StateMessage(installedTitle, message: installedMessage(state), symbolName: "checkmark.seal", actionTitle: "Done") {
                dismiss()
            }
            .lumenScreenBackground()
        case .ready, .installing:
            form
        }
    }

    private var installedTitle: String {
        review.isUpdate ? "\(review.manifest?.name ?? "Plugin") updated" : "\(review.manifest?.name ?? "Plugin") installed"
    }

    private func installedMessage(_ state: PluginState) -> String {
        switch state {
        case .disabled: return "It's installed but turned off. Turn it on in Settings › Plugins."
        default: return "Its automation templates are in Automations, its commands in the command palette and its shortcuts in the assistant. Change its permissions any time in Settings › Plugins."
        }
    }

    @ViewBuilder
    private var form: some View {
        if let manifest = review.manifest, let content = review.content {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: LumenSpace.xs) {
                        Text(manifest.name).lumenText(.title)
                        Text(verbatim: "\(manifest.publisher.name) · Version \(manifest.version)")
                            .lumenText(.subheadline)
                            .foregroundStyle(LumenColor.textSecondary)
                        if !manifest.description.isEmpty {
                            Text(manifest.description).lumenText(.body)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if let url = manifest.publisher.url {
                        Link(destination: url) {
                            Label(url.host ?? url.absoluteString, systemImage: "safari")
                        }
                    }
                    if let source = review.review?.source {
                        LabeledContent("Source", value: source.summary)
                    }
                }

                if let update = content.update {
                    Section("What changes") {
                        Text(update.versionLine).lumenText(.body)
                        ForEach(update.changes, id: \.self) { change in
                            Text(change).lumenText(.subheadline)
                        }
                    }
                }

                PluginSignatureSection(signature: content.signature)

                if !review.allowsThirdParty {
                    Section {
                        Label("This build of Lumen doesn't allow third-party plugins.", systemImage: "nosign")
                            .foregroundStyle(LumenColor.warning)
                    }
                }

                Section {
                    ForEach(content.capabilities) { row in
                        PluginCapabilityToggle(row: row, isOn: Binding(
                            get: { review.isGranted(row.capability) },
                            set: { review.setGranted($0, row.capability) }
                        ))
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text(review.withheldSummary ?? "Each permission can be turned off later in Settings › Plugins.")
                }

                if !content.hosts.isEmpty {
                    Section {
                        ForEach(content.hosts) { row in
                            PluginHostToggle(row: row, isOn: Binding(
                                get: { review.isAllowed(host: row.host) },
                                set: { review.setAllowed($0, host: row.host) }
                            ))
                        }
                    } header: {
                        Text("Internet addresses")
                    } footer: {
                        Text("Its automation steps send their fields only to the addresses you allow, and only with “Connect to the internet” on.")
                    }
                }

                PluginContributionSections(content: content)

                if let warnings = review.review?.warnings, !warnings.isEmpty {
                    Section("Notes") {
                        ForEach(warnings) { warning in
                            Label(warning.message, systemImage: "info.circle").lumenText(.caption)
                        }
                    }
                }

                if review.requiresUnsignedConfirmation {
                    Section {
                        Toggle("I trust where this plugin came from", isOn: $review.confirmsUnsigned)
                            .tint(LumenColor.warning)
                    } footer: {
                        Text("It isn't signed, so Lumen can't tell who made it or whether it was changed on the way.")
                    }
                }

                if let failure = review.installFailure {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                                Text(failure.title).lumenText(.headline)
                                Text(failure.message).lumenText(.caption)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(LumenColor.danger)
                        }
                    }
                }
            }
            .disabled(review.phase == .installing)
        }
    }
}
