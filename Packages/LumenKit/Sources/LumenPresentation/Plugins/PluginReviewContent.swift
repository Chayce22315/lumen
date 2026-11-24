import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenAutomation
import LumenApplication

/// What the install review shows, derived from a review. Pure, so it is tested without a screen.
public struct PluginReviewContent: Sendable, Hashable {
    public struct CapabilityRow: Sendable, Hashable, Identifiable {
        public let capability: PluginCapability
        public let title: String
        public let explanation: String
        public let isHighRisk: Bool
        /// Asked for by this update but not by the installed version.
        public let isNew: Bool
        /// What it allows in this plugin ("2 commands").
        public let enables: String
        public var id: PluginCapability { capability }
    }

    public struct HostRow: Sendable, Hashable, Identifiable {
        public let host: String
        public let isNew: Bool
        /// Titles of the automation steps that contact it.
        public let usedBy: [String]
        public var id: String { host }
    }

    public struct ContributionRow: Sendable, Hashable, Identifiable {
        public let kind: PluginContributionReference.Kind
        public let id: String
        public let title: String
        public let detail: String
    }

    public struct WorkflowPreview: Sendable, Hashable, Identifiable {
        public struct Step: Sendable, Hashable, Identifiable {
            public let id: WorkflowNode.ID
            public let title: String
            public let detail: String
            public let depth: Int
            public let changesData: Bool
            public let sendsData: Bool
        }

        public let id: String
        public let name: String
        public let summary: String
        public let trigger: String
        public let steps: [Step]

        public var changesData: Bool { steps.contains(where: \.changesData) }
        public var sendsData: Bool { steps.contains(where: \.sendsData) }
    }

    public struct Signature: Sendable, Hashable {
        public let title: String
        public let detail: String
        public let fingerprint: String?
        public let isWarning: Bool
    }

    public struct Update: Sendable, Hashable {
        public let versionLine: String
        public let changes: [String]
    }

    public let capabilities: [CapabilityRow]
    public let hosts: [HostRow]
    public let contributions: [ContributionRow]
    public let workflows: [WorkflowPreview]
    public let signature: Signature
    public let update: Update?

    /// Content for the install review of `review`.
    public init(review: PluginInstallReview, templates: [WorkflowTemplate], actions: [AutomationActionID: AutomationActionDescriptor], triggerTitle: (EventName) -> String? = { _ in nil }) {
        self.init(manifest: review.manifest, trust: review.trust, previous: review.installed?.manifest, diff: review.diff, templates: templates, actions: actions, triggerTitle: triggerTitle)
    }

    /// Content for an installed plugin's detail screen.
    public init(installed: InstalledPlugin, templates: [WorkflowTemplate], actions: [AutomationActionID: AutomationActionDescriptor], triggerTitle: (EventName) -> String? = { _ in nil }) {
        let trust: PluginTrust = installed.signature.key.map { .pinnedKey($0) } ?? .unsigned
        self.init(manifest: installed.manifest, trust: trust, previous: nil, diff: nil, templates: templates, actions: actions, triggerTitle: triggerTitle)
    }

    init(
        manifest: PluginPackageManifest,
        trust: PluginTrust,
        previous: PluginPackageManifest?,
        diff: PluginUpdateDiff?,
        templates: [WorkflowTemplate],
        actions: [AutomationActionID: AutomationActionDescriptor],
        triggerTitle: (EventName) -> String?
    ) {
        let contributions = manifest.contributions
        let addedCapabilities = Set(diff?.addedCapabilities ?? [])
        capabilities = manifest.capabilities.sorted { ($0.risk, $1.rawValue) > ($1.risk, $0.rawValue) }.map { capability in
            CapabilityRow(
                capability: capability,
                title: capability.title,
                explanation: capability.explanation,
                isHighRisk: capability.risk == .high,
                isNew: previous != nil && addedCapabilities.contains(capability),
                enables: Self.enables(capability, contributions: contributions)
            )
        }
        let addedHosts = Set(diff?.addedHosts ?? [])
        hosts = manifest.networkHosts.map { host in
            HostRow(host: host, isNew: previous != nil && addedHosts.contains(host), usedBy: contributions.webhooks.filter { $0.host == host }.map(\.title))
        }
        self.contributions = contributions.workflows.map { ContributionRow(kind: .workflow, id: $0.id, title: $0.name, detail: $0.summary) }
            + contributions.commands.map { command in
                let detail: String
                switch command.action {
                case .openLink(let url): detail = "Opens \(url.absoluteString)"
                case .runWorkflow(let id): detail = "Runs “\(contributions.workflow(id)?.name ?? id)”, adding it to your automations the first time"
                }
                return ContributionRow(kind: .command, id: command.id, title: command.title, detail: detail)
            }
            + contributions.prompts.map { ContributionRow(kind: .prompt, id: $0.id, title: $0.title, detail: $0.prompt) }
            + contributions.webhooks.map { webhook in
                let fields = webhook.fields.map(\.title).joined(separator: ", ")
                return ContributionRow(kind: .webhook, id: webhook.id, title: webhook.title, detail: "Sends \(fields.isEmpty ? "a request" : fields) to \(webhook.url.absoluteString)")
            }

        var known = actions
        var webhookHosts: [AutomationActionID: String] = [:]
        for webhook in contributions.webhooks {
            let id = PluginServices.webhookActionID(pluginID: manifest.id, webhookID: webhook.id)
            webhookHosts[id] = webhook.host
            known[id] = AutomationActionDescriptor(id: id, title: webhook.title, summary: webhook.summary, symbolName: "paperplane", category: manifest.name, isMutating: true)
        }
        workflows = templates.map { template in
            Self.preview(template, actions: known, webhookHosts: webhookHosts, triggerTitle: triggerTitle)
        }
        signature = Self.signature(trust)
        update = diff.map { Self.update($0) }
    }

