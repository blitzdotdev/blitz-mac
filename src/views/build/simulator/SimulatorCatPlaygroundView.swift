import SwiftUI

struct SimulatorCatPlaygroundView<PhoneContent: View>: View {
    let scene: SimulatorCatSceneModel
    let phoneAspectRatio: CGFloat?
    let mode: SimulatorCatSceneModel.RenderMode
    @ViewBuilder let phoneContent: () -> PhoneContent

    var body: some View {
        GeometryReader { geometry in
            let phoneRect = phoneRect(in: geometry.size)

            ZStack {
                SimulatorCatMetalView(scene: scene, phoneRect: phoneRect, mode: mode)
                    .overlay(alignment: .topLeading) {
                        if mode == .simulatorStage {
                            catBadge
                                .padding(14)
                        }
                    }

                if let phoneRect {
                    phoneContent()
                        .frame(width: phoneRect.width, height: phoneRect.height)
                        .position(x: phoneRect.midX, y: phoneRect.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var catBadge: some View {
        Text("C.C.")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func phoneRect(in size: CGSize) -> CGRect? {
        guard let phoneAspectRatio else { return nil }

        let horizontalReserve = min(max(size.width * 0.14, 72), 160)
        let verticalReserve = min(max(size.height * 0.08, 48), 104)
        let availableWidth = max(size.width - horizontalReserve * 2, 180)
        let availableHeight = max(size.height - verticalReserve * 2, 280)

        let width = min(availableWidth, availableHeight * phoneAspectRatio)
        let height = width / phoneAspectRatio

        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}

struct SimulatorCatFullscreenWindowView: View {
    @Bindable var appState: AppState
    @State private var window: NSWindow?
    @State private var didAttemptFullscreen = false

    var body: some View {
        SimulatorCatPlaygroundView(
            scene: appState.simulatorCats,
            phoneAspectRatio: nil,
            mode: .catsOnlyFullscreen
        ) {
            EmptyView()
        }
        .background(WindowObserverView { resolvedWindow in
            window = resolvedWindow
            guard let resolvedWindow,
                  appState.simulatorCats.consumePendingFullscreenRequest(),
                  !didAttemptFullscreen else { return }
            didAttemptFullscreen = true
            DispatchQueue.main.async {
                if !resolvedWindow.styleMask.contains(.fullScreen) {
                    resolvedWindow.toggleFullScreen(nil)
                }
            }
        })
        .onDisappear {
            didAttemptFullscreen = false
            window = nil
        }
    }
}
