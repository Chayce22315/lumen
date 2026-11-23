import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenIntelligence
import LumenAutomation
import LumenPlugins
import LumenApplication
import LumenTestSupport

// MARK: - Fakes

/// A stand-in for Ed25519 in Linux tests: the "signature" is the SHA-256 of key and message, so
/// it verifies only for the exact payload and key it was made for.
struct DigestSignatureVerifier: PluginSignatureVerifier {
    static func sign(_ message: Data, key: Data) -> Data {
        Data(SHA256.hash(key + message) + SHA256.hash(message + key))
    }

    func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool {
        signature == Self.sign(message, key: publicKey)
    }
}

/// Answers requests by URL and records what was sent.
final class RecordingTransport: HTTPStreamingTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data
    }

    let replies = Mutex<[URL: Reply]>([:])
    let requests = Mutex<[HTTPRequest]>([])

    func send(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        requests.withLock { $0.append(request) }
        let reply = replies.withLock { $0[request.url] } ?? Reply(status: 404, body: Data())
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            if !reply.body.isEmpty { continuation.yield(reply.body) }
            continuation.finish()
        }
        return HTTPStreamResponse(status: reply.status, headers: [:], body: stream)
    }
}

/// The sample package for application tests: a weekly-review automation that creates a task
/// and posts to a webhook, commands, and an assistant shortcut.
struct SamplePackage {
    static let id = "com.example.weekly-review"
    static let triggerNode = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    static let taskNode = "7A9619FF-8B86-D011-B42D-00C04FC964FF"
    static let postNode = "8B9619FF-8B86-D011-B42D-00C04FC964FF"
    static let webhookURL = "https://hooks.example.com/lumen"

    var manifest: [String: JSONValue]
    var key = Data(repeating: 7, count: 32)
    var signed = true

    init(version: String = "1.0.0", workflowSteps: [JSONValue]? = nil, edges: [JSONValue]? = nil) {
        let steps: [JSONValue] = workflowSteps ?? [
            ["id": .string(Self.triggerNode), "title": "Start", "kind": ["type": "trigger"]],
            ["id": .string(Self.taskNode), "title": "Add review task", "kind": [
                "type": "action", "actionID": "organization.createTask",
                "parameters": ["title": ["type": "literal", "value": "Weekly review"]],
            ]],
            ["id": .string(Self.postNode), "title": "Post", "kind": [
                "type": "action", "actionID": .string("\(Self.id).post-summary"),
                "parameters": ["text": ["type": "template", "template": .string("Created {{steps.\(Self.taskNode).output.title}}")]],
            ]],
        ]
        let links: [JSONValue] = edges ?? [
            ["from": .string(Self.triggerNode), "to": .string(Self.taskNode), "port": "next"],
            ["from": .string(Self.taskNode), "to": .string(Self.postNode), "port": "next"],
        ]
        manifest = [
            "schemaVersion": 1,
            "id": .string(Self.id),
            "name": "Weekly Review",
            "version": .string(version),
            "publisher": ["name": "Example Co"],
            "description": "Plan the week ahead.",
            "minimumLumenVersion": "1.0.0",
            "capabilities": ["contributeWorkflowTemplates", "contributeCommands", "contributeAssistantPrompts", "contributeAutomationActions", "network"],
            "network": ["hosts": ["hooks.example.com"]],
            "contributions": [
                "workflows": [["id": "weekly", "name": "Weekly review", "summary": "Adds a review task.", "trigger": ["type": "manual"], "graph": ["nodes": .array(steps), "edges": .array(links)]]],
                "commands": [
                    ["id": "open-today", "title": "Review today", "action": ["type": "openLink", "url": "lumen://tasks/today"]],
                    ["id": "run-weekly", "title": "Run weekly review", "action": ["type": "runWorkflow", "workflow": "weekly"]],
                ],
                "prompts": [["id": "plan", "title": "Plan my week", "prompt": "Propose a plan for my week."]],
                "webhooks": [["id": "post-summary", "title": "Post summary", "url": .string(Self.webhookURL), "fields": [["name": "text", "title": "Text", "required": true]]]],
            ],
        ]
    }

