import Foundation
import LumenFoundation

/// Semantic rules for a decoded manifest. Contributions whose meaning belongs to other engines
/// (workflow graphs, deep-link targets) are checked again by the application layer.
///
/// Rules:
/// - the identifier is reverse-DNS and outside Lumen's reserved `app.lumen.` namespace;
/// - contribution identifiers are short ASCII names, unique per kind;
/// - every contribution kind needs its capability, and every requested capability is used
///   (`network` and `contributeAutomationActions` by webhook steps);
/// - links are `lumen://` (never another plugin install); workflow commands name a template of
///   the same package;
/// - hosts are DNS names (no IP addresses, no `localhost`), each used by a webhook; webhook
///   addresses are `https` on the default port, on a declared host, without credentials.
public struct PluginPackageValidator: Sendable {
    public let limits: PluginPackageFormat.Limits

    public init(limits: PluginPackageFormat.Limits = PluginPackageFormat.Limits()) {
        self.limits = limits
    }

    public func issues(in manifest: PluginPackageManifest) -> [PluginPackageIssue] {
        var issues: [PluginPackageIssue] = []
        if !PluginIdentifier.isValid(manifest.id) {
            issues.append(PluginPackageIssue(path: "manifest.id", message: "The identifier must be reverse-DNS with at least three parts, like com.example.plugin."))
        } else if manifest.id.lowercased().hasPrefix(PluginIdentifier.reservedPrefix) {
            issues.append(PluginPackageIssue(path: "manifest.id", message: "Identifiers starting with app.lumen. are reserved for Lumen's own features."))
        }
        if let url = manifest.publisher.url, !Self.isHTTPS(url) {
            issues.append(PluginPackageIssue(path: "manifest.publisher.url", message: "The publisher's address must start with https://."))
        }
        if manifest.contributions.isEmpty {
            issues.append(PluginPackageIssue(path: "manifest.contributions", message: "The plugin doesn't contribute anything."))
        }
        issues += identifierIssues(manifest.contributions)
        issues += capabilityIssues(manifest)
        issues += commandIssues(manifest.contributions)
        issues += networkIssues(manifest)
        return issues
    }

    // MARK: - Identifiers

