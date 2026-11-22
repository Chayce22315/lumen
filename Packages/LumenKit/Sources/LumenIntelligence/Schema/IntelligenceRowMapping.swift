import Foundation
import LumenFoundation
import LumenPersistence

extension ProviderID: DatabaseValueConvertible {}
extension MessageRole: DatabaseValueConvertible {}
extension MessageStatus: DatabaseValueConvertible {}
extension MemorySource: DatabaseValueConvertible {}

/// Rebuilds a selection from its two nullable columns.
func storedSelection(providerID: ProviderID?, modelID: String?) -> ModelSelection? {
    guard let providerID, let modelID else { return nil }
    return ModelSelection(providerID: providerID, modelID: modelID)
}

extension Conversation {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            title: try row.get("title"),
            selection: storedSelection(providerID: try row.get("provider_id"), modelID: try row.get("model_id")),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at"),
            isArchived: try row.get("is_archived"),
            isPinned: try row.get("is_pinned")
        )
    }
}

extension ChatMessage {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            conversationID: try row.get("conversation_id"),
            role: try row.get("role"),
            blocks: try row.json("blocks"),
            status: try row.get("status"),
            createdAt: try row.get("created_at"),
            usage: try row.optionalJSON("usage"),
            errorMessage: try row.get("error_message"),
            model: storedSelection(providerID: try row.get("provider_id"), modelID: try row.get("model_id"))
        )
    }
}

extension MemoryItem {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            content: try row.get("content"),
            source: try row.get("source"),
            isEnabled: try row.get("is_enabled"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }
}
