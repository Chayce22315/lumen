import Foundation
import LumenFoundation

/// Progress of one assistant turn, streamed by `AssistantEngine.send(text:in:)`.
///
/// A turn produces one or more assistant messages (one per tool round). Each starts with
/// `messageStarted`, streams `textDelta`s and ends with `completed`. A cancelled message is
/// delivered through `completed` with `status == .cancelled`. Errors end the turn with `failed`.
public enum AssistantUpdate: Sendable, Hashable {
    case messageStarted(ChatMessage.ID)
    case textDelta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, isError: Bool)
    case completed(ChatMessage)
    case failed(ErrorPresentation)
}
