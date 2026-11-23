import Foundation
import LumenFoundation

/// A static JSON index of plugin packages at an `https` address the user added (for example a
/// raw file in a Git repository). Lumen has no built-in catalog and no server: a catalog only
/// lists packages; each is downloaded, checked against its listed SHA-256 and reviewed like any
/// other package.
public struct PluginCatalog: Sendable, Hashable, Identifiable {
    public typealias ID = Identifier<PluginCatalog>

    public let id: ID
    public let url: URL
    /// The name the catalog gives itself; `nil` until it was fetched.
    public var name: String?
    public var entries: [PluginCatalogEntry]
    public let addedAt: Date
    public var refreshedAt: Date?

    public init(id: ID = ID(), url: URL, name: String? = nil, entries: [PluginCatalogEntry] = [], addedAt: Date, refreshedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.entries = entries
        self.addedAt = addedAt
        self.refreshedAt = refreshedAt
    }

    /// The catalog's name, or its host before it was fetched.
    public var displayName: String {
        name ?? url.host ?? url.absoluteString
    }
}

/// One package a catalog lists.
public struct PluginCatalogEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let version: PluginVersion
    public let publisher: String
    public let summary: String
    /// `https` address of the `.lumenplugin` file.
    public let url: URL
    /// Lowercase hexadecimal SHA-256 of the file; a download that doesn't match is refused.
    public let sha256: String

    public init(id: String, name: String, version: PluginVersion, publisher: String, summary: String, url: URL, sha256: String) {
        self.id = id
        self.name = name
        self.version = version
        self.publisher = publisher
        self.summary = summary
        self.url = url
        self.sha256 = sha256
    }
}
