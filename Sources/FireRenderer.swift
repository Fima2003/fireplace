import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Matches `Uniforms` in the shader.
struct FireUniforms {
    var resolution: SIMD2<Float> = .zero
    var viewCenter: SIMD2<Float> = [0, 0.5]
    var viewScale: Float = 1
    var time: Float = 0
    var layoutAspect: Float
    var seed: Float
    var simSize: SIMD2<Float>
    /// Brightness of the flame's glow relative to the room.
    var exposure: Float = 5.5
    var pad1: Float = 0
}

/// Matches `SimUniforms` in the shader.
private struct SimUniforms {
    var size: SIMD2<Float>
    var dt: Float
    var time: Float
    var seed: Float
    var frame: Float
    var layoutAspect: Float
    var sparkCount = Float(FireSimulation.sparkCount)
    var burst: Float = 0
    var boost: Float = 0
    var sparkBurst: Float = 0
}

private struct Spark {
    var pos: SIMD2<Float> = .zero
    var vel: SIMD2<Float> = .zero
    var heat: Float = 0
    var life: Float = 0
    var pad: SIMD2<Float> = .zero
}

/// Matches `BlurParams` in the shader.
private struct BlurParams {
    var dir: SIMD2<Float>
    var targetSize: SIMD2<Float>
}

/// Matches `FireLight` in the shader: how much light each part of the fire gives off.
private struct FireLight {
    var bands: SIMD4<Float> = .zero
    var smooth: SIMD4<Float> = .zero
}

/// Shared Metal device and the compiled shader library.
enum FireGPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let library: MTLLibrary? = {
        guard let device else { return nil }
        do { return try device.makeLibrary(source: fireplaceShaderSource, options: nil) } catch {
            log("Fireplace shader failed to compile: \(error)")
            return nil
        }
    }()
}

/// The fire's physics: a fluid simulation over the firebox, stepped on the GPU.
final class FireSimulation {
    static let dt = 1.0 / 60
    static let pressureIterations = 36
    static let sparkCount = 384

    let size: SIMD2<Int>
    private let seed: FireSeed
    private let layoutAspect: Float
    /// Swapped in pairs every sub-step, so only valid to read between calls to `step`.
    private(set) var velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp: MTLTexture
    /// Forward and back-traced copies for the MacCormack advection.
    private var velFwd, velBack, stateFwd, stateBack: MTLTexture
    /// Latest state with a mip chain; the renderer taps the coarse levels for the room light.
    let display: MTLTexture
    let sparks: MTLBuffer
    let logs: MTLBuffer
    private let kernels: [String: MTLComputePipelineState]
    private var simTime: Double = 0
    private var frame: Float = 0
    private var needsClear = true
    private var stokedAt: Double = -.infinity

    /// A sudden flare-up with a shower of sparks, fading over a couple of seconds.
    func stoke() { stokedAt = simTime }

    /// How hard the fire is being driven right now, 0 (left alone) to 1 (the coil
    /// pressed into the coals): more fuel, hotter wood, more sparks, for as long as it's held.
    var boost: Float = 0

    init?(device: MTLDevice, library: MTLLibrary, seed: FireSeed, layoutAspect: Float) {
        self.seed = seed
        self.layoutAspect = layoutAspect
        // Square cells across the firebox mouth, matching makeLayout() in the shader.
        // The shader's per-cell constants are written for 256 across and rescaled from s.size.
        let fw = 0.56 * min(0.62 * layoutAspect, 1.05)
        let domainHeight: Float = 0.372 * 1.08 + 0.01
        let nx = 384
        let size = SIMD2<Int>(nx, Int((Float(nx) * domainHeight / fw).rounded(.up)))
        self.size = size

        func texture(_ format: MTLPixelFormat, mipmapped: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.x, height: size.y, mipmapped: mipmapped)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let v0 = texture(.rg16Float), let v1 = texture(.rg16Float),
              let s0 = texture(.rgba16Float), let s1 = texture(.rgba16Float),
              let c = texture(.r16Float), let dv = texture(.r32Float),
              let p0 = texture(.r32Float), let p1 = texture(.r32Float),
              let disp = texture(.rgba16Float, mipmapped: true),
              let vf = texture(.rg16Float), let vb = texture(.rg16Float),
              let sf = texture(.rgba16Float), let sb = texture(.rgba16Float)
        else { return nil }
        (velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp, display) = (v0, v1, s0, s1, c, dv, p0, p1, disp)
        (velFwd, velBack, stateFwd, stateBack) = (vf, vb, sf, sb)

        let blank = [Spark](repeating: Spark(), count: Self.sparkCount)
        guard let sparkBuffer = device.makeBuffer(bytes: blank, length: MemoryLayout<Spark>.stride * blank.count),
              let logBuffer = device.makeBuffer(bytes: seed.logs, length: MemoryLayout<LogParams>.stride * seed.logs.count)
        else { return nil }
        sparks = sparkBuffer
        logs = logBuffer

        var kernels: [String: MTLComputePipelineState] = [:]
        for name in ["clearTexture", "advectVelocity", "advectState", "advectBack", "macCormack", "react", "curl",
                     "applyForces", "divergence", "jacobi", "project", "updateSparks"] {
            guard let fn = library.makeFunction(name: name),
                  let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
            kernels[name] = pipeline
        }
        self.kernels = kernels
    }

