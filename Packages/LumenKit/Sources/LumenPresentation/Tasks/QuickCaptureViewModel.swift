import Foundation
import Observation
import LumenFoundation
import LumenOrganization
import LumenApplication

/// The capture field: parses as the user types and shows what was understood as chips.
@MainActor
@Observable
public final class QuickCaptureViewModel {
    public struct Chip: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case date, time, priority, tag, project, repeats }
        public let kind: Kind
        public let label: String
        public let symbolName: String
        public var id: String { "\(kind)-\(label)" }
    }

    public var text: String = "" {
        didSet { reparse() }
    }

    public private(set) var parsed: QuickCaptureResult?
    public private(set) var chips: [Chip] = []
    public private(set) var isSaving = false
    public private(set) var error: ErrorPresentation?
    /// The last task created, for the "Added" confirmation.
    public private(set) var lastCreated: TaskItem?

    private let services: LumenServices
    private let labels: DateLabels

    public init(services: LumenServices, initialText: String? = nil, locale: Locale = .current) {
        self.services = services
        self.labels = DateLabels(calendar: services.calendar, locale: locale)
        if let initialText {
            self.text = initialText
            reparse()
        }
    }

    public var canSubmit: Bool {
        !isSaving && text.collapsingWhitespace.nonBlank != nil
    }

    /// Creates the task; returns it on success and clears the field for the next capture.
    @discardableResult
    public func submit() async -> TaskItem? {
        guard canSubmit else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let (task, _) = try await services.organization.tasks.capture(text)
            lastCreated = task
            text = ""
            return task
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }

    private func reparse() {
        guard let line = text.collapsingWhitespace.nonBlank else {
            parsed = nil
            chips = []
            return
        }
        let today = services.today
        let result = QuickCaptureParser.parse(line, today: today)
        parsed = result
        var chips: [Chip] = []
        if let due = result.dueDate {
            chips.append(Chip(kind: .date, label: labels.dayLabel(due, today: today), symbolName: "calendar"))
        }
        if let time = result.dueTime {
            chips.append(Chip(kind: .time, label: labels.timeLabel(time), symbolName: "clock"))
        }
        if let rule = result.recurrence {
            chips.append(Chip(kind: .repeats, label: rule.summary, symbolName: "repeat"))
        }
        if result.priority != .none {
            chips.append(Chip(kind: .priority, label: result.priority.title, symbolName: "flag"))
        }
        for tag in result.tags {
            chips.append(Chip(kind: .tag, label: "#\(tag)", symbolName: "number"))
        }
        if let project = result.projectName {
            chips.append(Chip(kind: .project, label: project, symbolName: "folder"))
        }
        self.chips = chips
    }
}
