import Foundation
import Testing
import LumenFoundation
import LumenTestSupport
@testable import LumenIntelligence

@Suite("ContextBuilder")
struct ContextBuilderTests {
    let builder = ContextBuilder()
    let now = ManualTimeSource.referenceDate

    func memory(_ content: String, enabled: Bool = true, age: TimeInterval = 0) -> MemoryItem {
        MemoryItem(content: content, source: .user, isEnabled: enabled, createdAt: now.addingTimeInterval(-age))
    }

    // MARK: System prompt

    @Test("states the persona and the current date, time and time zone")
    func dateAndTime() {
        var calendar = Calendar.testUTC
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? calendar.timeZone
        let prompt = builder.systemPrompt(now: now, calendar: calendar, memories: [], memoryEnabled: true, appContext: nil)
        #expect(prompt.hasPrefix("You are the assistant built into Lumen"))
        #expect(prompt.contains("Current date and time: Saturday, 2026-11-21 18:00 (time zone Asia/Tokyo, UTC+09:00)."))
        #expect(!prompt.contains("remember"))
    }

    @Test("zones west and east of UTC get signed offsets")
    func offsets() {
        var calendar = Calendar.testUTC
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? calendar.timeZone
        #expect(ContextBuilder.describe(now, calendar: calendar) == "Saturday, 2026-11-21 10:00 (time zone Europe/Berlin, UTC+01:00)")
        calendar.timeZone = TimeZone(identifier: "America/St_Johns") ?? calendar.timeZone
        #expect(ContextBuilder.describe(now, calendar: calendar) == "Saturday, 2026-11-21 05:30 (time zone America/St_Johns, UTC-03:30)")
        #expect(ContextBuilder.describe(now, calendar: .testUTC).hasSuffix("UTC+00:00)"))
    }

    @Test("includes enabled memories, newest first, only while memory is on")
    func memories() {
        let items = [memory("Prefers metric units", age: 100), memory("Works at Example Corp", age: 10), memory("Disabled fact", enabled: false)]
        let on = builder.systemPrompt(now: now, calendar: .testUTC, memories: items, memoryEnabled: true, appContext: nil)
        #expect(on.contains("- Works at Example Corp\n- Prefers metric units"))
        #expect(!on.contains("Disabled fact"))
        let off = builder.systemPrompt(now: now, calendar: .testUTC, memories: items, memoryEnabled: false, appContext: nil)
        #expect(!off.contains("Prefers metric units"))
    }

    @Test("memories are capped by the character limit")
    func memoryLimit() {
        let limited = ContextBuilder(memoryCharacterLimit: 30)
        let prompt = limited.systemPrompt(
            now: now, calendar: .testUTC,
            memories: [memory("Second memory that is long", age: 5), memory("First memory, the newest", age: 1)],
            memoryEnabled: true, appContext: nil
        )
        #expect(prompt.contains("- First memory, the newest"))
        #expect(!prompt.contains("Second memory"))
    }

    @Test("adds the app-state summary, truncated to its limit")
    func appContext() {
        let short = ContextBuilder(appContextCharacterLimit: 20)
        let prompt = short.systemPrompt(now: now, calendar: .testUTC, memories: [], memoryEnabled: true, appContext: "  3 tasks due today; next event at 14:00 Design review  ")
        #expect(prompt.contains("Current state of the user's Lumen workspace:\n3 tasks due today; …"))
        let none = builder.systemPrompt(now: now, calendar: .testUTC, memories: [], memoryEnabled: true, appContext: "   ")
        #expect(!none.contains("workspace"))
    }

    // MARK: Token estimation

    @Test("token estimate is about one token per four characters, rounded up")
    func tokenEstimate() {
        #expect(ContextBuilder.estimatedTokens(for: "") == 0)
        #expect(ContextBuilder.estimatedTokens(for: "abc") == 1)
        #expect(ContextBuilder.estimatedTokens(for: "abcd") == 1)
        #expect(ContextBuilder.estimatedTokens(for: "abcde") == 2)
        #expect(ContextBuilder.estimatedTokens(for: String(repeating: "x", count: 4_000)) == 1_000)
    }

    @Test("history budget subtracts output and reserve and never goes negative")
    func budget() {
        #expect(ContextBuilder.historyBudget(contextWindow: 200_000, maxOutputTokens: 64_000, reserve: 1_000) == 135_000)
        #expect(ContextBuilder.historyBudget(contextWindow: 8_000, maxOutputTokens: 8_000, reserve: 500) == 0)
    }

    // MARK: Trimming

    @Test("a history within budget is returned unchanged except for earlier reasoning")
    func fitsUnchanged() {
        var transcript = TranscriptBuilder()
        transcript.user("First question")
        transcript.toolRound(id: "a", reasoning: true)
        transcript.assistant("First answer")
        transcript.user("Second question")
        transcript.toolRound(id: "b", reasoning: true)
        let fitted = builder.fit(transcript.messages, budget: 1_000_000)
        #expect(fitted.droppedMessageCount == 0)
        #expect(fitted.messages.map(\.id) == transcript.messages.map(\.id))
        // Reasoning survives only in the current turn.
        let earlierHasReasoning = fitted.messages[1].blocks.contains { $0.isReasoning }
        let currentHasReasoning = fitted.messages[5].blocks.contains { $0.isReasoning }
        #expect(!earlierHasReasoning)
        #expect(currentHasReasoning)
        #expect(!fitted.strippedCurrentTurnReasoning)
    }

