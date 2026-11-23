import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenApplication

/// One installed plugin: what it adds, its permissions (reviewed again and changed here), where
/// it came from, its signature and source, and uninstalling it.
@MainActor
@Observable
public final class PluginDetailViewModel {
    public let pluginID: String
    public private(set) var status: PluginStatus?
    /// `nil` for built-in features and for packages that no longer read.
    public private(set) var installed: InstalledPlugin?
    public private(set) var content: PluginReviewContent?
    /// Automations added from the plugin's templates; uninstalling deletes them.
    public private(set) var ownedWorkflowCount = 0
    public var grantedCapabilities: Set<PluginCapability> = []
    public var grantedHosts: Set<String> = []
    public private(set) var isLoaded = false
    public private(set) var isSaving = false
    public private(set) var isUninstalled = false

    private let services: LumenServices
    private var savedCapabilities: Set<PluginCapability> = []
    private var savedHosts: Set<String> = []

    public init(services: LumenServices, pluginID: String) {
        self.services = services
        self.pluginID = pluginID
    }

    public var name: String { installed?.manifest.name ?? status?.manifest.name ?? pluginID }
    public var isBuiltIn: Bool { status?.isBuiltIn ?? false }
    public var stateText: String { status.map(PluginStateText.text(for:)) ?? "Not installed" }
    public var hasChanges: Bool { grantedCapabilities != savedCapabilities || grantedHosts != savedHosts }
    public var manifestSource: String? { installed?.package.manifestSource }

    /// Where the package came from ("Downloaded from example.com").
    public var sourceText: String? { installed?.source.summary }
    public var updatedAt: Date? { installed?.updatedAt }

    public var uninstallConsequence: String {
        switch ownedWorkflowCount {
        case 0: return "Removes everything it added and the permissions you gave it."
        case 1: return "Removes everything it added, the permissions you gave it and the automation you added from it."
        default: return "Removes everything it added, the permissions you gave it and the \(ownedWorkflowCount) automations you added from it."
        }
    }

    public func load() async {
        status = await services.plugins.host.statuses().first { $0.id == pluginID }
        do {
            installed = try await services.plugins.packages.installedPlugin(pluginID)
            ownedWorkflowCount = try await services.plugins.packages.ownedEntities.entities(of: pluginID).filter { $0.entity.kind == .workflow }.count
        } catch is PluginPackageError {
            // A package that no longer reads shows its state (with the reason) and can still be
            // uninstalled.
            installed = nil
        } catch {
            installed = nil
            services.errors.report(error, context: "Loading a plugin")
        }
        if let installed {
            let catalog = services.automation.catalog
            content = PluginReviewContent(
                installed: installed,
                templates: services.plugins.templates(in: installed.manifest),
                actions: catalog.descriptorsByID,
                triggerTitle: { catalog.triggerDescriptor(for: $0)?.title }
            )
            savedHosts = installed.grantedHosts
        }
        savedCapabilities = status?.grantedCapabilities.intersection(status?.manifest.capabilities ?? []) ?? []
        grantedCapabilities = savedCapabilities
        grantedHosts = savedHosts
        isLoaded = true
    }

    public func setGranted(_ granted: Bool, _ capability: PluginCapability) {
        if granted { grantedCapabilities.insert(capability) } else { grantedCapabilities.remove(capability) }
    }

    public func setAllowed(_ allowed: Bool, host: String) {
        if allowed { grantedHosts.insert(host) } else { grantedHosts.remove(host) }
    }

    /// Applies the permission choices; the plugin restarts with them.
    public func savePermissions() async {
        guard hasChanges, !isBuiltIn else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await services.plugins.packages.updatePermissions(of: pluginID, capabilities: grantedCapabilities, hosts: grantedHosts)
        } catch {
            services.errors.report(error, context: "Changing plugin permissions")
        }
        await load()
    }

    public func discardChanges() {
        grantedCapabilities = savedCapabilities
        grantedHosts = savedHosts
    }

    public func setEnabled(_ enabled: Bool) async {
        do {
            try await services.plugins.host.setEnabled(enabled, for: pluginID)
        } catch {
            services.errors.report(error, context: "Turning a plugin \(enabled ? "on" : "off")")
        }
        await load()
    }

    /// Uninstalls the plugin. Returns whether it is gone.
    @discardableResult
    public func uninstall() async -> Bool {
        do {
            try await services.plugins.packages.uninstall(pluginID)
            isUninstalled = true
            return true
        } catch {
            services.errors.report(error, context: "Uninstalling a plugin")
            return false
        }
    }
}
