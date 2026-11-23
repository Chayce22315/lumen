import Foundation
import LumenFoundation

/// A third-party plugin as distributed: a `.lumenplugin` file.
///
/// iOS does not allow loading code, so a package is data — a manifest of contributions that
/// Lumen's own engines execute (workflow templates, commands, assistant prompts, webhook steps).
/// The file is a JSON envelope holding the manifest's exact bytes (`payload`) and a detached
/// Ed25519 signature over them; see `PluginPackageFormat` for the layout and limits.
public struct PluginPackage: Sendable, Hashable {
    /// Version of the envelope layout.
    public let formatVersion: Int
    /// The manifest bytes exactly as signed.
    public let payload: Data
    public let signature: PluginSignature?
    public let manifest: PluginPackageManifest
    /// SHA-256 of the whole file, lowercase hexadecimal. Catalogs list this value.
    public let sha256: String
    /// The file as received, kept so the package can be read again and shown as source.
    public let data: Data

    public init(formatVersion: Int, payload: Data, signature: PluginSignature?, manifest: PluginPackageManifest, sha256: String, data: Data) {
        self.formatVersion = formatVersion
        self.payload = payload
        self.signature = signature
        self.manifest = manifest
        self.sha256 = sha256
        self.data = data
    }

    public var isSigned: Bool { signature != nil }

    /// The manifest JSON pretty-printed for "view source"; the payload itself when it cannot be
    /// re-rendered (it was parsed once already, so this does not happen in practice).
    public var manifestSource: String {
        if let object = try? JSONSerialization.jsonObject(with: payload),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: payload, as: UTF8.self)
    }
}

/// A detached Ed25519 signature and the publisher key that made it.
public struct PluginSignature: Sendable, Hashable {
    public static let algorithm = "ed25519"
    public static let publicKeyByteCount = 32
    public static let signatureByteCount = 64

    /// Raw 32-byte Ed25519 public key.
    public let publicKey: Data
    /// Raw 64-byte signature of `PluginPackageFormat.signedMessage(payload:)`.
    public let value: Data

    public init(publicKey: Data, value: Data) {
        self.publicKey = publicKey
        self.value = value
    }
}

/// Who published a plugin, as the package states it. Only a valid signature ties a package to a
/// key; the name is what the publisher calls itself.
public struct PluginPublisher: Sendable, Hashable, Codable {
    public let name: String
    public let url: URL?

    public init(name: String, url: URL? = nil) {
        self.name = name
        self.url = url
    }
}

/// The signed part of a package.
public struct PluginPackageManifest: Sendable, Hashable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: PluginVersion
    public let publisher: PluginPublisher
    public let description: String
    /// The lowest Lumen plugin platform version (`PluginHost.hostVersion`) the package works with.
    public let minimumLumenVersion: PluginVersion
    public let capabilities: Set<PluginCapability>
    /// Hosts the package's webhook steps may contact, lowercased, in declared order.
    public let networkHosts: [String]
    public let contributions: PluginContributions

    public init(
        schemaVersion: Int,
        id: String,
        name: String,
        version: PluginVersion,
        publisher: PluginPublisher,
        description: String,
        minimumLumenVersion: PluginVersion,
        capabilities: Set<PluginCapability>,
        networkHosts: [String],
        contributions: PluginContributions
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.publisher = publisher
        self.description = description
        self.minimumLumenVersion = minimumLumenVersion
        self.capabilities = capabilities
        self.networkHosts = networkHosts
        self.contributions = contributions
    }

    /// The host-facing manifest. Every capability is optional: the user may deny any of them and
    /// keep what the rest allow.
    public var pluginManifest: PluginManifest {
        PluginManifest(
            id: id,
            name: name,
            summary: description.truncated(to: 300),
            author: publisher.name,
            version: version,
            capabilities: capabilities,
            optionalCapabilities: capabilities,
            minimumHostVersion: minimumLumenVersion
        )
    }
}

/// Everything a package adds to Lumen.
public struct PluginContributions: Sendable, Hashable {
    public var workflows: [WorkflowTemplateContribution]
    public var commands: [CommandContribution]
    public var prompts: [PromptContribution]
    public var webhooks: [WebhookContribution]

    public init(
        workflows: [WorkflowTemplateContribution] = [],
        commands: [CommandContribution] = [],
        prompts: [PromptContribution] = [],
        webhooks: [WebhookContribution] = []
    ) {
        self.workflows = workflows
        self.commands = commands
        self.prompts = prompts
        self.webhooks = webhooks
    }

    public var count: Int { workflows.count + commands.count + prompts.count + webhooks.count }
    public var isEmpty: Bool { count == 0 }

    public func workflow(_ id: String) -> WorkflowTemplateContribution? {
        workflows.first { $0.id == id }
    }

    /// Every contribution as a kind, identifier and title, for listings and update diffs.
    public var references: [PluginContributionReference] {
        workflows.map { PluginContributionReference(kind: .workflow, id: $0.id, title: $0.name) }
            + commands.map { PluginContributionReference(kind: .command, id: $0.id, title: $0.title) }
            + prompts.map { PluginContributionReference(kind: .prompt, id: $0.id, title: $0.title) }
            + webhooks.map { PluginContributionReference(kind: .webhook, id: $0.id, title: $0.title) }
    }
}

/// Identifies one contribution of a package.
public struct PluginContributionReference: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case workflow, command, prompt, webhook

        public var title: String {
            switch self {
            case .workflow: return "Automation template"
            case .command: return "Command"
            case .prompt: return "Assistant shortcut"
            case .webhook: return "Automation step"
            }
        }
    }

    public let kind: Kind
    public let id: String
    public let title: String

    public init(kind: Kind, id: String, title: String) {
        self.kind = kind
        self.id = id
        self.title = title
    }

    public var key: String { "\(kind.rawValue):\(id)" }
}

/// A ready-made automation. The trigger and graph are in the automation engine's JSON form; the
/// application layer decodes and validates them with the engine's validator before install.
public struct WorkflowTemplateContribution: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let trigger: JSONValue
    public let graph: JSONValue

    public init(id: String, name: String, summary: String, trigger: JSONValue, graph: JSONValue) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.graph = graph
    }
}

/// A command-palette entry.
public struct CommandContribution: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        /// Navigates to a `lumen://` deep link.
        case openLink(URL)
        /// Runs the automation added from one of the package's own workflow templates.
        case runWorkflow(templateID: String)
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let action: Action

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String] = [], action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.action = action
    }
}

/// A saved assistant prompt.
public struct PromptContribution: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let prompt: String

    public init(id: String, title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

/// An automation step that sends its fields as a JSON `POST` to a fixed HTTPS address on one of
/// the package's declared hosts.
public struct WebhookContribution: Sendable, Hashable, Identifiable {
    public struct Field: Sendable, Hashable {
        public let name: String
        public let title: String
        public let isMultiline: Bool
        public let isRequired: Bool

        public init(name: String, title: String, isMultiline: Bool = false, isRequired: Bool = false) {
            self.name = name
            self.title = title
            self.isMultiline = isMultiline
            self.isRequired = isRequired
        }
    }

    public let id: String
    public let title: String
    public let summary: String
    public let url: URL
    public let fields: [Field]

    public init(id: String, title: String, summary: String, url: URL, fields: [Field]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.url = url
        self.fields = fields
    }

    /// The lowercased host the step contacts.
    public var host: String { url.host?.lowercased() ?? "" }
}
