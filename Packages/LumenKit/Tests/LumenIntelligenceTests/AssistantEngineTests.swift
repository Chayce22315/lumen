import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

@Suite("AssistantEngine")
struct AssistantEngineTests {
    // MARK: Plain replies

    @Test("a text reply streams, is persisted with usage and names the conversation")
    func textReply() async throws {
        let harness = try await EngineHarness.make(provider: FakeProvider(script: [.reply(FakeProvider.text("Hello there!"))]))
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("  Say hello to the team  ", in: conversation.id)

        guard case .messageStarted(let id)? = updates.first else {
            Issue.record("expected messageStarted first")
            return
        }
        #expect(updates.deltas == "Hello there!")
        let reply = try #require(updates.completedMessages.last)
        #expect(reply.id == id && reply.text == "Hello there!" && reply.status == .complete)
        #expect(reply.usage == TokenUsage(input: 100, output: 20))
        #expect(reply.model == EngineHarness.selection)

        let stored = try await harness.messages(conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.first?.text == "Say hello to the team")
        #expect(try await harness.conversations.conversation(conversation.id)?.title == "Say hello to the team")

        let request = try #require(harness.provider.requests.first)
        #expect(request.model == "claude-opus-5-5")
        #expect(request.messages == [WireMessage(role: .user, blocks: [.text("Say hello to the team")])])
        #expect(request.maxTokens == 64_000)
        #expect(request.system.contains("Current date and time: Saturday, 2026-11-21 09:00"))
        #expect(await !harness.engine.isResponding(in: conversation.id))
    }

