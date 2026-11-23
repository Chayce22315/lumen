import Foundation
import LumenFoundation

/// Parses a catalog index strictly:
///
/// ```json
/// {
///   "format": "app.lumen.plugin-catalog",
///   "schemaVersion": 1,
///   "name": "Example plugins",
///   "plugins": [
///     { "id": "com.example.review", "name": "Weekly Review", "version": "1.2.0",
///       "publisher": "Example", "summary": "…",
///       "url": "https://raw.githubusercontent.com/example/plugins/main/review.lumenplugin",
///       "sha256": "<64 lowercase hex digits>" }
///   ]
/// }
/// ```
public enum PluginCatalogParser {
    public static let formatName = "app.lumen.plugin-catalog"
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...1
    public static let maximumBytes = 256 * 1024
    public static let maximumEntries = 200

    public struct Index: Sendable, Hashable {
        public let name: String?
        public let entries: [PluginCatalogEntry]
    }

    public static func parse(_ data: Data) throws -> Index {
        guard data.count <= maximumBytes else { throw PluginPackageError.tooLarge(bytes: data.count, limit: maximumBytes) }
        var root = try StrictJSONObject.parse(data, path: "")
        guard try root.string("format", maxLength: 100, required: false) == formatName else {
            throw PluginPackageError.malformed(path: "format", reason: "This address isn't a Lumen plugin catalog.")
        }
        let version = try root.integer("schemaVersion")
        guard supportedSchemaVersions.contains(version) else {
            throw PluginPackageError.unsupportedSchemaVersion(found: version, supported: supportedSchemaVersions)
        }
        let name = try root.string("name", maxLength: 80, required: false)
        var seen = Set<String>()
        let entries = try root.array("plugins", maxCount: maximumEntries, required: true).map { item -> PluginCatalogEntry in
            var object = try StrictJSONObject(item.value, path: item.path)
            let id = try object.requiredString("id", maxLength: PluginIdentifier.maximumLength)
            guard PluginIdentifier.isValid(id), !id.lowercased().hasPrefix(PluginIdentifier.reservedPrefix) else {
                throw PluginPackageError.malformed(path: object.childPath("id"), reason: "Expected a plugin identifier like com.example.plugin.")
            }
            guard seen.insert(id).inserted else {
                throw PluginPackageError.malformed(path: object.childPath("id"), reason: "The catalog lists this plugin twice.")
            }
            let entryName = try object.requiredString("name", maxLength: 60)
            let entryVersion = try PluginPackageDecoder.version(try object.requiredString("version", maxLength: 32), path: object.childPath("version"))
            let publisher = try object.requiredString("publisher", maxLength: 80)
            let summary = try object.string("summary", maxLength: 300, required: false, allowEmpty: true) ?? ""
            let url = try PluginPackageDecoder.url(try object.requiredString("url", maxLength: 2_048), path: object.childPath("url"))
            guard PluginInstallLink.isAllowedDownload(url) else {
                throw PluginPackageError.malformed(path: object.childPath("url"), reason: "Package addresses must start with https://.")
            }
            let digest = try object.requiredString("sha256", maxLength: 64).lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw PluginPackageError.malformed(path: object.childPath("sha256"), reason: "Expected the package's SHA-256 as 64 hexadecimal digits.")
            }
            try object.finish()
            return PluginCatalogEntry(id: id, name: entryName, version: entryVersion, publisher: publisher, summary: summary, url: url, sha256: digest)
        }
        try root.finish()
        return Index(name: name, entries: entries)
    }
}
