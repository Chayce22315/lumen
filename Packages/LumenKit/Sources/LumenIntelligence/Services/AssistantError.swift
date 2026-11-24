import Foundation
import LumenFoundation

/// Errors from the assistant itself (as opposed to the provider), with user-facing guidance.
public enum AssistantError: PresentableError, Hashable {
    /// Neither the conversation nor the default setting names a model.
    case noModelSelected
    /// The selected model's provider is not configured on this device.
    case providerUnavailable(ProviderID)
    case conversationNotFound
    case emptyMessage
    /// A reply is already being generated in this conversation.
    case turnInProgress
    /// The model declined to answer.
    case refused
    /// An attached item was deleted, has no readable text, or attachments aren't available here.
    case attachmentUnavailable
    /// More items than one message may carry.
    case tooManyAttachments(Int)

    public var presentation: ErrorPresentation {
        switch self {
        case .noModelSelected:
            return ErrorPresentation(
                title: "Choose a model",
                message: "The assistant needs a model provider before it can answer.",
                recoverySuggestion: "Open Settings › Assistant, add a provider (an Anthropic or OpenAI API key, or a local server) and pick a default model."
            )
        case .providerUnavailable(let provider):
            return ErrorPresentation(
                title: "Provider not set up",
                message: "This conversation uses \(provider.rawValue), which isn't configured on this device.",
                recoverySuggestion: "Set it up in Settings › Assistant, or choose another model for this conversation."
            )
        case .conversationNotFound:
            return ErrorPresentation(
                title: "Conversation not found",
                message: "This conversation no longer exists. It may have been deleted on another device."
            )
        case .emptyMessage:
            return ErrorPresentation(title: "Nothing to send", message: "Type a message first.")
        case .turnInProgress:
            return ErrorPresentation(
                title: "Still answering",
                message: "The assistant is still replying in this conversation.",
                recoverySuggestion: "Wait for the reply to finish, or stop it first.",
                isRetryable: true
            )
        case .refused:
            return ErrorPresentation(
                title: "Request declined",
                message: "The model declined to answer this request.",
                recoverySuggestion: "Try rephrasing, or choose another model."
            )
        case .attachmentUnavailable:
            return ErrorPresentation(
                title: "Attachment unavailable",
                message: "An attached item was deleted or has no text the assistant can read.",
                recoverySuggestion: "Remove it and send the message again."
            )
        case .tooManyAttachments(let limit):
            return ErrorPresentation(
                title: "Too many attachments",
                message: "A message can carry up to \(limit) items from your library.",
                recoverySuggestion: "Remove some attachments and send again."
            )
        }
    }
}
