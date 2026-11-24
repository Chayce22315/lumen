import Foundation

/// What the interface shows for an error. Engines translate their internal errors into this
/// shape at the boundary; views never format raw errors.
public struct ErrorPresentation: Sendable, Hashable {
    public var title: String
    public var message: String
    public var recoverySuggestion: String?
    public var isRetryable: Bool

    public init(title: String, message: String, recoverySuggestion: String? = nil, isRetryable: Bool = false) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRetryable = isRetryable
    }
}

/// Errors that know how to describe themselves to the user.
public protocol PresentableError: Error, Sendable {
    var presentation: ErrorPresentation { get }
}

extension ErrorPresentation {
    /// Presentation for any error: uses `PresentableError` when available, otherwise a generic message
    /// that never leaks internal detail.
    public static func from(_ error: any Error) -> ErrorPresentation {
        if let presentable = error as? any PresentableError {
            return presentable.presentation
        }
        return ErrorPresentation(
            title: "Something went wrong",
            message: "Lumen couldn't complete that action.",
            recoverySuggestion: "Try again. If it keeps happening, the diagnostics screen has details.",
            isRetryable: true
        )
    }
}

/// Raised when input fails validation before reaching persistence.
public struct ValidationError: PresentableError, Hashable {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var presentation: ErrorPresentation {
        ErrorPresentation(title: "Check \(field)", message: reason)
    }
}
