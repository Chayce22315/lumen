import Foundation
import Testing
import LumenFoundation
import LumenPlugins

@Suite("Plugin packages: decoding and validation")
struct PluginPackageDecodingTests {
    func decode(_ package: TestPackage) throws -> PluginPackage {
        try PluginPackageDecoder(digest: testDigest).decode(package.data)
    }

    func issues(_ package: TestPackage) -> [PluginPackageIssue] {
        do {
            _ = try decode(package)
            return []
        } catch PluginPackageError.invalid(let issues) {
            return issues
        } catch {
            Issue.record("expected validation issues, got \(error)")
            return []
        }
    }

    @Test("the sample package decodes with every contribution")
    func sample() throws {
        let package = try decode(.sample())
        let manifest = package.manifest
        #expect(manifest.id == "com.example.weekly-review")
        #expect(manifest.version == PluginVersion(major: 1, minor: 0, patch: 0))
        #expect(manifest.publisher == PluginPublisher(name: "Example Co", url: URL(string: "https://example.com")))
        #expect(manifest.capabilities == PluginCapability.packageCapabilities)
        #expect(manifest.networkHosts == ["hooks.example.com"])
        #expect(manifest.contributions.workflows.map(\.id) == ["weekly"])
        #expect(manifest.contributions.commands.map(\.action) == [.openLink(try #require(URL(string: "lumen://tasks/today"))), .runWorkflow(templateID: "weekly")])
        #expect(manifest.contributions.prompts.first?.prompt.hasPrefix("Look at my tasks") == true)
        let webhook = try #require(manifest.contributions.webhooks.first)
        #expect(webhook.host == "hooks.example.com")
        #expect(webhook.fields == [WebhookContribution.Field(name: "text", title: "Text", isMultiline: true, isRequired: true)])
        #expect(package.isSigned)
        #expect(package.sha256 == testDigest(TestPackage.sample().data))
        #expect(package.sha256.count == 64)
        // The host-facing manifest makes every capability optional, so any can be denied.
        #expect(manifest.pluginManifest.requiredCapabilities.isEmpty)
        #expect(package.manifestSource.contains("com.example.weekly-review") && package.manifestSource.contains("\n"))
    }

    @Test("oversized packages are refused before parsing")
    func oversized() {
        var package = TestPackage.sample()
        package.set("description", .string(String(repeating: "x", count: 600 * 1024)))
        #expect(throws: PluginPackageError.tooLarge(bytes: package.data.count, limit: 512 * 1024)) { try decode(package) }
    }

