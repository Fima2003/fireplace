import Foundation
import Security

/// Everything random about one fire, drawn from a single hardware-sourced seed.
///
/// The seed comes from `SecRandomCopyBytes`, the kernel's cryptographic random
/// generator. macOS seeds that generator from the hardware true random number
/// generator (the Secure Enclave TRNG on Apple silicon, RDSEED on Intel), so every
/// launch on every Mac gets a different fire: different logs, different bricks,
/// and, because fluid flow is chaotic, flames that never repeat.
struct FireSeed {
    let raw: UInt64
    /// Offsets every noise and hash field in the shaders.
    let shaderSeed: Float
    let logs: [LogParams]

    init(raw: UInt64 = FireSeed.hardwareRandom()) {
        self.raw = raw
        var rng = SplitMix64(state: raw)
        shaderSeed = Float(rng.next() % 50_000) / 100
        func r(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &rng) }
        logs = [
            // Back log, then two crossing in front.
            LogParams(center: [r(-0.05...0.05), r(0.06...0.075)], halfLen: r(0.27...0.33), radius: r(0.019...0.024),
                      angle: r(-0.07...0.07), charred: r(0.6...0.9)),
            LogParams(center: [r(-0.13...(-0.04)), r(0.03...0.04)], halfLen: r(0.28...0.34), radius: r(0.021...0.026),
                      angle: r(0.05...0.18), charred: r(0.45...0.8)),
            LogParams(center: [r(0.05...0.13), r(0.033...0.043)], halfLen: r(0.24...0.3), radius: r(0.019...0.024),
                      angle: r(-0.2...(-0.07)), charred: r(0.5...0.85)),
        ]
    }

    static func hardwareRandom() -> UInt64 {
        var value: UInt64 = 0
        let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return value
    }
}

/// Matches `LogParams` in the shader.
struct LogParams {
    var center: SIMD2<Float>
    var halfLen: Float
    var radius: Float
    var angle: Float
    var charred: Float
    var pad: SIMD2<Float> = .zero
}

/// Expands the 64-bit hardware seed into as many numbers as the layout needs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
