import SwiftUI

/// A thin circular progress indicator that animates to its value.
public struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat
    @State private var displayed: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(fraction: Double, tint: Color = LumenColor.accent, lineWidth: CGFloat = 3) {
        self.fraction = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        self.tint = tint
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(LumenColor.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: displayed)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { animate(to: fraction) }
        .onChange(of: fraction) { _, new in animate(to: new) }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    private func animate(to value: Double) {
        if reduceMotion {
            displayed = value
        } else {
            withAnimation(.lumenSmooth) { displayed = value }
        }
    }
}
