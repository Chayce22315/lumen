import Foundation
import Testing
import LumenFoundation
import LumenPlugins

@Suite("Plugin packages: signatures, trust, updates, links and catalogs")
struct PluginTrustAndFormatTests {
    // MARK: - Signatures

    @Test("a valid signature yields the publisher key and its fingerprint")
    func validSignature() throws {
        let verified = try testReader.read(TestPackage.sample().data)
        let key = try #require(verified.signature.key)
        #expect(key.rawValue == FakeSigner(seed: 1).publicKey)
        #expect(key.fingerprint.split(separator: " ").count == 8)
        #expect(key.fingerprint.split(separator: " ").allSatisfy { $0.count == 4 })
        #expect(key.fingerprint == key.fingerprint.uppercased())
    }

    @Test("a signature that doesn't match the payload or key is refused")
    func invalidSignature() throws {
        let good = TestPackage.sample()
        // Same signature, edited payload: what a tampered download looks like.
        var envelope = try JSONValue(parsing: String(decoding: good.data, as: UTF8.self))
        var edited = good
        edited.set("name", "Totally Legit")
        if case .object(var fields) = envelope {
            fields["payload"] = .string(edited.payload.base64EncodedString())
            envelope = .object(fields)
        }
        let tampered = try JSONCoding.encoder.encode(envelope)
        #expect(throws: PluginPackageError.signatureInvalid) { try testReader.read(tampered) }

        // A signature by one key presented with another key.
        if case .object(var fields) = try JSONValue(parsing: String(decoding: good.data, as: UTF8.self)),
           case .object(var signature) = fields["signature"] {
            signature["publicKey"] = .string(FakeSigner(seed: 2).publicKey.base64EncodedString())
            fields["signature"] = .object(signature)
            #expect(throws: PluginPackageError.signatureInvalid) { try testReader.read(try JSONCoding.encoder.encode(JSONValue.object(fields))) }
        } else {
            Issue.record("the sample package has no signature")
        }
    }

    @Test("unsigned packages read as unsigned; without Ed25519 signed ones are refused")
    func unsignedAndUnverifiable() throws {
        var unsigned = TestPackage.sample()
        unsigned.signer = nil
        #expect(try testReader.read(unsigned.data).signature == .unsigned)

        let reader = PluginPackageReader(verifier: UnavailableSignatureVerifier(), digest: testDigest)
        #expect(throws: PluginPackageError.signatureUnverifiable) { try reader.read(TestPackage.sample().data) }
        #expect(try reader.read(unsigned.data).signature == .unsigned)
    }

    // MARK: - Trust

