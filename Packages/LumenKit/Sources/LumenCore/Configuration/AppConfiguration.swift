import Foundation

/// A named switch for functionality that is still maturing.
public struct FeatureFlag: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Allows activating third-party plugins (built-in features are always active).
    public static let thirdPartyPlugins = FeatureFlag(rawValue: "plugins.thirdParty")
    /// Verbose logging of engine internals.
    public static let verboseLogging = FeatureFlag(rawValue: "diagnostics.verbose")
}

/// Static description of the running build, resolved once at launch by the composition root.
public struct AppConfiguration: Sendable {
    public enum Flavor: String, Sendable, Codable {
        case debug
        case release
        case test
        case preview
    }

    public var flavor: Flavor
    /// Directory holding the database, imported documents and caches.
    public var dataDirectory: URL
    /// App Group shared with the widget extension, if configured.
    public var appGroupIdentifier: String?
    /// Keychain service name for `KeychainSecretStore`.
    public var keychainService: String
    /// Subsystem for unified logging.
    public var logSubsystem: String
    public var featureFlags: Set<FeatureFlag>
    public var appVersion: String
    public var buildNumber: String

    public init(
        flavor: Flavor,
        dataDirectory: URL,
        appGroupIdentifier: String? = nil,
        keychainService: String = "app.lumen.secrets",
        logSubsystem: String = "app.lumen",
        featureFlags: Set<FeatureFlag> = [],
        appVersion: String = "0.0.0",
        buildNumber: String = "0"
    ) {
        self.flavor = flavor
        self.dataDirectory = dataDirectory
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainService = keychainService
        self.logSubsystem = logSubsystem
        self.featureFlags = featureFlags
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        featureFlags.contains(flag)
    }

    public var databaseURL: URL {
        dataDirectory.appendingPathComponent("Lumen.sqlite")
    }

    public var documentsDirectory: URL {
        dataDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Where the app writes the snapshot the widget extension renders.
    public var widgetSnapshotURL: URL {
        dataDirectory.appendingPathComponent("WidgetSnapshot.json")
    }
}
