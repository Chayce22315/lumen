import Foundation
import LumenFoundation

/// Builds what the model sees: the system prompt and a history that fits the context window.
/// Pure: time, calendar, memories and app state are passed in.
public struct ContextBuilder: Sendable {
    public static let defaultPersona = """
        You are the assistant built into Lumen, a personal productivity app for tasks, projects, \
        calendar events, notes, documents, automations and analytics. Be concise and helpful: \
        answer directly, use short paragraphs or lists, and skip filler. When a tool can read or \
        change the user's Lumen data, use it instead of guessing, and never claim you did something \
        unless a tool confirmed it. If a tool fails or the user declines an action, say so plainly \
        and suggest what they can do instead. Ask a brief clarifying question when a request is \
        ambiguous.
        """

    public var persona: String
    /// Memories are listed newest first until this many characters are used.
    public var memoryCharacterLimit: Int
    /// The app-state summary is cut to this many characters.
    public var appContextCharacterLimit: Int

    public init(persona: String = ContextBuilder.defaultPersona, memoryCharacterLimit: Int = 4_000, appContextCharacterLimit: Int = 2_000) {
        self.persona = persona
        self.memoryCharacterLimit = max(0, memoryCharacterLimit)
        self.appContextCharacterLimit = max(0, appContextCharacterLimit)
    }

    /// The system prompt: persona, current date and time in the user's time zone, remembered
    /// facts (only when memory is on, and only enabled items) and the app-state summary.
    public func systemPrompt(
        now: Date,
        calendar: Calendar,
        memories: [MemoryItem],
        memoryEnabled: Bool,
        appContext: String?
    ) -> String {
        var sections = [persona.trimmingCharacters(in: .whitespacesAndNewlines)]
        sections.append("Current date and time: \(Self.describe(now, calendar: calendar)).")

        if memoryEnabled {
            let lines = memoryLines(memories)
            if !lines.isEmpty {
                sections.append("""
                    Things the user asked you to remember (they can review and edit these; prefer \
                    what they say now if it conflicts):
                    \(lines.joined(separator: "\n"))
                    """)
            }
        }

        if let summary = appContext?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            sections.append("Current state of the user's Lumen workspace:\n\(summary.truncated(to: appContextCharacterLimit))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func memoryLines(_ memories: [MemoryItem]) -> [String] {
        var lines: [String] = []
        var used = 0
        let enabled = memories.filter(\.isEnabled).sorted { $0.createdAt > $1.createdAt }
        for memory in enabled {
            let line = "- " + memory.content.collapsingWhitespace
            guard used + line.count <= memoryCharacterLimit else { break }
            used += line.count + 1
            lines.append(line)
        }
        return lines
    }

    /// `Saturday, 2026-11-21 09:00 (time zone Europe/Berlin, UTC+01:00)`. Built from calendar
    /// components rather than a locale-dependent formatter so the prompt is deterministic.
    static func describe(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = components.weekday.flatMap { weekdays.indices.contains($0 - 1) ? weekdays[$0 - 1] : nil } ?? ""
        let day = "\(pad(components.year ?? 0, 4))-\(pad(components.month ?? 1, 2))-\(pad(components.day ?? 1, 2))"
        let time = "\(pad(components.hour ?? 0, 2)):\(pad(components.minute ?? 0, 2))"
        let zone = calendar.timeZone
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3_600
        let minutes = abs(offset) % 3_600 / 60
        let prefix = weekday.isEmpty ? "" : "\(weekday), "
        return "\(prefix)\(day) \(time) (time zone \(zone.identifier), UTC\(sign)\(pad(hours, 2)):\(pad(minutes, 2)))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

// MARK: - Token estimation

extension ContextBuilder {
    /// Fixed per-message overhead (role markers, block framing) in estimated tokens.
    static let messageOverhead = 4

    /// An *estimate* of the tokens in `text`: about four characters per token, rounded up.
    /// Real tokenizers differ by model and language; budgets built on this keep a safety margin.
    public static func estimatedTokens(for text: String) -> Int {
        let characters = text.unicodeScalars.count
        return characters == 0 ? 0 : (characters + 3) / 4
    }

    public static func estimatedTokens(for block: ContentBlock) -> Int {
        switch block {
        case .text(let text):
            return estimatedTokens(for: text)
        case .toolUse(_, let name, let input):
            return estimatedTokens(for: name) + estimatedTokens(for: input.compactText) + 8
        case .toolResult(_, let content, _):
            return estimatedTokens(for: content) + 8
        case .thinking(let text, let signature):
            return estimatedTokens(for: text) + estimatedTokens(for: signature ?? "")
        case .redactedThinking(let data):
            return estimatedTokens(for: data)
        }
    }

    public static func estimatedTokens(for message: ChatMessage) -> Int {
        message.blocks.reduce(messageOverhead) { $0 + estimatedTokens(for: $1) }
    }

    public static func estimatedTokens(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokens(for: $1) }
    }

    public static func estimatedTokens(for tools: [ToolDefinition]) -> Int {
        tools.reduce(0) { total, tool in
            total + estimatedTokens(for: tool.name) + estimatedTokens(for: tool.description)
                + estimatedTokens(for: tool.inputSchema.compactText) + 8
        }
    }

    /// Tokens available for history: `contextWindow - maxOutputTokens - reserve`, never negative.
    /// `reserve` covers the system prompt, tool definitions and a safety margin.
    public static func historyBudget(contextWindow: Int, maxOutputTokens: Int, reserve: Int) -> Int {
        max(0, contextWindow - maxOutputTokens - reserve)
    }
}
