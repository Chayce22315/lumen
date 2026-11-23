import Foundation
import LumenFoundation

/// Decodes `.lumenplugin` files strictly (see `PluginPackageFormat`) and validates what they
/// declare. Signature checks are separate (`PluginPackageReader`), so this stays pure.
public struct PluginPackageDecoder: Sendable {
    public let limits: PluginPackageFormat.Limits
    private let digest: @Sendable (Data) -> String

    /// - Parameter digest: SHA-256 of the given bytes as lowercase hexadecimal.
    public init(limits: PluginPackageFormat.Limits = PluginPackageFormat.Limits(), digest: @escaping @Sendable (Data) -> String) {
        self.limits = limits
        self.digest = digest
    }

    /// Decodes and validates a package. Throws `PluginPackageError` describing the first
    /// structural problem, or every semantic problem at once (`.invalid`).
    public func decode(_ data: Data) throws -> PluginPackage {
        guard data.count <= limits.maximumPackageBytes else {
            throw PluginPackageError.tooLarge(bytes: data.count, limit: limits.maximumPackageBytes)
        }
        var envelope = try StrictJSONObject.parse(data, path: "")
        let format = try envelope.string("format", maxLength: 100, required: false)
        guard format == PluginPackageFormat.formatName else { throw PluginPackageError.unsupportedFormat }
        let formatVersion = try envelope.integer("formatVersion")
        guard PluginPackageFormat.supportedFormatVersions.contains(formatVersion) else {
            throw PluginPackageError.unsupportedSchemaVersion(found: formatVersion, supported: PluginPackageFormat.supportedFormatVersions)
        }
        let encodedPayload = try envelope.requiredString("payload", maxLength: limits.maximumPackageBytes)
        guard let payload = Data(base64Encoded: encodedPayload) else {
            throw PluginPackageError.malformed(path: "payload", reason: "Expected base64-encoded manifest bytes.")
        }
        let signature = try envelope.object("signature", required: false).map(Self.signature(from:))
        try envelope.finish()

        let manifest = try decodeManifest(payload)
        let issues = PluginPackageValidator(limits: limits).issues(in: manifest)
        guard issues.isEmpty else { throw PluginPackageError.invalid(issues) }
        return PluginPackage(formatVersion: formatVersion, payload: payload, signature: signature, manifest: manifest, sha256: digest(data), data: data)
    }

    private static func signature(from object: StrictJSONObject) throws -> PluginSignature {
        var object = object
        let algorithm = try object.requiredString("algorithm", maxLength: 40)
        guard algorithm == PluginSignature.algorithm else {
            throw PluginPackageError.malformed(path: object.childPath("algorithm"), reason: "Only ed25519 signatures are supported.")
        }
        let key = Data(base64Encoded: try object.requiredString("publicKey", maxLength: 200))
        guard let key, key.count == PluginSignature.publicKeyByteCount else {
            throw PluginPackageError.malformed(path: object.childPath("publicKey"), reason: "Expected a base64-encoded 32-byte Ed25519 public key.")
        }
        let value = Data(base64Encoded: try object.requiredString("value", maxLength: 200))
        guard let value, value.count == PluginSignature.signatureByteCount else {
            throw PluginPackageError.malformed(path: object.childPath("value"), reason: "Expected a base64-encoded 64-byte Ed25519 signature.")
        }
        try object.finish()
        return PluginSignature(publicKey: key, value: value)
    }

    // MARK: - Manifest

    func decodeManifest(_ payload: Data) throws -> PluginPackageManifest {
        var root = try StrictJSONObject.parse(payload, path: "manifest")
        let schemaVersion = try root.integer("schemaVersion")
        guard PluginPackageFormat.supportedSchemaVersions.contains(schemaVersion) else {
            throw PluginPackageError.unsupportedSchemaVersion(found: schemaVersion, supported: PluginPackageFormat.supportedSchemaVersions)
        }
        // Capabilities first: an unknown or disallowed one is the clearest reason to refuse.
        let capabilities = try Self.capabilities(try root.stringArray("capabilities", maxCount: PluginCapability.allCases.count, maxLength: 60))
        let id = try root.requiredString("id", maxLength: PluginIdentifier.maximumLength)
        let name = try root.requiredString("name", maxLength: limits.maximumNameLength)
        let version = try Self.version(try root.requiredString("version", maxLength: 32), path: root.childPath("version"))
        let minimum = try Self.version(try root.requiredString("minimumLumenVersion", maxLength: 32), path: root.childPath("minimumLumenVersion"))
        let description = try root.string("description", maxLength: limits.maximumDescriptionLength, required: false, allowEmpty: true) ?? ""
        let publisher = try publisher(try root.object("publisher"))
        var hosts: [String] = []
        if var network = try root.object("network", required: false) {
            hosts = try network.stringArray("hosts", maxCount: limits.maximumHosts, maxLength: 253, required: true).map { $0.lowercased() }
            try network.finish()
        }
        let contributions = try decodeContributions(try root.object("contributions", required: false))
        try root.finish()
        return PluginPackageManifest(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            version: version,
            publisher: publisher,
            description: description,
            minimumLumenVersion: minimum,
            capabilities: capabilities,
            networkHosts: hosts.reduce(into: [String]()) { unique, host in if !unique.contains(host) { unique.append(host) } },
            contributions: contributions
        )
    }

    static func capabilities(_ names: [String]) throws -> Set<PluginCapability> {
        var result = Set<PluginCapability>()
        for name in names {
            guard let capability = PluginCapability(rawValue: name) else { throw PluginPackageError.unknownCapability(name) }
            guard PluginCapability.packageCapabilities.contains(capability) else { throw PluginPackageError.capabilityNotAllowed(capability) }
            result.insert(capability)
        }
        return result
    }