    var data: Data {
        let payload = (try? JSONCoding.encoder.encode(JSONValue.object(manifest))) ?? Data()
        var envelope: [String: JSONValue] = ["format": "app.lumen.plugin", "formatVersion": 1, "payload": .string(payload.base64EncodedString())]
        if signed {
            let signature = DigestSignatureVerifier.sign(PluginPackageFormat.signedMessage(payload: payload), key: key)
            envelope["signature"] = ["algorithm": "ed25519", "publicKey": .string(key.base64EncodedString()), "value": .string(signature.base64EncodedString())]
        }
        return (try? JSONCoding.encoder.encode(JSONValue.object(envelope))) ?? Data()
    }
}

struct PluginApp {
    let services: LumenServices
    let runtime: LumenRuntime
    let transport: RecordingTransport
    let logs: LogCapture
    let directory: URL

    static func start() async throws -> PluginApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-plugins-\(UUID().uuidString)")
        let transport = RecordingTransport()
        let logs = LogCapture()
        var platform = PlatformServices(secrets: InMemorySecretStore(), notificationScheduler: CountingScheduler(), httpTransport: transport, additionalLogSinks: [logs])
        platform.pluginSignatureVerifier = DigestSignatureVerifier()
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: ManualTimeSource(),
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        await runtime.start()
        return PluginApp(services: services, runtime: runtime, transport: transport, logs: logs, directory: directory)
    }

    var packages: PluginPackageManager { services.plugins.packages }

    func install(_ package: SamplePackage, capabilities: Set<PluginCapability> = PluginCapability.packageCapabilities, hosts: Set<String> = ["hooks.example.com"]) async throws {
        let review = try await packages.review(package.data, source: .file)
        try await packages.install(review, choices: PluginInstallChoices(capabilities: capabilities, hosts: hosts))
    }

    func stop() async {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Tests

@Suite("Plugin distribution in the running app")
struct PluginDistributionTests {
    let commandID = "plugin.\(SamplePackage.id).open-today"
    let runCommandID = "plugin.\(SamplePackage.id).run-weekly"
    let webhookAction = AutomationActionID("\(SamplePackage.id).post-summary")

    @Test("third-party plugins are allowed by default and packages are hashed with SHA-256")
    func defaults() async throws {
        let app = try await PluginApp.start()
        #expect(app.services.plugins.allowsThirdParty)
        let data = SamplePackage().data
        let review = try await app.packages.review(data, source: .file)
        #expect(review.package.sha256 == SHA256.hexDigest(of: data))
        #expect(review.warnings.isEmpty)
        await app.stop()
    }

    @Test("an installed package contributes commands, templates, shortcuts and a webhook step; uninstalling removes them all")
    func lifecycle() async throws {
        let app = try await PluginApp.start()
        let services = app.services
        let webhook = try #require(URL(string: SamplePackage.webhookURL))
        app.transport.replies.withLock { $0[webhook] = .init(status: 200, body: Data("ok".utf8)) }
        try await app.install(SamplePackage())

        #expect(await eventually { services.commands.action(for: commandID) != nil && services.automation.catalog.action(webhookAction) != nil })
        guard case .navigate(let destination) = services.commands.action(for: commandID) else {
            Issue.record("the link command doesn't navigate")
            return
        }
        #expect(destination == .tasks(.today))
        #expect(services.commands.registry.all.contains { $0.id == commandID && $0.category == "Weekly Review" })
        #expect(services.plugins.promptShortcuts().map(\.title) == ["Plan my week"])

        // Templates become workflows that start off, once.
        let template = try #require(services.plugins.templates.templates().first)
        #expect(template.name == "Weekly review" && template.pluginID == SamplePackage.id)
        let workflow = try await services.plugins.templates.add(template)
        #expect(!workflow.isEnabled)
        #expect(try await services.plugins.templates.add(template).id == workflow.id)

        // The run command runs that workflow: it creates the task and posts to the webhook.
        guard case .perform(let work) = services.commands.action(for: runCommandID) else {
            Issue.record("the workflow command doesn't perform")
            return
        }
        let result = try await work()
        #expect(result.message == "Ran “Weekly review”.")
        #expect(try await services.organization.tasks.list(.inbox).contains { $0.title == "Weekly review" })
        let posted = try #require(app.transport.requests.withLock { $0.last })
        #expect(posted.method == "POST" && posted.url.absoluteString == SamplePackage.webhookURL)
        #expect(posted.headers["content-type"] == "application/json")
        #expect(try JSONValue(parsing: posted.bodyText ?? "") == ["text": "Created Weekly review"])
        // The plugin's logs carry its identifier and the status, never what was sent.
        #expect(!app.logs.recorded.contains { $0.message.contains("Created Weekly review") || $0.metadata.values.contains { $0.contains("Created Weekly review") } })

        try await app.packages.uninstall(SamplePackage.id)
        #expect(await eventually { services.commands.action(for: commandID) == nil && services.automation.catalog.action(webhookAction) == nil })
        #expect(services.plugins.templates.templates().isEmpty)
        #expect(services.plugins.promptShortcuts().isEmpty)
        #expect(try await services.automation.engine.workflow(workflow.id) == nil)
        #expect(try await app.packages.installed().isEmpty)
        await app.stop()
    }

    @Test("denied capabilities and hosts withhold their contributions; granting them later adds them")
    func permissions() async throws {
        let app = try await PluginApp.start()
        let services = app.services
        try await app.install(SamplePackage(), capabilities: [.contributeCommands, .contributeAutomationActions, .network], hosts: [])
        #expect(await eventually { services.commands.action(for: commandID) != nil })
        // Without the templates capability the template and its run command are withheld; without
        // the host the webhook step is.
        #expect(services.commands.action(for: runCommandID) == nil)
        #expect(services.plugins.templates.templates().isEmpty)
        #expect(services.plugins.promptShortcuts().isEmpty)
        #expect(services.automation.catalog.action(webhookAction) == nil)

        try await app.packages.updatePermissions(of: SamplePackage.id, capabilities: PluginCapability.packageCapabilities, hosts: ["hooks.example.com"])
        #expect(await eventually { services.automation.catalog.action(webhookAction) != nil && services.commands.action(for: runCommandID) != nil })

        // Revoking the host removes the step; a workflow using it no longer validates.
        let workflow = try await services.plugins.templates.add(try #require(services.plugins.templates.templates().first))
        try await app.packages.updatePermissions(of: SamplePackage.id, capabilities: PluginCapability.packageCapabilities, hosts: [])
        #expect(await eventually { services.automation.catalog.action(webhookAction) == nil })
        await #expect(throws: AutomationError.self) { try await services.automation.engine.run(workflow.id) }
        #expect(!app.transport.requests.withLock { $0.contains { $0.url.host == "hooks.example.com" } })
        await app.stop()
    }

    @Test("webhook steps refuse hosts that weren't allowed and classify failures")
    func webhookResponses() async throws {
        let app = try await PluginApp.start()
        let url = try #require(URL(string: SamplePackage.webhookURL))
        try await app.install(SamplePackage())
        #expect(await eventually { app.services.automation.catalog.action(webhookAction) != nil })
        let action = try #require(app.services.automation.catalog.action(webhookAction))
        func invoke(_ text: String) async throws -> ActionOutcome {
            try await action.perform(ActionInvocation(parameters: ["text": .string(text)], context: ActionContext(actor: .automation), runID: WorkflowRun.ID(), workflowID: Workflow.ID(), nodeID: WorkflowNode.ID(), attempt: 1))
        }
        app.transport.replies.withLock { $0[url] = .init(status: 503, body: Data()) }
        await #expect(throws: AutomationActionError.transient("hooks.example.com answered 503. Lumen will retry.")) { try await invoke("x") }
        app.transport.replies.withLock { $0[url] = .init(status: 400, body: Data()) }
        await #expect(throws: AutomationActionError.permanent("hooks.example.com refused the request (400).")) { try await invoke("x") }
        await #expect(throws: AutomationActionError.permanent("“Text” is required.")) { try await invoke(" ") }
        app.transport.replies.withLock { $0[url] = .init(status: 204, body: Data()) }
        #expect(try await invoke("x").output == ["status": 204])
        await app.stop()
    }

    @Test("templates are checked with the automation validator and links with the app's destinations")
    func contentChecks() async throws {
        let app = try await PluginApp.start()
        let unknownAction = SamplePackage(workflowSteps: [
            ["id": .string(SamplePackage.triggerNode), "title": "Start", "kind": ["type": "trigger"]],
            ["id": .string(SamplePackage.taskNode), "title": "Wipe", "kind": ["type": "action", "actionID": "com.other.plugin.wipe"]],
        ], edges: [["from": .string(SamplePackage.triggerNode), "to": .string(SamplePackage.taskNode), "port": "next"]])
        do {
            _ = try await app.packages.review(unknownAction.data, source: .file)
            Issue.record("a template with an unknown step was accepted")
        } catch PluginPackageError.invalid(let issues) {
            #expect(issues.map(\.path).contains("manifest.contributions.workflows[0].graph.nodes[1]"))
        }

        var badLink = SamplePackage()
        if case .object(var contributions) = badLink.manifest["contributions"] {
            contributions["commands"] = [["id": "nowhere", "title": "Nowhere", "action": ["type": "openLink", "url": "lumen://nowhere"]]]
            contributions["workflows"] = SamplePackage().manifest["contributions"]?["workflows"]
            badLink.manifest["contributions"] = .object(contributions)
        }
        await #expect(throws: PluginPackageError.invalid([PluginPackageIssue(path: "manifest.contributions.commands[0].action.url", message: "This link doesn't open a place in Lumen.")])) {
            try await app.packages.review(badLink.data, source: .file)
        }

        var event = SamplePackage()
        if case .object(var contributions) = event.manifest["contributions"], case .array(var workflows) = contributions["workflows"], case .object(var first) = workflows[0] {
            first["trigger"] = ["type": "event", "name": "com.example.never"]
            workflows[0] = .object(first)
            contributions["workflows"] = .array(workflows)
            event.manifest["contributions"] = .object(contributions)
        }
        let review = try await app.packages.review(event.data, source: .file)
        #expect(review.warnings.map(\.path) == ["manifest.contributions.workflows[0]"])
        await app.stop()
    }

    @Test("install links download through the HTTP transport with limits")
    func downloads() async throws {
        let app = try await PluginApp.start()
        let url = try #require(URL(string: "https://example.com/weekly.lumenplugin"))
        app.transport.replies.withLock { $0[url] = .init(status: 200, body: SamplePackage().data) }
        let review = try await app.packages.reviewDownload(from: url)
        #expect(review.source == .link(url) && review.manifest.id == SamplePackage.id)
        #expect(app.transport.requests.withLock { $0.last?.method } == "GET")

        app.transport.replies.withLock { $0[url] = .init(status: 404, body: Data()) }
        await #expect(throws: PluginPackageError.downloadFailed(host: "example.com", reason: "The server answered 404.")) { try await app.packages.reviewDownload(from: url) }
        app.transport.replies.withLock { $0[url] = .init(status: 200, body: Data(repeating: 0x20, count: 600 * 1024)) }
        await #expect(throws: PluginPackageError.downloadFailed(host: "example.com", reason: "The file is larger than the 512 KB Lumen accepts.")) { try await app.packages.reviewDownload(from: url) }
        await app.stop()
    }

    @Test("installed packages come back after a relaunch")
    func relaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-plugins-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func launch() async throws -> (LumenServices, LumenRuntime) {
            var platform = PlatformServices(secrets: InMemorySecretStore(), notificationScheduler: CountingScheduler(), httpTransport: RecordingTransport())
            platform.pluginSignatureVerifier = DigestSignatureVerifier()
            let services = try await LumenBootstrap.make(configuration: AppConfiguration(flavor: .debug, dataDirectory: directory), platform: platform, timeSource: ManualTimeSource(), calendar: .testUTC)
            let runtime = LumenRuntime(services: services)
            await runtime.start()
            return (services, runtime)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (first, firstRuntime) = try await launch()
        let review = try await first.plugins.packages.review(SamplePackage().data, source: .file)
        try await first.plugins.packages.install(review, choices: PluginInstallChoices(capabilities: [.contributeCommands], hosts: []))
        await firstRuntime.shutdown()

        let (second, secondRuntime) = try await launch()
        #expect(await second.plugins.host.state(of: SamplePackage.id) == .active)
        #expect(await eventually { second.commands.action(for: commandID) != nil })
        await secondRuntime.shutdown()
    }
}
