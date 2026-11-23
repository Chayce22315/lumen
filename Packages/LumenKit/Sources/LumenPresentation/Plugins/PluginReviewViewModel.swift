import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenApplication

/// The install review: everything about a package before it is installed or updated, the
/// user's per-capability and per-host decisions, and the install itself.
@MainActor
@Observable
public final class PluginReviewViewModel {
    public enum Phase: Equatable {
        case loading
        /// The package can't be installed; the message says why.
        case refused(ErrorPresentation)
        case ready
        case installing
        case installed(PluginState)
    }

    public let request: PluginInstallRequest
    public private(set) var phase: Phase = .loading
    public private(set) var review: PluginInstallReview?
    public private(set) var content: PluginReviewContent?
    public var grantedCapabilities: Set<PluginCapability> = []
    public var grantedHosts: Set<String> = []
    /// The extra confirmation an unsigned package needs.
    public var confirmsUnsigned = false
    /// Why the last install attempt failed (the review stays open so the user can retry).
    public private(set) var installFailure: ErrorPresentation?

    private let services: LumenServices

    public init(services: LumenServices, request: PluginInstallRequest) {
        self.services = services
        self.request = request
    }

    public var manifest: PluginPackageManifest? { review?.manifest }
    public var isUpdate: Bool { review?.isUpdate ?? false }
    public var requiresUnsignedConfirmation: Bool { review?.requiresUnsignedConfirmation ?? false }
    public var allowsThirdParty: Bool { services.plugins.allowsThirdParty }

    public var installTitle: String {
        guard let diff = review?.diff else { return isUpdate ? "Replace" : "Install" }
        switch diff.versionChange {
        case .upgrade: return "Update"
        case .same: return "Reinstall"
        case .downgrade: return "Replace"
        }
    }

    public var canInstall: Bool {
        phase == .ready && allowsThirdParty && (!requiresUnsignedConfirmation || confirmsUnsigned)
    }

    /// A note shown when the choices leave parts of the plugin unused.
    public var withheldSummary: String? {
        guard let manifest else { return nil }
        let denied = manifest.capabilities.subtracting(grantedCapabilities)
        let deniedHosts = Set(manifest.networkHosts).subtracting(grantedHosts)
        if denied == manifest.capabilities { return "With no permissions, the plugin adds nothing until you allow some in Settings › Plugins." }
        if denied.isEmpty, deniedHosts.isEmpty { return nil }
        var parts: [String] = []
        if !denied.isEmpty { parts.append("what needs the permissions you turned off") }
        if !deniedHosts.isEmpty, grantedCapabilities.contains(.network) { parts.append("steps that contact addresses you didn't allow") }
        return parts.isEmpty ? nil : "The plugin will leave out " + parts.joined(separator: " and ") + ". You can change this later in Settings › Plugins."
    }

    public func load() async {
        phase = .loading
        do {
            let review: PluginInstallReview
            let packages = services.plugins.packages
            switch request {
            case .package(let data):
                review = try await packages.review(data, source: .file)
            case .download(let url):
                review = try await packages.reviewDownload(from: url)
            case .catalogEntry(let entry, let catalog):
                review = try await packages.reviewCatalogEntry(entry, from: catalog)
            case .unreadable(let error):
                phase = .refused(error)
                return
            }
            let catalog = services.automation.catalog
            self.review = review
            content = PluginReviewContent(
                review: review,
                templates: services.plugins.templates(in: review.manifest),
                actions: catalog.descriptorsByID,
                triggerTitle: { catalog.triggerDescriptor(for: $0)?.title }
            )
            grantedCapabilities = review.suggestedCapabilities
            grantedHosts = review.suggestedHosts
            phase = .ready
        } catch {
            // A package that can't be installed is the outcome to show, not a failure to report.
            phase = .refused(ErrorPresentation.from(error))
        }
    }

    public func isGranted(_ capability: PluginCapability) -> Bool {
        grantedCapabilities.contains(capability)
    }

    public func setGranted(_ granted: Bool, _ capability: PluginCapability) {
        if granted { grantedCapabilities.insert(capability) } else { grantedCapabilities.remove(capability) }
    }

    public func isAllowed(host: String) -> Bool {
        grantedHosts.contains(host)
    }

    public func setAllowed(_ allowed: Bool, host: String) {
        if allowed { grantedHosts.insert(host) } else { grantedHosts.remove(host) }
    }

    /// Installs with the current choices. Returns whether it succeeded.
    @discardableResult
    public func install() async -> Bool {
        guard let review, canInstall else { return false }
        phase = .installing
        installFailure = nil
        do {
            let state = try await services.plugins.packages.install(
                review,
                choices: PluginInstallChoices(capabilities: grantedCapabilities, hosts: grantedHosts, confirmsUnsigned: confirmsUnsigned)
            )
            phase = .installed(state)
            return true
        } catch {
            // Shown on the review itself, which stays open so the user can adjust and retry; the
            // package manager already put back whatever was installed before.
            installFailure = ErrorPresentation.from(error)
            phase = .ready
            return false
        }
    }
}
