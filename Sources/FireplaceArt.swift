import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where everything sits, in pixels with a bottom-left origin. Shared by the
/// still wallpaper and the animated window so the live flames line up with the art.
struct FireplaceLayout {
    let size: CGSize
    let floorTop: CGFloat
    let hearth: CGRect
    let surround: CGRect
    let chimney: CGRect
    let mantel: CGRect
    let firebox: CGRect
    let archHeight: CGFloat
    let brickHeight: CGFloat

    init(size: CGSize) {
        let w = size.width, h = size.height
        self.size = size
        floorTop = h * 0.13
        let sw = min(w * 0.62, h * 1.05)
        let sh = h * 0.6
        surround = CGRect(x: (w - sw) / 2, y: floorTop + h * 0.025, width: sw, height: sh)
        hearth = CGRect(x: surround.minX - w * 0.025, y: floorTop - h * 0.01,
                        width: sw + w * 0.05, height: surround.minY - floorTop + h * 0.01)
        mantel = CGRect(x: surround.minX - w * 0.035, y: surround.maxY, width: sw + w * 0.07, height: h * 0.04)
        chimney = CGRect(x: surround.minX + sw * 0.08, y: mantel.maxY, width: sw * 0.84, height: h - mantel.maxY)
        let fw = sw * 0.56, fh = sh * 0.62
        firebox = CGRect(x: (w - fw) / 2, y: surround.minY, width: fw, height: fh)
        archHeight = fh * 0.22
        brickHeight = sh / 15
    }

    /// The firebox opening: straight sides with a shallow arch on top.
    static func archPath(in r: CGRect, archHeight a: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - a))
        // Control points a/3 above the top make the curve peak exactly at maxY.
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - a),
                   control1: CGPoint(x: r.minX, y: r.maxY + a / 3),
                   control2: CGPoint(x: r.maxX, y: r.maxY + a / 3))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

enum FireplaceArt {
    typealias RGBA = (CGFloat, CGFloat, CGFloat, CGFloat)

    /// Renders the scene. `flames: false` leaves the firebox empty for the live emitter.
    static func render(size: CGSize, flames: Bool) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let layout = FireplaceLayout(size: CGSize(width: width, height: height))

