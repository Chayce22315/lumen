import Foundation
import LumenFoundation

/// Where a package came from.
public enum PluginSource: Sendable, Hashable, Codable {
    /// Opened from Files or the share sheet.
    case file
    /// Downloaded through a `lumen://plugin/install` link.
    case link(URL)
    /// Downloaded from a catalog the user added.
    case catalog(catalogURL: URL, packageURL: URL)

    /// The address the package was downloaded from, if it was downloaded.
    public var downloadURL: URL? {
        switch self {
        case .file: return nil
        case .link(let url): return url
        case .catalog(_, let url): return url
        }
    }

    public var summary: String {
        switch self {
        case .file: return "Imported from a file"
        case .link(let url): return "Downloaded from \(url.host ?? url.absoluteString)"
        case .catalog(let catalog, _): return "From the catalog at \(catalog.host ?? catalog.absoluteString)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, url, catalogURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "file": self = .file
        case "link": self = .link(try container.decode(URL.self, forKey: .url))
        case "catalog": self = .catalog(catalogURL: try container.decode(URL.self, forKey: .catalogURL), packageURL: try container.decode(URL.self, forKey: .url))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown plugin source '\(type)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file:
            try container.encode("file", forKey: .type)
        case .link(let url):
            try container.encode("link", forKey: .type)
            try container.encode(url, forKey: .url)
        case .catalog(let catalog, let url):
            try container.encode("catalog", forKey: .type)
            try container.encode(catalog, forKey: .catalogURL)
            try container.encode(url, forKey: .url)
        }
    }
}

/// A package installed on this device. Installed plugins are device-local, like settings.
public struct InstalledPlugin: Sendable, Hashable, Identifiable {
    public let verified: VerifiedPluginPackage
    public let source: PluginSource
    /// The declared hosts the user allows its webhook steps to contact.
    public let grantedHosts: Set<String>
    public let installedAt: Date
    public let updatedAt: Date

    public init(verified: VerifiedPluginPackage, source: PluginSource, grantedHosts: Set<String>, installedAt: Date, updatedAt: Date) {
        self.verified = verified
        self.source = source
        self.grantedHosts = grantedHosts.intersection(verified.manifest.networkHosts)
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }

    public var id: String { manifest.id }
    public var package: PluginPackage { verified.package }
    public var manifest: PluginPackageManifest { verified.manifest }
    public var signature: PluginSignatureStatus { verified.signature }
}

/// A Lumen entity a plugin created on the user's request (for example the workflow added from
/// one of its templates). Uninstalling the plugin deletes it.
public struct PluginOwnedEntity: Sendable, Hashable {
    public let pluginID: String
    /// The contribution it came from, as `PluginContributionReference.key` (`workflow:weekly`).
    public let contributionKey: String
    public let entity: EntityReference
    public let createdAt: Date

    public init(pluginID: String, contributionKey: String, entity: EntityReference, createdAt: Date) {
        self.pluginID = pluginID
        self.contributionKey = contributionKey
        self.entity = entity
        self.createdAt = createdAt
    }
}
