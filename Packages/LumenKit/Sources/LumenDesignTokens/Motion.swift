/// Spring parameters (response in seconds, damping fraction 0…1) shared by every animation.
public struct SpringToken: Sendable, Hashable {
    public let response: Double
    public let dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }
}

/// Lumen's motion vocabulary. Motion confirms cause and effect; it never decorates.
public enum Motion {
    /// Toggles, checkmarks, small state changes.
    public static let snappy = SpringToken(response: 0.28, dampingFraction: 0.86)
    /// Layout changes, list insertions, expanding rows.
    public static let smooth = SpringToken(response: 0.42, dampingFraction: 0.9)
    /// Sheets and presentations following a gesture.
    public static let interactive = SpringToken(response: 0.35, dampingFraction: 0.82)
    /// Rare, celebratory moments (completing the last task of the day).
    public static let lively = SpringToken(response: 0.5, dampingFraction: 0.7)

    public enum Duration {
        public static let instant: Double = 0.1
        public static let short: Double = 0.18
        public static let medium: Double = 0.3
        public static let long: Double = 0.5
    }

    /// Delay between items of a staggered entrance.
    public static let stagger: Double = 0.035
    /// Maximum number of staggered items; beyond this everything appears together.
    public static let staggerLimit = 8
    /// Parallax travel as a fraction of scroll offset.
    public static let parallaxFactor: Double = 0.25
    /// Scale applied to pressed controls.
    public static let pressedScale: Double = 0.97

    /// The delay for the `index`-th item of a staggered entrance.
    public static func staggerDelay(for index: Int) -> Double {
        Double(min(max(index, 0), staggerLimit)) * stagger
    }
}
