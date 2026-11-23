import Foundation

/// Everything the install review screen shows before a package is installed or updated. Built
/// by `PluginPackageManager.review`, after the package was decoded, validated, its signature
/// checked and its trust decided; a review exists only for a package that may be installed.
public struct PluginInstallReview: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let verified: VerifiedPluginPackage
    public let source: PluginSource
    public let trust: PluginTrust
    /// The installed version this package replaces.
    public let installed: InstalledPlugin?
    /// SHA-256 of the stored package this replaces (also when it no longer reads), so the install
    /// can tell whether it changed since the review.
    public let replacedPackageSHA256: String?
    /// Capabilities the user granted to the installed version.
    public let installedGrants: Set<PluginCapability>
    public let diff: PluginUpdateDiff?
    /// Problems that don't block installing (an automation template whose trigger event no
    /// installed feature announces, for example).
    public let warnings: [PluginPackageIssue]

    public init(
        id: UUID = UUID(),
        verified: VerifiedPluginPackage,
        source: PluginSource,
        trust: PluginTrust,
        installed: InstalledPlugin?,
        replacedPackageSHA256: String?,
        installedGrants: Set<PluginCapability>,
        warnings: [PluginPackageIssue]
    ) {
        self.id = id
        self.verified = verified
        self.source = source
        self.trust = trust
        self.installed = installed
        self.replacedPackageSHA256 = replacedPackageSHA256
        self.installedGrants = installedGrants
        self.diff = installed.map { PluginUpdateDiff(from: $0.package, to: verified.package) }
        self.warnings = warnings
    }

    public var manifest: PluginPackageManifest { verified.manifest }
    public var package: PluginPackage { verified.package }
    public var isUpdate: Bool { replacedPackageSHA256 != nil }
    public var requiresUnsignedConfirmation: Bool { trust.requiresUnsignedConfirmation }

    /// What the review starts with switched on. A first install allows the low-risk
    /// capabilities and nothing that reaches the network; an update keeps what was granted and
    /// treats capabilities it adds like a first install. Hosts always start off unless they were
    /// allowed before.
    public var suggestedCapabilities: Set<PluginCapability> {
        let requested = manifest.capabilities
        let previouslyRequested = installed?.manifest.capabilities ?? []
        let kept = installedGrants.intersection(requested)
        let new = requested.subtracting(previouslyRequested).filter { $0.risk == .low }
        return kept.union(new)
    }

    public var suggestedHosts: Set<String> {
        installed?.grantedHosts.intersection(manifest.networkHosts) ?? []
    }
}

/// The user's decisions on the review screen.
public struct PluginInstallChoices: Sendable, Hashable {
    public var capabilities: Set<PluginCapability>
    public var hosts: Set<String>
    /// Required for unsigned packages: the user confirmed they trust where it came from.
    public var confirmsUnsigned: Bool

    public init(capabilities: Set<PluginCapability>, hosts: Set<String>, confirmsUnsigned: Bool = false) {
        self.capabilities = capabilities
        self.hosts = hosts
        self.confirmsUnsigned = confirmsUnsigned
    }
}

/// Findings of the application layer about contributions whose meaning belongs to other
/// engines (workflow graphs, deep-link targets).
public struct PluginContentReport: Sendable, Hashable {
    public var errors: [PluginPackageIssue]
    public var warnings: [PluginPackageIssue]

    public init(errors: [PluginPackageIssue] = [], warnings: [PluginPackageIssue] = []) {
        self.errors = errors
        self.warnings = warnings
    }
}
