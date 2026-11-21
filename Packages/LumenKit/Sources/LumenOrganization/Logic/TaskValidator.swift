import Foundation
import LumenFoundation

/// Validation rules shared by creation and update.
public enum TaskValidator {
    public static let maximumTitleLength = 500
    public static let maximumNotesLength = 100_000
    public static let maximumTags = 32

    /// Returns a cleaned copy of `task` or throws the first violated rule.
    public static func validated(_ task: TaskItem) throws -> TaskItem {
        var task = task
        guard let title = task.title.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "title", reason: "A task needs a title.")
        }
        guard title.count <= maximumTitleLength else {
            throw ValidationError(field: "title", reason: "Titles can be at most \(maximumTitleLength) characters.")
        }
        task.title = title
        guard task.notes.count <= maximumNotesLength else {
            throw ValidationError(field: "notes", reason: "Notes are too long.")
        }
        if let estimate = task.estimatedMinutes, !(0...(60 * 24 * 30)).contains(estimate) {
            throw ValidationError(field: "estimate", reason: "Estimates must be between 0 minutes and 30 days.")
        }
        if let start = task.startDate, let due = task.dueDate, start > due {
            throw ValidationError(field: "start date", reason: "A task can't start after it is due.")
        }
        if task.dueTime != nil && task.dueDate == nil {
            throw ValidationError(field: "due time", reason: "Pick a due date before choosing a time.")
        }
        if task.recurrence != nil && task.dueDate == nil {
            throw ValidationError(field: "repeat", reason: "Repeating tasks need a due date to repeat from.")
        }
        if case .minutesBefore(let minutes) = task.reminder, minutes < 0 {
            throw ValidationError(field: "reminder", reason: "Reminders must come before the due time.")
        }
        if let parentID = task.parentID, parentID == task.id {
            throw ValidationError(field: "parent", reason: "A task can't be its own subtask.")
        }
        task.tags = normalizedTags(task.tags)
        guard task.tags.count <= maximumTags else {
            throw ValidationError(field: "tags", reason: "A task can have at most \(maximumTags) tags.")
        }
        task.blockedBy = task.blockedBy.filter { $0 != task.id }.uniqued()
        return task
    }

    /// Lowercased, `#`-stripped, whitespace-free tags without duplicates, order preserved.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        tags.compactMap { raw -> String? in
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            let cleaned = tag.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
            guard !cleaned.isEmpty else { return nil }
            return String(cleaned.prefix(64))
        }.uniqued()
    }
}

extension Array where Element: Hashable {
    /// Removes duplicates, keeping the first occurrence.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
