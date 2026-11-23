import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenIntelligence
import LumenAutomation
import LumenPlugins
import LumenApplication
import LumenPresentation
import LumenTestSupport

/// Serves fixed bodies by URL (404 otherwise).
private final class StubTransport: HTTPStreamingTransport {
    let bodies = Mutex<[URL: Data]>([:])

    func send(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let body = bodies.withLock { $0[request.url] }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            if let body { continuation.yield(body) }
            continuation.finish()
        }
        return HTTPStreamResponse(status: body == nil ? 404 : 200, headers: [:], body: stream)
    }
}

/// Signatures for tests: the SHA-256 of key and message.
private struct DigestVerifier: PluginSignatureVerifier {
    static func sign(_ message: Data, key: Data) -> Data { Data(SHA256.hash(key + message) + SHA256.hash(message + key)) }
    func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool {
        signature == Self.sign(message, key: publicKey)
    }
}

/// A package with an automation template (a task step and a webhook step), a command and a
/// prompt shortcut.
private func package(version: String = "1.0.0", signed: Bool = false, extraCapability: Bool = false) -> Data {
    let trigger = "6F9619FF-8B86-D011-B42D-00C04FC964FF", task = "7A9619FF-8B86-D011-B42D-00C04FC964FF", post = "8B9619FF-8B86-D011-B42D-00C04FC964FF"
    var capabilities: [JSONValue] = ["contributeWorkflowTemplates", "contributeCommands", "contributeAutomationActions", "network"]
    var contributions: [String: JSONValue] = [
        "workflows": [[
            "id": "weekly", "name": "Weekly review", "trigger": ["type": "manual"],
            "graph": [
                "nodes": [
                    ["id": .string(trigger), "title": "Start", "kind": ["type": "trigger"]],
                    ["id": .string(task), "title": "Add review task", "kind": ["type": "action", "actionID": "organization.createTask", "parameters": ["title": ["type": "literal", "value": "Weekly review"]]]],
                    ["id": .string(post), "title": "Post", "kind": ["type": "action", "actionID": "com.example.weekly.post", "parameters": ["text": ["type": "literal", "value": "done"]]]],
                ],
                "edges": [["from": .string(trigger), "to": .string(task), "port": "next"], ["from": .string(task), "to": .string(post), "port": "next"]],
            ],
        ]],
        "commands": [["id": "today", "title": "Review today", "action": ["type": "openLink", "url": "lumen://tasks/today"]]],
        "webhooks": [["id": "post", "title": "Post summary", "url": "https://hooks.example.com/lumen", "fields": [["name": "text", "title": "Text"]]]],
    ]
    if extraCapability {
        capabilities.append("contributeAssistantPrompts")
        contributions["prompts"] = [["id": "plan", "title": "Plan my week", "prompt": "Propose a plan for my week."]]
    }
    let manifest: JSONValue = [
        "schemaVersion": 1, "id": "com.example.weekly", "name": "Weekly", "version": .string(version),
        "publisher": ["name": "Example Co"], "minimumLumenVersion": "1.0.0",
        "capabilities": .array(capabilities), "network": ["hosts": ["hooks.example.com"]], "contributions": .object(contributions),
    ]
    let payload = (try? JSONCoding.encoder.encode(manifest)) ?? Data()
    var envelope: [String: JSONValue] = ["format": "app.lumen.plugin", "formatVersion": 1, "payload": .string(payload.base64EncodedString())]
    if signed {
        let key = Data(repeating: 3, count: 32)
        envelope["signature"] = ["algorithm": "ed25519", "publicKey": .string(key.base64EncodedString()), "value": .string(DigestVerifier.sign(PluginPackageFormat.signedMessage(payload: payload), key: key).base64EncodedString())]
    }
    return (try? JSONCoding.encoder.encode(JSONValue.object(envelope))) ?? Data()
}