    /// Contribution identifiers: an ASCII letter, then letters, digits or hyphens (they become
    /// part of command and automation-step identifiers).
    static func isValidContributionID(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.first, first.isASCII, first.isLetter else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func identifierIssues(_ contributions: PluginContributions) -> [PluginPackageIssue] {
        var issues: [PluginPackageIssue] = []
        func check(_ ids: [String], path: String) {
            var seen = Set<String>()
            for (index, id) in ids.enumerated() {
                if !Self.isValidContributionID(id) {
                    issues.append(PluginPackageIssue(path: "\(path)[\(index)].id", message: "Identifiers start with a letter and use only letters, digits and hyphens."))
                } else if !seen.insert(id).inserted {
                    issues.append(PluginPackageIssue(path: "\(path)[\(index)].id", message: "Another entry already uses the identifier \(id)."))
                }
            }
        }
        check(contributions.workflows.map(\.id), path: "manifest.contributions.workflows")
        check(contributions.commands.map(\.id), path: "manifest.contributions.commands")
        check(contributions.prompts.map(\.id), path: "manifest.contributions.prompts")
        check(contributions.webhooks.map(\.id), path: "manifest.contributions.webhooks")
        for (index, webhook) in contributions.webhooks.enumerated() {
            var names = Set<String>()
            for (fieldIndex, field) in webhook.fields.enumerated() {
                let path = "manifest.contributions.webhooks[\(index)].fields[\(fieldIndex)].name"
                if !Self.isValidContributionID(field.name) {
                    issues.append(PluginPackageIssue(path: path, message: "Field names start with a letter and use only letters, digits and hyphens."))
                } else if !names.insert(field.name).inserted {
                    issues.append(PluginPackageIssue(path: path, message: "Another field already uses the name \(field.name)."))
                }
            }
        }
        return issues
    }

    // MARK: - Capabilities

    /// The capabilities a set of contributions needs.
    public static func neededCapabilities(for contributions: PluginContributions) -> Set<PluginCapability> {
        var needed = Set<PluginCapability>()
        if !contributions.workflows.isEmpty { needed.insert(.contributeWorkflowTemplates) }
        if !contributions.commands.isEmpty { needed.insert(.contributeCommands) }
        if !contributions.prompts.isEmpty { needed.insert(.contributeAssistantPrompts) }
        if !contributions.webhooks.isEmpty { needed.formUnion([.contributeAutomationActions, .network]) }
        return needed
    }

    private func capabilityIssues(_ manifest: PluginPackageManifest) -> [PluginPackageIssue] {
        let needed = Self.neededCapabilities(for: manifest.contributions)
        var issues: [PluginPackageIssue] = []
        for capability in needed.subtracting(manifest.capabilities).sorted() {
            issues.append(PluginPackageIssue(path: "manifest.capabilities", message: "The plugin's contributions need the \(capability.rawValue) permission, but it doesn't ask for it."))
        }
        for capability in manifest.capabilities.subtracting(needed).sorted() {
            issues.append(PluginPackageIssue(path: "manifest.capabilities", message: "The plugin asks for \(capability.rawValue) but contributes nothing that uses it."))
        }
        return issues
    }

    // MARK: - Commands

    private func commandIssues(_ contributions: PluginContributions) -> [PluginPackageIssue] {
        var issues: [PluginPackageIssue] = []
        let templates = Set(contributions.workflows.map(\.id))
        for (index, command) in contributions.commands.enumerated() {
            let path = "manifest.contributions.commands[\(index)].action"
            switch command.action {
            case .openLink(let url):
                if url.scheme?.lowercased() != "lumen" {
                    issues.append(PluginPackageIssue(path: "\(path).url", message: "Commands can only open lumen:// links."))
                } else if url.host?.lowercased() == PluginInstallLink.host {
                    issues.append(PluginPackageIssue(path: "\(path).url", message: "Commands can't open plugin installation links."))
                }
            case .runWorkflow(let templateID):
                if !templates.contains(templateID) {
                    issues.append(PluginPackageIssue(path: "\(path).workflow", message: "No workflow template of this plugin has the identifier \(templateID.truncated(to: 40))."))
                }
            }
        }
        return issues
    }

    // MARK: - Network

    private func networkIssues(_ manifest: PluginPackageManifest) -> [PluginPackageIssue] {
        var issues: [PluginPackageIssue] = []
        let declared = Set(manifest.networkHosts)
        for (index, host) in manifest.networkHosts.enumerated() where !Self.isValidHost(host) {
            issues.append(PluginPackageIssue(path: "manifest.network.hosts[\(index)]", message: "Hosts must be internet domain names like hooks.example.com (no addresses, ports or localhost)."))
        }
        var used = Set<String>()
        for (index, webhook) in manifest.contributions.webhooks.enumerated() {
            let path = "manifest.contributions.webhooks[\(index)].url"
            let url = webhook.url
            guard Self.isHTTPS(url), url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else {
                issues.append(PluginPackageIssue(path: path, message: "Webhook addresses must be https:// on the standard port, without a user name, password or #fragment."))
                continue
            }
            if !declared.contains(webhook.host) {
                issues.append(PluginPackageIssue(path: path, message: "The webhook's host isn't listed in network.hosts."))
            }
            used.insert(webhook.host)
        }
        for (index, host) in manifest.networkHosts.enumerated() where !used.contains(host) {
            issues.append(PluginPackageIssue(path: "manifest.network.hosts[\(index)]", message: "No webhook uses the host \(host.truncated(to: 60))."))
        }
        return issues
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.host?.isEmpty == false)
    }

    /// A public DNS name: at least two labels of ASCII letters, digits and inner hyphens; not an
    /// IP address, not `localhost`, not a `.local` name.
    public static func isValidHost(_ host: String) -> Bool {
        guard (1...253).contains(host.count), host == host.lowercased() else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.count)
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && label.first != "-" && label.last != "-"
        }) else { return false }
        // A numeric last label means an IPv4 address (or nonsense); top-level domains have letters.
        guard let tld = labels.last, tld.contains(where: \.isLetter) else { return false }
        return !["localhost", "local", "internal", "localdomain"].contains(String(tld))
    }
}
