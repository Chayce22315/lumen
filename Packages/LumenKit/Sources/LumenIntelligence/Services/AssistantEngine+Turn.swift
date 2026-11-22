import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

extension AssistantEngine {
    /// One user turn, from the user message to the final assistant message.
    func runTurn(text: String, conversationID: Conversation.ID, turnID: UUID, updates: Updates) async {
        defer {
            if activeTurns[conversationID]?.id == turnID {
                activeTurns[conversationID] = nil
            }
            updates.finish()
        }
        guard let prompt = text.nonBlank else {
            updates.yield(.failed(AssistantError.emptyMessage.presentation))
            return
        }

        let setup: TurnSetup
        var history: [ChatMessage]
        var stamp: Date
        do {
            let (prepared, conversation) = try await prepare(conversationID: conversationID, turnID: turnID)
            setup = prepared
            let userMessage = try await persistUserMessage(prompt, in: conversation, setup: setup)
            stamp = userMessage.createdAt
            let stored = try await database.read { db in try MessageRepository.messages(in: conversationID, db: db) }
            // Earlier turns are fitted once; the tool loop below only appends, so the request
            // prefix stays identical across rounds (which keeps replayed reasoning valid).
            history = contextBuilder.fit(stored, budget: setup.historyBudget).messages
        } catch {
            logger.notice("Assistant turn not started", metadata: ["reason": Self.errorKind(error)])
            updates.yield(.failed(ErrorPresentation.from(error)))
            return
        }

        logger.info("Assistant turn started", metadata: ["provider": setup.selection.providerID.rawValue, "model": setup.selection.modelID])
        let executor = ToolExecutor(timeout: configuration.toolTimeout, logger: logger)
        var turnMessages: [ChatMessage] = []
        var roundsExecuted = 0

        while true {
            let toolChoice: ToolChoice = roundsExecuted >= configuration.maxToolRounds ? .none : .auto
            let fitted = contextBuilder.fit(history + turnMessages, budget: setup.historyBudget)
            if fitted.droppedMessageCount > 0 {
                // Later rounds keep this smaller history so their prefix matches.
                history = fitted.messages.filter { message in !turnMessages.contains { $0.id == message.id } }
                turnMessages = fitted.messages.filter { message in turnMessages.contains { $0.id == message.id } }
                logger.info("History trimmed to fit the context window", metadata: ["dropped": String(fitted.droppedMessageCount)])
            }
            let request = CompletionRequest(
                model: setup.selection.modelID,
                system: setup.system,
                messages: WireTranscript.messages(from: fitted.messages, includeToolBlocks: !setup.toolDefinitions.isEmpty),
                tools: setup.toolDefinitions,
                toolChoice: toolChoice,
                maxTokens: setup.maxTokens
            )

            let messageID = ChatMessage.ID()
            updates.yield(.messageStarted(messageID))
            var accumulator = MessageAccumulator()
            var failure: (any Error)?
            do {
                let maxRetryAfter = configuration.maxRetryAfter
                try await withRetry(
                    policy: configuration.retryPolicy,
                    classify: { error in
                        // Once text or a tool call arrived, a retry would restart a visible reply.
                        accumulator.hasOutput ? .fail : ProviderError.classifyForRetry(error, maxRetryAfter: maxRetryAfter)
                    },
                    sleep: sleep,
                    onRetry: { attempt, error, delay in
                        self.logger.notice("Retrying completion", metadata: [
                            "attempt": String(attempt), "error": Self.errorKind(error), "delay": String(format: "%.1f", delay),
                        ])
                    },
                    operation: {
                        accumulator = MessageAccumulator()
                        for try await event in setup.provider.stream(request) {
                            accumulator.apply(event)
                            if case .textDelta(let delta) = event {
                                updates.yield(.textDelta(delta))
                            }
                        }
                        try Task.checkCancellation()
                        guard accumulator.stopReason != nil else {
                            throw ProviderError.invalidResponse("The response ended without a stop reason.")
                        }
                    }
                )
            } catch {
                failure = error
            }

            stamp = nextStamp(after: stamp)
            let message = ChatMessage(
                id: messageID,
                conversationID: conversationID,
                role: .assistant,
                blocks: accumulator.blocks,
                status: .complete,
                createdAt: stamp,
                usage: accumulator.usage,
                model: setup.selection
            )

            if let failure {
                if failure is CancellationError || Task.isCancelled {
                    await finishCancelled(message, setup: setup, updates: updates)
                } else {
                    await finishFailed(message, error: failure, setup: setup, updates: updates)
                }
                return
            }

            if accumulator.stopReason == .refusal {
                // A declined reply is discarded (partial output included) and its tools never run.
                var declined = message
                declined.blocks = []
                declined.status = .failed
                declined.errorMessage = AssistantError.refused.presentation.message
                await finishFailed(declined, error: AssistantError.refused, setup: setup, updates: updates)
                return
            }

            let toolUses = message.toolUses
            // Tool calls cut off by the output limit, or requested after tools were withdrawn, are
            // not run; they are removed so the stored transcript never holds unanswered calls.
            let runsTools = !toolUses.isEmpty && toolChoice == .auto && accumulator.stopReason != .maxTokens
            guard runsTools else {
                await finishCompleted(toolUses.isEmpty ? message : message.removingToolUses(), stopReason: accumulator.stopReason, setup: setup, updates: updates)
                return
            }

            do {
                let stored = try await persistAssistant(message, setup: setup)
                publishCompleted(stored, stopReason: accumulator.stopReason, setup: setup)
                updates.yield(.completed(stored))
            } catch {
                await reportPersistenceFailure(error, updates: updates)
                return
            }
            // The in-memory copy keeps its reasoning blocks for the rest of this turn.
            turnMessages.append(message)

            var executions: [ToolExecution] = []
            let toolContext = ToolContext(conversationID: conversationID, action: setup.context, turnID: turnID)
            for call in toolUses {
                guard !Task.isCancelled else {
                    executions.append(ToolExecution(toolUseID: call.id, name: call.name, outcome: .cancelled, content: "Cancelled before the tool ran.", referencedEntities: []))
                    continue
                }
                updates.yield(.toolStarted(name: call.name))
                let execution = await executor.execute(
                    id: call.id,
                    name: call.name,
                    input: call.input,
                    tool: setup.tools[call.name],
                    invalidRawInput: accumulator.invalidToolInputs[call.id],
                    requiresApproval: setup.requiresApproval,
                    approval: approvalHandler,
                    context: toolContext
                )
                executions.append(execution)
                updates.yield(.toolFinished(name: call.name, isError: execution.isError))
            }

            stamp = nextStamp(after: stamp)
            let results = ChatMessage(
                conversationID: conversationID,
                role: .user,
                blocks: executions.map(\.resultBlock),
                status: .complete,
                createdAt: stamp
            )
            do {
                _ = try await persistMessage(results, usage: nil, setup: setup)
            } catch {
                await reportPersistenceFailure(error, updates: updates)
                return
            }
            for execution in executions {
                publishToolExecuted(execution, setup: setup)
            }
            turnMessages.append(results)

            if Task.isCancelled {
                logger.info("Assistant turn cancelled during tool calls")
                return
            }
            roundsExecuted += 1
        }
    }