    /// Steps the physics in fixed increments up to `time`, catching up at most a few steps
    /// (after the window was hidden, the fire simply carries on from where it was).
    func advance(to time: Double, commandBuffer: MTLCommandBuffer) {
        var steps = Int((time - simTime) / Self.dt)
        if steps > 4 {
            simTime = time - 4 * Self.dt
            steps = 4
        }
        // The first call always steps, so that `display` holds something before the first draw.
        if needsClear { steps = max(steps, 1) }
        if steps > 0 { step(count: steps, commandBuffer: commandBuffer) }
    }

    func step(count: Int, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        if needsClear {
            for t in [velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp,
                      velFwd, velBack, stateFwd, stateBack, display] {
                dispatch(enc, "clearTexture", textures: [t])
            }
            needsClear = false
        }
        for _ in 0..<count {
            simTime += Self.dt
            frame += 1
            let sinceStoke = max(0, simTime - stokedAt)
            var u = SimUniforms(size: [Float(size.x), Float(size.y)], dt: Float(Self.dt),
                                time: Float(simTime.truncatingRemainder(dividingBy: 4000)),
                                seed: seed.shaderSeed, frame: frame, layoutAspect: layoutAspect,
                                burst: Float(exp(-sinceStoke / 0.8)), boost: boost,
                                sparkBurst: Float(exp(-sinceStoke / 0.8) + 0.4 * exp(-sinceStoke / 3)))
            enc.setBytes(&u, length: MemoryLayout<SimUniforms>.stride, index: 0)
            enc.setBuffer(logs, offset: 0, index: 1)

            // MacCormack advection: forward trace, back trace, then the corrected result.
            dispatch(enc, "advectVelocity", textures: [velocity, velFwd])
            dispatch(enc, "advectBack", textures: [velFwd, velocity, velBack])
            dispatch(enc, "macCormack", textures: [velocity, velFwd, velBack, velocity, velocityTmp])
            dispatch(enc, "advectState", textures: [state, velocity, stateFwd])
            dispatch(enc, "advectBack", textures: [stateFwd, velocity, stateBack])
            dispatch(enc, "macCormack", textures: [state, stateFwd, stateBack, velocity, stateTmp])
            dispatch(enc, "react", textures: [stateTmp, state, velocityTmp])
            dispatch(enc, "curl", textures: [velocityTmp, curl])
            dispatch(enc, "applyForces", textures: [velocityTmp, state, curl, velocity])
            dispatch(enc, "divergence", textures: [velocity, divergence])
            for _ in 0..<Self.pressureIterations {
                dispatch(enc, "jacobi", textures: [pressure, divergence, pressureTmp])
                swap(&pressure, &pressureTmp)
            }
            dispatch(enc, "project", textures: [velocity, pressure, velocityTmp])
            swap(&velocity, &velocityTmp)

            enc.setComputePipelineState(kernels["updateSparks"]!)
            enc.setBuffer(sparks, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<SimUniforms>.stride, index: 1)
            enc.setBuffer(logs, offset: 0, index: 2)
            enc.setTexture(velocity, index: 0)
            enc.setTexture(state, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (Self.sparkCount + 31) / 32, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        }
        enc.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: state, sourceSlice: 0, sourceLevel: 0, to: display, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.generateMipmaps(for: display)
        blit.endEncoding()
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ name: String, textures: [MTLTexture]) {
        enc.setComputePipelineState(kernels[name]!)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let w = textures.last!.width, h = textures.last!.height
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
    }
}

/// Bakes the room once per size, then draws the simulated fire into it every frame:
/// a low-resolution glow pass blurred at two scales for the bloom, the main pass,
/// and the sparks on top.
final class FireRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulation: FireSimulation
    var uniforms: FireUniforms
    private let scenePipeline, framePipeline, sparkPipeline, glowPipeline, blurPipeline, sparkGlowPipeline: MTLRenderPipelineState
    private let fireLightPipeline: MTLComputePipelineState
    /// How much light each part of the fire gives off, measured once per frame (see `fireLight` in the shader).
    private let fireLight: MTLBuffer
    private var scene0: MTLTexture?
    private var scene1: MTLTexture?
    private var scene2: MTLTexture?
    /// Bloom chain: the emissive parts at 1/8 resolution (glowA/B) and 1/32 (wideA/B).
    private var glowA, glowB, wideA, wideB: MTLTexture?

