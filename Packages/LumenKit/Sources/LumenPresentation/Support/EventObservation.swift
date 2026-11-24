import Foundation
import Synchronization
import LumenCore

/// Owns an observation task and cancels it when released, so a view model's subscription ends
/// with the view model even though its `deinit` cannot touch main-actor state.
final class ObservationHandle: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    init() {}

    func replace(with newTask: Task<Void, Never>) {
        let previous = task.withLock { current -> Task<Void, Never>? in
            let old = current
            current = newTask
            return old
        }
        previous?.cancel()
    }

    func cancel() {
        task.withLock { $0?.cancel() }
    }

    deinit {
        task.withLock { $0?.cancel() }
    }
}

extension EventBus {
    /// Calls `action` on the main actor after matching events, coalescing bursts into one call
    /// per `debounce` interval.
    @MainActor
    func observe(
        _ filter: EventFilter,
        debounce: TimeInterval = 0.25,
        into handle: ObservationHandle,
        action: @escaping @MainActor () async -> Void
    ) {
        let stream = events(matching: filter)
        let delay = UInt64(max(0, debounce) * 1_000_000_000)
        handle.replace(with: Task { @MainActor in
            var pending: Task<Void, Never>?
            for await _ in stream {
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                    await action()
                }
            }
            pending?.cancel()
        })
    }
}
