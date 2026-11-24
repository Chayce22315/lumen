import AppIntents
import Foundation

// The focus Live Activity's buttons, declared here so the extension's views can name them. They
// are `LiveActivityIntent`s and the app declares the same types (App/Lumen/FocusActivityIntents.swift),
// so the system performs them in the app's process, through the focus service. Keep both
// declarations' titles and parameters identical. The extension never opens Lumen's database:
// should the system ever run one here, it asks the user to open Lumen instead.

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
        try FocusNeedsApp.refuse()
        return .result()
    }
}

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
        try FocusNeedsApp.refuse()
        return .result()
    }
}

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
        try FocusNeedsApp.refuse()
        return .result()
    }
}

/// Focus sessions change only in the app, which owns the database.
struct FocusNeedsApp: Error, CustomLocalizedStringResourceConvertible {
    /// Always fails: the extension can't change a session.
    static func refuse() throws {
        throw FocusNeedsApp()
    }

    var localizedStringResource: LocalizedStringResource {
        "Open Lumen to change the focus session."
    }
}