    init?(layoutAspect: Float, seed: FireSeed) {
        guard let device = FireGPU.device, let library = FireGPU.library, let queue = device.makeCommandQueue(),
              let sim = FireSimulation(device: device, library: library, seed: seed, layoutAspect: layoutAspect)
        else { return nil }
        self.device = device
        self.queue = queue
        simulation = sim
        uniforms = FireUniforms(layoutAspect: layoutAspect, seed: seed.shaderSeed,
                                simSize: [Float(sim.size.x), Float(sim.size.y)])

        enum Blend { case none, additive, brighter }   // brighter: keeps the brighter of source and destination
        func pipeline(_ vertex: String, _ fragment: String, _ formats: [MTLPixelFormat], blend: Blend = .none) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            for (i, f) in formats.enumerated() { d.colorAttachments[i].pixelFormat = f }
            if blend != .none {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.rgbBlendOperation = blend == .additive ? .add : .max
                a.sourceAlphaBlendFactor = .zero
                a.destinationAlphaBlendFactor = .one
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                log("Pipeline \(fragment) failed: \(error)")
                return nil
            }
        }
        guard let scene = pipeline("fullscreenVertex", "sceneFragment", [.rgba8Unorm_srgb, .rgba8Unorm, .rgba8Unorm]),
              let frame = pipeline("fullscreenVertex", "frameFragment", [.bgra8Unorm_srgb]),
              let spark = pipeline("sparkVertex", "sparkFragment", [.bgra8Unorm_srgb], blend: .brighter),
              let glow = pipeline("fullscreenVertex", "glowFragment", [.rgba16Float]),
              let blur = pipeline("fullscreenVertex", "blurFragment", [.rgba16Float]),
              let sparkGlow = pipeline("sparkVertex", "sparkGlowFragment", [.rgba16Float], blend: .additive),
              let lightFn = library.makeFunction(name: "fireLight"),
              let light = try? device.makeComputePipelineState(function: lightFn),
              let lightBuffer = device.makeBuffer(bytes: [FireLight()], length: MemoryLayout<FireLight>.stride, options: .storageModeShared)
        else { return nil }
        (scenePipeline, framePipeline, sparkPipeline) = (scene, frame, spark)
        (glowPipeline, blurPipeline, sparkGlowPipeline) = (glow, blur, sparkGlow)
        (fireLightPipeline, fireLight) = (light, lightBuffer)
    }

    /// Advances the physics to `time` and draws a frame into `target` (bgra8Unorm_srgb).
    func encodeFrame(to target: MTLTexture, time: Double, commandBuffer: MTLCommandBuffer) {
        simulation.advance(to: time, commandBuffer: commandBuffer)
        draw(to: target, time: time, commandBuffer: commandBuffer)
    }

    private func draw(to target: MTLTexture, time: Double, commandBuffer: MTLCommandBuffer) {
        uniforms.resolution = [Float(target.width), Float(target.height)]
        uniforms.time = Float(time.truncatingRemainder(dividingBy: 4000))
        bakeSceneIfNeeded(width: target.width, height: target.height, commandBuffer: commandBuffer)
        guard let scene0, let scene1, let scene2, let glowA, let glowB, let wideA, let wideB else { return }

        // How much light each part of the fire gives off this frame, for the room light.
        guard let lightEnc = commandBuffer.makeComputeCommandEncoder() else { return }
        lightEnc.setComputePipelineState(fireLightPipeline)
        lightEnc.setTexture(simulation.display, index: 0)
        lightEnc.setBuffer(fireLight, offset: 0, index: 0)
        lightEnc.setBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 1)
        lightEnc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
        lightEnc.endEncoding()

        // Bloom: the emissive parts alone at an eighth of the resolution, sparks
        // included, blurred to a 16 px halo, then again at a 32nd for a 64 px one.
        var glowUniforms = uniforms
        glowUniforms.resolution = [Float(glowA.width), Float(glowA.height)]
        guard let glowEnc = renderPass(to: glowA, commandBuffer: commandBuffer) else { return }
        glowEnc.setRenderPipelineState(glowPipeline)
        glowEnc.setFragmentBytes(&glowUniforms, length: MemoryLayout<FireUniforms>.stride, index: 0)
        glowEnc.setFragmentBuffer(fireLight, offset: 0, index: 1)
        glowEnc.setFragmentTexture(scene1, index: 1)
        glowEnc.setFragmentTexture(simulation.display, index: 2)
        glowEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        glowEnc.setRenderPipelineState(sparkGlowPipeline)
        glowEnc.setVertexBuffer(simulation.sparks, offset: 0, index: 0)
        glowEnc.setVertexBytes(&glowUniforms, length: MemoryLayout<FireUniforms>.stride, index: 1)
        glowEnc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: FireSimulation.sparkCount)
        glowEnc.endEncoding()
        blur(from: glowA, to: glowB, dir: [1, 0], commandBuffer: commandBuffer)
        blur(from: glowB, to: glowA, dir: [0, 1], commandBuffer: commandBuffer)
        blur(from: glowA, to: wideA, dir: [4, 0], commandBuffer: commandBuffer)   // taps a wide texel apart: downsamples as it blurs
        blur(from: wideA, to: wideB, dir: [0, 1], commandBuffer: commandBuffer)

        guard let enc = renderPass(to: target, commandBuffer: commandBuffer) else { return }
        enc.setRenderPipelineState(framePipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 0)
        enc.setFragmentBuffer(fireLight, offset: 0, index: 1)
        enc.setFragmentTexture(scene0, index: 0)
        enc.setFragmentTexture(scene1, index: 1)
        enc.setFragmentTexture(simulation.display, index: 2)
        enc.setFragmentTexture(scene2, index: 3)
        enc.setFragmentTexture(glowA, index: 4)
        enc.setFragmentTexture(wideB, index: 5)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(sparkPipeline)
        enc.setVertexBuffer(simulation.sparks, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: FireSimulation.sparkCount)
        enc.endEncoding()
    }

    private func renderPass(to target: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    }

    /// One direction of the separable Gaussian, `dir` in source texels.
    private func blur(from src: MTLTexture, to dst: MTLTexture, dir: SIMD2<Float>, commandBuffer: MTLCommandBuffer) {
        guard let enc = renderPass(to: dst, commandBuffer: commandBuffer) else { return }
        var params = BlurParams(dir: dir, targetSize: [Float(dst.width), Float(dst.height)])
        enc.setRenderPipelineState(blurPipeline)
        enc.setFragmentBytes(&params, length: MemoryLayout<BlurParams>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func bakeSceneIfNeeded(width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        if let scene0, scene0.width == width, scene0.height == height { return }
        func texture(_ format: MTLPixelFormat, _ w: Int = width, _ h: Int = height) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let gw = max(1, width / 8), gh = max(1, height / 8), ww = max(1, width / 32), wh = max(1, height / 32)
        guard let t0 = texture(.rgba8Unorm_srgb), let t1 = texture(.rgba8Unorm), let t2 = texture(.rgba8Unorm),
              let gA = texture(.rgba16Float, gw, gh), let gB = texture(.rgba16Float, gw, gh),
              let wA = texture(.rgba16Float, ww, wh), let wB = texture(.rgba16Float, ww, wh)
        else { return }
        (glowA, glowB, wideA, wideB) = (gA, gB, wA, wB)
        let pass = MTLRenderPassDescriptor()
        for (i, t) in [t0, t1, t2].enumerated() {
            pass.colorAttachments[i].texture = t
            pass.colorAttachments[i].loadAction = .dontCare
            pass.colorAttachments[i].storeAction = .store
        }
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(scenePipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 0)
        enc.setFragmentBuffer(simulation.logs, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        scene0 = t0
        scene1 = t1
        scene2 = t2
    }

    /// Lets the fire burn for `warmUp` seconds of simulated time, then captures a still.
    func renderImage(width: Int, height: Int, warmUp: Double = 4, stokeAt: Double? = nil) -> CGImage? {
        let steps = Int(warmUp / FireSimulation.dt)
        let stokeStep = stokeAt.map { Int($0 / FireSimulation.dt) } ?? -1
        var done = 0
        while done < steps {
            guard let cb = queue.makeCommandBuffer() else { return nil }
            if done == stokeStep { simulation.stoke() }
            let n = min(60, steps - done, done < stokeStep ? stokeStep - done : .max)
            simulation.step(count: n, commandBuffer: cb)
            cb.commit()
            done += n
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .managed
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        draw(to: target, time: warmUp, commandBuffer: cb)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
