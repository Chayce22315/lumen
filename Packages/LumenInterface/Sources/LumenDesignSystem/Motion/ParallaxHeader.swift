import SwiftUI
import LumenDesignTokens

private struct ParallaxModifier: ViewModifier {
    let offset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Content scrolled past the top drifts slower than the page and fades slightly.
        let travel = max(0, offset)
        content
            .offset(y: reduceMotion ? 0 : travel * CGFloat(Motion.parallaxFactor))
            .opacity(reduceMotion ? 1 : Double(max(0.3, 1 - travel / 220)))
    }
}

extension View {
    /// Subtle parallax for a header, driven by the scroll offset of its scroll view.
    public func parallax(offset: CGFloat) -> some View {
        modifier(ParallaxModifier(offset: offset))
    }
}
