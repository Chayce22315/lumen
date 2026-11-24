import Foundation

/// The `.lumenplugin` file format.
///
/// A package is UTF-8 JSON:
///
/// ```json
/// {
///   "format": "app.lumen.plugin",
///   "formatVersion": 1,
///   "payload": "<base64 of the manifest JSON bytes>",
///   "signature": { "algorithm": "ed25519", "publicKey": "<base64, 32 bytes>", "value": "<base64, 64 bytes>" }
/// }
/// ```
///
/// `signature` is optional (unsigned packages install only after an extra confirmation). It is
/// detached: it signs `signedMessage(payload:)`, the context string followed by the payload's
/// exact bytes, so no JSON canonicalization is involved. The manifest inside the payload carries
/// its own `schemaVersion`, covered by the signature. Every object is decoded strictly: unknown
/// keys, wrong types and values beyond the limits reject the package before anything is stored.
public enum PluginPackageFormat {
    public static let fileExtension = "lumenplugin"
    /// Uniform Type Identifier the app exports for `.lumenplugin` files.
    public static let typeIdentifier = "app.lumen.plugin"
    public static let mimeType = "application/vnd.lumen.plugin+json"
    /// Value of the envelope's `format` key.
    public static let formatName = "app.lumen.plugin"
    public static let supportedFormatVersions: ClosedRange<Int> = 1...1
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...1
    /// Prepended to the payload before signing, so a signature made for anything else can never
    /// pass as a plugin signature.
    public static let signingContext = Data("app.lumen.plugin.signature.v1".utf8) + Data([0])

    public static func signedMessage(payload: Data) -> Data {
        signingContext + payload
    }

    /// Size and count limits. A package beyond any of them is refused.
    public struct Limits: Sendable, Hashable {
        public var maximumPackageBytes = 512 * 1024
        public var maximumWorkflows = 20
        public var maximumNodesPerWorkflow = 50
        public var maximumCommands = 40
        public var maximumPrompts = 40
        public var maximumWebhooks = 10
        public var maximumWebhookFields = 12
        public var maximumHosts = 10
        public var maximumKeywords = 8
        public var maximumNameLength = 60
        public var maximumTitleLength = 80
        public var maximumDescriptionLength = 1_000
        public var maximumSummaryLength = 300
        public var maximumPromptLength = 4_000
        public var maximumURLLength = 2_048

        public init() {}
    }
}