        drawWall(ctx, layout)
        drawFloor(ctx, layout)
        drawBricks(ctx, rect: layout.chimney, brickHeight: layout.brickHeight, shade: 0.7, seed: 7)
        drawBricks(ctx, rect: layout.surround, brickHeight: layout.brickHeight, shade: 1.0, seed: 3)
        drawFirebox(ctx, layout, flames: flames)
        drawMantel(ctx, layout)
        drawHearth(ctx, layout)
        drawRoomGlow(ctx, layout, strength: flames ? 1 : 0.6)
        drawVignette(ctx, layout)
        return ctx.makeImage()
    }

    /// A soft round particle for the flame emitter.
    static func particleImage(diameter: Int = 128) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let c = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        ctx.drawRadialGradient(gradient([(1, 1, 1, 1), (1, 1, 1, 0.35), (1, 1, 1, 0)], [0, 0.4, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: c.x, options: [])
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Pieces

    private static func drawWall(_ ctx: CGContext, _ l: FireplaceLayout) {
        ctx.drawLinearGradient(gradient([(0.10, 0.06, 0.045, 1), (0.04, 0.025, 0.02, 1)], [0, 1]),
                               start: CGPoint(x: 0, y: l.floorTop), end: CGPoint(x: 0, y: l.size.height), options: [])
    }

    private static func drawFloor(_ ctx: CGContext, _ l: FireplaceLayout) {
        let floor = CGRect(x: 0, y: 0, width: l.size.width, height: l.floorTop)
        ctx.saveGState()
        ctx.clip(to: floor)
        ctx.drawLinearGradient(gradient([(0.03, 0.017, 0.01, 1), (0.11, 0.06, 0.035, 1)], [0, 1]),
                               start: .zero, end: CGPoint(x: 0, y: l.floorTop), options: [])
        // Floorboards, closer together toward the wall for a hint of perspective.
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.setLineWidth(max(1, l.size.height * 0.0015))
        var y = l.floorTop, step = l.floorTop * 0.08
        while y > 0 {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: l.size.width, y: y))
            y -= step
            step *= 1.35
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBricks(_ ctx: CGContext, rect: CGRect, brickHeight bh: CGFloat, shade: CGFloat, seed: UInt64) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(CGColor(srgbRed: 0.09 * shade, green: 0.06 * shade, blue: 0.05 * shade, alpha: 1))
        ctx.fill(rect)
        var rng = SeededRandom(seed: seed)
        let bw = bh * 2.4, gap = max(1, bh * 0.09)
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX - (row % 2 == 0 ? 0 : bw / 2) - bw * 0.3
            while x < rect.maxX {
                let r = 0.30 + rng.next() * 0.12, g = 0.11 + rng.next() * 0.05, b = 0.07 + rng.next() * 0.04
                ctx.setFillColor(CGColor(srgbRed: r * shade, green: g * shade, blue: b * shade, alpha: 1))
                let brick = CGRect(x: x + gap / 2, y: y + gap / 2, width: bw - gap, height: bh - gap)
                ctx.fill(brick)
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.6, alpha: 0.04))
                ctx.fill(CGRect(x: brick.minX, y: brick.maxY - gap, width: brick.width, height: gap))
                x += bw
            }
            y += bh
            row += 1
        }
        ctx.restoreGState()
    }

    private static func drawMantel(_ ctx: CGContext, _ l: FireplaceLayout) {
        let m = l.mantel
        // Shadow cast onto the bricks below.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: m.minX, y: m.minY - m.height, width: m.width, height: m.height))
        ctx.drawLinearGradient(gradient([(0, 0, 0, 0), (0, 0, 0, 0.5)], [0, 1]),
                               start: CGPoint(x: 0, y: m.minY - m.height), end: CGPoint(x: 0, y: m.minY), options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: m)
        ctx.drawLinearGradient(gradient([(0.13, 0.07, 0.04, 1), (0.27, 0.15, 0.08, 1), (0.2, 0.11, 0.06, 1)], [0, 0.75, 1]),
                               start: CGPoint(x: 0, y: m.minY), end: CGPoint(x: 0, y: m.maxY), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.75, blue: 0.5, alpha: 0.12))
        ctx.fill(CGRect(x: m.minX, y: m.maxY - m.height * 0.08, width: m.width, height: m.height * 0.08))
        ctx.restoreGState()
    }

    private static func drawHearth(_ ctx: CGContext, _ l: FireplaceLayout) {
        let r = l.hearth
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(gradient([(0.08, 0.065, 0.06, 1), (0.2, 0.15, 0.12, 1)], [0, 1]),
                               start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        // Firelight spilling onto the stone.
        let c = CGPoint(x: r.midX, y: r.maxY)
        ctx.drawRadialGradient(gradient([(1, 0.45, 0.12, 0.35), (1, 0.45, 0.12, 0)], [0, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: l.firebox.width * 0.7, options: [])
        ctx.restoreGState()
    }

    private static func drawFirebox(_ ctx: CGContext, _ l: FireplaceLayout, flames: Bool) {
        let fb = l.firebox
        let opening = FireplaceLayout.archPath(in: fb, archHeight: l.archHeight)

        // A darker course of bricks framing the opening.
        ctx.saveGState()
        ctx.addPath(opening)
        ctx.setLineWidth(l.brickHeight * 0.9)
        ctx.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.07, blue: 0.045, alpha: 1))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(opening)
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.01, blue: 0.008, alpha: 1))
        ctx.fill(fb)
        let base = CGPoint(x: fb.midX, y: fb.minY + fb.height * 0.1)
        ctx.drawRadialGradient(gradient([(1, 0.42, 0.08, flames ? 0.85 : 0.6), (0.6, 0.12, 0.02, 0.4), (0, 0, 0, 0)], [0, 0.35, 1]),
                               startCenter: base, startRadius: 0, endCenter: base, endRadius: fb.height * 0.9, options: [])
        drawLogs(ctx, fb)
        if flames { drawFlames(ctx, fb) }
        ctx.restoreGState()
    }

    private static func drawLogs(_ ctx: CGContext, _ fb: CGRect) {
        let fw = fb.width, fh = fb.height
        let bed = CGPoint(x: fb.midX, y: fb.minY + fh * 0.05)
        ctx.saveGState()
        ctx.translateBy(x: bed.x, y: bed.y)
        ctx.scaleBy(x: 1, y: 0.18)
        ctx.drawRadialGradient(gradient([(1, 0.6, 0.18, 1), (0.8, 0.2, 0.03, 0.8), (0.3, 0.05, 0.01, 0)], [0, 0.5, 1]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: fw * 0.38, options: [])
        ctx.restoreGState()

        let logs: [(dx: CGFloat, dy: CGFloat, length: CGFloat, thickness: CGFloat, angle: CGFloat)] = [
            (-0.09, 0.085, 0.55, 0.11, 0.12),
            (0.1, 0.095, 0.5, 0.105, -0.15),
            (0.0, 0.17, 0.42, 0.095, 0.03),
        ]
        for log in logs {
            let len = fw * log.length, thick = fh * log.thickness
            ctx.saveGState()
            ctx.translateBy(x: fb.midX + fw * log.dx, y: fb.minY + fh * log.dy)
            ctx.rotate(by: log.angle)
            let body = CGRect(x: -len / 2, y: -thick / 2, width: len, height: thick)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(gradient([(0.05, 0.025, 0.015, 1), (0.2, 0.1, 0.05, 1), (0.45, 0.18, 0.06, 1)], [0, 0.6, 1]),
                                   start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
            // Glowing cracks in the bark.
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.55))
            ctx.setLineWidth(max(1, thick * 0.06))
            for i in 0..<5 {
                let x = body.minX + len * (0.15 + CGFloat(i) * 0.17)
                ctx.move(to: CGPoint(x: x, y: body.minY + thick * 0.2))
                ctx.addLine(to: CGPoint(x: x + thick * 0.4, y: body.minY + thick * 0.55))
            }
            ctx.strokePath()
            ctx.restoreGState()

            // Cut end of the log.
            ctx.saveGState()
            ctx.translateBy(x: fb.midX + fw * log.dx, y: fb.minY + fh * log.dy)
            ctx.rotate(by: log.angle)
            let end = CGRect(x: len / 2 - thick * 0.35, y: -thick / 2, width: thick * 0.7, height: thick)
            ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.27, blue: 0.16, alpha: 1))
            ctx.fillEllipse(in: end)
            ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.14, blue: 0.08, alpha: 1))
            ctx.setLineWidth(max(1, thick * 0.05))
            ctx.strokeEllipse(in: end.insetBy(dx: thick * 0.12, dy: thick * 0.18))
            ctx.restoreGState()
        }
    }

    private static func drawFlames(_ ctx: CGContext, _ fb: CGRect) {
        let baseY = fb.minY + fb.height * 0.12
        let outer: [(dx: CGFloat, w: CGFloat, h: CGFloat)] = [
            (-0.18, 0.22, 0.5), (-0.08, 0.2, 0.62), (0.0, 0.28, 0.78), (0.09, 0.2, 0.6), (0.18, 0.22, 0.48),
        ]
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        let outerGradient = gradient([(1, 0.85, 0.5, 0.95), (1, 0.5, 0.08, 0.9), (0.85, 0.18, 0.02, 0.55), (0.5, 0.05, 0, 0)],
                                     [0, 0.3, 0.7, 1])
        let innerGradient = gradient([(1, 1, 0.9, 1), (1, 0.9, 0.5, 0.9), (1, 0.6, 0.15, 0)], [0, 0.5, 1])
        for f in outer {
            flame(ctx, cx: fb.midX + fb.width * f.dx, baseY: baseY,
                  width: fb.width * f.w, height: fb.height * f.h, gradient: outerGradient)
        }
        for f in outer {
            flame(ctx, cx: fb.midX + fb.width * f.dx * 0.8, baseY: baseY,
                  width: fb.width * f.w * 0.5, height: fb.height * f.h * 0.55, gradient: innerGradient)
        }
        ctx.restoreGState()
    }

    private static func flame(_ ctx: CGContext, cx: CGFloat, baseY: CGFloat, width w: CGFloat, height h: CGFloat, gradient g: CGGradient) {
        let bottom = CGPoint(x: cx, y: baseY), tip = CGPoint(x: cx, y: baseY + h)
        let p = CGMutablePath()
        p.move(to: bottom)
        p.addCurve(to: tip, control1: CGPoint(x: cx + w * 0.65, y: baseY + h * 0.05),
                   control2: CGPoint(x: cx + w * 0.12, y: baseY + h * 0.6))
        p.addCurve(to: bottom, control1: CGPoint(x: cx - w * 0.12, y: baseY + h * 0.6),
                   control2: CGPoint(x: cx - w * 0.65, y: baseY + h * 0.05))
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        ctx.drawLinearGradient(g, start: bottom, end: tip, options: [])
        ctx.restoreGState()
    }

    private static func drawRoomGlow(_ ctx: CGContext, _ l: FireplaceLayout, strength: CGFloat) {
        let c = CGPoint(x: l.firebox.midX, y: l.firebox.minY + l.firebox.height * 0.3)
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(gradient([(1, 0.45, 0.1, 0.28 * strength), (0.9, 0.3, 0.05, 0.1 * strength), (0, 0, 0, 0)], [0, 0.4, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: l.size.width * 0.6, options: [])
        ctx.restoreGState()
    }

    private static func drawVignette(_ ctx: CGContext, _ l: FireplaceLayout) {
        let c = CGPoint(x: l.size.width / 2, y: l.size.height * 0.45)
        let radius = hypot(l.size.width, l.size.height) / 2
        ctx.drawRadialGradient(gradient([(0, 0, 0, 0), (0, 0, 0, 0.65)], [0, 1]),
                               startCenter: c, startRadius: radius * 0.45, endCenter: c, endRadius: radius * 1.05,
                               options: [.drawsAfterEndLocation])
    }

    static func gradient(_ stops: [RGBA], _ locations: [CGFloat]) -> CGGradient {
        let colors = stops.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) } as CFArray
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations)!
    }
}

/// Small deterministic PRNG so the bricks look the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
