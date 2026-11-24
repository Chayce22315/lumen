import Foundation
import Testing
import Synchronization
import LumenFoundation

@Suite("RetryPolicy")
struct RetryPolicyTests {
    struct Transient: Error {}
    struct Permanent: Error {}

    @Test("delays grow exponentially and are capped")
    func backoff() {
        let policy = RetryPolicy(maxAttempts: 10, initialDelay: 1, multiplier: 2, maxDelay: 10, jitter: 0)
        #expect(policy.delay(beforeRetry: 1, randomUnit: 0.5) == 1)
        #expect(policy.delay(beforeRetry: 2, randomUnit: 0.5) == 2)
        #expect(policy.delay(beforeRetry: 3, randomUnit: 0.5) == 4)
        #expect(policy.delay(beforeRetry: 5, randomUnit: 0.5) == 10)
        #expect(policy.delay(beforeRetry: 500, randomUnit: 0.5) == 10)
    }

    @Test("jitter only shortens the delay, within the configured fraction")
    func jitter() {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 4, multiplier: 2, maxDelay: 60, jitter: 0.25)
        #expect(policy.delay(beforeRetry: 1, randomUnit: 0) == 4)
        #expect(policy.delay(beforeRetry: 1, randomUnit: 1) == 3)
    }

    @Test("retries transient failures then succeeds")
    func retriesThenSucceeds() async throws {
        let attempts = Mutex(0)
        let sleeps = Mutex<[TimeInterval]>([])
        let result = try await withRetry(
            policy: RetryPolicy(maxAttempts: 4, initialDelay: 1, jitter: 0),
            classify: { $0 is Transient ? .retry : .fail },
            sleep: { seconds in sleeps.withLock { $0.append(seconds) } },
            operation: {
                let attempt = attempts.withLock { value -> Int in
                    value += 1
                    return value
                }
                if attempt < 3 { throw Transient() }
                return "done"
            }
        )
        #expect(result == "done")
        #expect(attempts.withLock { $0 } == 3)
        #expect(sleeps.withLock { $0 } == [1, 2])
    }

    @Test("does not retry permanent failures")
    func permanent() async {
        let attempts = Mutex(0)
        await #expect(throws: Permanent.self) {
            try await withRetry(
                policy: .standard,
                classify: { $0 is Transient ? .retry : .fail },
                sleep: { _ in },
                operation: {
                    attempts.withLock { $0 += 1 }
                    throw Permanent()
                }
            )
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test("honours server-provided delays and gives up after the last attempt")
    func retryAfterAndExhaustion() async {
        let sleeps = Mutex<[TimeInterval]>([])
        await #expect(throws: Transient.self) {
            try await withRetry(
                policy: RetryPolicy(maxAttempts: 3, initialDelay: 1),
                classify: { _ in .retryAfter(7) },
                sleep: { seconds in sleeps.withLock { $0.append(seconds) } },
                operation: { throw Transient() }
            )
        }
        #expect(sleeps.withLock { $0 } == [7, 7])
    }
}