    @Test("malformed files are refused with the path of the problem")
    func malformed() throws {
        let decoder = PluginPackageDecoder(digest: testDigest)
        #expect(throws: PluginPackageError.malformed(path: "", reason: "The file isn't valid JSON.")) { try decoder.decode(Data("{nope".utf8)) }
        #expect(throws: PluginPackageError.unsupportedFormat) { try decoder.decode(Data(#"{"format":"other","formatVersion":1,"payload":""}"#.utf8)) }
        #expect(throws: PluginPackageError.malformed(path: "payload", reason: "Expected base64-encoded manifest bytes.")) {
            try decoder.decode(Data(#"{"format":"app.lumen.plugin","formatVersion":1,"payload":"%%%"}"#.utf8))
        }

        var unknownEnvelopeKey = TestPackage.sample()
        unknownEnvelopeKey.extraEnvelope = ["script": "rm -rf"]
        #expect(throws: PluginPackageError.malformed(path: "script", reason: "Lumen doesn't know this key.")) { try decode(unknownEnvelopeKey) }

        var unknownManifestKey = TestPackage.sample()
        unknownManifestKey.set("homepage", "https://example.com")
        #expect(throws: PluginPackageError.malformed(path: "manifest.homepage", reason: "Lumen doesn't know this key.")) { try decode(unknownManifestKey) }

        var wrongType = TestPackage.sample()
        wrongType.set("name", 42)
        #expect(throws: PluginPackageError.malformed(path: "manifest.name", reason: "Expected text.")) { try decode(wrongType) }

        var missing = TestPackage.sample()
        missing.set("version", nil)
        #expect(throws: PluginPackageError.malformed(path: "manifest.version", reason: "This value is required.")) { try decode(missing) }

        var badVersion = TestPackage.sample()
        badVersion.set("version", "1.0")
        #expect(throws: PluginPackageError.malformed(path: "manifest.version", reason: "Expected a version like 1.2.0.")) { try decode(badVersion) }

        var badAction = TestPackage.sample()
        badAction.set("contributions", ["commands": [["id": "x", "title": "X", "action": ["type": "shell", "command": "ls"]]]])
        badAction.set("capabilities", ["contributeCommands"])
        badAction.set("network", nil)
        #expect(throws: PluginPackageError.malformed(path: "manifest.contributions.commands[0].action.type", reason: "Commands can open a Lumen link (openLink) or run one of the plugin's workflows (runWorkflow).")) { try decode(badAction) }

        var badSignature = TestPackage.sample()
        badSignature.signer = nil
        badSignature.extraEnvelope = ["signature": ["algorithm": "rsa", "publicKey": "", "value": ""]]
        #expect(throws: PluginPackageError.malformed(path: "signature.algorithm", reason: "Only ed25519 signatures are supported.")) { try decode(badSignature) }
    }

    @Test("an unknown capability is refused with its name; built-in-only ones are not available")
    func capabilities() {
        var unknown = TestPackage.sample()
        unknown.set("capabilities", ["contributeCommands", "readContacts"])
        #expect(throws: PluginPackageError.unknownCapability("readContacts")) { try decode(unknown) }
        #expect(PluginPackageError.unknownCapability("readContacts").presentation.message.contains("“readContacts”, which isn't a permission this version of Lumen knows"))
        // Logs and diagnostics never carry the package's text.
        #expect(PluginPackageError.unknownCapability("readContacts").description == "unknownCapability")

        var builtInOnly = TestPackage.sample()
        builtInOnly.set("capabilities", ["readTasks"])
        #expect(throws: PluginPackageError.capabilityNotAllowed(.readTasks)) { try decode(builtInOnly) }
    }

    @Test("unsupported envelope and manifest versions are refused")
    func schemaVersions() {
        var newerEnvelope = TestPackage.sample()
        newerEnvelope.formatVersion = 2
        #expect(throws: PluginPackageError.unsupportedSchemaVersion(found: 2, supported: 1...1)) { try decode(newerEnvelope) }
        #expect(PluginPackageError.unsupportedSchemaVersion(found: 2, supported: 1...1).presentation.title == "Needs a newer Lumen")

        var newerManifest = TestPackage.sample()
        newerManifest.set("schemaVersion", 3)
        #expect(throws: PluginPackageError.unsupportedSchemaVersion(found: 3, supported: 1...1)) { try decode(newerManifest) }

        var older = TestPackage.sample()
        older.set("schemaVersion", 0)
        #expect(PluginPackageError.unsupportedSchemaVersion(found: 0, supported: 1...1).presentation.title == "Outdated plugin format")
        #expect(throws: PluginPackageError.unsupportedSchemaVersion(found: 0, supported: 1...1)) { try decode(older) }
    }

    @Test("limits on lists and text")
    func limits() {
        var many = TestPackage.sample()
        let commands = (0..<41).map { index -> JSONValue in ["id": .string("c\(index)"), "title": "C", "action": ["type": "openLink", "url": "lumen://home"]] }
        many.set("contributions", ["commands": .array(commands)])
        #expect(throws: PluginPackageError.malformed(path: "manifest.contributions.commands", reason: "This list can have at most 40 entries.")) { try decode(many) }

        var longName = TestPackage.sample()
        longName.set("name", .string(String(repeating: "n", count: 61)))
        #expect(throws: PluginPackageError.malformed(path: "manifest.name", reason: "This value can be at most 60 characters.")) { try decode(longName) }
    }

    @Test("semantic rules: identifiers, permissions, links and hosts")
    func semantics() {
        var reserved = TestPackage.sample(id: "app.lumen.fake")
        reserved.set("name", "Fake")
        #expect(issues(reserved).map(\.path) == ["manifest.id"])

        var unusedCapability = TestPackage.sample()
        unusedCapability.set("contributions", ["prompts": [["id": "p", "title": "P", "prompt": "Hi"]]])
        unusedCapability.set("network", nil)
        let unused = issues(unusedCapability)
        #expect(unused.count == 4)
        #expect(unused.allSatisfy { $0.path == "manifest.capabilities" && $0.message.contains("contributes nothing that uses it") })

        var missingCapability = TestPackage.sample()
        missingCapability.set("capabilities", ["contributeCommands", "contributeWorkflowTemplates", "contributeAssistantPrompts", "contributeAutomationActions"])
        #expect(issues(missingCapability).contains { $0.message == "The plugin's contributions need the network permission, but it doesn't ask for it." })

        var links = TestPackage.sample()
        links.set("contributions", [
            "workflows": TestPackage.sample().manifest["contributions"]?["workflows"] ?? [],
            "commands": [
                ["id": "web", "title": "Web", "action": ["type": "openLink", "url": "https://example.com"]],
                ["id": "install", "title": "Install", "action": ["type": "openLink", "url": "lumen://plugin/install?url=https://evil.example/p.lumenplugin"]],
                ["id": "ghost", "title": "Ghost", "action": ["type": "runWorkflow", "workflow": "missing"]],
                ["id": "ghost", "title": "Dup", "action": ["type": "openLink", "url": "lumen://home"]],
                ["id": "9bad", "title": "Bad", "action": ["type": "openLink", "url": "lumen://home"]],
            ],
            "prompts": TestPackage.sample().manifest["contributions"]?["prompts"] ?? [],
            "webhooks": TestPackage.sample().manifest["contributions"]?["webhooks"] ?? [],
        ])
        let linkIssues = issues(links).map(\.path)
        #expect(linkIssues == [
            "manifest.contributions.commands[3].id",
            "manifest.contributions.commands[4].id",
            "manifest.contributions.commands[0].action.url",
            "manifest.contributions.commands[1].action.url",
            "manifest.contributions.commands[2].action.workflow",
        ])

