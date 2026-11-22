import Foundation

/// Decides when saving a note snapshots a new `NoteVersion`, and how many versions are kept.
///
/// - The first save of a note always creates a version.
/// - A save whose title and body equal the latest version never does.
/// - Otherwise a version is created when the latest one is at least `minimumInterval` old, or
///   immediately when the body changed a lot since the latest version: more than
///   `largeChangeFraction` of lines, as measured by `LineDiff`'s `changedFraction`.
/// - At most `maximumVersionsPerNote` versions are retained; the oldest are pruned.
///
/// Small edits in quick succession therefore coalesce into the next version instead of flooding
/// the history.
public struct VersionPolicy: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable, CaseIterable {
        case firstVersion
        case intervalElapsed
        case largeChange
        case unchanged
        case tooRecent

        public var createsVersion: Bool {
            switch self {
            case .firstVersion, .intervalElapsed, .largeChange: return true
            case .unchanged, .tooRecent: return false
            }
        }
    }

    public var minimumInterval: TimeInterval
    public var largeChangeFraction: Double
    public var maximumVersionsPerNote: Int

    public init(minimumInterval: TimeInterval = 10 * 60, largeChangeFraction: Double = 0.3, maximumVersionsPerNote: Int = 50) {
        self.minimumInterval = max(0, minimumInterval)
        self.largeChangeFraction = min(max(0, largeChangeFraction), 1)
        self.maximumVersionsPerNote = max(1, maximumVersionsPerNote)
    }

    /// What saving `title`/`body` at `now` should do, given the note's latest version.
    public func evaluate(latest: NoteVersion?, title: String, body: String, now: Date) -> Outcome {
        guard let latest else { return .firstVersion }
        if latest.matches(title: title, body: body) { return .unchanged }
        if now.timeIntervalSince(latest.savedAt) >= minimumInterval { return .intervalElapsed }
        if latest.body != body, LineDiff(old: latest.body, new: body).summary.changedFraction > largeChangeFraction {
            return .largeChange
        }
        return .tooRecent
    }

    public func shouldCreateVersion(latest: NoteVersion?, title: String, body: String, now: Date) -> Bool {
        evaluate(latest: latest, title: title, body: body, now: now).createsVersion
    }

    /// Versions to delete so that only the newest `maximumVersionsPerNote` remain. Newer means a
    /// later `savedAt`; versions saved at the same instant are ordered as given (earlier in the
    /// array counts as newer, matching the newest-first order repositories return).
    public func versionsToPrune(_ versions: [NoteVersion]) -> [NoteVersion.ID] {
        guard versions.count > maximumVersionsPerNote else { return [] }
        let newestFirst = versions.enumerated().sorted { lhs, rhs in
            if lhs.element.savedAt != rhs.element.savedAt {
                return lhs.element.savedAt > rhs.element.savedAt
            }
            return lhs.offset < rhs.offset
        }
        return newestFirst.dropFirst(maximumVersionsPerNote).map(\.element.id)
    }
}
