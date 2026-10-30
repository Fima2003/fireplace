import AVFoundation

/// The sound of a fire being stoked: a whoosh as it flares, a low roar, a hiss of
/// gas, and a scatter of crackles and pops that thin out as it settles.
/// Synthesised sample by sample, with randomness from a hardware-seeded generator.
final class FireCrackle {
    static let duration = 5.0

    private let sampleRate: Double
    private var rng: UInt64
    private var n = 0
    private var brown: Float = 0
    private var hissLow: Float = 0
    private var whooshLow: Float = 0
    private var roarLFO: Float = 0
    private var roarTarget: Float = 0.5
    // Crackle voices: remaining amplitude, per-sample decay, a one-pole low-pass for tone.
    private static let voices = 12
    private let amp = UnsafeMutablePointer<Float>.allocate(capacity: voices)
    private let decay = UnsafeMutablePointer<Float>.allocate(capacity: voices)
    private let tone = UnsafeMutablePointer<Float>.allocate(capacity: voices)
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: voices)

    init(sampleRate: Double, seed: UInt64 = FireSeed.hardwareRandom()) {
        self.sampleRate = sampleRate
        rng = seed | 1
        for p in [amp, decay, tone, state] { p.initialize(repeating: 0, count: Self.voices) }
    }

    deinit { for p in [amp, decay, tone, state] { p.deallocate() } }

    private func random() -> Float {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        return Float((rng &* 0x2545_F491_4F6C_DD1D) >> 40) / Float(1 << 24)
    }

    /// Fills `count` samples; real-time safe (no allocation, no locks).
    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let sr = Float(sampleRate)
        for i in 0..<count {
            let t = Float(n) / sr
            n += 1
            let white = random() * 2 - 1

            // Overall shape: a quick flare, a long settle, a gentle fade at the end.
            let attack = min(1, t / 0.12)
            let settle = exp(-t / 2.4)
            let fadeOut = min(1, max(0, (Float(Self.duration) - t) / 0.6))
            let env = attack * (0.35 + 0.65 * settle) * fadeOut

            // Whoosh: noise through a low-pass that opens as the flames leap up.
            let whooshEnv = min(1, t / 0.08) * exp(-t / 0.45)
            let cutoff = 250 + 1800 * whooshEnv
            whooshLow += (white - whooshLow) * (1 - exp(-2 * .pi * cutoff / sr))
            let whoosh = whooshLow * whooshEnv * 0.9

            // Roar: brown noise with a slow, uneven swell.
            brown = (brown + white * 0.02) * 0.998
            if n % 2400 == 0 { roarTarget = 0.4 + 0.6 * random() }
            roarLFO += (roarTarget - roarLFO) * 0.0004
            let roar = brown * 2.2 * roarLFO * env

            // Hiss: the high end of the noise, very quiet.
            hissLow += (white - hissLow) * 0.2
            let hiss = (white - hissLow) * 0.025 * env

            // Crackles: sap and gas pockets bursting, frequent at first then sparser.
            let rate = (6 + 55 * settle * settle) * fadeOut
            if random() < rate / sr {
                var v = 0
                for k in 1..<Self.voices where amp[k] < amp[v] { v = k }
                let big = random()
                let strength = 0.08 + 0.9 * big * big * big
                amp[v] = strength * (0.6 + 0.4 * env)
                let tau = (0.0006 + 0.004 * random()) * (strength > 0.5 ? 2.5 : 1)   // big pops ring longer
                decay[v] = exp(-1 / (tau * sr))
                tone[v] = strength > 0.5 ? 0.25 : 0.6 + 0.35 * random()             // big pops are duller
            }
            var crackle: Float = 0
            for k in 0..<Self.voices where amp[k] > 1e-4 {
                let raw = (random() * 2 - 1) * amp[k]
                state[k] += (raw - state[k]) * tone[k]
                crackle += state[k]
                amp[k] *= decay[k]
            }

            let mix = whoosh + roar + hiss + crackle * 0.9
            out[i] = tanh(mix * 1.3) * 0.7
        }
    }
}

/// Plays one stoking sound through its own engine, which runs only while it plays.
final class FireSound {
    private var engine: AVAudioEngine?

    func play() {
        stop()
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let synth = FireCrackle(sampleRate: rate)
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                synth.render(into: data, count: Int(frames))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            log("Could not play fire sound: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + FireCrackle.duration) { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine else { return }
            self.stop()
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