    // MARK: - Endings

    private func finishCompleted(_ message: ChatMessage, stopReason: StopReason?, setup: TurnSetup, updates: Updates) async {
        do {
            let stored = try await persistAssistant(message, setup: setup)
            publishCompleted(stored, stopReason: stopReason, setup: setup)
            updates.yield(.completed(stored))
        } catch {
            await reportPersistenceFailure(error, updates: updates)
        }
    }

    private func finishCancelled(_ message: ChatMessage, setup: TurnSetup, updates: Updates) async {
        var cancelled = message.removingToolUses()
        cancelled.status = .cancelled
        do {
            let stored = try await persistAssistant(cancelled, setup: setup)
            publish(IntelligenceEvents.messageCancelled, entity: stored.reference, attributes: baseAttributes(setup), setup: setup)
            logger.info("Assistant reply cancelled")
            updates.yield(.completed(stored))
        } catch {
            await reportPersistenceFailure(error, updates: updates)
        }
    }

    private func finishFailed(_ message: ChatMessage, error: any Error, setup: TurnSetup, updates: Updates) async {
        let presentation = ErrorPresentation.from(error)
        var failed = message.removingToolUses()
        failed.status = .failed
        failed.errorMessage = presentation.message
        logger.error("Assistant reply failed", metadata: ["error": Self.errorKind(error), "provider": setup.selection.providerID.rawValue])
        do {
            let stored = try await persistAssistant(failed, setup: setup)
            var attributes = baseAttributes(setup)
            attributes["error"] = .string(Self.errorKind(error))
            publish(IntelligenceEvents.messageFailed, entity: stored.reference, attributes: attributes, setup: setup)
        } catch {
            logger.error("Failed reply could not be stored", error: error)
        }
        updates.yield(.failed(presentation))
    }

    private func reportPersistenceFailure(_ error: any Error, updates: Updates) async {
        logger.error("Assistant message could not be stored", error: error)
        updates.yield(.failed(ErrorPresentation.from(error)))
    }

    // MARK: - Persistence

    /// Stores the first user message of the turn, bumping the conversation and naming it when new.
    private func persistUserMessage(_ prompt: String, in conversation: Conversation, setup: TurnSetup) async throws -> ChatMessage {
        let conversationID = conversation.id
        let now = timeSource.now()
        let (message, autoTitled) = try await database.write { db -> (ChatMessage, Bool) in
            guard var current = try ConversationRepository.fetch(conversationID, in: db) else {
                throw AssistantError.conversationNotFound
            }
            let latest = try MessageRepository.latestCreatedAt(in: conversationID, db: db)
            let createdAt = latest.map { max(now, $0.addingTimeInterval(0.001)) } ?? now
            let message = ChatMessage(conversationID: conversationID, role: .user, blocks: [.text(prompt)], createdAt: createdAt)
            try MessageRepository.save(message, in: db)
            let autoTitled = latest == nil && current.title.isEmpty
            if autoTitled {
                current.title = ConversationTitle.make(from: prompt)
            }
            current.updatedAt = max(current.updatedAt, createdAt)
            try ConversationRepository.save(current, in: db)
            return (message, autoTitled)
        }
        if autoTitled {
            events.publish(DomainEvent(
                name: IntelligenceEvents.conversationRenamed,
                entity: conversation.reference,
                attributes: ["automatic": true],
                actor: .system,
                occurredAt: timeSource.now(),
                correlationID: setup.turnID
            ))
        }
        return message
    }

