import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenTestSupport

// MARK: - Manager harness

let promptPoint = ExtensionPoint<String>("test.prompts", requires: .contributeAssistantPrompts)
let webhookPoint = ExtensionPoint<String>("test.webhooks", requires: .contributeAutomationActions)

/// Contributes a package's commands and prompts as strings, skipping what isn't granted, the
/// way the application's packaged plugin does.
struct TestPackagedPlugin: LumenPlugin {
    let installed: InstalledPlugin
    let failActivation: Bool

    var manifest: PluginManifest { installed.manifest.pluginManifest }

    func activate(_ context: PluginContext) async throws {
        if failActivation { throw PluginError.serviceUnavailable("test") }
        let contributions = installed.manifest.contributions
        if context.has(.contributeCommands) {
            for command in contributions.commands { try context.contribute("\(installed.id).\(command.id)", to: commandPoint) }
        }
        if context.has(.contributeAssistantPrompts) {
            for prompt in contributions.prompts { try context.contribute(prompt.title, to: promptPoint) }
        }
        if context.has(.contributeAutomationActions), context.has(.network) {
            for webhook in contributions.webhooks where installed.grantedHosts.contains(webhook.host) {
                try context.contribute(webhook.id, to: webhookPoint)
            }
        }
    }
}

final class TestIntegration: PluginPackageIntegration {
    let failingPlugins = Mutex<Set<String>>([])
    let removed = Mutex<[PluginOwnedEntity]>([])
    let report = Mutex(PluginContentReport())

    func makePlugin(for installed: InstalledPlugin) -> any LumenPlugin {
        TestPackagedPlugin(installed: installed, failActivation: failingPlugins.withLock { $0.contains("\(installed.id)@\(installed.manifest.version)") })
    }

    func contentReport(for manifest: PluginPackageManifest) async -> PluginContentReport {
        report.withLock { $0 }
    }

    func removeOwnedEntities(_ entities: [PluginOwnedEntity]) async throws {
        removed.withLock { $0 += entities }
    }
}

/// Serves fixed bodies by URL.
final class FakeDownloader: PluginPackageDownloading {
    let bodies = Mutex<[URL: Data]>([:])
    let requests = Mutex<[URL]>([])

    func download(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        requests.withLock { $0.append(url) }
        guard let body = bodies.withLock({ $0[url] }) else {
            throw PluginPackageError.downloadFailed(host: url.host ?? "", reason: "Not found (404).")
        }
        guard body.count <= limit else { throw PluginPackageError.downloadFailed(host: url.host ?? "", reason: "Too large.") }
        return body
    }
}

struct ManagerHarness {
    let environment: CoreTestEnvironment
    let registry: ExtensionRegistry
    let host: PluginHost
    let manager: PluginPackageManager
    let integration: TestIntegration
    let downloader: FakeDownloader

    static func make(allowsThirdParty: Bool = true, verifier: any PluginSignatureVerifier = FakeSignatureVerifier(), environment: CoreTestEnvironment? = nil, integration: TestIntegration = TestIntegration()) async throws -> ManagerHarness {
        let environment = if let environment { environment } else { try await CoreTestEnvironment.make(schemas: [PluginHost.schema]) }
        let registry = ExtensionRegistry()
        let host = PluginHost(database: environment.database, registry: registry, services: Services(), events: environment.events,
                              timeSource: environment.clock, logging: environment.logging, allowsThirdParty: allowsThirdParty)
        let downloader = FakeDownloader()
        let manager = PluginPackageManager(
            database: environment.database, host: host, events: environment.events, timeSource: environment.clock,
            logger: environment.logger("plugins"), verifier: verifier, digest: testDigest, integration: integration, downloader: downloader
        )
        return ManagerHarness(environment: environment, registry: registry, host: host, manager: manager, integration: integration, downloader: downloader)
    }

    /// Reviews and installs with the review's suggestions plus `grant`, confirming unsigned.
    @discardableResult
    func install(_ package: TestPackage, grant: Set<PluginCapability> = PluginCapability.packageCapabilities, hosts: Set<String> = ["hooks.example.com"]) async throws -> PluginState {
        let review = try await manager.review(package.data, source: .file)
        return try await manager.install(review, choices: PluginInstallChoices(capabilities: grant, hosts: hosts, confirmsUnsigned: true))
    }
}

