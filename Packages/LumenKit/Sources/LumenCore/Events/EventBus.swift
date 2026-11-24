import Foundation
import Synchronization
import LumenFoundation

/// Selects which events a subscriber receives.
public struct EventFilter: Sendable, Hashable {
    public var names: Set<EventName>?
    public var modules: Set<String>?
    public var entityKinds: Set<EntityKind>?

    public init(names: Set<EventName>? = nil, modules: Set<String>? = nil, entityKinds: Set<EntityKind>? = nil) {
        self.names = names
        self.modules = modules
        self.entityKinds = entityKinds
    }

    public static let all = EventFilter()

    public func matches(_ event: DomainEvent) -> Bool {
        if let names, !names.contains(event.name) { return false }
        if let modules, !modules.contains(event.name.module) { return false }
        if let entityKinds {
            guard let kind = event.entity?.kind, entityKinds.contains(kind) else { return false }
        }
        return true
    }
}

/// In-process publish/subscribe for committed domain events.
///
/// Publishing is synchronous and preserves order per subscriber. Each subscriber gets a bounded
/// buffer; a subscriber that falls more than `bufferSize` events behind loses the oldest ones
/// (reported through `droppedEventCount`) rather than stalling publishers.
public final class EventBus: Sendable {
    private struct Subscriber {
        let filter: EventFilter
        let continuation: AsyncStream<DomainEvent>.Continuation
    }

    private let subscribers = Mutex<[UUID: Subscriber]>([:])
    private let dropped = Mutex(0)
    private let bufferSize: Int

    public init(bufferSize: Int = 512) {
        self.bufferSize = max(1, bufferSize)
    }

    /// Delivers `event` to every matching subscriber.
    public func publish(_ event: DomainEvent) {
        let targets = subscribers.withLock { subscribers in
            subscribers.values.filter { $0.filter.matches(event) }.map(\.continuation)
        }
        for continuation in targets {
            if case .dropped = continuation.yield(event) {
                dropped.withLock { $0 += 1 }
            }
        }
    }

    public func publish(_ events: [DomainEvent]) {
        for event in events {
            publish(event)
        }
    }

    /// A stream of matching events published after this call. Cancel the consuming task (or drop
    /// the stream) to unsubscribe.
    public func events(matching filter: EventFilter = .all) -> AsyncStream<DomainEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DomainEvent>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        subscribers.withLock { $0[id] = Subscriber(filter: filter, continuation: continuation) }
        return stream
    }

    public var subscriberCount: Int {
        subscribers.withLock { $0.count }
    }

    /// Events discarded because a subscriber's buffer was full.
    public var droppedEventCount: Int {
        dropped.withLock { $0 }
    }

    /// Ends every subscription (used on shutdown).
    public func finishAll() {
        let all = subscribers.withLock { subscribers -> [Subscriber] in
            let values = Array(subscribers.values)
            subscribers.removeAll()
            return values
        }
        for subscriber in all {
            subscriber.continuation.finish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        _ = subscribers.withLock { $0.removeValue(forKey: id) }
    }
}
