import Foundation
import LumenFoundation

/// Entity kinds owned by the intelligence engine. Raw values are persisted and synchronized.
extension EntityKind {
    public static let conversation: EntityKind = "conversation"
    public static let chatMessage: EntityKind = "chat-message"
    public static let memory: EntityKind = "memory"
}
