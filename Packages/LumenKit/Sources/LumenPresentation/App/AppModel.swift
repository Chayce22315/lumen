import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenApplication

/// The root of the interface: launches Lumen, owns navigation, and surfaces errors and toasts.
@MainActor
@Observable
public final class AppModel {
    public enum Phase {
        case launching
        case ready(LumenServices)
        case failed(ErrorPresentation)
    }

    public private(set) var phase: Phase = .launching
    public let router = Router()
    /// Non-blocking error banners, newest last.
    public private(set) var banners: [ReportedIssue] = []
    /// A short confirmation ("Moved 2 tasks to today.").
    public var toast: String?
    /// A plugin package or install link opened from outside, waiting for its review in
    /// Settings › Plugins.
    public let pluginRequests = PluginRequestInbox()

    private let makeServices: @Sendable () async throws -> LumenServices
    private let makeRuntime: @Sendable (LumenServices) async throws -> LumenRuntime
    private var runtime: LumenRuntime?
    private let issueObservation = ObservationHandle()
    private var pendingURL: URL?

    /// - Parameter makeRuntime: the runtime for the services. The app passes its process-wide
    ///   runtime, shared with background refresh, so engines are started once.
    public init(
        makeServices: @escaping @Sendable () async throws -> LumenServices,
        makeRuntime: @escaping @Sendable (LumenServices) async throws -> LumenRuntime = { LumenRuntime(services: $0) }
    ) {
        self.makeServices = makeServices
        self.makeRuntime = makeRuntime
    }

    public var services: LumenServices? {
        if case .ready(let services) = phase { return services }
        return nil
    }

    /// Builds the services and starts the runtime. Safe to call again after a failure.
    public func launch() async {
        if case .ready = phase { return }
        phase = .launching
        do {
            let services = try await makeServices()
            let runtime = try await makeRuntime(services)
            await runtime.start()
            self.runtime = runtime
            observeIssues(services.errors)
            phase = .ready(services)
            if let url = pendingURL {
                pendingURL = nil
                handle(url: url)
            }
        } catch {
            phase = .failed(ErrorPresentation.from(error))
        }
    }

    public func sceneDidBecomeActive() async {
        await runtime?.didBecomeActive()
    }

    public func sceneDidEnterBackground() async {
        await runtime?.didEnterBackground()
    }

    /// Opens a `lumen://` link; links that arrive during launch are handled once ready.
    public func handle(url: URL) {
        guard services != nil else {
            pendingURL = url
            return
        }
        if pluginRequests.accept(url) {
            router.open(.settings(.plugins))
            return
        }
        if let destination = DeepLink.destination(from: url) {
            router.open(destination)
        }
    }

    /// Runs a palette command by id.
    public func runCommand(_ id: String) async {
        guard let services, let action = services.commands.action(for: id) else { return }
        switch action {
        case .navigate(let destination):
            router.open(destination)
        case .perform(let work):
            do {
                let result = try await work()
                if let message = result.message { toast = message }
                if let destination = result.destination { router.open(destination) }
            } catch {
                services.errors.report(error, context: "Running \(id)")
            }
        }
    }

    public func dismissBanner(_ id: ReportedIssue.ID) {
        banners.removeAll { $0.id == id }
    }

    private func observeIssues(_ reporter: ErrorReporter) {
        let stream = reporter.issues()
        issueObservation.replace(with: Task { @MainActor [weak self] in
            for await issue in stream {
                guard let self else { return }
                self.banners.append(issue)
                if self.banners.count > 3 { self.banners.removeFirst(self.banners.count - 3) }
            }
        })
    }
}
