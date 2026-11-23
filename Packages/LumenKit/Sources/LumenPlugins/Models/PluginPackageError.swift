import Foundation
import LumenFoundation

/// One problem found while validating a package. `path` locates it in the manifest
/// (`contributions.commands[2].title`); `message` is written for the person installing.
public struct PluginPackageIssue: Sendable, Hashable, Identifiable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var id: String { "\(path)|\(message)" }
}

/// Why a package cannot be installed, downloaded or catalogued.
///
/// `description` (what logs and diagnostics record) names the case and identifiers or versions
/// only — never text taken from a package, which is untrusted content.
public enum PluginPackageError: PresentableError, Equatable, CustomStringConvertible {
    case tooLarge(bytes: Int, limit: Int)
    case malformed(path: String, reason: String)
    case unsupportedFormat
    case unsupportedSchemaVersion(found: Int, supported: ClosedRange<Int>)
    case unknownCapability(String)
    case capabilityNotAllowed(PluginCapability)
    case invalid([PluginPackageIssue])
    case incompatible(required: PluginVersion, available: PluginVersion)
    case signatureInvalid
    case signatureUnverifiable
    case publisherKeyChanged(pluginID: String, pinned: String, presented: String)
    case signatureRemoved(pluginID: String)
    case unsignedNotConfirmed
    case downgrade(pluginID: String, installed: PluginVersion, offered: PluginVersion)
    case digestMismatch(expected: String, actual: String)
    case catalogMismatch(pluginID: String)
    case reviewOutdated(pluginID: String)
    case notInstalled(String)
    case thirdPartyDisabled
    case activationFailed(pluginID: String, message: String)
    case insecureURL
    case downloadFailed(host: String, reason: String)
    case catalogAlreadyAdded
    case unknownCatalog

    public var presentation: ErrorPresentation {
        switch self {
        case .tooLarge(_, let limit):
            return ErrorPresentation(title: "Plugin too large", message: "Plugin packages can be at most \(ByteCountText.text(limit)). This one is larger, so it wasn't opened.")
        case .malformed(let path, let reason):
            let location = path.isEmpty ? "" : " (\(path))"
            return ErrorPresentation(title: "Not a valid plugin", message: "\(reason)\(location)")
        case .unsupportedFormat:
            return ErrorPresentation(title: "Not a Lumen plugin", message: "This file isn't a Lumen plugin package.")
        case .unsupportedSchemaVersion(let found, let supported):
            let newer = found > supported.upperBound
            return ErrorPresentation(
                title: newer ? "Needs a newer Lumen" : "Outdated plugin format",
                message: newer
                    ? "This plugin uses package format \(found); this version of Lumen reads up to \(supported.upperBound)."
                    : "This plugin uses package format \(found), which Lumen no longer reads.",
                recoverySuggestion: newer ? "Update Lumen, then try again." : "Ask the publisher for an updated package."
            )
        case .unknownCapability(let name):
            return ErrorPresentation(
                title: "Unknown permission",
                message: "The plugin asks for “\(name.truncated(to: 40))”, which isn't a permission this version of Lumen knows, so it can't be reviewed or installed.",
                recoverySuggestion: "Update Lumen, or ask the publisher for a package for your version."
            )
        case .capabilityNotAllowed(let capability):
            return ErrorPresentation(title: "Permission not available to plugins", message: "The plugin asks to \(capability.title.lowercased()). Plugin packages are data run by Lumen and can't use that permission.")
        case .invalid(let issues):
            let shown = issues.prefix(3).map { "\($0.message) (\($0.path))" }
            let more = issues.count > 3 ? " And \(issues.count - 3) more." : ""
            return ErrorPresentation(title: "Plugin has problems", message: shown.joined(separator: " ") + more)
        case .incompatible(let required, _):
            return ErrorPresentation(title: "Needs a newer Lumen", message: "This plugin needs Lumen plugin platform \(required) or newer.", recoverySuggestion: "Update Lumen, then try again.")
        case .signatureInvalid:
            return ErrorPresentation(title: "Signature doesn't match", message: "The plugin's signature doesn't match its contents. It may have been changed after it was signed, so it won't be installed.")
        case .signatureUnverifiable:
            return ErrorPresentation(title: "Can't check the signature", message: "Signatures can't be verified on this device, so signed plugins can't be installed here.")
        case .publisherKeyChanged(_, let pinned, let presented):
            return ErrorPresentation(
                title: "Signed by someone else",
                message: "This update is signed with key \(presented), but the installed plugin was signed with key \(pinned). Lumen refuses updates from a different key, because anyone can claim a publisher's name.",
                recoverySuggestion: "If the publisher really changed its key, uninstall the plugin and install the new package after checking with them."
            )
        case .signatureRemoved:
            return ErrorPresentation(
                title: "Update isn't signed",
                message: "The installed plugin is signed, but this update isn't. Lumen refuses it, because an unsigned update could come from anyone.",
                recoverySuggestion: "Get a signed update from the publisher."
            )
        case .unsignedNotConfirmed:
            return ErrorPresentation(title: "Confirm the unsigned plugin", message: "This plugin isn't signed. Confirm that you trust where it came from before installing it.")
        case .downgrade(_, let installed, let offered):
            return ErrorPresentation(
                title: "Older version",
                message: "Version \(installed) is installed; this package is the older \(offered).",
                recoverySuggestion: "To go back, uninstall the plugin first."
            )
        case .digestMismatch:
            return ErrorPresentation(title: "Download doesn't match", message: "The downloaded package isn't the one the catalog lists (its SHA-256 differs), so it won't be installed.")
        case .catalogMismatch:
            return ErrorPresentation(title: "Download doesn't match", message: "The downloaded package is a different plugin or version than the catalog lists.")
        case .reviewOutdated:
            return ErrorPresentation(title: "Plugin changed", message: "The installed plugin changed while you were reviewing this one.", recoverySuggestion: "Review the package again.", isRetryable: true)
        case .notInstalled:
            return ErrorPresentation(title: "Plugin not installed", message: "That plugin isn't installed.")
        case .thirdPartyDisabled:
            return ErrorPresentation(title: "Plugins are off", message: "This build of Lumen doesn't allow third-party plugins.")
        case .activationFailed(_, let message):
            return ErrorPresentation(title: "Plugin didn't start", message: "\(message) Nothing was changed.")
        case .insecureURL:
            return ErrorPresentation(title: "Address not allowed", message: "Plugins and catalogs can only be downloaded from https:// addresses.")
        case .downloadFailed(let host, let reason):
            return ErrorPresentation(title: "Download failed", message: "Lumen couldn't download from \(host). \(reason)", isRetryable: true)
        case .catalogAlreadyAdded:
            return ErrorPresentation(title: "Catalog already added", message: "That catalog is already in your list.")
        case .unknownCatalog:
            return ErrorPresentation(title: "Catalog not found", message: "That catalog was removed.")
        }
    }