    static func version(_ text: String, path: String) throws -> PluginVersion {
        guard let version = PluginVersion(text) else {
            throw PluginPackageError.malformed(path: path, reason: "Expected a version like 1.2.0.")
        }
        return version
    }

    private func publisher(_ object: StrictJSONObject?) throws -> PluginPublisher {
        guard var object else { throw PluginPackageError.malformed(path: "manifest.publisher", reason: "This value is required.") }
        let name = try object.requiredString("name", maxLength: limits.maximumTitleLength)
        let url = try object.string("url", maxLength: limits.maximumURLLength, required: false).map { try Self.url($0, path: object.childPath("url")) }
        try object.finish()
        return PluginPublisher(name: name, url: url)
    }

    static func url(_ text: String, path: String) throws -> URL {
        guard let url = URL(string: text), url.scheme != nil else {
            throw PluginPackageError.malformed(path: path, reason: "Expected an address.")
        }
        return url
    }

    private func decodeContributions(_ object: StrictJSONObject?) throws -> PluginContributions {
        guard var object else { return PluginContributions() }
        let workflows = try object.array("workflows", maxCount: limits.maximumWorkflows).map(workflow)
        let commands = try object.array("commands", maxCount: limits.maximumCommands).map(command)
        let prompts = try object.array("prompts", maxCount: limits.maximumPrompts).map(prompt)
        let webhooks = try object.array("webhooks", maxCount: limits.maximumWebhooks).map(webhook)
        try object.finish()
        return PluginContributions(workflows: workflows, commands: commands, prompts: prompts, webhooks: webhooks)
    }

    private func workflow(_ item: (value: JSONValue, path: String)) throws -> WorkflowTemplateContribution {
        var object = try StrictJSONObject(item.value, path: item.path)
        let id = try object.requiredString("id", maxLength: 40)
        let name = try object.requiredString("name", maxLength: limits.maximumNameLength)
        let summary = try object.string("summary", maxLength: limits.maximumSummaryLength, required: false, allowEmpty: true) ?? ""
        let trigger = try object.rawObject("trigger")
        let graph = try object.rawObject("graph")
        try object.finish()
        let nodes = graph["nodes"]?.arrayValue?.count ?? 0
        guard nodes <= limits.maximumNodesPerWorkflow else {
            throw PluginPackageError.malformed(path: "\(item.path).graph.nodes", reason: "A workflow can have at most \(limits.maximumNodesPerWorkflow) steps.")
        }
        return WorkflowTemplateContribution(id: id, name: name, summary: summary, trigger: trigger, graph: graph)
    }

    private func command(_ item: (value: JSONValue, path: String)) throws -> CommandContribution {
        var object = try StrictJSONObject(item.value, path: item.path)
        let id = try object.requiredString("id", maxLength: 40)
        let title = try object.requiredString("title", maxLength: limits.maximumTitleLength)
        let subtitle = try object.string("subtitle", maxLength: limits.maximumTitleLength, required: false)
        let keywords = try object.stringArray("keywords", maxCount: limits.maximumKeywords, maxLength: 30)
        guard var action = try object.object("action") else {
            throw PluginPackageError.malformed(path: object.childPath("action"), reason: "This value is required.")
        }
        let type = try action.requiredString("type", maxLength: 40)
        let resolved: CommandContribution.Action
        switch type {
        case "openLink":
            resolved = .openLink(try Self.url(try action.requiredString("url", maxLength: limits.maximumURLLength), path: action.childPath("url")))
        case "runWorkflow":
            resolved = .runWorkflow(templateID: try action.requiredString("workflow", maxLength: 40))
        default:
            throw PluginPackageError.malformed(path: action.childPath("type"), reason: "Commands can open a Lumen link (openLink) or run one of the plugin's workflows (runWorkflow).")
        }
        try action.finish()
        try object.finish()
        return CommandContribution(id: id, title: title, subtitle: subtitle, keywords: keywords, action: resolved)
    }

    private func prompt(_ item: (value: JSONValue, path: String)) throws -> PromptContribution {
        var object = try StrictJSONObject(item.value, path: item.path)
        let id = try object.requiredString("id", maxLength: 40)
        let title = try object.requiredString("title", maxLength: limits.maximumNameLength)
        let prompt = try object.requiredString("prompt", maxLength: limits.maximumPromptLength)
        try object.finish()
        return PromptContribution(id: id, title: title, prompt: prompt)
    }

    private func webhook(_ item: (value: JSONValue, path: String)) throws -> WebhookContribution {
        var object = try StrictJSONObject(item.value, path: item.path)
        let id = try object.requiredString("id", maxLength: 40)
        let title = try object.requiredString("title", maxLength: limits.maximumNameLength)
        let summary = try object.string("summary", maxLength: limits.maximumSummaryLength, required: false, allowEmpty: true) ?? ""
        let url = try Self.url(try object.requiredString("url", maxLength: limits.maximumURLLength), path: object.childPath("url"))
        let fields = try object.array("fields", maxCount: limits.maximumWebhookFields).map { field -> WebhookContribution.Field in
            var entry = try StrictJSONObject(field.value, path: field.path)
            let name = try entry.requiredString("name", maxLength: 40)
            let title = try entry.requiredString("title", maxLength: limits.maximumNameLength)
            let multiline = try entry.bool("multiline", default: false)
            let required = try entry.bool("required", default: false)
            try entry.finish()
            return WebhookContribution.Field(name: name, title: title, isMultiline: multiline, isRequired: required)
        }
        try object.finish()
        return WebhookContribution(id: id, title: title, summary: summary, url: url, fields: fields)
    }
}
