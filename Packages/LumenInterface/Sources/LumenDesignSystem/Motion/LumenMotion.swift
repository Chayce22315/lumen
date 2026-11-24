import SwiftUI
import LumenDesignTokens

extension Animation {
    /// A spring from the motion tokens.
    public static func lumen(_ token: SpringToken) -> Animation {
        .spring(response: token.response, dampingFraction: token.dampingFraction)
    }

    public static var lumenSnappy: Animation { .lumen(Motion.snappy) }
    public static var lumenSmooth: Animation { .lumen(Motion.smooth) }
    public static var lumenInteractive: Animation { .lumen(Motion.interactive) }
    public static var lumenLively: Animation { .lumen(Motion.lively) }
}

private struct ReducedMotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: Motion.Duration.short) : animation, value: value)
    }
}

private struct StaggeredAppearance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(.lumenSmooth.delay(reduceMotion ? 0 : Motion.staggerDelay(for: index))) {
                    isVisible = true
                }
            }
    }
}

extension View {
    /// Animates changes of `value` with `animation`, or a short fade when Reduce Motion is on.
    public func lumenAnimation<Value: Equatable>(_ animation: Animation = .lumenSmooth, value: Value) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }

    /// Fades and lifts the view in, staggered by `index` (bounded), once.
    public func staggeredAppearance(index: Int) -> some View {
        modifier(StaggeredAppearance(index: index))
    }
}

/// Runs `body` animated, honouring Reduce Motion.
@MainActor
public func withLumenAnimation<Result>(_ animation: Animation = .lumenSmooth, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? .easeInOut(duration: Motion.Duration.short) : animation, body)
}
