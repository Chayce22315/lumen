import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenAutomation
import LumenIntelligence

/// An automation step a plugin package declares: sends the step's fields as a JSON `POST` to a
/// fixed `https` address. It runs only for hosts the user allowed, and logs the plugin and the
/// response status — never the fields.
struct PluginWebhookAction: AutomationAction {
    static let timeout: TimeInterval = 15
    static let responseLimit = 64 * 1024

    let pluginID: String
    let webhook: WebhookContribution
    let grantedHosts: Set<String>
    let transport: any HTTPStreamingTransport
    let logger: Logger
    let descriptor: AutomationActionDescriptor

    init(pluginID: String, pluginName: String, webhook: WebhookContribution, grantedHosts: Set<String>, transport: any HTTPStreamingTransport, logger: Logger) {
        self.pluginID = pluginID
        self.webhook = webhook
        self.grantedHosts = grantedHosts
        self.transport = transport
        self.logger = logger
        self.descriptor = AutomationActionDescriptor(
            id: Self.actionID(pluginID: pluginID, webhookID: webhook.id),
            title: webhook.title,
            summary: webhook.summary.isEmpty ? "Sends the fields to \(webhook.host)." : "\(webhook.summary) Sends the fields to \(webhook.host).",
            symbolName: "paperplane",
            category: pluginName,
            parameters: webhook.fields.map { field in
                ActionParameterSpec(name: field.name, title: field.title, kind: field.isMultiline ? .multilineText : .text, isRequired: field.isRequired)
            },
            isMutating: true
        )
    }

    /// `<plugin id>.<webhook id>`: what workflow templates use to reference the step.
    static func actionID(pluginID: String, webhookID: String) -> AutomationActionID {
        AutomationActionID("\(pluginID).\(webhookID)")
    }

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        let host = webhook.host
        guard grantedHosts.contains(host) else {
            throw AutomationActionError.permanent("Lumen isn't allowed to contact \(host). Allow it in Settings › Plugins.")
        }
        var body: [String: JSONValue] = [:]
        for field in webhook.fields {
            let value = invocation.string(field.name) ?? invocation.parameters[field.name]?.displayString ?? ""
            if field.isRequired, value.nonBlank == nil {
                throw AutomationActionError.permanent("“\(field.title)” is required.")
            }
            body[field.name] = .string(value)
        }
        let request = HTTPRequest(
            method: "POST",
            url: webhook.url,
            headers: ["content-type": "application/json", "user-agent": "Lumen"],
            body: try JSONCoding.encoder.encode(JSONValue.object(body)),
            timeout: Self.timeout
        )
        let status: Int
        do {
            status = try await transport.fetch(request, limit: Self.responseLimit).status
        } catch {
            logger.warning("Plugin webhook could not be sent", metadata: ["plugin": pluginID, "error.type": String(describing: type(of: error))])
            throw AutomationActionError.transient("Couldn't reach \(host). Check your connection.")
        }
        logger.info("Plugin webhook sent", metadata: ["plugin": pluginID, "status": String(status)])
        switch status {
        case 200..<300:
            return ActionOutcome(output: ["status": .number(Double(status))], message: "Sent to \(host)")
        case 408, 425, 429, 500...599:
            throw AutomationActionError.transient("\(host) answered \(status). Lumen will retry.")
        default:
            throw AutomationActionError.permanent("\(host) refused the request (\(status)).")
        }
    }
}

/// Downloads package and catalog files over the app's HTTP transport, with a size limit and an
/// overall deadline.
struct TransportPluginDownloader: PluginPackageDownloading {
    let transport: any HTTPStreamingTransport

    func download(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        let host = url.host ?? url.absoluteString
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await fetch(url, limit: limit, timeout: timeout, host: host) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 2 * 1_000_000_000))
                    throw PluginPackageError.downloadFailed(host: host, reason: "It took too long.")
                }
                defer { group.cancelAll() }
                guard let data = try await group.next() else {
                    throw PluginPackageError.downloadFailed(host: host, reason: "Nothing was received.")
                }
                return data
            }
        } catch let error as PluginPackageError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginPackageError.downloadFailed(host: host, reason: "Check your connection and the address.")
        }
    }

    private func fetch(_ url: URL, limit: Int, timeout: TimeInterval, host: String) async throws -> Data {
        let response = try await transport.send(HTTPRequest(method: "GET", url: url, headers: ["accept": "application/json, application/octet-stream"], timeout: timeout))
        guard response.isSuccess else {
            throw PluginPackageError.downloadFailed(host: host, reason: "The server answered \(response.status).")
        }
        var data = Data()
        for try await chunk in response.body {
            data.append(chunk)
            if data.count > limit {
                throw PluginPackageError.downloadFailed(host: host, reason: "The file is larger than the \(limit / 1024) KB Lumen accepts.")
            }
        }
        try Task.checkCancellation()
        return data
    }
}
