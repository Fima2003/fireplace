import CoreGraphics
import Foundation

/// Renders the app icon from the same fire simulation: a close-up of the firebox
/// in the standard macOS rounded-square shape.
enum AppIcon {
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let master = try render()
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try writePNG(resize(master, to: px), to: dir.appendingPathComponent(name))
            }
        }
    }

    private static func render() throws -> CGImage {
        let canvas = 1024, tile = 824, inset = CGFloat(canvas - tile) / 2
        guard let renderer = FireRenderer(layoutAspect: 1.6, seed: FireSeed()) else { throw CocoaError(.featureUnsupported) }
        // Frame the firebox mouth: floor at fy0 = 0.155, height fh = 0.372 (see makeLayout).
        renderer.uniforms.viewCenter = [0, 0.155 + 0.372 * 0.52]
        renderer.uniforms.viewScale = 0.372 * 1.4
        guard let fire = renderer.renderImage(width: tile, height: tile, warmUp: 5),
              let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }

        let rect = CGRect(x: inset, y: inset, width: CGFloat(tile), height: CGFloat(tile))
        let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(fire, in: rect)
        // Soft top sheen, like glass over the fire.
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [CGColor(gray: 1, alpha: 0.1), CGColor(gray: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
        ctx.restoreGState()

        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(2)
        ctx.strokePath()
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    private static func resize(_ image: CGImage, to px: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}