private func makePluginServices() async throws -> (LumenServices, LumenRuntime, StubTransport) {
    let transport = StubTransport()
    var platform = PlatformServices.ephemeral()
    platform.httpTransport = transport
    platform.pluginSignatureVerifier = DigestVerifier()
    let services = try await LumenBootstrap.make(
        configuration: AppConfiguration(flavor: .test, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lumen-ui-plugins-\(UUID().uuidString)")),
        platform: platform,
        timeSource: ManualTimeSource(),
        calendar: .testUTC
    )
    let runtime = LumenRuntime(services: services)
    await runtime.start()
    return (services, runtime, transport)
}

@MainActor
@Suite("Plugin screens")
struct PluginViewModelTests {
    @Test("opened files and install links wait in the inbox and open Settings › Plugins")
    func inbox() async throws {
        let inbox = PluginRequestInbox(readFile: { _ in Data("bytes".utf8) })
        #expect(inbox.accept(URL(fileURLWithPath: "/tmp/Inbox/weekly.lumenplugin")))
        #expect(inbox.pending == .package(Data("bytes".utf8)))
        let link = try #require(URL(string: "lumen://plugin/install?url=https://example.com/weekly.lumenplugin"))
        #expect(inbox.accept(link))
        #expect(inbox.pending == .download(try #require(URL(string: "https://example.com/weekly.lumenplugin"))))
        #expect(inbox.accept(try #require(URL(string: "lumen://plugin/install?url=http://example.com/a"))))
        guard case .unreadable(let error) = inbox.pending else {
            Issue.record("an insecure link was accepted")
            return
        }
        #expect(error.title == "Link not supported")
        #expect(!inbox.accept(try #require(URL(string: "lumen://tasks/today"))))
        #expect(!inbox.accept(URL(fileURLWithPath: "/tmp/notes.txt")))

        let failing = PluginRequestInbox(readFile: { _ in throw PluginPackageError.tooLarge(bytes: 600_000, limit: 524_288) })
        #expect(failing.accept(URL(fileURLWithPath: "/tmp/big.lumenplugin")))
        #expect(failing.pending == .unreadable(PluginPackageError.tooLarge(bytes: 600_000, limit: 524_288).presentation))

        let (services, runtime) = try await makeServices()
        let model = AppModel(makeServices: { services })
        await model.launch()
        model.handle(url: link)
        #expect(model.router.sheet == .settings(.plugins))
        #expect(model.pluginRequests.pending == .download(try #require(URL(string: "https://example.com/weekly.lumenplugin"))))
        await runtime.shutdown()
    }

    @Test("the review shows permissions, hosts, signature and workflow previews, and installs with the choices")
    func review() async throws {
        let (services, runtime, _) = try await makePluginServices()
        let review = PluginReviewViewModel(services: services, request: .package(package()))
        await review.load()
        #expect(review.phase == .ready)
        let content = try #require(review.content)
        // High-risk capabilities come first.
        #expect(content.capabilities.first?.capability == .network && content.capabilities.first?.isHighRisk == true)
        #expect(content.capabilities.first { $0.capability == .contributeCommands }?.enables == "1 command")
        #expect(content.hosts.map(\.host) == ["hooks.example.com"])
        #expect(content.hosts.first?.usedBy == ["Post summary"] && content.hosts.first?.isNew == false)
        #expect(content.signature.title == "Not signed" && content.signature.isWarning)
        let preview = try #require(content.workflows.first)
        #expect(preview.trigger == "Runs when you start it")
        #expect(preview.steps.map(\.title) == ["Start", "Add review task", "Post"])
        #expect(preview.steps[1].detail == "Create task" && preview.steps[1].changesData)
        #expect(preview.steps[2].detail == "Post summary · sends data to hooks.example.com" && preview.steps[2].sendsData)
        #expect(content.contributions.map(\.kind) == [.workflow, .command, .webhook])

        // Network and hosts start off; an unsigned package needs the extra confirmation.
        #expect(!review.isGranted(.network) && !review.isAllowed(host: "hooks.example.com"))
        #expect(review.requiresUnsignedConfirmation && !review.canInstall)
        #expect(review.withheldSummary?.contains("what needs the permissions you turned off") == true)
        review.setGranted(true, .network)
        review.setAllowed(true, host: "hooks.example.com")
        review.confirmsUnsigned = true
        #expect(review.canInstall && review.installTitle == "Install")
        #expect(await review.install())
        #expect(review.phase == .installed(.active))

        let list = PluginsViewModel(services: services)
        await list.load()
        let row = try #require(list.thirdParty.first)
        #expect(row.name == "Weekly" && row.stateText == "On")
        #expect(row.subtitle == "Example Co · Version 1.0.0 · Not signed")
        #expect(list.builtIn.count == 5)
        await runtime.shutdown()
    }

    @Test("a package that can't be installed shows why")
    func refused() async throws {
        let (services, runtime, _) = try await makePluginServices()
        let malformed = PluginReviewViewModel(services: services, request: .package(Data("not json".utf8)))
        await malformed.load()
        #expect(malformed.phase == .refused(PluginPackageError.malformed(path: "", reason: "The file isn't valid JSON.").presentation))
        let missing = PluginReviewViewModel(services: services, request: .download(try #require(URL(string: "https://example.com/missing.lumenplugin"))))
        await missing.load()
        guard case .refused(let error) = missing.phase else {
            Issue.record("a failed download was reviewable")
            return
        }
        #expect(error.title == "Download failed")
        await runtime.shutdown()
    }

    @Test("updates show what changed and keep earlier choices")
    func update() async throws {
        let (services, runtime, _) = try await makePluginServices()
        let first = PluginReviewViewModel(services: services, request: .package(package(signed: true)))
        await first.load()
        #expect(first.content?.signature.title == "Signed by a new publisher key")
        #expect(first.content?.signature.fingerprint?.split(separator: " ").count == 8)
        #expect(await first.install())

        let second = PluginReviewViewModel(services: services, request: .package(package(version: "1.1.0", signed: true, extraCapability: true)))
        await second.load()
        #expect(second.isUpdate && second.installTitle == "Update")
        #expect(second.content?.signature.title == "Signed by the same publisher")
        let update = try #require(second.content?.update)
        #expect(update.versionLine == "Updates version 1.0.0 to 1.1.0.")
        #expect(update.changes == ["Asks for a new permission: Add assistant shortcuts", "Adds the assistant shortcut “Plan my week”"])
        #expect(second.content?.capabilities.first { $0.capability == .contributeAssistantPrompts }?.isNew == true)
        // The low-risk permissions granted before stay granted; the network stays off.
        #expect(second.grantedCapabilities == [.contributeWorkflowTemplates, .contributeCommands, .contributeAutomationActions, .contributeAssistantPrompts])
        await runtime.shutdown()
    }

    @Test("plugin details change permissions, list templates in Automations and uninstall cleanly")
    func detail() async throws {
        let (services, runtime, _) = try await makePluginServices()
        let review = PluginReviewViewModel(services: services, request: .package(package(extraCapability: true)))
        await review.load()
        review.setGranted(true, .network)
        review.setAllowed(true, host: "hooks.example.com")
        review.confirmsUnsigned = true
        #expect(await review.install())
        // The template's webhook step must be in the catalog before the template can be added.
        #expect(await eventually { services.automation.catalog.action("com.example.weekly.post") != nil })

        let conversations = ConversationsViewModel(services: services)
        await conversations.load()
        #expect(conversations.shortcuts.map(\.title) == ["Plan my week"])
        let chat = ChatViewModel(conversationID: Conversation.ID(), services: services, initialDraft: "Propose a plan for my week.")
        #expect(chat.draft == "Propose a plan for my week.")

        let automations = AutomationsViewModel(services: services)
        await automations.load()
        let template = try #require(automations.templates.first)
        #expect(template.addedWorkflowID == nil)
        let workflow = try #require(await automations.addTemplate(template.template))
        #expect(!workflow.isEnabled)
        #expect(automations.templates.first?.addedWorkflowID == workflow.id)

        let detail = PluginDetailViewModel(services: services, pluginID: "com.example.weekly")
        await detail.load()
        #expect(detail.sourceText == "Imported from a file")
        #expect(detail.content?.workflows.count == 1)
        #expect(detail.manifestSource?.contains("com.example.weekly") == true)
        #expect(detail.ownedWorkflowCount == 1)
        #expect(detail.uninstallConsequence.contains("the automation you added from it"))
        #expect(detail.grantedCapabilities.contains(.contributeCommands))
        detail.setGranted(false, .contributeCommands)
        #expect(detail.hasChanges)
        await detail.savePermissions()
        #expect(!detail.hasChanges)
        #expect(detail.stateText == "On · 4 of 5 permissions allowed")
        #expect(await eventually { services.commands.action(for: "plugin.com.example.weekly.today") == nil })

        #expect(await detail.uninstall())
        #expect(detail.isUninstalled)
        #expect(try await services.automation.engine.workflow(workflow.id) == nil)
        await automations.load()
        #expect(automations.templates.isEmpty)
        await runtime.shutdown()
    }

    @Test("catalogs list entries with their install state")
    func catalogs() async throws {
        let (services, runtime, transport) = try await makePluginServices()
        let catalogURL = try #require(URL(string: "https://raw.githubusercontent.com/example/plugins/main/catalog.json"))
        let packageURL = try #require(URL(string: "https://raw.githubusercontent.com/example/plugins/main/weekly.lumenplugin"))
        let data = package()
        let index: JSONValue = [
            "format": "app.lumen.plugin-catalog", "schemaVersion": 1, "name": "Example plugins",
            "plugins": [["id": "com.example.weekly", "name": "Weekly", "version": "1.1.0", "publisher": "Example Co", "url": .string(packageURL.absoluteString), "sha256": .string(SHA256.hexDigest(of: data))]],
        ]
        transport.bodies.withLock {
            $0[catalogURL] = try? JSONCoding.encoder.encode(index)
            $0[packageURL] = data
        }
        let catalogs = PluginCatalogsViewModel(services: services)
        await catalogs.load()
        catalogs.newCatalogAddress = "http://example.com/catalog.json"
        #expect(await catalogs.add() == false)
        #expect(catalogs.addFailure?.title == "Address not allowed")
        catalogs.newCatalogAddress = catalogURL.absoluteString
        #expect(await catalogs.add())
        #expect(catalogs.newCatalogAddress.isEmpty)
        let catalog = try #require(catalogs.catalogs.first)
        #expect(catalog.displayName == "Example plugins")
        let row = try #require(catalogs.rows(for: catalog).first)
        #expect(row.status == .available && row.actionTitle == "Review")

        // The listed version differs from the file, so the review refuses it.
        let review = PluginReviewViewModel(services: services, request: .catalogEntry(row.entry, catalog))
        await review.load()
        #expect(review.phase == .refused(PluginPackageError.catalogMismatch(pluginID: "com.example.weekly").presentation))

        let direct = PluginReviewViewModel(services: services, request: .package(data))
        await direct.load()
        direct.confirmsUnsigned = true
        #expect(await direct.install())
        await catalogs.load()
        #expect(catalogs.rows(for: catalog).first?.status == .updateAvailable(from: PluginVersion(major: 1, minor: 0, patch: 0)))
        await catalogs.remove(catalog)
        #expect(catalogs.catalogs.isEmpty)
        await runtime.shutdown()
    }
}
