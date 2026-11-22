import Foundation

/// Token counts reported by a provider for one completion.
///
/// `input` counts uncached input tokens only; tokens written to or read from the provider's prompt
/// cache are reported separately (this matches Anthropic's accounting; the OpenAI-compatible
/// provider converts to it).
public struct TokenUsage: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    public static let zero = TokenUsage()

    /// Every input token the request consumed, cached or not.
    public var totalInput: Int { input + cacheCreation + cacheRead }

    public var total: Int { totalInput + output }

    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

extension TokenUsage: Codable {
    enum CodingKeys: String, CodingKey {
        case input, output, cacheCreation, cacheRead
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try container.decodeIfPresent(Int.self, forKey: .input) ?? 0,
            output: try container.decodeIfPresent(Int.self, forKey: .output) ?? 0,
            cacheCreation: try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0,
            cacheRead: try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(cacheCreation, forKey: .cacheCreation)
        try container.encode(cacheRead, forKey: .cacheRead)
    }
}
