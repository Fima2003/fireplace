import AppKit
import MetalKit

/// The live fireplace: the fluid simulation and its rendering, 30 times a second.
/// `isPaused` is flipped by the controller whenever the desktop is covered.
final class FireplaceView: MTKView, MTKViewDelegate {
    private let renderer: FireRenderer
    private let start = CACurrentMediaTime()

    init?(frame: NSRect, seed: FireSeed) {
        guard let renderer = FireRenderer(layoutAspect: Float(frame.width / frame.height), seed: seed) else { return nil }
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)
        colorPixelFormat = .bgra8Unorm_srgb
        framebufferOnly = true
        preferredFramesPerSecond = 30
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        renderer.encodeFrame(to: drawable.texture, time: CACurrentMediaTime() - start, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func stoke() { renderer.simulation.stoke() }
}