    @Test("the second turn sends the earlier exchange and keeps the title")
    func secondTurn() async throws {
        let harness = try await EngineHarness.make(provider: FakeProvider(script: [.reply(FakeProvider.text("Four.")), .reply(FakeProvider.text("Eight."))]))
        let conversation = try await harness.conversations.create()
        _ = await harness.send("What is 2 + 2?", in: conversation.id)
        _ = await harness.send("And doubled?", in: conversation.id)
        let second = try #require(harness.provider.requests.last)
        #expect(second.messages == [
            WireMessage(role: .user, blocks: [.text("What is 2 + 2?")]),
            WireMessage(role: .assistant, blocks: [.text("Four.")]),
            WireMessage(role: .user, blocks: [.text("And doubled?")]),
        ])
        #expect(try await harness.conversations.conversation(conversation.id)?.title == "What is 2 + 2?")
    }

    @Test("usage is recorded per completion and events are published after commit")
    func usageAndEvents() async throws {
        let harness = try await EngineHarness.make(provider: FakeProvider(script: [.reply(FakeProvider.text("Hi", usage: TokenUsage(input: 40, output: 9, cacheRead: 300)))]))
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Hi", in: conversation.id)
        let range = DateInterval(start: harness.environment.clock.now().addingTimeInterval(-60), duration: 3_600)
        let totals = try await harness.usage.totals(in: range, groupedBy: .model)
        #expect(totals == [UsageTotal(providerID: .anthropic, modelID: "claude-opus-5-5", usage: TokenUsage(input: 40, output: 9, cacheRead: 300), completions: 1)])

        let events = await harness.events.waitForEvents(3)
        #expect(events.map(\.name) == [IntelligenceEvents.conversationCreated, IntelligenceEvents.conversationRenamed, IntelligenceEvents.messageCompleted])
        let completed = try #require(events.last)
        #expect(completed.actor == .assistant)
        #expect(completed.entity?.kind == .chatMessage)
        #expect(completed.attributes["inputTokens"] == 40)
        #expect(completed.attributes["cacheReadTokens"] == 300)
        #expect(completed.attributes["stopReason"] == "endTurn")
        // Attributes stay small: no message text.
        #expect(!completed.attributes.values.contains(.string("Hi")))
    }

    // MARK: Tools

    @Test("a tool call round-trip: execute, feed the result back, and answer")
    func toolRoundTrip() async throws {
        let search = RecordingTool("search_notes", behavior: .output(ToolOutput(text: "2 notes about Kyoto", referencedEntities: [EntityReference(kind: "note", id: UUID())])))
        let provider = FakeProvider(script: [
            .reply(FakeProvider.tool(id: "toolu_1", name: "search_notes", input: ["query": "Kyoto"])),
            .reply(FakeProvider.text("You have two Kyoto notes.")),
        ])
        let harness = try await EngineHarness.make(provider: provider, tools: [search])
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("What did I write about Kyoto?", in: conversation.id)

        #expect(updates.contains(.toolStarted(name: "search_notes")))
        #expect(updates.contains(.toolFinished(name: "search_notes", isError: false)))
        #expect(updates.completedMessages.map(\.text) == ["Let me check.", "You have two Kyoto notes."])
        #expect(search.inputs == [["query": "Kyoto"]])
        let context = try #require(search.contexts.first)
        #expect(context.conversationID == conversation.id)
        #expect(context.action.actor == .assistant)
        #expect(context.action.correlationID == context.turnID)

        let requests = provider.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.name) == ["forget", "remember", "search_notes"])
        #expect(requests[1].messages.last == WireMessage(role: .user, blocks: [.toolResult(toolUseID: "toolu_1", content: "2 notes about Kyoto", isError: false)]))

        let stored = try await harness.messages(conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(stored[2].blocks == [.toolResult(toolUseID: "toolu_1", content: "2 notes about Kyoto", isError: false)])

        let turnEvents = await harness.events.waitForEvents(5)
        #expect(turnEvents.map(\.name) == [
            IntelligenceEvents.conversationCreated, IntelligenceEvents.conversationRenamed, IntelligenceEvents.messageCompleted,
            IntelligenceEvents.toolExecuted, IntelligenceEvents.messageCompleted,
        ])
        let executed = turnEvents.first { $0.name == IntelligenceEvents.toolExecuted }
        #expect(executed?.attributes["tool"] == "search_notes")
        #expect(executed?.attributes["outcome"] == "succeeded")
        #expect(executed?.attributes["entities"]?.arrayValue?.count == 1)
        #expect(executed?.correlationID == context.turnID)
    }

    @Test("a mutating tool asks for approval; when denied it does not run and the model is told")
    func approvalDenied() async throws {
        let create = RecordingTool("create_task", isMutating: true)
        let approval = ScriptedApproval(false)
        let provider = FakeProvider(script: [
            .reply(FakeProvider.tool(id: "toolu_1", name: "create_task", input: ["query": "Buy milk"])),
            .reply(FakeProvider.text("Okay, I won't add it.")),
        ])
        let harness = try await EngineHarness.make(provider: provider, tools: [create], approval: approval)
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Add milk", in: conversation.id)

        #expect(approval.requests == ["create_task"])
        #expect(create.inputs.isEmpty)
        #expect(updates.contains(.toolFinished(name: "create_task", isError: true)))
        guard case .toolResult(_, let content, let isError)? = provider.requests.last?.messages.last?.blocks.first else {
            Issue.record("expected a tool result")
            return
        }
        #expect(isError && content.contains("declined"))
        let turnEvents = await harness.events.waitForEvents(5)
        #expect(turnEvents.map(\.name) == [
            IntelligenceEvents.conversationCreated, IntelligenceEvents.conversationRenamed, IntelligenceEvents.messageCompleted,
            IntelligenceEvents.toolExecuted, IntelligenceEvents.messageCompleted,
        ])
        let executed = turnEvents.first { $0.name == IntelligenceEvents.toolExecuted }
        #expect(executed?.attributes["outcome"] == "denied")
    }

    @Test("approval is skipped for read-only tools and when the setting is off; no handler means denied")
    func approvalRules() async throws {
        let create = RecordingTool("create_task", isMutating: true)
        let read = RecordingTool("list_tasks")
        let provider = FakeProvider(script: [
            .reply(FakeProvider.tool(id: "a", name: "list_tasks", input: [:])),
            .reply(FakeProvider.tool(id: "b", name: "create_task", input: [:])),
            .reply(FakeProvider.text("Done")),
            .reply(FakeProvider.tool(id: "c", name: "create_task", input: [:])),
            .reply(FakeProvider.text("Done")),
        ])
        let harness = try await EngineHarness.make(provider: provider, tools: [create, read])
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Do it", in: conversation.id)
        #expect(read.inputs.count == 1)
        #expect(create.inputs.isEmpty)

        try await harness.environment.settings.set(false, for: AssistantSettings.requireApprovalForMutatingTools)
        _ = await harness.send("Do it again", in: conversation.id)
        #expect(create.inputs.count == 1)
    }

    @Test("tool errors, unknown tools, invalid input and timeouts become error results the model can read")
    func toolFailures() async throws {
        let failing = RecordingTool("sync_calendar", behavior: .fail("calendar locked"))
        let slow = RecordingTool("slow_report", behavior: .sleep(10))
        let strict = RecordingTool("rename", schema: ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]])
        let provider = FakeProvider(script: [
            .reply([
                .toolUse(id: "1", name: "sync_calendar", input: [:]),
                .toolUse(id: "2", name: "does_not_exist", input: [:]),
                .toolUse(id: "3", name: "rename", input: ["title": 5]),
                .invalidToolUse(id: "4", name: "rename", rawInput: #"{"title": "Unterminated"#),
                .toolUse(id: "5", name: "slow_report", input: [:]),
                .stop(.toolUse),
            ]),
            .reply(FakeProvider.text("Some tools failed.")),
        ])
        let harness = try await EngineHarness.make(provider: provider, tools: [failing, slow, strict], configuration: .init(toolTimeout: 0.05))
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Run everything", in: conversation.id)

        #expect(updates.completedMessages.last?.text == "Some tools failed.")
        let results = try #require(provider.requests.last?.messages.last?.blocks)
        let contents = results.compactMap { block -> (String, String, Bool)? in
            if case .toolResult(let id, let content, let isError) = block { return (id, content, isError) }
            return nil
        }
        #expect(contents.map(\.0) == ["1", "2", "3", "4", "5"])
        #expect(contents.allSatisfy { $0.2 })
        #expect(contents[0].1 == "The tool failed: calendar locked")
        #expect(contents[1].1 == "No tool named “does_not_exist” is available.")
        #expect(contents[2].1 == "Invalid input: input.title must be string.")
        #expect(contents[3].1 == #"{"INVALID_JSON":"{\"title\": \"Unterminated"}"#)
        #expect(contents[4].1 == "The tool did not finish within 0.05 seconds.")
        #expect(strict.inputs.isEmpty)
        #expect(harness.environment.logs.entries(atLeast: .warning).contains { $0.message == "Tool failed" && $0.metadata["tool"] == "sync_calendar" })
        // The echoed invalid call carries an object input so the transcript stays valid.
        let echoed = try #require(provider.requests.last?.messages[1].blocks)
        #expect(echoed.contains(.toolUse(id: "4", name: "rename", input: .object([:]))))
    }

    @Test("after the tool-round limit the model must answer without tools")
    func maxToolRounds() async throws {
        let search = RecordingTool("search_notes")
        let provider = FakeProvider(repeating: .dynamic { request in
            request.toolChoice == .none
                ? FakeProvider.text("Here is what I found.")
                : FakeProvider.tool(id: "t\(request.messages.count)", name: "search_notes", input: ["query": "more"])
        })
        let harness = try await EngineHarness.make(provider: provider, tools: [search], configuration: .init(maxToolRounds: 3))
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Dig deep", in: conversation.id)

        #expect(search.inputs.count == 3)
        #expect(provider.requests.map(\.toolChoice) == [.auto, .auto, .auto, .none])
        #expect(provider.requests.last?.tools.isEmpty == false)
        #expect(updates.completedMessages.last?.text == "Here is what I found.")
        #expect(try await harness.messages(conversation.id).count == 1 + 3 * 2 + 1)
    }

    @Test("tool calls the model makes after tools were withdrawn are not run or stored")
    func ignoresToolsAfterLimit() async throws {
        let search = RecordingTool("search_notes")
        let provider = FakeProvider(repeating: .reply(FakeProvider.tool(id: "again", name: "search_notes", input: [:])))
        let harness = try await EngineHarness.make(provider: provider, tools: [search], configuration: .init(maxToolRounds: 1))
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Loop", in: conversation.id)
        #expect(search.inputs.count == 1)
        let last = try #require(updates.completedMessages.last)
        #expect(last.toolUses.isEmpty && last.text == "Let me check.")
    }

    @Test("tool calls cut off by the output limit are not run")
    func maxTokensWithTools() async throws {
        let search = RecordingTool("search_notes")
        let provider = FakeProvider(script: [.reply([.textDelta("Searching"), .toolUse(id: "x", name: "search_notes", input: [:]), .stop(.maxTokens)])])
        let harness = try await EngineHarness.make(provider: provider, tools: [search])
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Search", in: conversation.id)
        #expect(search.inputs.isEmpty)
        #expect(provider.requests.count == 1)
        #expect(updates.completedMessages.last?.blocks == [.text("Searching")])
    }

    @Test("reasoning is replayed within the turn, never stored, and stripped from later turns")
    func reasoningReplay() async throws {
        let search = RecordingTool("search_notes")
        let provider = FakeProvider(script: [
            .reply(FakeProvider.tool(id: "toolu_r", name: "search_notes", input: [:], reasoning: true)),
            .reply(FakeProvider.text("Found it.")),
            .reply(FakeProvider.text("Sure.")),
        ])
        let harness = try await EngineHarness.make(provider: provider, tools: [search])
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Find it", in: conversation.id)

        let withinTurn = try #require(provider.requests.dropFirst().first)
        #expect(withinTurn.messages[1].blocks.first == .thinking(text: "", signature: "sig-toolu_r"))
        let stored = try await harness.messages(conversation.id)
        #expect(!stored.contains { $0.blocks.contains { $0.isReasoning } })

        _ = await harness.send("Thanks", in: conversation.id)
        let nextTurn = try #require(provider.requests.last)
        #expect(!nextTurn.messages.contains { $0.blocks.contains { $0.isReasoning } })
        #expect(nextTurn.messages[1].blocks == [.text("Let me check."), .toolUse(id: "toolu_r", name: "search_notes", input: [:])])
    }

    // MARK: Memory and context

    @Test("memories and the app summary reach the system prompt only while memory is on")
    func memoryInPrompt() async throws {
        let harness = try await EngineHarness.make(contextProvider: FixedContext(summary: "2 tasks due today"))
        try await harness.memory.add("Prefers concise answers")
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Hi", in: conversation.id)
        let first = try #require(harness.provider.requests.last)
        #expect(first.system.contains("- Prefers concise answers"))
        #expect(first.system.contains("2 tasks due today"))
        #expect(first.tools.map(\.name).contains("remember"))

        try await harness.memory.setMemoryEnabled(false)
        _ = await harness.send("Hi again", in: conversation.id)
        let second = try #require(harness.provider.requests.last)
        #expect(!second.system.contains("Prefers concise answers"))
        #expect(second.tools.isEmpty)
    }

    @Test("the remember tool saves an assistant memory")
    func rememberTool() async throws {
        let provider = FakeProvider(script: [
            .reply(FakeProvider.tool(id: "m", name: "remember", input: ["content": "Has a dog named Miso"])),
            .reply(FakeProvider.text("I'll remember that.")),
        ])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Remember my dog is Miso", in: conversation.id)
        let memories = try await harness.memory.memories()
        #expect(memories.map(\.content) == ["Has a dog named Miso"])
        #expect(memories.first?.source == .assistant)
    }

    @Test("a model without tool support gets no tools and no tool history")
    func noToolSupport() async throws {
        let provider = FakeProvider(models: [ModelDescriptor(id: "claude-opus-5-5", displayName: "No tools", providerID: .anthropic, supportsTools: false)])
        let harness = try await EngineHarness.make(provider: provider, tools: [RecordingTool("search_notes")])
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Hi", in: conversation.id)
        #expect(provider.requests.first?.tools.isEmpty == true)
    }

    // MARK: Configuration failures

    @Test("a missing API key fails with setup guidance and stores nothing")
    func missingKey() async throws {
        let harness = try await EngineHarness.make(keys: [:])
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Hello", in: conversation.id)
        #expect(updates == [.failed(ProviderError.missingAPIKey(provider: "Anthropic").presentation)])
        #expect(try await harness.messages(conversation.id).isEmpty)
        #expect(harness.provider.requests.isEmpty)
    }

    @Test("without any model selected the user is told to set one up")
    func noModel() async throws {
        let harness = try await EngineHarness.make(defaultModel: nil)
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Hello", in: conversation.id)
        #expect(updates.failure == AssistantError.noModelSelected.presentation)
        #expect(updates.failure?.recoverySuggestion?.contains("Settings › Assistant") == true)
        #expect(harness.provider.requests.isEmpty)
    }

    @Test("a conversation's own selection wins over the default; an unknown provider fails clearly")
    func selectionResolution() async throws {
        let harness = try await EngineHarness.make()
        let conversation = try await harness.conversations.create(selection: ModelSelection(providerID: "ollama", modelID: "llama3"))
        let updates = await harness.send("Hello", in: conversation.id)
        #expect(updates.failure == AssistantError.providerUnavailable("ollama").presentation)

        try await harness.conversations.setSelection(ModelSelection(providerID: .anthropic, modelID: "claude-haiku-5-5"), for: conversation.id)
        _ = await harness.send("Hello", in: conversation.id)
        #expect(harness.provider.requests.last?.model == "claude-haiku-5-5")
        // An unlisted model falls back to conservative limits.
        #expect(harness.provider.requests.last?.maxTokens == 4_096)
    }

    @Test("empty messages and unknown conversations are rejected")
    func invalidInput() async throws {
        let harness = try await EngineHarness.make()
        let conversation = try await harness.conversations.create()
        #expect(await harness.send("   ", in: conversation.id).failure == AssistantError.emptyMessage.presentation)
        #expect(await harness.send("Hi", in: Conversation.ID()).failure == AssistantError.conversationNotFound.presentation)
    }

    // MARK: Retries and provider failures

    @Test("transient failures before any output are retried, honouring retry-after")
    func retriesBeforeOutput() async throws {
        let provider = FakeProvider(script: [.fail(.rateLimited(retryAfter: 2)), .fail(.overloaded(retryAfter: nil)), .reply(FakeProvider.text("Finally"))])
        let harness = try await EngineHarness.make(provider: provider, configuration: .init(retryPolicy: RetryPolicy(maxAttempts: 4, initialDelay: 1, jitter: 0)))
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Hi", in: conversation.id)
        #expect(updates.completedMessages.last?.text == "Finally")
        #expect(provider.requests.count == 3)
        #expect(harness.sleeps.recorded == [2, 2])
    }

    @Test("a failure after output is not retried; the partial reply is stored as failed")
    func noRetryAfterOutput() async throws {
        let provider = FakeProvider(script: [.failAfter([.usage(TokenUsage(input: 50, output: 1)), .textDelta("Half an ans")], .overloaded(retryAfter: nil))])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Hi", in: conversation.id)
        #expect(provider.requests.count == 1)
        #expect(updates.deltas == "Half an ans")
        #expect(updates.failure == ProviderError.overloaded(retryAfter: nil).presentation)
        let stored = try #require(try await harness.messages(conversation.id).last)
        #expect(stored.status == .failed && stored.text == "Half an ans")
        #expect(stored.errorMessage == ProviderError.overloaded(retryAfter: nil).presentation.message)
        let failureEvents = await harness.events.waitForEvents(3)
        #expect(failureEvents.map(\.name) == [IntelligenceEvents.conversationCreated, IntelligenceEvents.conversationRenamed, IntelligenceEvents.messageFailed])
        let failed = failureEvents.last
        #expect(failed?.attributes["error"] == "overloaded")
        // Partial usage is still accounted for.
        let total = try await harness.usage.total(in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(total.usage.input == 50)
    }

    @Test("permanent errors fail immediately and the failed reply is left out of later requests")
    func permanentFailure() async throws {
        let provider = FakeProvider(script: [.fail(.unauthorized), .reply(FakeProvider.text("Now it works"))])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("First", in: conversation.id)
        #expect(updates.failure == ProviderError.unauthorized.presentation)
        #expect(provider.requests.count == 1)
        _ = await harness.send("Second", in: conversation.id)
        #expect(provider.requests.last?.messages == [WireMessage(role: .user, blocks: [.text("First"), .text("Second")])])
    }

    @Test("a refusal discards the partial reply and runs no tools")
    func refusal() async throws {
        let search = RecordingTool("search_notes")
        let provider = FakeProvider(script: [.reply([.textDelta("I can"), .toolUse(id: "x", name: "search_notes", input: [:]), .stop(.refusal)])])
        let harness = try await EngineHarness.make(provider: provider, tools: [search])
        let conversation = try await harness.conversations.create()
        let updates = await harness.send("Something", in: conversation.id)
        #expect(updates.failure == AssistantError.refused.presentation)
        #expect(search.inputs.isEmpty)
        let stored = try #require(try await harness.messages(conversation.id).last)
        #expect(stored.status == .failed && stored.blocks.isEmpty)
    }

    // MARK: Cancellation and concurrency

    @Test("cancel(conversationID:) stops the stream and stores the partial text as cancelled")
    func cancelByConversation() async throws {
        let provider = FakeProvider(script: [.hang([.usage(TokenUsage(input: 30, output: 1)), .textDelta("Once upon a")])])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        var updates: [AssistantUpdate] = []
        // The consumer keeps listening; the user presses "stop" once text has appeared.
        for try await update in await harness.engine.send(text: "Tell me a story", in: conversation.id) {
            updates.append(update)
            if case .textDelta = update {
                #expect(await harness.engine.isResponding(in: conversation.id))
                await harness.engine.cancel(conversationID: conversation.id)
            }
        }

        let cancelled = try #require(updates.completedMessages.last)
        #expect(cancelled.status == .cancelled && cancelled.text == "Once upon a")
        let stored = try #require(try await harness.messages(conversation.id).last)
        #expect(stored.status == .cancelled && stored.text == "Once upon a")
        await EngineHarness.waitUntil { provider.cancelledStreams == 1 }
        #expect(provider.cancelledStreams == 1)
        let names = await harness.events.waitForEvents(3).map(\.name)
        #expect(names.contains(IntelligenceEvents.messageCancelled))
        #expect(await !harness.engine.isResponding(in: conversation.id))
    }

    @Test("a consumer that stops listening cancels the turn and the partial text is kept")
    func consumerStops() async throws {
        let provider = FakeProvider(script: [.hang([.textDelta("Partial reply")])])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        for try await update in await harness.engine.send(text: "Go", in: conversation.id) {
            if case .textDelta = update { break }
        }
        await EngineHarness.waitUntil {
            let messages = (try? await harness.messages(conversation.id)) ?? []
            return messages.last?.status == .cancelled
        }
        let stored = try #require(try await harness.messages(conversation.id).last)
        #expect(stored.status == .cancelled && stored.text == "Partial reply")
        await EngineHarness.waitUntil { provider.cancelledStreams == 1 }
        #expect(provider.cancelledStreams == 1)
    }

    @Test("a second message while a reply is streaming is refused")
    func turnInProgress() async throws {
        let provider = FakeProvider(script: [.hang([.textDelta("Thinking")])])
        let harness = try await EngineHarness.make(provider: provider)
        let conversation = try await harness.conversations.create()
        let first = Task { await harness.send("One", in: conversation.id) }
        await EngineHarness.waitUntil { !provider.requests.isEmpty }
        let second = await harness.send("Two", in: conversation.id)
        #expect(second == [.failed(AssistantError.turnInProgress.presentation)])
        await harness.engine.cancel(conversationID: conversation.id)
        _ = await first.value
    }

    @Test("an oversized history is trimmed oldest-first to the model's context window")
    func trimsHistory() async throws {
        let small = ModelDescriptor(id: "claude-opus-5-5", displayName: "Small", providerID: .anthropic, contextWindow: 3_000, maxOutputTokens: 500)
        let provider = FakeProvider(models: [small], repeating: .reply(FakeProvider.text(String(repeating: "long answer ", count: 200))))
        let harness = try await EngineHarness.make(provider: provider, configuration: .init(contextSafetyMargin: 0))
        try await harness.memory.setMemoryEnabled(false)
        let conversation = try await harness.conversations.create()
        for index in 0..<4 {
            _ = await harness.send("Question \(index) " + String(repeating: "detail ", count: 100), in: conversation.id)
        }
        let last = try #require(provider.requests.last)
        #expect(last.maxTokens == 500)
        #expect(last.messages.first?.role == .user)
        #expect(last.messages.count < 7)
        #expect(last.messages.last?.blocks.first?.textValue?.hasPrefix("Question 3") == true)
    }
}
