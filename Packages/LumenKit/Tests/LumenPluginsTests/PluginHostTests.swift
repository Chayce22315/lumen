import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenTestSupport

let commandPoint = ExtensionPoint<String>("test.commands", requires: .contributeCommands)
let toolPoint = ExtensionPoint<String>("test.tools", requires: .contributeAssistantTools)
let readerKey = ServiceKey<String>("test.taskReader", requires: .readTasks)

struct Services: PluginServiceProvider {
    func service(id: String, for pluginID: String) -> (any Sendable)? {
        id == readerKey.id ? "reader for \(pluginID)" : nil
    }
}

final class TestPlugin: LumenPlugin {
    let manifest: PluginManifest
    let failAfterContributing: Bool
    let hang: Bool
    let activations = Mutex(0)
    let deactivations = Mutex(0)
    let serviceResult = Mutex<String?>(nil)

    init(id: String = "com.example.test", capabilities: Set<PluginCapability> = [.contributeCommands], failAfterContributing: Bool = false, hang: Bool = false, minimumHost: PluginVersion = PluginVersion(major: 1, minor: 0, patch: 0)) {
        self.manifest = PluginManifest(id: id, name: "Test", summary: "A test plugin.", author: "Tests", version: PluginVersion(major: 1, minor: 2, patch: 3), capabilities: capabilities, minimumHostVersion: minimumHost)
        self.failAfterContributing = failAfterContributing
        self.hang = hang
    }

    struct Boom: Error {}

    func activate(_ context: PluginContext) async throws {
        activations.withLock { $0 += 1 }
        try context.contribute("command from \(manifest.id)", to: commandPoint)
        if context.has(.readTasks) {
            let reader = try context.service(readerKey)
            serviceResult.withLock { $0 = reader }
        }
        if hang { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if failAfterContributing { throw Boom() }
    }

    func deactivate() async {
        deactivations.withLock { $0 += 1 }
    }
}

struct PluginHarness {
    let environment: CoreTestEnvironment
    let registry: ExtensionRegistry
    let host: PluginHost

    static func make(allowsThirdParty: Bool = true, timeout: TimeInterval = 5) async throws -> PluginHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [PluginHost.schema])
        let registry = ExtensionRegistry()
        let host = PluginHost(database: environment.database, registry: registry, services: Services(), events: environment.events,
                              timeSource: environment.clock, logging: environment.logging, allowsThirdParty: allowsThirdParty, activationTimeout: timeout)
        return PluginHarness(environment: environment, registry: registry, host: host)
    }
}

@Suite("Plugins")
struct PluginHostTests {
    @Test("manifests are validated")
    func manifestValidation() {
        let good = TestPlugin().manifest
        #expect(good.validationIssues().isEmpty)
        var bad = good
        bad = PluginManifest(id: "noDots", name: " ", summary: "", author: "", version: good.version, capabilities: [])
        #expect(bad.validationIssues().count == 2)
        #expect(PluginVersion("1.10.0").map { $0 > PluginVersion(major: 1, minor: 9, patch: 9) } == true)
        #expect(PluginVersion("1.0") == nil)
    }

    @Test("built-in plugins are granted their declared capabilities and activate")
    func builtIn() async throws {
        let harness = try await PluginHarness.make(allowsThirdParty: false)
        let plugin = TestPlugin(id: "app.lumen.builtin", capabilities: [.contributeCommands, .readTasks])
        try await harness.host.register(plugin, isBuiltIn: true)
        await harness.host.activateAll()
        #expect(await harness.host.state(of: "app.lumen.builtin") == .active)
        #expect(harness.registry.contributions(to: commandPoint) == ["command from app.lumen.builtin"])
        #expect(plugin.serviceResult.withLock { $0 } == "reader for app.lumen.builtin")
    }

    @Test("third-party plugins wait for permission and are blocked when the flag is off")
    func thirdPartyPermissions() async throws {
        let harness = try await PluginHarness.make()
        let plugin = TestPlugin(capabilities: [.contributeCommands, .readTasks])
        try await harness.host.register(plugin, isBuiltIn: false)
        #expect(await harness.host.activate(plugin.manifest.id) == .needsPermission([.contributeCommands, .readTasks]))
        try await harness.host.grant([.contributeCommands, .readTasks, .network], to: plugin.manifest.id)
        #expect(await harness.host.activate(plugin.manifest.id) == .active)
        let status = try #require(await harness.host.statuses().first)
        // Undeclared capabilities are never granted.
        #expect(status.grantedCapabilities == [.contributeCommands, .readTasks])

        let blocked = try await PluginHarness.make(allowsThirdParty: false)
        try await blocked.host.register(TestPlugin(), isBuiltIn: false)
        #expect(await blocked.host.activate("com.example.test") == .blocked)
    }