@Suite("Plugin packages: install, update, permissions and uninstall")
struct PluginPackageManagerTests {
    let id = "com.example.weekly-review"

    @Test("install registers contributions; uninstall removes them and the plugin's data")
    func installAndUninstall() async throws {
        let harness = try await ManagerHarness.make()
        let recorder = EventRecorder(bus: harness.environment.events, filter: EventFilter(modules: ["plugins"]))
        let review = try await harness.manager.review(TestPackage.sample().data, source: .file)
        #expect(!review.isUpdate)
        #expect(review.trust == .newKey(testReader.publisherKey(FakeSigner(seed: 1).publicKey)))
        // Low-risk capabilities start on; the network and every host start off.
        #expect(review.suggestedCapabilities == [.contributeCommands, .contributeWorkflowTemplates, .contributeAssistantPrompts, .contributeAutomationActions])
        #expect(review.suggestedHosts.isEmpty)

        let state = try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: PluginCapability.packageCapabilities, hosts: ["hooks.example.com"]))
        #expect(state == .active)
        #expect(harness.registry.contributions(to: commandPoint) == ["\(id).open-today", "\(id).run-weekly"])
        #expect(harness.registry.contributions(to: promptPoint) == ["Plan my week"])
        #expect(harness.registry.contributions(to: webhookPoint) == ["post-summary"])
        let installed = try #require(try await harness.manager.installedPlugin(id))
        #expect(installed.grantedHosts == ["hooks.example.com"])
        #expect(installed.source == .file)

        let workflow = EntityReference(kind: "workflow", id: UUID())
        try await harness.manager.recordOwnedEntity(PluginOwnedEntity(pluginID: id, contributionKey: "workflow:weekly", entity: workflow, createdAt: harness.environment.clock.now()))
        #expect(try await harness.manager.ownedEntity(pluginID: id, contributionKey: "workflow:weekly")?.entity == workflow)

        try await harness.manager.uninstall(id)
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
        #expect(harness.registry.contributions(to: promptPoint).isEmpty)
        #expect(await harness.host.state(of: id) == nil)
        #expect(try await harness.manager.installed().isEmpty)
        #expect(harness.integration.removed.withLock { $0.map(\.entity) } == [workflow])
        #expect(try await harness.manager.ownedEntities(of: id).isEmpty)
        let grants = try await harness.environment.database.read { db in try db.queryFirst("SELECT * FROM plugins_registry WHERE plugin_id = ?", [id]) }
        #expect(grants == nil)
        await #expect(throws: PluginPackageError.notInstalled(id)) { try await harness.manager.uninstall(id) }

        let names = await recorder.waitForEvents(4).map(\.name)
        #expect(names.contains(PluginPackageManager.packageInstalledEvent))
        #expect(names.contains(PluginPackageManager.packageUninstalledEvent))
        // Events carry identifiers and versions only.
        let installedEvent = try #require(recorder.events.first { $0.name == PluginPackageManager.packageInstalledEvent })
        #expect(installedEvent.attributes == ["plugin": .string(id), "version": "1.0.0", "signed": true])
    }

    @Test("denied capabilities and hosts withhold exactly their contributions")
    func permissionDenial() async throws {
        let harness = try await ManagerHarness.make()
        try await harness.install(.sample(), grant: [.contributeAssistantPrompts, .contributeAutomationActions, .network], hosts: [])
        // Active with what was granted: no commands, the prompt, and no webhook without its host.
        #expect(await harness.host.state(of: id) == .active)
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
        #expect(harness.registry.contributions(to: promptPoint) == ["Plan my week"])
        #expect(harness.registry.contributions(to: webhookPoint).isEmpty)

        try await harness.manager.updatePermissions(of: id, capabilities: [.contributeCommands, .contributeAutomationActions, .network], hosts: ["hooks.example.com", "undeclared.example.com"])
        #expect(harness.registry.contributions(to: commandPoint).count == 2)
        #expect(harness.registry.contributions(to: promptPoint).isEmpty)
        #expect(harness.registry.contributions(to: webhookPoint) == ["post-summary"])
        // Hosts the package didn't declare are never granted.
        #expect(try await harness.manager.installedPlugin(id)?.grantedHosts == ["hooks.example.com"])

        try await harness.host.setEnabled(false, for: id)
        try await harness.manager.updatePermissions(of: id, capabilities: [.contributeCommands], hosts: [])
        #expect(await harness.host.state(of: id) == .disabled)
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
    }

    @Test("unsigned packages need an explicit confirmation")
    func unsignedConfirmation() async throws {
        let harness = try await ManagerHarness.make()
        var package = TestPackage.sample()
        package.signer = nil
        let review = try await harness.manager.review(package.data, source: .file)
        #expect(review.trust == .unsigned && review.requiresUnsignedConfirmation)
        await #expect(throws: PluginPackageError.unsignedNotConfirmed) {
            try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: [.contributeCommands], hosts: []))
        }
        #expect(try await harness.manager.installed().isEmpty)
        try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: [.contributeCommands], hosts: [], confirmsUnsigned: true))
        #expect(try await harness.manager.installed().count == 1)
    }

    @Test("updates keep grants, show what changed and refuse other keys, removed signatures and downgrades")
    func updates() async throws {
        let harness = try await ManagerHarness.make()
        try await harness.install(.sample(), grant: [.contributeCommands, .contributeAssistantPrompts], hosts: [])

        var next = TestPackage.sample(version: "1.1.0")
        next.set("contributions", [
            "workflows": TestPackage.sample().manifest["contributions"]?["workflows"] ?? [],
            "commands": TestPackage.sample().manifest["contributions"]?["commands"] ?? [],
            "prompts": [["id": "retro", "title": "Retrospective", "prompt": "What went well?"]],
            "webhooks": TestPackage.sample().manifest["contributions"]?["webhooks"] ?? [],
        ])
        let review = try await harness.manager.review(next.data, source: .link(try #require(URL(string: "https://example.com/r.lumenplugin"))))
        #expect(review.isUpdate)
        #expect(review.trust == .pinnedKey(testReader.publisherKey(FakeSigner(seed: 1).publicKey)))
        let diff = try #require(review.diff)
        #expect(diff.versionChange == .upgrade)
        #expect(diff.addedContributions.map(\.key) == ["prompt:retro"])
        #expect(diff.removedContributions.map(\.key) == ["prompt:plan"])
        // What was granted stays granted; what was denied stays denied.
        #expect(review.installedGrants == [.contributeCommands, .contributeAssistantPrompts])
        #expect(review.suggestedCapabilities == [.contributeCommands, .contributeAssistantPrompts])
        try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: review.suggestedCapabilities, hosts: review.suggestedHosts))
        #expect(harness.registry.contributions(to: promptPoint) == ["Retrospective"])
        let updated = try #require(try await harness.manager.installedPlugin(id))
        #expect(updated.manifest.version == PluginVersion(major: 1, minor: 1, patch: 0))
        #expect(updated.source == .link(try #require(URL(string: "https://example.com/r.lumenplugin"))))

        var otherKey = TestPackage.sample(version: "1.2.0")
        otherKey.signer = FakeSigner(seed: 9)
        await #expect(throws: PluginPackageError.self) { try await harness.manager.review(otherKey.data, source: .file) }
        do {
            _ = try await harness.manager.review(otherKey.data, source: .file)
        } catch PluginPackageError.publisherKeyChanged(let plugin, _, _) {
            #expect(plugin == id)
        }

        var unsigned = TestPackage.sample(version: "1.2.0")
        unsigned.signer = nil
        await #expect(throws: PluginPackageError.signatureRemoved(pluginID: id)) { try await harness.manager.review(unsigned.data, source: .file) }
        await #expect(throws: PluginPackageError.downgrade(pluginID: id, installed: PluginVersion(major: 1, minor: 1, patch: 0), offered: PluginVersion(major: 1, minor: 0, patch: 0))) {
            try await harness.manager.review(TestPackage.sample().data, source: .file)
        }

        // A review made before another install landed is refused rather than overwriting it.
        let stale = try await harness.manager.review(TestPackage.sample(version: "1.3.0").data, source: .file)
        try await harness.install(.sample(version: "1.4.0"))
        await #expect(throws: PluginPackageError.reviewOutdated(pluginID: id)) {
            try await harness.manager.install(stale, choices: PluginInstallChoices(capabilities: [], hosts: []))
        }
    }

    @Test("a plugin that fails to start is rolled back to what was there")
    func activationRollback() async throws {
        let harness = try await ManagerHarness.make()
        harness.integration.failingPlugins.withLock { $0 = ["\(id)@1.0.0"] }
        await #expect(throws: PluginPackageError.self) { try await harness.install(.sample()) }
        #expect(try await harness.manager.installed().isEmpty)
        #expect(await harness.host.state(of: id) == nil)
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)

        harness.integration.failingPlugins.withLock { $0 = ["\(id)@2.0.0"] }
        try await harness.install(.sample(), grant: [.contributeCommands], hosts: [])
        do {
            try await harness.install(.sample(version: "2.0.0"))
            Issue.record("the failing update installed")
        } catch PluginPackageError.activationFailed(let plugin, _) {
            #expect(plugin == id)
        }
        #expect(try await harness.manager.installedPlugin(id)?.manifest.version == PluginVersion(major: 1, minor: 0, patch: 0))
        #expect(await harness.host.state(of: id) == .active)
        #expect(try await harness.host.grantedCapabilities(of: id) == [.contributeCommands])
        #expect(harness.registry.contributions(to: commandPoint).count == 2)
    }

    @Test("installed packages are read and verified again at launch")
    func relaunch() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [PluginHost.schema])
        let first = try await ManagerHarness.make(environment: environment)
        try await first.install(.sample(), grant: [.contributeCommands], hosts: [])

        let second = try await ManagerHarness.make(environment: environment)
        await second.manager.registerInstalled()
        await second.host.activateAll()
        #expect(await second.host.state(of: id) == .active)
        #expect(second.registry.contributions(to: commandPoint).count == 2)

        // A stored package whose signature no longer verifies starts as failed and can be removed.
        try await environment.database.write { db in
            try db.execute("UPDATE plugins_packages SET publisher_key = ? WHERE plugin_id = ?", [FakeSigner(seed: 5).publicKey.base64EncodedString(), "com.example.weekly-review"])
        }
        let third = try await ManagerHarness.make(environment: environment)
        await third.manager.registerInstalled()
        await third.host.activateAll()
        guard case .failed = await third.host.state(of: id) else {
            Issue.record("expected the tampered package to fail")
            return
        }
        #expect(third.registry.contributions(to: commandPoint).isEmpty)
        try await third.manager.uninstall(id)
        #expect(try await third.manager.installedVersions().isEmpty)
    }

    @Test("content problems found by the application block installing; warnings don't")
    func contentReport() async throws {
        let harness = try await ManagerHarness.make()
        harness.integration.report.withLock { $0 = PluginContentReport(errors: [PluginPackageIssue(path: "manifest.contributions.workflows[0].graph", message: "Unknown step.")]) }
        await #expect(throws: PluginPackageError.invalid([PluginPackageIssue(path: "manifest.contributions.workflows[0].graph", message: "Unknown step.")])) {
            try await harness.manager.review(TestPackage.sample().data, source: .file)
        }
        let warning = PluginPackageIssue(path: "manifest.contributions.workflows[0].trigger", message: "No feature announces this event.")
        harness.integration.report.withLock { $0 = PluginContentReport(warnings: [warning]) }
        #expect(try await harness.manager.review(TestPackage.sample().data, source: .file).warnings == [warning])

        var future = TestPackage.sample()
        future.set("minimumLumenVersion", "9.0.0")
        await #expect(throws: PluginPackageError.incompatible(required: PluginVersion(major: 9, minor: 0, patch: 0), available: PluginHost.hostVersion)) {
            try await harness.manager.review(future.data, source: .file)
        }
    }

    @Test("without the feature flag nothing is installed")
    func featureFlag() async throws {
        let harness = try await ManagerHarness.make(allowsThirdParty: false)
        let review = try await harness.manager.review(TestPackage.sample().data, source: .file)
        await #expect(throws: PluginPackageError.thirdPartyDisabled) {
            try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: [], hosts: []))
        }
    }

    @Test("downloads go through the downloader and only over https")
    func downloads() async throws {
        let harness = try await ManagerHarness.make()
        let url = try #require(URL(string: "https://example.com/weekly.lumenplugin"))
        harness.downloader.bodies.withLock { $0[url] = TestPackage.sample().data }
        let review = try await harness.manager.reviewDownload(from: url)
        #expect(review.source == .link(url))
        await #expect(throws: PluginPackageError.insecureURL) { try await harness.manager.reviewDownload(from: try #require(URL(string: "http://example.com/weekly.lumenplugin"))) }
        #expect(harness.downloader.requests.withLock { $0 } == [url])
    }

    @Test("catalogs list packages that install through the same review, checked against their digest")
    func catalogs() async throws {
        let harness = try await ManagerHarness.make()
        let catalogURL = try #require(URL(string: "https://raw.githubusercontent.com/example/plugins/main/catalog.json"))
        let packageURL = try #require(URL(string: "https://raw.githubusercontent.com/example/plugins/main/weekly.lumenplugin"))
        let package = TestPackage.sample(version: "1.0.0").data
        func index(sha: String, version: String = "1.0.0") throws -> Data {
            try JSONCoding.encoder.encode(JSONValue.object([
                "format": "app.lumen.plugin-catalog", "schemaVersion": 1, "name": "Example",
                "plugins": [["id": "com.example.weekly-review", "name": "Weekly Review", "version": .string(version), "publisher": "Example Co", "url": .string(packageURL.absoluteString), "sha256": .string(sha)]],
            ]))
        }
        harness.downloader.bodies.withLock {
            $0[catalogURL] = try? index(sha: testDigest(package))
            $0[packageURL] = package
        }
        await #expect(throws: PluginPackageError.insecureURL) { try await harness.manager.addCatalog(try #require(URL(string: "http://example.com/c.json"))) }
        let catalog = try await harness.manager.addCatalog(catalogURL)
        #expect(catalog.name == "Example" && catalog.entries.count == 1)
        await #expect(throws: PluginPackageError.catalogAlreadyAdded) { try await harness.manager.addCatalog(catalogURL) }

        let entry = try #require(catalog.entries.first)
        let review = try await harness.manager.reviewCatalogEntry(entry, from: catalog)
        #expect(review.source == .catalog(catalogURL: catalogURL, packageURL: packageURL))
        try await harness.manager.install(review, choices: PluginInstallChoices(capabilities: [.contributeCommands], hosts: []))
        #expect(try await harness.manager.installedVersions() == ["com.example.weekly-review": PluginVersion(major: 1, minor: 0, patch: 0)])

        // A catalog whose digest doesn't match what downloads is refused.
        harness.downloader.bodies.withLock { $0[catalogURL] = try? index(sha: String(repeating: "0", count: 64)) }
        let refreshed = try await harness.manager.refreshCatalog(catalog.id)
        let wrong = try #require(refreshed.entries.first)
        await #expect(throws: PluginPackageError.digestMismatch(expected: String(repeating: "0", count: 64), actual: testDigest(package))) {
            try await harness.manager.reviewCatalogEntry(wrong, from: refreshed)
        }
        // A catalog that lists another version than the file is refused too.
        harness.downloader.bodies.withLock { $0[catalogURL] = try? index(sha: testDigest(package), version: "3.0.0") }
        let mislabeled = try #require(try await harness.manager.refreshCatalog(catalog.id).entries.first)
        await #expect(throws: PluginPackageError.catalogMismatch(pluginID: "com.example.weekly-review")) {
            try await harness.manager.reviewCatalogEntry(mislabeled, from: refreshed)
        }

        try await harness.manager.removeCatalog(catalog.id)
        #expect(try await harness.manager.catalogs().isEmpty)
        await #expect(throws: PluginPackageError.unknownCatalog) { try await harness.manager.removeCatalog(catalog.id) }
        // Removing a catalog leaves what was installed from it.
        #expect(try await harness.manager.installed().count == 1)
    }
}
