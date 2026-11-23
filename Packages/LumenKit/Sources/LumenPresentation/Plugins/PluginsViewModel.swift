import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenApplication

/// Settings › Plugins: Lumen's built-in features and the plugins the user installed.
@MainActor
@Observable
public final class PluginsViewModel {
    public struct Row: Sendable, Hashable, Identifiable {
        public let status: PluginStatus
        /// The package, for third-party plugins that read correctly.
        public let installed: InstalledPlugin?
        public let stateText: String
        /// Failed, blocked or incompatible: shown in a warning color.
        public let hasProblem: Bool

        public var id: String { status.id }
        public var isBuiltIn: Bool { status.isBuiltIn }
        public var name: String { installed?.manifest.name ?? status.manifest.name }
        public var isEnabled: Bool { status.state != .disabled }

        public var subtitle: String {
            guard let installed else { return status.isBuiltIn ? "Built in" : "Version \(status.manifest.version)" }
            let signature = installed.signature.isSigned ? "" : " · Not signed"
            return "\(installed.manifest.publisher.name) · Version \(installed.manifest.version)\(signature)"
        }
    }

    public private(set) var builtIn: [Row] = []
    public private(set) var thirdParty: [Row] = []
    public private(set) var isLoaded = false

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public var allowsThirdParty: Bool { services.plugins.allowsThirdParty }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["plugins"]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        let statuses = await services.plugins.host.statuses()
        let installed: [String: InstalledPlugin]
        do {
            installed = Dictionary(try await services.plugins.packages.installed().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            services.errors.report(error, context: "Loading plugins")
            installed = [:]
        }
        let rows = statuses.map { status in
            Row(
                status: status,
                installed: installed[status.id],
                stateText: PluginStateText.text(for: status),
                hasProblem: PluginStateText.isProblem(status.state)
            )
        }
        builtIn = rows.filter(\.isBuiltIn)
        thirdParty = rows.filter { !$0.isBuiltIn }
        isLoaded = true
    }

    public func setEnabled(_ enabled: Bool, plugin id: String) async {
        do {
            try await services.plugins.host.setEnabled(enabled, for: id)
        } catch {
            services.errors.report(error, context: "Turning a plugin \(enabled ? "on" : "off")")
        }
        await load()
    }
}

/// How a plugin's state reads in Settings.
public enum PluginStateText {
    public static func text(for status: PluginStatus) -> String {
        switch status.state {
        case .active:
            let declared = status.manifest.capabilities
            let granted = status.grantedCapabilities.intersection(declared)
            if status.isBuiltIn || granted == declared { return "On" }
            if granted.isEmpty { return "On · no permissions allowed, so it adds nothing" }
            return "On · \(granted.count) of \(declared.count) permissions allowed"
        case .inactive: return "Not running"
        case .disabled: return "Off"
        case .needsPermission: return "Needs permission"
        case .failed(let message): return "Didn't start: \(message)"
        case .incompatible: return "Needs a newer Lumen"
        case .blocked: return "Third-party plugins are off in this build"
        }
    }

    public static func isProblem(_ state: PluginState) -> Bool {
        switch state {
        case .failed, .incompatible, .blocked, .needsPermission: return true
        case .active, .inactive, .disabled: return false
        }
    }
}
