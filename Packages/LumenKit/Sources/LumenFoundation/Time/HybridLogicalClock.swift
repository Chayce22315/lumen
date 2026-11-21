import Foundation

/// A hybrid logical clock timestamp: physical milliseconds, a logical counter and the replica
/// that produced it. Totally ordered, and its string form sorts lexicographically in the same
/// order, so it can be compared inside SQLite.
public struct HybridTimestamp: Hashable, Sendable, Comparable {
    public let milliseconds: Int64
    public let counter: UInt32
    public let replica: String

    public init(milliseconds: Int64, counter: UInt32, replica: String) {
        self.milliseconds = milliseconds
        self.counter = counter
        self.replica = replica
    }

    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.replica < rhs.replica
    }

    public static let zero = HybridTimestamp(milliseconds: 0, counter: 0, replica: "")
}

extension HybridTimestamp: CustomStringConvertible, LosslessStringConvertible {
    /// `MMMMMMMMMMMMMMM-CCCCCCCCCC-replica`, zero padded so string order equals timestamp order.
    public var description: String {
        "\(Self.pad(String(milliseconds), 15))-\(Self.pad(String(counter), 10))-\(replica)"
    }

    public init?(_ description: String) {
        let parts = description.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let milliseconds = Int64(parts[0]), milliseconds >= 0,
              let counter = UInt32(parts[1])
        else { return nil }
        self.init(milliseconds: milliseconds, counter: counter, replica: String(parts[2]))
    }

    private static func pad(_ digits: String, _ width: Int) -> String {
        digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

extension HybridTimestamp: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = HybridTimestamp(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid hybrid timestamp '\(text)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Hybrid logical clock (Kulkarni et al.). Produces timestamps that respect causality across
/// replicas even when device clocks drift, which is what conflict resolution in the sync engine
/// relies on.
public struct HybridLogicalClock: Sendable {
    public let replica: String
    public private(set) var latest: HybridTimestamp

    public init(replica: String, latest: HybridTimestamp? = nil) {
        self.replica = replica
        self.latest = latest ?? HybridTimestamp(milliseconds: 0, counter: 0, replica: replica)
    }

    /// Timestamp for a local event.
    public mutating func tick(now: Date) -> HybridTimestamp {
        let physical = Self.milliseconds(now)
        let next: HybridTimestamp
        if physical > latest.milliseconds {
            next = HybridTimestamp(milliseconds: physical, counter: 0, replica: replica)
        } else {
            next = HybridTimestamp(milliseconds: latest.milliseconds, counter: latest.counter &+ 1, replica: replica)
        }
        latest = next
        return next
    }

    /// Merges a timestamp received from another replica and returns the timestamp of the receive event.
    public mutating func receive(_ remote: HybridTimestamp, now: Date) -> HybridTimestamp {
        let physical = Self.milliseconds(now)
        let wall = max(latest.milliseconds, remote.milliseconds, physical)
        let counter: UInt32
        if wall == latest.milliseconds && wall == remote.milliseconds {
            counter = max(latest.counter, remote.counter) &+ 1
        } else if wall == latest.milliseconds {
            counter = latest.counter &+ 1
        } else if wall == remote.milliseconds {
            counter = remote.counter &+ 1
        } else {
            counter = 0
        }
        let next = HybridTimestamp(milliseconds: wall, counter: counter, replica: replica)
        latest = next
        return next
    }

    static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value > 0 else { return 0 }
        return Int64(min(value, Double(Int64.max / 2)))
    }
}