    @Test("drops the oldest turns first")
    func dropsOldestTurns() {
        var transcript = TranscriptBuilder()
        transcript.user(String(repeating: "old ", count: 200))
        transcript.assistant(String(repeating: "old answer ", count: 100))
        let middle = transcript.user("middle")
        transcript.assistant("middle answer")
        let latest = transcript.user("latest")
        let budget = ContextBuilder.estimatedTokens(for: Array(transcript.messages.suffix(3)))
        let fitted = builder.fit(transcript.messages, budget: budget)
        #expect(fitted.messages.map(\.id) == [middle.id, transcript.messages[3].id, latest.id])
        #expect(fitted.droppedMessageCount == 2)
    }

    @Test("always keeps the latest user message, even when it alone exceeds the budget")
    func keepsLatestUserMessage() {
        var transcript = TranscriptBuilder()
        transcript.user("earlier")
        transcript.assistant("reply")
        let latest = transcript.user(String(repeating: "huge ", count: 1_000))
        let fitted = builder.fit(transcript.messages, budget: 10)
        #expect(fitted.messages.map(\.id) == [latest.id])
    }

    @Test("within an oversized current turn, drops the oldest tool rounds but keeps the prompt and newest round")
    func dropsOldestRounds() {
        var transcript = TranscriptBuilder()
        let prompt = transcript.user("Plan my week")
        transcript.toolRound(id: "r1", payload: String(repeating: "x", count: 4_000), reasoning: true)
        transcript.toolRound(id: "r2", payload: String(repeating: "y", count: 4_000), reasoning: true)
        transcript.toolRound(id: "r3", payload: "small", reasoning: true)
        let fitted = builder.fit(transcript.messages, budget: 200)
        let ids = fitted.messages.map(\.id)
        #expect(ids.first == prompt.id)
        #expect(ids.count == 3)
        #expect(fitted.messages[1].toolUses.map(\.id) == ["r3"])
        // Dropping changed the request prefix, so the remaining reasoning had to go too.
        #expect(fitted.strippedCurrentTurnReasoning)
        #expect(!fitted.messages.contains { $0.blocks.contains(where: \.isReasoning) })
    }

    @Test("trimming invariants hold for generated histories and budgets")
    func generatedInvariants() {
        var random = SeededGenerator(seed: 42)
        for _ in 0..<200 {
            var transcript = TranscriptBuilder()
            var roundID = 0
            let turns = Int.random(in: 1...6, using: &random)
            for turn in 0..<turns {
                transcript.user("turn \(turn) " + String(repeating: "w", count: Int.random(in: 0...400, using: &random)))
                for _ in 0..<Int.random(in: 0...3, using: &random) {
                    roundID += 1
                    transcript.toolRound(
                        id: "t\(roundID)",
                        payload: String(repeating: "p", count: Int.random(in: 0...800, using: &random)),
                        reasoning: Bool.random(using: &random)
                    )
                }
                if Bool.random(using: &random) {
                    transcript.assistant("answer \(turn)")
                }
            }
            let history = transcript.messages
            let budget = Int.random(in: 0...800, using: &random)
            let fitted = builder.fit(history, budget: budget)
            let result = fitted.messages

            // The latest user prompt is always present.
            let latestPrompt = history.last(where: \.startsTurn)
            #expect(result.contains { $0.id == latestPrompt?.id })
            // The result is an ordered subsequence of the input.
            let positions = result.compactMap { message in history.firstIndex { $0.id == message.id } }
            #expect(positions.count == result.count && positions == positions.sorted())
            // Every tool call is answered by the next message, and every result answers the previous one.
            for (index, message) in result.enumerated() {
                for call in message.toolUses {
                    let next = index + 1 < result.count ? result[index + 1] : nil
                    let answered = next?.blocks.contains { block in
                        if case .toolResult(let id, _, _) = block { return id == call.id }
                        return false
                    } ?? false
                    #expect(answered)
                }
                for case .toolResult(let id, _, _) in message.blocks {
                    #expect(index > 0 && result[index - 1].toolUses.contains { $0.id == id })
                }
            }
            // Reasoning only ever remains in the current turn.
            let currentStart = result.lastIndex(where: \.startsTurn) ?? 0
            #expect(!result[..<currentStart].contains { $0.blocks.contains(where: \.isReasoning) })
            // Nothing is dropped when everything fits.
            if ContextBuilder.estimatedTokens(for: history.map { $0.removingReasoning() }) <= budget {
                #expect(fitted.droppedMessageCount == 0)
            }
            #expect(result.count + fitted.droppedMessageCount == history.count)
        }
    }
}