    @Test("trust on first use, pinned keys, known keys and refusals")
    func trust() throws {
        let first = testReader.publisherKey(FakeSigner(seed: 1).publicKey)
        let second = testReader.publisherKey(FakeSigner(seed: 2).publicKey)
        let id = "com.example.weekly-review"

        #expect(try PluginTrustEvaluator.evaluate(.signed(first), pluginID: id, installed: []) == .newKey(first))
        #expect(try PluginTrustEvaluator.evaluate(.signed(first), pluginID: id, installed: [(id: "com.example.other", key: first)]) == .knownKey(first, otherPlugins: ["com.example.other"]))
        #expect(try PluginTrustEvaluator.evaluate(.signed(first), pluginID: id, installed: [(id: id, key: first)]) == .pinnedKey(first))
        #expect(try PluginTrustEvaluator.evaluate(.unsigned, pluginID: id, installed: []) == .unsigned)
        // An unsigned install can be updated by a signed package, which pins its key from then on.
        #expect(try PluginTrustEvaluator.evaluate(.signed(second), pluginID: id, installed: [(id: id, key: nil)]) == .newKey(second))
        #expect(try PluginTrustEvaluator.evaluate(.unsigned, pluginID: id, installed: [(id: id, key: nil)]) == .unsigned)

        #expect(throws: PluginPackageError.publisherKeyChanged(pluginID: id, pinned: first.fingerprint, presented: second.fingerprint)) {
            try PluginTrustEvaluator.evaluate(.signed(second), pluginID: id, installed: [(id: id, key: first)])
        }
        #expect(throws: PluginPackageError.signatureRemoved(pluginID: id)) {
            try PluginTrustEvaluator.evaluate(.unsigned, pluginID: id, installed: [(id: id, key: first)])
        }
        let message = PluginPackageError.publisherKeyChanged(pluginID: id, pinned: first.fingerprint, presented: second.fingerprint).presentation.message
        #expect(message.contains(first.fingerprint) && message.contains(second.fingerprint))
    }

    // MARK: - Update diffs

    @Test("an update lists added and removed capabilities, hosts and contributions")
    func updateDiff() throws {
        let old = try testReader.read(TestPackage.sample().data).package
        var next = TestPackage.sample(version: "1.1.0")
        next.set("capabilities", ["contributeCommands", "contributeAssistantPrompts", "contributeWorkflowTemplates"])
        next.set("network", nil)
        next.set("contributions", [
            "workflows": TestPackage.sample().manifest["contributions"]?["workflows"] ?? [],
            "commands": [["id": "open-today", "title": "Review today (new title)", "action": ["type": "openLink", "url": "lumen://tasks/today"]]],
            "prompts": [
                ["id": "plan", "title": "Plan my week", "prompt": "Look at my tasks and propose a plan for the week."],
                ["id": "retro", "title": "Retrospective", "prompt": "What went well?"],
            ],
        ])
        let new = try testReader.read(next.data).package
        let diff = PluginUpdateDiff(from: old, to: new)
        #expect(diff.versionChange == .upgrade)
        #expect(diff.addedCapabilities.isEmpty)
        #expect(diff.removedCapabilities == [.contributeAutomationActions, .network])
        #expect(diff.removedHosts == ["hooks.example.com"])
        #expect(diff.addedHosts.isEmpty)
        #expect(!diff.asksForMore)
        #expect(diff.addedContributions.map(\.key) == ["prompt:retro"])
        #expect(diff.removedContributions.map(\.key) == ["command:run-weekly", "webhook:post-summary"])
        #expect(diff.changedContributions.map(\.key) == ["command:open-today"])
        #expect(diff.hasChanges && diff.contentsChanged)

        let reverse = PluginUpdateDiff(from: new, to: old)
        #expect(reverse.versionChange == .downgrade)
        #expect(reverse.addedCapabilities == [.contributeAutomationActions, .network])
        #expect(reverse.asksForMore)

        let same = PluginUpdateDiff(from: old, to: old)
        #expect(same.versionChange == .same && !same.hasChanges && !same.contentsChanged)
    }

    // MARK: - Install links

    @Test("install links carry one https package address")
    func installLinks() throws {
        let package = try #require(URL(string: "https://raw.githubusercontent.com/example/plugins/main/review.lumenplugin"))
        let link = try #require(PluginInstallLink.link(for: package))
        #expect(link.absoluteString.hasPrefix("lumen://plugin/install?url="))
        #expect(PluginInstallLink.packageURL(from: link) == package)
        #expect(PluginInstallLink.packageURL(from: try #require(URL(string: "lumen://plugin/install?url=https%3A%2F%2Fexample.com%2Fa.lumenplugin"))) == URL(string: "https://example.com/a.lumenplugin"))

        let rejected = [
            "lumen://plugin/install?url=http://example.com/a.lumenplugin",
            "lumen://plugin/install",
            "lumen://plugin/install?url=",
            "lumen://plugin/install?url=https://a.example/x&url=https://b.example/y",
            "lumen://plugin/remove?url=https://example.com/a.lumenplugin",
            "lumen://settings/install?url=https://example.com/a.lumenplugin",
            "https://plugin/install?url=https://example.com/a.lumenplugin",
            "lumen://plugin/install?url=https://user:pass@example.com/a.lumenplugin",
            "lumen://plugin/install?url=file:///etc/passwd",
        ]
        for text in rejected {
            #expect(PluginInstallLink.packageURL(from: try #require(URL(string: text))) == nil, "\(text)")
        }
        #expect(PluginInstallLink.link(for: try #require(URL(string: "http://example.com/a"))) == nil)
        #expect(PluginInstallLink.isPackageFile(URL(fileURLWithPath: "/tmp/Inbox/Review.LumenPlugin")))
        #expect(!PluginInstallLink.isPackageFile(URL(fileURLWithPath: "/tmp/review.json")))
    }

    // MARK: - Catalogs

    @Test("catalog indexes are parsed strictly")
    func catalogs() throws {
        let digest = String(repeating: "ab", count: 32)
        func catalog(_ plugins: [JSONValue], format: String = "app.lumen.plugin-catalog", version: Int = 1) throws -> Data {
            try JSONCoding.encoder.encode(JSONValue.object(["format": .string(format), "schemaVersion": .number(Double(version)), "name": "Example plugins", "plugins": .array(plugins)]))
        }
        let entry: JSONValue = [
            "id": "com.example.weekly-review", "name": "Weekly Review", "version": "1.2.0", "publisher": "Example Co",
            "summary": "Plan the week.", "url": "https://raw.githubusercontent.com/example/plugins/main/review.lumenplugin", "sha256": .string(digest.uppercased()),
        ]
        let index = try PluginCatalogParser.parse(try catalog([entry]))
        #expect(index.name == "Example plugins")
        let parsed = try #require(index.entries.first)
        #expect(parsed.id == "com.example.weekly-review" && parsed.version == PluginVersion(major: 1, minor: 2, patch: 0))
        #expect(parsed.sha256 == digest)

        #expect(throws: PluginPackageError.malformed(path: "format", reason: "This address isn't a Lumen plugin catalog.")) { try PluginCatalogParser.parse(try catalog([entry], format: "other")) }
        #expect(throws: PluginPackageError.unsupportedSchemaVersion(found: 2, supported: 1...1)) { try PluginCatalogParser.parse(try catalog([entry], version: 2)) }
        #expect(throws: PluginPackageError.malformed(path: "plugins[1].id", reason: "The catalog lists this plugin twice.")) { try PluginCatalogParser.parse(try catalog([entry, entry])) }

        func with(_ key: String, _ value: JSONValue) -> JSONValue {
            guard case .object(var fields) = entry else { return entry }
            fields[key] = value
            return .object(fields)
        }
        #expect(throws: PluginPackageError.malformed(path: "plugins[0].url", reason: "Package addresses must start with https://.")) { try PluginCatalogParser.parse(try catalog([with("url", "http://example.com/a.lumenplugin")])) }
        #expect(throws: PluginPackageError.malformed(path: "plugins[0].sha256", reason: "Expected the package's SHA-256 as 64 hexadecimal digits.")) { try PluginCatalogParser.parse(try catalog([with("sha256", "abc")])) }
        #expect(throws: PluginPackageError.malformed(path: "plugins[0].id", reason: "Expected a plugin identifier like com.example.plugin.")) { try PluginCatalogParser.parse(try catalog([with("id", "app.lumen.core")])) }
        #expect(throws: PluginPackageError.malformed(path: "plugins[0].extra", reason: "Lumen doesn't know this key.")) { try PluginCatalogParser.parse(try catalog([with("extra", true)])) }
        let huge = Data(repeating: 0x20, count: PluginCatalogParser.maximumBytes + 1)
        #expect(throws: PluginPackageError.tooLarge(bytes: huge.count, limit: PluginCatalogParser.maximumBytes)) { try PluginCatalogParser.parse(huge) }
    }
}
