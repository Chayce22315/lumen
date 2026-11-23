import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenPlugins

/// One capability with what it allows, as a toggle the user grants or denies.
struct PluginCapabilityToggle: View {
    let row: PluginReviewContent.CapabilityRow
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                HStack(spacing: LumenSpace.xs) {
                    Text(row.title).lumenText(.body)
                    if row.isNew {
                        Chip("New", tint: LumenColor.accent)
                    }
                }
                Text(row.explanation)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                if !row.enables.isEmpty {
                    Text(row.enables)
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textTertiary)
                }
            }
        }
        .tint(row.isHighRisk ? LumenColor.warning : LumenColor.accent)
        .accessibilityHint(row.isHighRisk ? "High-risk permission. \(row.explanation)" : row.explanation)
    }
}

/// A network host the plugin's steps may contact, as a toggle.
struct PluginHostToggle: View {
    let row: PluginReviewContent.HostRow
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                HStack(spacing: LumenSpace.xs) {
                    Text(row.host).lumenText(.monospaced)
                    if row.isNew {
                        Chip("New", tint: LumenColor.accent)
                    }
                }
                if !row.usedBy.isEmpty {
                    Text("Used by " + row.usedBy.joined(separator: ", "))
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textSecondary)
                }
            }
        }
        .tint(LumenColor.warning)
        .accessibilityLabel("Allow contacting \(row.host)")
    }
}

/// The signature status and publisher key fingerprint.
struct PluginSignatureSection: View {
    let signature: PluginReviewContent.Signature

    var body: some View {
        Section("Signature") {
            Label {
                VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                    Text(signature.title).lumenText(.body)
                    Text(signature.detail)
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textSecondary)
                }
            } icon: {
                Image(systemName: signature.isWarning ? "exclamationmark.shield" : "checkmark.seal")
                    .foregroundStyle(signature.isWarning ? LumenColor.warning : LumenColor.success)
            }
            if let fingerprint = signature.fingerprint {
                LabeledContent("Key fingerprint") {
                    Text(fingerprint)
                        .lumenText(.monospaced)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Everything a plugin adds, with a step-by-step preview of each automation template.
struct PluginContributionSections: View {
    let content: PluginReviewContent

    var body: some View {
        Section("What it adds") {
            ForEach(content.contributions, id: \.self) { row in
                Label {
                    VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                        Text(row.title).lumenText(.body)
                        Text(row.kind.title)
                            .lumenText(.caption)
                            .foregroundStyle(LumenColor.textTertiary)
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .lumenText(.caption)
                                .foregroundStyle(LumenColor.textSecondary)
                                .lineLimit(4)
                        }
                    }
                } icon: {
                    Image(systemName: symbol(for: row.kind)).foregroundStyle(LumenColor.accent)
                }
            }
        }
        ForEach(content.workflows) { workflow in
            Section {
                ForEach(workflow.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: LumenSpace.s) {
                        VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                            Text(step.title).lumenText(.subheadline)
                            Text(step.detail)
                                .lumenText(.caption)
                                .foregroundStyle(step.sendsData ? LumenColor.warning : LumenColor.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if step.changesData {
                            Image(systemName: "pencil.circle")
                                .foregroundStyle(LumenColor.textSecondary)
                                .accessibilityLabel("Changes your data")
                        }
                        if step.sendsData {
                            Image(systemName: "network")
                                .foregroundStyle(LumenColor.warning)
                                .accessibilityLabel("Sends data to the internet")
                        }
                    }
                    .padding(.leading, CGFloat(step.depth) * LumenSpace.l)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Automation: \(workflow.name)")
            } footer: {
                Text(workflowFooter(workflow))
            }
        }
    }

    private func symbol(for kind: PluginContributionReference.Kind) -> String {
        switch kind {
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .command: return "command"
        case .prompt: return "text.bubble"
        case .webhook: return "paperplane"
        }
    }

    private func workflowFooter(_ workflow: PluginReviewContent.WorkflowPreview) -> String {
        var parts = [workflow.trigger + "."]
        if !workflow.summary.isEmpty { parts.insert(workflow.summary, at: 0) }
        if workflow.changesData { parts.append("It changes your data.") }
        if workflow.sendsData { parts.append("It sends data to the internet.") }
        parts.append("Nothing runs until you add it in Automations.")
        return parts.joined(separator: " ")
    }
}

/// The manifest JSON, read-only and selectable.
struct PluginManifestSourceView: View {
    let source: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(source)
                .lumenText(.monospaced)
                .textSelection(.enabled)
                .padding(LumenSpace.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lumenScreenBackground()
        .navigationTitle("Manifest")
    }
}