    @Test("revoking a capability restarts the plugin without it")
    func revoke() async throws {
        let harness = try await PluginHarness.make()
        let plugin = TestPlugin(capabilities: [.contributeCommands])
        try await harness.host.register(plugin, isBuiltIn: false)
        try await harness.host.grant([.contributeCommands], to: plugin.manifest.id)
        await harness.host.activate(plugin.manifest.id)
        try await harness.host.revoke([.contributeCommands], from: plugin.manifest.id)
        #expect(await harness.host.state(of: plugin.manifest.id) == .needsPermission([.contributeCommands]))
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
        #expect(plugin.deactivations.withLock { $0 } == 1)
    }

    @Test("a failing activation rolls back its contributions")
    func failureRollsBack() async throws {
        let harness = try await PluginHarness.make()
        let plugin = TestPlugin(id: "app.lumen.flaky", failAfterContributing: true)
        try await harness.host.register(plugin, isBuiltIn: true)
        let state = await harness.host.activate("app.lumen.flaky")
        guard case .failed = state else {
            Issue.record("expected failure, got \(state)")
            return
        }
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
        #expect(harness.environment.logs.entries(atLeast: .error).count == 1)
    }

    @Test("a plugin that hangs during activation is timed out")
    func timeout() async throws {
        let harness = try await PluginHarness.make(timeout: 0.05)
        try await harness.host.register(TestPlugin(id: "app.lumen.slow", hang: true), isBuiltIn: true)
        let state = await harness.host.activate("app.lumen.slow")
        #expect(state == .failed(PluginError.activationTimedOut("app.lumen.slow").presentation.message))
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
    }

    @Test("contexts reject undeclared and ungranted capabilities")
    func contextChecks() async throws {
        let harness = try await PluginHarness.make()
        final class Sneaky: LumenPlugin {
            let manifest = PluginManifest(id: "com.example.sneaky", name: "Sneaky", summary: "", author: "", version: PluginVersion(major: 1, minor: 0, patch: 0), capabilities: [.contributeCommands])
            let error = Mutex<PluginError?>(nil)
            func activate(_ context: PluginContext) async throws {
                do {
                    try context.contribute("tool", to: toolPoint)
                } catch let error as PluginError {
                    self.error.withLock { $0 = error }
                }
            }
        }
        let sneaky = Sneaky()
        try await harness.host.register(sneaky, isBuiltIn: false)
        try await harness.host.grant([.contributeCommands], to: sneaky.manifest.id)
        #expect(await harness.host.activate(sneaky.manifest.id) == .active)
        #expect(sneaky.error.withLock { $0 } == .undeclaredCapability(plugin: "com.example.sneaky", capability: .contributeAssistantTools))
        #expect(harness.registry.contributions(to: toolPoint).isEmpty)
    }

    @Test("disabling, incompatibility, duplicates and uninstall")
    func lifecycle() async throws {
        let harness = try await PluginHarness.make()
        let plugin = TestPlugin(id: "app.lumen.feature")
        try await harness.host.register(plugin, isBuiltIn: true)
        await #expect(throws: PluginError.duplicatePlugin("app.lumen.feature")) {
            try await harness.host.register(TestPlugin(id: "app.lumen.feature"), isBuiltIn: true)
        }
        await harness.host.activate("app.lumen.feature")
        try await harness.host.setEnabled(false, for: "app.lumen.feature")
        #expect(await harness.host.state(of: "app.lumen.feature") == .disabled)
        #expect(harness.registry.contributions(to: commandPoint).isEmpty)
        // The choice persists: a new host keeps it disabled.
        let second = PluginHost(database: harness.environment.database, registry: ExtensionRegistry(), services: Services(), events: harness.environment.events,
                                timeSource: harness.environment.clock, logging: harness.environment.logging, allowsThirdParty: true)
        try await second.register(TestPlugin(id: "app.lumen.feature"), isBuiltIn: true)
        #expect(await second.activate("app.lumen.feature") == .disabled)
        await #expect(throws: PluginError.builtInCannotBeRemoved("app.lumen.feature")) { try await harness.host.uninstall("app.lumen.feature") }

        try await harness.host.register(TestPlugin(id: "com.example.future", minimumHost: PluginVersion(major: 9, minor: 0, patch: 0)), isBuiltIn: false)
        #expect(await harness.host.activate("com.example.future") == .incompatible)
        try await harness.host.uninstall("com.example.future")
        #expect(await harness.host.state(of: "com.example.future") == nil)
    }
}
