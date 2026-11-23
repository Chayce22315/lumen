import Foundation

/// What an update changes compared with the installed version.
public struct PluginUpdateDiff: Sendable, Hashable {
    public enum VersionChange: Sendable, Hashable {
        case upgrade
        /// The same version again (a reinstall, possibly with different contents).
        case same
        case downgrade
    }

    public let fromVersion: PluginVersion
    public let toVersion: PluginVersion
    public let addedCapabilities: [PluginCapability]
    public let removedCapabilities: [PluginCapability]
    public let addedHosts: [String]
    public let removedHosts: [String]
    public let addedContributions: [PluginContributionReference]
    public let removedContributions: [PluginContributionReference]
    /// Same kind and identifier, different definition.
    public let changedContributions: [PluginContributionReference]
    /// Whether the package bytes differ at all (a reinstall of the identical file changes nothing).
    public let contentsChanged: Bool

    public var versionChange: VersionChange {
        if toVersion > fromVersion { return .upgrade }
        if toVersion < fromVersion { return .downgrade }
        return .same
    }

    /// Whether the update asks for anything the installed version didn't have.
    public var asksForMore: Bool {
        !addedCapabilities.isEmpty || !addedHosts.isEmpty
    }

    public var hasChanges: Bool {
        fromVersion != toVersion || !addedCapabilities.isEmpty || !removedCapabilities.isEmpty || !addedHosts.isEmpty
            || !removedHosts.isEmpty || !addedContributions.isEmpty || !removedContributions.isEmpty || !changedContributions.isEmpty
    }

    public init(from installed: PluginPackage, to offered: PluginPackage) {
        let old = installed.manifest, new = offered.manifest
        fromVersion = old.version
        toVersion = new.version
        addedCapabilities = new.capabilities.subtracting(old.capabilities).sorted()
        removedCapabilities = old.capabilities.subtracting(new.capabilities).sorted()
        addedHosts = Set(new.networkHosts).subtracting(old.networkHosts).sorted()
        removedHosts = Set(old.networkHosts).subtracting(new.networkHosts).sorted()
        contentsChanged = installed.sha256 != offered.sha256

        let oldDefinitions = Self.definitions(old.contributions)
        let newDefinitions = Self.definitions(new.contributions)
        let oldReferences = Dictionary(old.contributions.references.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let newReferences = new.contributions.references
        addedContributions = newReferences.filter { oldReferences[$0.key] == nil }
        removedContributions = old.contributions.references.filter { newDefinitions[$0.key] == nil }
        changedContributions = newReferences.filter { reference in
            guard let before = oldDefinitions[reference.key] else { return false }
            return before != newDefinitions[reference.key]
        }
    }

    /// Each contribution's definition keyed by `kind:id`, compared to spot changes.
    private static func definitions(_ contributions: PluginContributions) -> [String: AnyHashable] {
        var result: [String: AnyHashable] = [:]
        for item in contributions.workflows { result["workflow:\(item.id)"] = AnyHashable(item) }
        for item in contributions.commands { result["command:\(item.id)"] = AnyHashable(item) }
        for item in contributions.prompts { result["prompt:\(item.id)"] = AnyHashable(item) }
        for item in contributions.webhooks { result["webhook:\(item.id)"] = AnyHashable(item) }
        return result
    }
}
