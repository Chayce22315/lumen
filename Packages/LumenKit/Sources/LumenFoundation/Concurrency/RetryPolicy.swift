import Foundation

/// Exponential backoff with bounded jitter.
///
/// Shared by the intelligence engine (rate limits, overloaded providers), the sync engine
/// (transport failures) and the automation engine (failed steps), so every system backs off
/// the same predictable way.
public struct RetryPolicy: Sendable, Hashable, Codable {
    /// Total attempts including the first one. `1` means "never retry".
    public var maxAttempts: Int
    /// Delay before the first retry, in seconds.
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// Fraction of the computed delay that is randomized, `0...1`.
    public var jitter: Double

    public init(maxAttempts: Int, initialDelay: TimeInterval, multiplier: Double = 2, maxDelay: TimeInterval = 60, jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(max(jitter, 0), 1)
    }

    public static let never = RetryPolicy(maxAttempts: 1, initialDelay: 0)
    public static let standard = RetryPolicy(maxAttempts: 4, initialDelay: 1, multiplier: 2, maxDelay: 30, jitter: 0.2)

    /// Delay before retry number `retry` (1-based: `1` is the first retry).
    ///
    /// - Parameter randomUnit: a value in `0...1` used for jitter; injected so the function is pure.
    public func delay(beforeRetry retry: Int, randomUnit: Double) -> TimeInterval {
        guard retry >= 1 else { return 0 }
        let exponent = Double(retry - 1)
        let raw = initialDelay * pow(multiplier, exponent)
        let capped = min(raw.isFinite ? raw : maxDelay, maxDelay)
        let unit = min(max(randomUnit, 0), 1)
        // Jitter spreads the delay over [capped * (1 - jitter), capped].
        return capped * (1 - jitter * unit)
    }

    public func allowsRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }
}

/// What to do after a failed attempt.
public enum RetryDecision: Sendable, Equatable {
    /// Retry using the policy's backoff.
    case retry
    /// Retry after a server-provided delay (for example an HTTP `retry-after` header).
    case retryAfter(TimeInterval)
    /// Do not retry; rethrow.
    case fail
}

/// Runs `operation`, retrying according to `policy` while `classify` allows it.
///
/// Cancellation is never retried: a `CancellationError` (or a cancelled task) is rethrown immediately.
public func withRetry<T>(
    policy: RetryPolicy,
    isolation: isolated (any Actor)? = #isolation,
    classify: (any Error) -> RetryDecision,
    sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    randomUnit: () -> Double = { Double.random(in: 0...1) },
    onRetry: (_ attempt: Int, _ error: any Error, _ delay: TimeInterval) -> Void = { _, _, _ in },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled, policy.allowsRetry(afterAttempt: attempt) else { throw error }
            let delay: TimeInterval
            switch classify(error) {
            case .fail:
                throw error
            case .retry:
                delay = policy.delay(beforeRetry: attempt, randomUnit: randomUnit())
            case .retryAfter(let seconds):
                // A server-provided delay is honoured as-is; only nonsensical values fall back to the cap.
                delay = seconds.isFinite ? max(0, seconds) : policy.maxDelay
            }
            onRetry(attempt, error, delay)
            try await sleep(delay)
            attempt += 1
        }
    }
}
