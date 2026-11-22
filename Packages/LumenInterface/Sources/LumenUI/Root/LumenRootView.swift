import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// The app's root: launch, failure and the main interface, with banners and toasts on top.
public struct LumenRootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .top) {
            switch model.phase {
            case .launching:
                LaunchView()
            case .failed(let presentation):
                StateMessage(presentation.title, message: presentation.message, symbolName: "exclamationmark.triangle", actionTitle: "Try again") {
                    Task { await model.launch() }
                }
                .lumenScreenBackground()
            case .ready(let services):
                MainTabView(services: services, model: model)
            }
            overlays
        }
        .tint(LumenColor.accent)
        .task { await model.launch() }
        .onOpenURL { model.handle(url: $0) }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active: await model.sceneDidBecomeActive()
                case .background: await model.sceneDidEnterBackground()
                default: break
                }
            }
        }
    }

    private var overlays: some View {
        VStack(spacing: LumenSpace.s) {
            ForEach(model.banners) { issue in
                Banner(title: issue.presentation.title, message: issue.presentation.message) {
                    withAnimation(.lumenSnappy) { model.dismissBanner(issue.id) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if let toast = model.toast {
                Toast(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.lumenSmooth) { model.toast = nil }
                    }
                    .padding(.bottom, 72)
            }
        }
        .padding(.horizontal, LumenSpace.l)
        .animation(.lumenSmooth, value: model.banners.map(\.id))
        .animation(.lumenSmooth, value: model.toast)
    }
}

/// Shown for the moment it takes to open the database.
struct LaunchView: View {
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: LumenSpace.l) {
            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LumenColor.accent)
                .opacity(glow ? 1 : 0.5)
                .scaleEffect(glow && !reduceMotion ? 1.06 : 1)
            Text("Lumen")
                .lumenText(.title)
                .foregroundStyle(LumenColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lumenScreenBackground()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lumen is opening")
    }
}
