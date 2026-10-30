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
    var pad: SIMD2<Float> = .zero
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
    var pad: Float = 0
}

private struct Spark {
    var pos: SIMD2<Float> = .zero
    var vel: SIMD2<Float> = .zero
    var heat: Float = 0
    var life: Float = 0
    var pad: SIMD2<Float> = .zero
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
    static let pressureIterations = 30
    static let sparkCount = 384

    let size: SIMD2<Int>
    private let seed: FireSeed
    private let layoutAspect: Float
    private var velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp: MTLTexture
    /// Latest state with a mip chain; the top mip is the fire's mean temperature.
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

    init?(device: MTLDevice, library: MTLLibrary, seed: FireSeed, layoutAspect: Float) {
        self.seed = seed
        self.layoutAspect = layoutAspect
        // Square cells across the firebox mouth, matching makeLayout() in the shader.
        let fw = 0.56 * min(0.62 * layoutAspect, 1.05)
        let domainHeight: Float = 0.372 * 1.08 + 0.01
        let nx = 256
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
              let disp = texture(.rgba16Float, mipmapped: true)
        else { return nil }
        (velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp, display) = (v0, v1, s0, s1, c, dv, p0, p1, disp)

        let blank = [Spark](repeating: Spark(), count: Self.sparkCount)
        guard let sparkBuffer = device.makeBuffer(bytes: blank, length: MemoryLayout<Spark>.stride * blank.count),
              let logBuffer = device.makeBuffer(bytes: seed.logs, length: MemoryLayout<LogParams>.stride * seed.logs.count)
        else { return nil }
        sparks = sparkBuffer
        logs = logBuffer

        var kernels: [String: MTLComputePipelineState] = [:]
        for name in ["clearTexture", "advectVelocity", "advectState", "react", "curl", "applyForces",
                     "divergence", "jacobi", "project", "updateSparks"] {
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
        if steps > 0 { step(count: steps, commandBuffer: commandBuffer) }
    }

    func step(count: Int, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        if needsClear {
            for t in [velocity, velocityTmp, state, stateTmp, curl, divergence, pressure, pressureTmp] {
                dispatch(enc, "clearTexture", textures: [t])
            }
            needsClear = false
        }
        for _ in 0..<count {
            simTime += Self.dt
            frame += 1
            var u = SimUniforms(size: [Float(size.x), Float(size.y)], dt: Float(Self.dt),
                                time: Float(simTime.truncatingRemainder(dividingBy: 4000)),
                                seed: seed.shaderSeed, frame: frame, layoutAspect: layoutAspect,
                                burst: Float(exp(-max(0, simTime - stokedAt) / 0.8)))
            enc.setBytes(&u, length: MemoryLayout<SimUniforms>.stride, index: 0)
            enc.setBuffer(logs, offset: 0, index: 1)

            dispatch(enc, "advectVelocity", textures: [velocity, velocityTmp])
            dispatch(enc, "advectState", textures: [state, velocity, stateTmp])
            dispatch(enc, "react", textures: [stateTmp, state])
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

/// Bakes the room once per size, then draws the simulated fire into it every frame.
final class FireRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulation: FireSimulation
    var uniforms: FireUniforms
    private let scenePipeline, framePipeline, sparkPipeline: MTLRenderPipelineState
    private var scene0: MTLTexture?
    private var scene1: MTLTexture?

    init?(layoutAspect: Float, seed: FireSeed) {
        guard let device = FireGPU.device, let library = FireGPU.library, let queue = device.makeCommandQueue(),
              let sim = FireSimulation(device: device, library: library, seed: seed, layoutAspect: layoutAspect)
        else { return nil }
        self.device = device
        self.queue = queue
        simulation = sim
        uniforms = FireUniforms(layoutAspect: layoutAspect, seed: seed.shaderSeed,
                                simSize: [Float(sim.size.x), Float(sim.size.y)])

        func pipeline(_ vertex: String, _ fragment: String, _ formats: [MTLPixelFormat], additive: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            for (i, f) in formats.enumerated() { d.colorAttachments[i].pixelFormat = f }
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .zero
                a.destinationAlphaBlendFactor = .one
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                log("Pipeline \(fragment) failed: \(error)")
                return nil
            }
        }
        guard let scene = pipeline("fullscreenVertex", "sceneFragment", [.rgba16Float, .rgba8Unorm]),
              let frame = pipeline("fullscreenVertex", "frameFragment", [.bgra8Unorm_srgb]),
              let spark = pipeline("sparkVertex", "sparkFragment", [.bgra8Unorm_srgb], additive: true)
        else { return nil }
        (scenePipeline, framePipeline, sparkPipeline) = (scene, frame, spark)
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
        guard let scene0, let scene1 else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(framePipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 0)
        enc.setFragmentTexture(scene0, index: 0)
        enc.setFragmentTexture(scene1, index: 1)
        enc.setFragmentTexture(simulation.display, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(sparkPipeline)
        enc.setVertexBuffer(simulation.sparks, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<FireUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: FireSimulation.sparkCount)
        enc.endEncoding()
    }

    private func bakeSceneIfNeeded(width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        if let scene0, scene0.width == width, scene0.height == height { return }
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let t0 = texture(.rgba16Float), let t1 = texture(.rgba8Unorm) else { return }
        let pass = MTLRenderPassDescriptor()
        for (i, t) in [t0, t1].enumerated() {
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