    public var description: String {
        switch self {
        case .tooLarge(let bytes, let limit): return "tooLarge(bytes: \(bytes), limit: \(limit))"
        case .malformed: return "malformed"
        case .unsupportedFormat: return "unsupportedFormat"
        case .unsupportedSchemaVersion(let found, let supported): return "unsupportedSchemaVersion(found: \(found), supported: \(supported))"
        case .unknownCapability: return "unknownCapability"
        case .capabilityNotAllowed(let capability): return "capabilityNotAllowed(\(capability.rawValue))"
        case .invalid(let issues): return "invalid(paths: \(issues.map(\.path).joined(separator: ", ")))"
        case .incompatible(let required, let available): return "incompatible(required: \(required), available: \(available))"
        case .signatureInvalid: return "signatureInvalid"
        case .signatureUnverifiable: return "signatureUnverifiable"
        case .publisherKeyChanged(let id, let pinned, let presented): return "publisherKeyChanged(\(id), pinned: \(pinned), presented: \(presented))"
        case .signatureRemoved(let id): return "signatureRemoved(\(id))"
        case .unsignedNotConfirmed: return "unsignedNotConfirmed"
        case .downgrade(let id, let installed, let offered): return "downgrade(\(id), installed: \(installed), offered: \(offered))"
        case .digestMismatch(let expected, let actual): return "digestMismatch(expected: \(expected), actual: \(actual))"
        case .catalogMismatch(let id): return "catalogMismatch(\(id))"
        case .reviewOutdated(let id): return "reviewOutdated(\(id))"
        case .notInstalled(let id): return "notInstalled(\(id))"
        case .thirdPartyDisabled: return "thirdPartyDisabled"
        case .activationFailed(let id, _): return "activationFailed(\(id))"
        case .insecureURL: return "insecureURL"
        case .downloadFailed: return "downloadFailed"
        case .catalogAlreadyAdded: return "catalogAlreadyAdded"
        case .unknownCatalog: return "unknownCatalog"
        }
    }
}

/// Byte counts for messages, without depending on a formatter's locale data (identical on every
/// platform, which keeps messages testable).
enum ByteCountText {
    static func text(_ bytes: Int) -> String {
        if bytes >= 1_048_576, bytes % 1_048_576 == 0 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1_024 { return "\(bytes / 1_024) KB" }
        return "\(bytes) bytes"
    }
}
