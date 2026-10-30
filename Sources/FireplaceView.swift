import AppKit
import QuartzCore

/// The live fireplace: the still art as a backdrop with Core Animation flames on top.
/// All motion is particle emitters and layer animations run by the window server,
/// so the app itself does no per-frame work.
final class FireplaceView: NSView {
    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        let pixelSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        let layout = FireplaceLayout(size: pixelSize)
        root.contents = FireplaceArt.render(size: pixelSize, flames: false)
        root.contentsGravity = .resize

        func points(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
        }
        let firebox = points(layout.firebox)
        let archHeight = layout.archHeight / scale

        root.addSublayer(roomGlow(around: firebox, width: frame.width))

        let fire = CALayer()
        fire.frame = firebox
        let mask = CAShapeLayer()
        mask.path = FireplaceLayout.archPath(in: CGRect(origin: .zero, size: firebox.size), archHeight: archHeight)
        fire.mask = mask
        fire.addSublayer(emberGlow(in: firebox.size))
        fire.addSublayer(flames(in: firebox.size, scale: scale))
        root.addSublayer(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func roomGlow(around firebox: CGRect, width: CGFloat) -> CALayer {
        let glow = CAGradientLayer()
        glow.type = .radial
        let d = width * 1.2
        glow.frame = CGRect(x: firebox.midX - d / 2, y: firebox.minY + firebox.height * 0.3 - d / 2, width: d, height: d)
        glow.colors = [NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.16).cgColor,
                       NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0.05).cgColor,
                       NSColor.clear.cgColor]
        glow.locations = [0, 0.35, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.add(flicker(values: [0.75, 1, 0.82, 0.95, 0.7, 1, 0.85, 0.75], duration: 2.6), forKey: "flicker")
        return glow
    }

    private func emberGlow(in size: CGSize) -> CALayer {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(x: size.width * 0.05, y: -size.height * 0.25, width: size.width * 0.9, height: size.height * 0.8)
        glow.colors = [NSColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 0.7).cgColor,
                       NSColor(srgbRed: 0.8, green: 0.15, blue: 0.02, alpha: 0.3).cgColor,
                       NSColor.clear.cgColor]
        glow.locations = [0, 0.4, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.add(flicker(values: [0.8, 1, 0.7, 0.95, 0.85, 0.65, 1, 0.8], duration: 1.7), forKey: "flicker")
        return glow
    }

    private func flicker(values: [Float], duration: CFTimeInterval) -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values
        a.duration = duration
        a.calculationMode = .cubic
        a.repeatCount = .infinity
        return a
    }

    private func flames(in size: CGSize, scale: CGFloat) -> CAEmitterLayer {
        let particle = FireplaceArt.particleImage()
        let particleSize: CGFloat = 128
        let fw = size.width, fh = size.height

        let emitter = CAEmitterLayer()
        emitter.frame = CGRect(origin: .zero, size: size)
        emitter.emitterPosition = CGPoint(x: fw / 2, y: fh * 0.13)
        emitter.emitterSize = CGSize(width: fw * 0.36, height: 1)
        emitter.emitterShape = .line
        emitter.renderMode = .additive
        emitter.seed = UInt32.random(in: 0...UInt32.max)
        emitter.contentsScale = scale

        // Big soft tongues of flame that cool from orange to red as they rise.
        let flame = CAEmitterCell()
        flame.contents = particle
        flame.birthRate = 260
        flame.lifetime = 0.9
        flame.lifetimeRange = 0.3
        // Small random drift plus strong buoyancy, so flames accelerate upward like real ones.
        flame.velocity = fh * 0.06
        flame.velocityRange = fh * 0.04
        flame.emissionRange = .pi * 2
        flame.yAcceleration = fh * 1.5
        flame.scale = fw * 0.17 / particleSize
        flame.scaleRange = flame.scale * 0.3
        flame.scaleSpeed = -flame.scale * 0.5
        flame.spinRange = 1
        flame.color = NSColor(srgbRed: 1, green: 0.5, blue: 0.15, alpha: 0.45).cgColor
        flame.alphaSpeed = -0.45
        flame.greenSpeed = -0.45
        flame.blueSpeed = -0.3

        // Bright, short-lived core near the logs.
        let core = CAEmitterCell()
        core.contents = particle
        core.birthRate = 90
        core.lifetime = 0.55
        core.lifetimeRange = 0.2
        core.velocity = fh * 0.04
        core.emissionRange = .pi * 2
        core.yAcceleration = fh * 1.2
        core.scale = fw * 0.1 / particleSize
        core.scaleSpeed = -core.scale * 0.8
        core.color = NSColor(srgbRed: 1, green: 0.85, blue: 0.5, alpha: 0.45).cgColor
        core.alphaSpeed = -0.9

        // Occasional sparks drifting up.
        let ember = CAEmitterCell()
        ember.contents = particle
        ember.birthRate = 4
        ember.lifetime = 2.5
        ember.lifetimeRange = 1
        ember.velocity = fh * 0.12
        ember.velocityRange = fh * 0.06
        ember.emissionRange = .pi * 2
        ember.yAcceleration = fh * 0.3
        ember.scale = 5 / particleSize
        ember.scaleRange = 2 / particleSize
        ember.color = NSColor(srgbRed: 1, green: 0.65, blue: 0.25, alpha: 1).cgColor
        ember.alphaSpeed = -0.4

        emitter.emitterCells = [flame, core, ember]
        return emitter
    }
}
