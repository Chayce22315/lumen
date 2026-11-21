import Foundation
import Synchronization
import LumenFoundation

/// An error that reached the user-facing boundary.
public struct ReportedIssue: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let presentation: ErrorPresentation
    /// What the app was doing, e.g. "Saving task". Shown in diagnostics.
    public let context: String
    public let technicalDescription: String
    public let occurredAt: Date
}

/// Central sink for errors that cannot be handled locally.
///
/// Every `catch` that does not recover must end here (or rethrow): the error is logged with its
/// technical description, kept for the diagnostics screen and streamed to the interface, which
/// shows a non-blocking banner. Nothing is swallowed.
public final class ErrorReporter: Sendable {
    private let logger: Logger
    private let timeSource: any TimeSource
    private let recent = Mutex<[ReportedIssue]>([])
    private let observers = Mutex<[UUID: AsyncStream<ReportedIssue>.Continuation]>([:])
    private let retention: Int

    public init(logger: Logger, timeSource: any TimeSource, retention: Int = 100) {
        self.logger = logger
        self.timeSource = timeSource
        self.retention = max(1, retention)
    }

    @discardableResult
    public func report(_ error: any Error, context: String) -> ReportedIssue {
        let issue = ReportedIssue(
            id: UUID(),
            presentation: .from(error),
            context: context,
            technicalDescription: String(describing: error),
            occurredAt: timeSource.now()
        )
        logger.error(context, error: error)
        recent.withLock { issues in
            issues.append(issue)
            if issues.count > retention {
                issues.removeFirst(issues.count - retention)
            }
        }
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(issue)
        }
        return issue
    }

    /// Issues reported after this call.
    public func issues() -> AsyncStream<ReportedIssue> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ReportedIssue>.makeStream(bufferingPolicy: .bufferingNewest(20))
        continuation.onTermination = { [weak self] _ in
            _ = self?.observers.withLock { $0.removeValue(forKey: id) }
        }
        observers.withLock { $0[id] = continuation }
        return stream
    }

    /// Most recent issues, oldest first.
    public var recentIssues: [ReportedIssue] {
        recent.withLock { $0 }
    }
}
