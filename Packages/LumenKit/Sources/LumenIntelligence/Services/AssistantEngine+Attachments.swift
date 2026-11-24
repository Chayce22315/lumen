import Foundation
import LumenFoundation
import LumenCore

extension AssistantEngine {
    /// An attachment of the message being sent, with the content it was resolved to.
    struct ResolvedAttachment: Sendable {
        let attachment: MessageAttachment
        let content: AttachmentContent
    }

    // MARK: - Models

    /// The models this device can answer with: every configured provider's model list (from the
    /// catalog's cache unless `refresh`). Providers without credentials are left out entirely;
    /// configured providers whose list fails are reported in `unavailable`.
    public func modelChoices(refresh: Bool = false) async -> ModelChoices {
        var listed: [ModelChoices.ProviderModels] = []
        var unavailable: [ProviderID: ErrorPresentation] = [:]
        for provider in providers.providers {
            do {
                guard try hasCredentials(provider) else { continue }
                let models = try await catalog.models(for: provider.id, refresh: refresh)
                guard !models.isEmpty else { continue }
                listed.append(ModelChoices.ProviderModels(id: provider.id, displayName: provider.displayName, models: models))
            } catch {
                unavailable[provider.id] = ErrorPresentation.from(error)
            }
        }
        return ModelChoices(providers: listed, unavailable: unavailable)
    }

    /// Whether `provider` can be called on this device: it needs no key, or a key is stored.
    nonisolated func hasCredentials(_ provider: any ModelProvider) throws -> Bool {
        guard provider.requiresAPIKey else { return true }
        return try secrets.secret(for: provider.id.apiKeySecret)?.nonBlank != nil
    }

    // MARK: - Attachments

    /// Reads the new message's attachments and decides how much of each is sent. Throws — before
    /// anything is persisted — when an item can't be attached.
    func resolveAttachments(_ references: [EntityReference], historyBudget: Int) async throws -> [ResolvedAttachment] {
        var unique: [EntityReference] = []
        for reference in references where !unique.contains(reference) {
            unique.append(reference)
        }
        guard !unique.isEmpty else { return [] }
        guard unique.count <= configuration.maxAttachmentsPerMessage else {
            throw AssistantError.tooManyAttachments(configuration.maxAttachmentsPerMessage)
        }
        guard let attachmentResolver else { throw AssistantError.attachmentUnavailable }
        var contents: [AttachmentContent] = []
        for reference in unique {
            guard let content = try await attachmentResolver.content(of: reference), content.text.nonBlank != nil else {
                throw AssistantError.attachmentUnavailable
            }
            contents.append(content)
        }
        let limit = AttachmentBudget.characterLimit(historyBudgetTokens: historyBudget, ceiling: configuration.maxAttachmentCharacters)
        let allocation = AttachmentBudget.allocate(lengths: contents.map(\.text.count), limit: limit)
        return unique.indices.map { index in
            let content = contents[index]
            return ResolvedAttachment(
                attachment: MessageAttachment(
                    reference: unique[index],
                    title: content.title,
                    includedCharacters: allocation[index],
                    totalCharacters: content.text.count
                ),
                content: content
            )
        }
    }

    /// The history with each attachment's current text placed ahead of the user's text, as the
    /// model sees it. Only the request is expanded; stored messages keep references only.
    /// `known` holds content already read for this turn, so each item is read at most once.
    func expandingAttachments(in messages: [ChatMessage], known: [EntityReference: AttachmentContent]) async -> [ChatMessage] {
        var cache: [EntityReference: AttachmentContent?] = known.mapValues { Optional($0) }
        var expanded: [ChatMessage] = []
        for message in messages {
            guard message.role == .user, !message.attachments.isEmpty else {
                expanded.append(message)
                continue
            }
            var blocks: [ContentBlock] = []
            for attachment in message.attachments {
                let content: AttachmentContent?
                if let cached = cache[attachment.reference] {
                    content = cached
                } else {
                    content = await currentContent(of: attachment.reference)
                    cache[attachment.reference] = content
                }
                blocks.append(.text(AttachmentPrompt.block(for: attachment, content: content)))
            }
            var copy = message
            copy.blocks = blocks + message.blocks
            expanded.append(copy)
        }
        return expanded
    }

    /// The content of an item attached to an earlier message. A failed read is logged and the
    /// item is presented to the model as unavailable, so one unreadable attachment never blocks
    /// the rest of the conversation.
    private func currentContent(of reference: EntityReference) async -> AttachmentContent? {
        guard let attachmentResolver else { return nil }
        do {
            return try await attachmentResolver.content(of: reference)
        } catch {
            logger.warning("Attachment could not be read", metadata: ["kind": reference.kind.rawValue, "error": Self.errorKind(error)])
            return nil
        }
    }
}
