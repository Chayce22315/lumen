import Foundation

/// A value compared with the same measure over an earlier period.
public struct Comparison: Sendable, Hashable, Codable {
    public enum Direction: String, Sendable, Hashable, Codable {
        case up
        case down
        case unchanged
    }

    public let current: Double
    public let previous: Double
    /// `current - previous`.
    public let absoluteChange: Double
    /// Change relative to `previous`, in percent (40 means +40 %). `nil` when `previous` is 0,
    /// because growth from nothing has no meaningful percentage.
    public let percentChange: Double?

    public init(current: Double, previous: Double) {
        self.current = current
        self.previous = previous
        self.absoluteChange = current - previous
        self.percentChange = SeriesBuilder.percentChange(from: previous, to: current)
    }

    public var direction: Direction {
        if absoluteChange > 0 { return .up }
        if absoluteChange < 0 { return .down }
        return .unchanged
    }
}