    /// Stores an assistant message (without reasoning blocks) and records its usage.
    private func persistAssistant(_ message: ChatMessage, setup: TurnSetup) async throws -> ChatMessage {
        try await persistMessage(message, usage: message.usage, setup: setup)
    }

    private func persistMessage(_ message: ChatMessage, usage: TokenUsage?, setup: TurnSetup) async throws -> ChatMessage {
        let stored = message.removingReasoning()
        let now = timeSource.now()
        let day = CalendarDate(now, calendar: calendar)
        let record = usage.flatMap { usage -> UsageRecord? in
            guard !usage.isEmpty else { return nil }
            return UsageRecord(
                providerID: setup.selection.providerID,
                modelID: setup.selection.modelID,
                conversationID: stored.conversationID,
                messageID: stored.id,
                usage: usage,
                recordedAt: now
            )
        }
        try await database.write { db in
            try MessageRepository.save(stored, in: db)
            if var conversation = try ConversationRepository.fetch(stored.conversationID, in: db) {
                conversation.updatedAt = max(conversation.updatedAt, stored.createdAt)
                try ConversationRepository.save(conversation, in: db)
            }
            if let record {
                try UsageRepository.insert(record, day: day, in: db)
            }
        }
        return stored
    }

    /// Message timestamps strictly increase within a turn so stored order is deterministic.
    private func nextStamp(after previous: Date) -> Date {
        max(timeSource.now(), previous.addingTimeInterval(0.001))
    }

    // MARK: - Events

    private func baseAttributes(_ setup: TurnSetup) -> [String: JSONValue] {
        [
            "conversationID": .string(setup.conversationID.uuidString),
            "provider": .string(setup.selection.providerID.rawValue),
            "model": .string(setup.selection.modelID),
        ]
    }

    private func publishCompleted(_ message: ChatMessage, stopReason: StopReason?, setup: TurnSetup) {
        var attributes = baseAttributes(setup)
        let usage = message.usage ?? .zero
        attributes["inputTokens"] = .number(Double(usage.input))
        attributes["outputTokens"] = .number(Double(usage.output))
        attributes["cacheReadTokens"] = .number(Double(usage.cacheRead))
        attributes["cacheCreationTokens"] = .number(Double(usage.cacheCreation))
        attributes["toolCalls"] = .number(Double(message.toolUses.count))
        attributes["stopReason"] = .string(Self.label(stopReason))
        publish(IntelligenceEvents.messageCompleted, entity: message.reference, attributes: attributes, setup: setup)
        logger.info("Assistant reply completed", metadata: [
            "inputTokens": String(usage.totalInput), "outputTokens": String(usage.output), "stopReason": Self.label(stopReason),
        ])
    }

    private func publishToolExecuted(_ execution: ToolExecution, setup: TurnSetup) {
        var attributes = baseAttributes(setup)
        attributes["tool"] = .string(execution.name)
        attributes["outcome"] = .string(execution.outcome.rawValue)
        attributes["isError"] = .bool(execution.isError)
        if !execution.referencedEntities.isEmpty {
            attributes["entities"] = .array(execution.referencedEntities.prefix(10).map { .string($0.uri) })
        }
        let conversation = EntityReference(kind: .conversation, id: setup.conversationID)
        publish(IntelligenceEvents.toolExecuted, entity: conversation, attributes: attributes, setup: setup)
        logger.info("Tool executed", metadata: ["tool": execution.name, "outcome": execution.outcome.rawValue])
    }

    private func publish(_ name: EventName, entity: EntityReference, attributes: [String: JSONValue], setup: TurnSetup) {
        events.publish(setup.context.event(name, entity: entity, attributes: attributes, at: timeSource.now()))
    }

    static func label(_ reason: StopReason?) -> String {
        switch reason {
        case .endTurn?: return "endTurn"
        case .toolUse?: return "toolUse"
        case .maxTokens?: return "maxTokens"
        case .stopSequence?: return "stopSequence"
        case .refusal?: return "refusal"
        case .other(let raw)?: return raw
        case nil: return "none"
        }
    }

    /// A content-free description of an error for logs and event attributes.
    static func errorKind(_ error: any Error) -> String {
        if let provider = error as? ProviderError { return provider.kind }
        if let assistant = error as? AssistantError { return "assistant.\(assistant)" }
        return String(describing: type(of: error))
    }
}
