import SwiftUI
import MetalKit

struct SimulatorCatMetalView: NSViewRepresentable {
    let scene: SimulatorCatSceneModel
    let phoneRect: CGRect?
    let mode: SimulatorCatSceneModel.RenderMode

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: scene)
    }

    func makeNSView(context: Context) -> MTKView {
        let renderer = context.coordinator.renderer
        let mtkView = MTKView()
        mtkView.device = renderer.metalDevice
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.autoResizeDrawable = true
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.phoneRect = phoneRect
        context.coordinator.mode = mode
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let scene: SimulatorCatSceneModel
        let renderer: SimulatorCatRenderer
        var phoneRect: CGRect?
        var mode: SimulatorCatSceneModel.RenderMode = .simulatorStage

        init(scene: SimulatorCatSceneModel) {
            self.scene = scene
            self.renderer = try! SimulatorCatRenderer()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor else {
                return
            }

            let boundsSize = view.bounds.size
            let scaleX = boundsSize.width > 0 ? view.drawableSize.width / boundsSize.width : 1
            let scaleY = boundsSize.height > 0 ? view.drawableSize.height / boundsSize.height : 1
            let scaledPhoneRect = phoneRect.map {
                CGRect(
                    x: $0.origin.x * scaleX,
                    y: $0.origin.y * scaleY,
                    width: $0.size.width * scaleX,
                    height: $0.size.height * scaleY
                )
            }
            let snapshot = scene.snapshot(
                stageSize: view.drawableSize,
                phoneRect: scaledPhoneRect,
                mode: mode
            )
            renderer.render(snapshot: snapshot, to: drawable, renderPassDescriptor: renderPassDescriptor)
        }
    }
}