        var hosts = TestPackage.sample()
        hosts.set("network", ["hosts": ["hooks.example.com", "192.168.1.10", "printer.local", "unused.example.org"]])
        hosts.set("contributions", [
            "webhooks": [
                ["id": "a", "title": "A", "url": "http://hooks.example.com/x"],
                ["id": "b", "title": "B", "url": "https://other.example.com/x"],
                ["id": "c", "title": "C", "url": "https://hooks.example.com:8443/x"],
                ["id": "d", "title": "D", "url": "https://hooks.example.com/x"],
            ],
        ])
        hosts.set("capabilities", ["contributeAutomationActions", "network"])
        #expect(issues(hosts).map(\.path) == [
            "manifest.network.hosts[1]",
            "manifest.network.hosts[2]",
            "manifest.contributions.webhooks[0].url",
            "manifest.contributions.webhooks[1].url",
            "manifest.contributions.webhooks[2].url",
            "manifest.network.hosts[1]",
            "manifest.network.hosts[2]",
            "manifest.network.hosts[3]",
        ])
        #expect(PluginPackageValidator.isValidHost("hooks.example.com"))
        #expect(!PluginPackageValidator.isValidHost("localhost"))
        #expect(!PluginPackageValidator.isValidHost("10.0.0.1"))
        #expect(!PluginPackageValidator.isValidHost("Hooks.Example.com"))
        #expect(!PluginPackageValidator.isValidHost("-bad.example.com"))
    }

    @Test("validation messages never reach logs")
    func redaction() {
        let error = PluginPackageError.invalid([PluginPackageIssue(path: "manifest.name", message: "Secret plan for Q3")])
        #expect(!error.description.contains("Secret"))
        #expect(error.presentation.message.contains("Secret plan for Q3"))
        #expect(PluginPackageError.malformed(path: "manifest.evilKey", reason: "x").description == "malformed")
    }
}
