import AppIntents
import Foundation
import LumenFoundation
import LumenOrganization
import LumenApplication
import LumenPlatform

// The focus Live Activity's buttons. As `LiveActivityIntent`s they run in the app's process
// (launched in the background when needed) and go through the focus service; the widget
// extension declares the same types (App/LumenWidgets/FocusActivityIntents.swift) so its buttons
// can name them. Keep both declarations' titles and parameters identical.

/// Pauses the focus session from its Live Activity.
struct PauseFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Focus"
    static let description = IntentDescription("Pauses the running focus session.")
    static let isDiscoverable = false

    @Parameter(title: "Session ID")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        try await FocusActivityButton.pause.apply(to: sessionID)
        return .result()
    }
}

/// Resumes the paused focus session from its Live Activity.
struct ResumeFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Focus"
    static let description = IntentDescription("Resumes the paused focus session.")
    static let isDiscoverable = false

    @Parameter(title: "Session ID")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        try await FocusActivityButton.resume.apply(to: sessionID)
        return .result()
    }
}

/// Finishes the focus session from its Live Activity, counting the time so far.
struct FinishFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish Focus"
    static let description = IntentDescription("Finishes the focus session and counts the time so far.")
    static let isDiscoverable = false

    @Parameter(title: "Session ID")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        try await FocusActivityButton.finish.apply(to: sessionID)
        return .result()
    }
}

/// What a Live Activity button does, through the same service as the interface.
private enum FocusActivityButton {
    case pause
    case resume
    case finish

    func apply(to rawSessionID: String) async throws {
        let services = try await SharedServices.shared.services()
        let focus = services.focus.service
        // A session that ended meanwhile (its countdown ran out, or another device's button) is
        // left as it is; the activity is brought in line below either way.
        if let uuid = UUID(uuidString: rawSessionID), let session = try await focus.session(FocusSession.ID(uuid)), session.isActive {
            switch self {
            case .pause: try await focus.pause(session.id)
            case .resume: try await focus.resume(session.id)
            case .finish: try await focus.finish(session.id)
            }
        }
        // The runtime may not be running in a background launch: update the Live Activity and
        // the end-of-session alert before the intent returns.
        await services.focus.coordinator.reconcile()
    }
}