    // MARK: - Pieces

    static func enables(_ capability: PluginCapability, contributions: PluginContributions) -> String {
        func count(_ number: Int, _ singular: String, _ plural: String) -> String {
            "\(number) \(number == 1 ? singular : plural)"
        }
        switch capability {
        case .contributeWorkflowTemplates: return count(contributions.workflows.count, "automation template", "automation templates")
        case .contributeCommands: return count(contributions.commands.count, "command", "commands")
        case .contributeAssistantPrompts: return count(contributions.prompts.count, "assistant shortcut", "assistant shortcuts")
        case .contributeAutomationActions: return count(contributions.webhooks.count, "automation step", "automation steps")
        case .network: return count(Set(contributions.webhooks.map(\.host)).count, "internet address", "internet addresses")
        default: return ""
        }
    }

    static func preview(
        _ template: WorkflowTemplate,
        actions: [AutomationActionID: AutomationActionDescriptor],
        webhookHosts: [AutomationActionID: String],
        triggerTitle: (EventName) -> String?
    ) -> WorkflowPreview {
        let trigger = triggerSummary(template.trigger, triggerTitle: triggerTitle)
        let steps = WorkflowOutline.items(for: template.graph).compactMap { item -> WorkflowPreview.Step? in
            guard let node = template.graph.node(item.nodeID) else { return nil }
            var detail: String
            var changesData = false
            var sendsData = false
            switch node.kind {
            case .trigger:
                detail = trigger
            case .action(let actionID, _):
                if let descriptor = actions[actionID] {
                    detail = descriptor.title
                    changesData = descriptor.isMutating && webhookHosts[actionID] == nil
                } else {
                    detail = "A step Lumen doesn't have"
                }
                if let host = webhookHosts[actionID] {
                    detail += " · sends data to \(host)"
                    sendsData = true
                }
            case .condition:
                detail = "Checks a condition"
            case .delay(let seconds):
                detail = "Waits \(duration(seconds))"
            case .end:
                detail = "Ends the automation"
            }
            if !item.isConnected { detail += " · not connected" }
            return WorkflowPreview.Step(id: node.id, title: node.title.isEmpty ? detail : node.title, detail: detail, depth: item.depth, changesData: changesData, sendsData: sendsData)
        }
        return WorkflowPreview(id: template.templateID, name: template.name, summary: template.summary, trigger: trigger, steps: steps)
    }

    static func triggerSummary(_ trigger: TriggerDefinition, triggerTitle: (EventName) -> String?) -> String {
        switch trigger {
        case .manual: return "Runs when you start it"
        case .event(let name, let condition):
            let title = triggerTitle(name).map { "When “\($0)” happens" } ?? "When \(name.rawValue) happens"
            return condition == nil ? title : "\(title), if conditions match"
        case .schedule(let schedule): return schedule.summary
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        if value >= 86_400, value % 86_400 == 0 { return value == 86_400 ? "1 day" : "\(value / 86_400) days" }
        if value >= 3_600, value % 3_600 == 0 { return value == 3_600 ? "1 hour" : "\(value / 3_600) hours" }
        if value >= 60, value % 60 == 0 { return value == 60 ? "1 minute" : "\(value / 60) minutes" }
        return value == 1 ? "1 second" : "\(value) seconds"
    }

    static func signature(_ trust: PluginTrust) -> Signature {
        switch trust {
        case .pinnedKey(let key):
            return Signature(title: "Signed by the same publisher", detail: "This update is signed with the key that signed the version you have.", fingerprint: key.fingerprint, isWarning: false)
        case .newKey(let key):
            return Signature(title: "Signed by a new publisher key", detail: "The package hasn't been changed since it was signed. You haven't installed anything signed with this key before; compare its fingerprint with the one the publisher shows.", fingerprint: key.fingerprint, isWarning: false)
        case .knownKey(let key, let others):
            let list = others.count == 1 ? "1 other plugin" : "\(others.count) other plugins"
            return Signature(title: "Signed by a publisher you know", detail: "The same key signed \(list) you installed.", fingerprint: key.fingerprint, isWarning: false)
        case .unsigned:
            return Signature(title: "Not signed", detail: "Anyone could have made or changed this package. Install it only if you trust where it came from.", fingerprint: nil, isWarning: true)
        }
    }

    static func update(_ diff: PluginUpdateDiff) -> Update {
        let versionLine: String
        switch diff.versionChange {
        case .upgrade: versionLine = "Updates version \(diff.fromVersion) to \(diff.toVersion)."
        case .same: versionLine = diff.contentsChanged ? "Replaces version \(diff.toVersion) with a different package of the same version." : "Reinstalls version \(diff.toVersion)."
        case .downgrade: versionLine = "Replaces version \(diff.fromVersion) with the older \(diff.toVersion)."
        }
        var changes: [String] = []
        changes += diff.addedCapabilities.map { "Asks for a new permission: \($0.title)" }
        changes += diff.removedCapabilities.map { "No longer asks to \($0.title.lowercased())" }
        changes += diff.addedHosts.map { "Asks to contact a new address: \($0)" }
        changes += diff.removedHosts.map { "No longer contacts \($0)" }
        changes += diff.addedContributions.map { "Adds the \($0.kind.title.lowercased()) “\($0.title)”" }
        changes += diff.removedContributions.map { "Removes the \($0.kind.title.lowercased()) “\($0.title)”" }
        changes += diff.changedContributions.map { "Changes the \($0.kind.title.lowercased()) “\($0.title)”" }
        if changes.isEmpty, diff.contentsChanged { changes.append("Changes details that don't affect permissions or contributions") }
        return Update(versionLine: versionLine, changes: changes)
    }
}
