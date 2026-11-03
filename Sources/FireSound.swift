import AVFoundation

/// The sound of the fire, synthesised sample by sample for as long as it burns:
/// a soft roar that swells unevenly, a faint hiss, crackles of every size from
/// ticks to the odd big pop with a thump, and now and then a sizzle of sap.
/// Pressing the coil raises the roar, multiplies the crackles and adds rushing air.
///
/// `render` runs on the audio thread and is real-time safe: no allocation, no
/// locks, no Objective-C, no Date(). The controls are plain stored properties
/// written from other threads and read here; aligned 32- and 64-bit stores
/// are single-copy atomic on arm64, so a half-written value can't be seen.
final class FireAmbience {
    // MARK: Controls (other threads write, audio thread reads)

    /// 0 to 1: how hard the coil is driving the fire.
    var intensity: Float = 0
    /// Small-crackle rate at rest, per second. Lowered when nothing cancels our echo.
    var tickRate: Float = 3
    /// Added to each crackle's onset time so it is stamped when it leaves the speaker.
    var outputLatency: Double = 0
    /// Host-clock seconds before which no crackle is started: the clap detector sets it
    /// (from its tap thread) while a first clap waits for its partner, so that our own
    /// pops can't get the second one vetoed.
    var holdCracklesUntil: Double = 0
    private var fadeTarget: Float = 0
    private var fadeSeconds: Float = 2
    private var stokeRequested = false

    // MARK: Synth state

    private(set) var sampleRate: Float
    private var rng: UInt64
    private var level: Float = 0
    private var heat: Float = 0                   // intensity, smoothed
    private var stokeSamples: Int = 1 << 40        // samples since the last stoke (long ago)
    private var brown: Float = 0
    private var pink0: Float = 0, pink1: Float = 0, pink2: Float = 0
    private var bedLP: Float = 0
    private var hissLP: Float = 0
    private var whooshLP: Float = 0, whooshLP2: Float = 0
    private var flutter: Float = 0.8, flutterTarget: Float = 0.8, flutterCountdown = 0
    private var breath: Float = 0.5, breathTarget: Float = 0.5, breathCountdown = 0
    private var sizzleEnv: Float = 0, sizzlePeak: Float = 0, sizzleDecay: Float = 0
    private var sizzleMod: Float = 0, sizzleTarget: Float = 0, sizzleCountdown = 0

    // Coefficients that depend on the sample rate.
    private var brownLeak: Float = 0, brownGain: Float = 0
    private var hissCoef: Float = 0, whooshLP2Coef: Float = 0, heatCoef: Float = 0
    private var flutterCoef: Float = 0, breathCoef: Float = 0, sizzleModCoef: Float = 0, sizzleAttack: Float = 0
    private var flutterPeriod = 1, breathPeriod = 1, sizzlePeriod = 1

    /// A crackle voice: a burst of filtered noise, plus a ringing or thumping sine.
    private struct Voice {
        var amp: Float = 0, decay: Float = 0, tone: Float = 0, lp: Float = 0
        var ringAmp: Float = 0, ringDecay: Float = 0, ringPhase: Float = 0, ringInc: Float = 0
    }
    private static let voiceCount = 16
    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: voiceCount)

    /// Host-clock seconds at which the last crackles left the speaker, so the clap
    /// detector can tell our pops from the real thing when echo cancellation is off.
    private static let onsetCount = 64
    private let onsets = UnsafeMutablePointer<Double>.allocate(capacity: onsetCount)
    private var onsetIndex = 0
    private let hostSecondsPerTick: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(sampleRate: Double, seed: UInt64 = FireSeed.hardwareRandom()) {
        self.sampleRate = Float(sampleRate)
        rng = seed | 1
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        onsets.initialize(repeating: -1e9, count: Self.onsetCount)
        prepare(sampleRate: sampleRate)
    }

    deinit {
        voices.deallocate()
        onsets.deallocate()
    }

    /// Sets the rate the next `render` calls will run at. Call while nothing renders.
    func prepare(sampleRate: Double) {
        let sr = Float(sampleRate)
        self.sampleRate = sr
        func onePole(_ hz: Float) -> Float { 1 - exp(-2 * .pi * hz / sr) }
        brownLeak = exp(-2 * .pi * 12 / sr)           // leaky integrator: rumble below ~12 Hz rolls off
        brownGain = 0.02 * (48_000 / sr).squareRoot()
        hissCoef = onePole(1800)
        whooshLP2Coef = onePole(120)
        heatCoef = onePole(1 / (2 * .pi * 0.3))        // intensity follows the coil over ~0.3 s
        flutterCoef = onePole(1 / (2 * .pi * 0.04))
        breathCoef = onePole(1 / (2 * .pi * 0.8))
        sizzleModCoef = onePole(1 / (2 * .pi * 0.006))
        sizzleAttack = onePole(1 / (2 * .pi * 0.03))
        flutterPeriod = Int(sr * 0.06)
        breathPeriod = Int(sr * 1.5)
        sizzlePeriod = Int(sr * 0.01)
    }

    /// Ramps the output level to `target` (0 to 1) over `seconds`.
    func fade(to target: Float, over seconds: Double) {
        fadeSeconds = Float(max(0.01, seconds))
        fadeTarget = target
    }

    /// A whoosh as the flames leap, then a burst of crackles that settles over ~4 s.
    func stoke() { stokeRequested = true }

    /// Whether one of our own crackles left the speaker within [-20 ms, +60 ms] of `hostSeconds`.
    /// (Wide enough for a room's worth of echo; any wider and real claps start to be lost.)
    func recentCrackle(near hostSeconds: Double) -> Bool {
        for k in 0..<Self.onsetCount {
            let dt = hostSeconds - onsets[k]
            if dt >= -0.02, dt <= 0.06 { return true }
        }
        return false
    }

    private func random() -> Float {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        return Float((rng &* 0x2545_F491_4F6C_DD1D) >> 40) / Float(1 << 24)
    }

    private enum Crackle { case tick, pop, big }

    private func spawn(_ kind: Crackle, at hostSeconds: Double) {
        // Take over the quietest voice, counting its ring: cutting a thump mid-cycle clicks.
        var v = 0
        for k in 1..<Self.voiceCount where voices[k].amp + voices[k].ringAmp < voices[v].amp + voices[v].ringAmp { v = k }
        let sr = sampleRate
        func decay(_ tau: Float) -> Float { exp(-1 / (tau * sr)) }
        switch kind {
        case .tick:
            // Sap and bark snapping: tiny, bright, over in a millisecond.
            voices[v] = Voice(amp: 0.06 + 0.18 * random(), decay: decay(0.0003 + 0.001 * random()),
                              tone: 0.5 + 0.45 * random())
        case .pop:
            // A gas pocket bursting: sharper, with a short ring from the wood.
            let f = 900 + 1700 * random()
            voices[v] = Voice(amp: 0.25 + 0.3 * random(), decay: decay(0.0015 + 0.003 * random()),
                              tone: 0.3 + 0.3 * random(),
                              ringAmp: 0.1 + 0.15 * random(), ringDecay: decay(0.008 + 0.02 * random()),
                              ringInc: 2 * .pi * f / sr)
        case .big:
            // A log splitting: a dull bang and a low thump you feel in the floor.
            let f = 55 + 60 * random()
            voices[v] = Voice(amp: 0.6 + 0.35 * random(), decay: decay(0.004 + 0.006 * random()),
                              tone: 0.18 + 0.15 * random(),
                              ringAmp: 0.5 + 0.3 * random(), ringDecay: decay(0.07 + 0.08 * random()),
                              ringInc: 2 * .pi * f / sr)
        }
        onsets[onsetIndex] = hostSeconds
        onsetIndex = (onsetIndex + 1) % Self.onsetCount
    }

    /// Fills `count` samples. `hostTime` is the mach host time of the first sample.
    func render(into out: UnsafeMutablePointer<Float>, count: Int, hostTime: UInt64) {
        let sr = sampleRate
        let bufferStart = Double(hostTime) * hostSecondsPerTick + outputLatency
        if stokeRequested {
            stokeRequested = false
            stokeSamples = 0
        }
        let intensity = self.intensity
        let hold = holdCracklesUntil
        let target = fadeTarget
        let fadeStep = 1 / (fadeSeconds * sr)
        let drive = 1 + 2 * intensity                      // crackle rate up to 3x under the coil
        let tickBase = tickRate * drive / sr
        let popBase = 0.5 * drive / sr
        let bigBase = 0.067 * (1 + intensity) / sr          // one every 15 s or so
        let sizzleBase = 0.14 * (1 + intensity) / sr

        for i in 0..<count {
            let white = random() * 2 - 1
            let t = Float(stokeSamples) / sr
            stokeSamples += 1
            let stokeEnv = t < 12 ? exp(-t / 1.4) : 0
            let stokeWhoosh = t < 6 ? min(1, t / 0.08) * exp(-t / 0.45) : 0
            heat += (intensity - heat) * heatCoef

            // Slow, uneven swells: a quick flicker and a long breath, both random walks.
            if flutterCountdown <= 0 { flutterCountdown = flutterPeriod; flutterTarget = 0.55 + 0.45 * random() }
            flutterCountdown -= 1
            flutter += (flutterTarget - flutter) * flutterCoef
            if breathCountdown <= 0 { breathCountdown = breathPeriod; breathTarget = random() }
            breathCountdown -= 1
            breath += (breathTarget - breath) * breathCoef

            // Roar: brown and pink noise through a low-pass that opens as the fire is driven.
            brown = (brown + white * brownGain) * brownLeak
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            let pink = (pink0 + pink1 + pink2 + white * 0.1848) * 0.12
            let bedCutoff = 350 + 1000 * heat + 500 * stokeEnv
            bedLP += (brown * 1.6 + pink - bedLP) * (1 - exp(-2 * .pi * bedCutoff / sr))
            let bed = bedLP * flutter * (0.7 + 0.3 * breath) * (0.47 + 0.4 * heat + 0.35 * stokeEnv)

            // Hiss: the top of the noise, very quiet.
            hissLP += (white - hissLP) * hissCoef
            let high = white - hissLP
            let hiss = high * (0.012 + 0.01 * heat)

            // Whoosh: rushing air, a band of noise that opens with the coil and with a stoke.
            // Kept modest under the coil so the crackles still come through it.
            let w = max(stokeWhoosh, heat)
            whooshLP += (white - whooshLP) * (1 - exp(-2 * .pi * (250 + 1800 * w) / sr))
            whooshLP2 += (whooshLP - whooshLP2) * whooshLP2Coef
            let whoosh = (whooshLP - whooshLP2) * (0.9 * stokeWhoosh + 0.2 * heat) * (0.75 + 0.25 * flutter)

            // Crackles: Poisson events of three sizes, denser under the coil and after a stoke.
            let burst = stokeEnv * stokeEnv
            let pTick = tickBase + 35 * burst / sr
            let pPop = popBase + 6 * burst / sr
            let pBig = bigBase + 0.3 * burst / sr
            let pSizzle = sizzleBase + 0.5 * stokeEnv / sr
            let r = random()
            if r < pTick + pPop + pBig + pSizzle {
                let when = bufferStart + Double(i) / Double(sr)
                if when < hold {
                    // A clap may be on its way: keep quiet so we can't get it vetoed.
                } else if r < pTick {
                    spawn(.tick, at: when)
                } else if r < pTick + pPop {
                    spawn(.pop, at: when)
                } else if r < pTick + pPop + pBig {
                    spawn(.big, at: when)
                } else {
                    // Sap boiling out of a log: a sputtering hiss for a fraction of a second.
                    // It swells in over ~30 ms rather than snapping, but is stamped like a crackle anyway.
                    sizzlePeak = 1
                    sizzleDecay = exp(-1 / ((0.15 + 0.3 * random()) * sr))
                    onsets[onsetIndex] = when
                    onsetIndex = (onsetIndex + 1) % Self.onsetCount
                }
            }
            var crackle: Float = 0
            for k in 0..<Self.voiceCount {
                if voices[k].amp > 1e-4 {
                    let raw = (random() * 2 - 1) * voices[k].amp
                    voices[k].lp += (raw - voices[k].lp) * voices[k].tone
                    crackle += voices[k].lp
                    voices[k].amp *= voices[k].decay
                }
                if voices[k].ringAmp > 1e-4 {
                    voices[k].ringPhase += voices[k].ringInc
                    if voices[k].ringPhase > 2 * .pi { voices[k].ringPhase -= 2 * .pi }
                    crackle += sin(voices[k].ringPhase) * voices[k].ringAmp
                    voices[k].ringAmp *= voices[k].ringDecay
                }
            }
            if sizzleCountdown <= 0 { sizzleCountdown = sizzlePeriod; sizzleTarget = 0.3 + 0.7 * random() }
            sizzleCountdown -= 1
            sizzleMod += (sizzleTarget - sizzleMod) * sizzleModCoef
            sizzleEnv += (sizzlePeak - sizzleEnv) * sizzleAttack
            sizzlePeak *= sizzleDecay
            let sizzle = high * sizzleEnv * sizzleMod * 0.12

            // Fade, then a soft limiter: peaks can never pass -6 dBFS.
            if level < target { level = min(target, level + fadeStep) } else if level > target { level = max(target, level - fadeStep) }
            let mix = bed + hiss + whoosh + crackle * 0.85 + sizzle
            out[i] = tanh(mix * 1.5) * 0.5 * level
        }
    }
}

/// Plays the ambience. While the fire is lit its node sits on the clap detector's
/// engine, so echo cancellation can hear what we play; `--preview` and the
/// developer commands give it a small engine of its own instead.
final class FireSound {
    let synth = FireAmbience(sampleRate: 48_000)
    private var ownEngine: AVAudioEngine?

    /// 0 to 1: how hard the coil is driving the fire.
    var intensity: Float {
        get { synth.intensity }
        set { synth.intensity = newValue }
    }

    func stoke() { synth.stoke() }
    func fadeIn(over seconds: Double = 2) { synth.fade(to: 1, over: seconds) }
    func fadeOut(over seconds: Double = 0.8) { synth.fade(to: 0, over: seconds) }

    /// Whether one of our own crackles left the speaker within [-20 ms, +60 ms] of `hostSeconds`.
    func recentCrackle(near hostSeconds: Double) -> Bool { synth.recentCrackle(near: hostSeconds) }

    /// A node that plays the ambience in `format` (mono). Attach it to a stopped engine.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        synth.prepare(sampleRate: format.sampleRate)
        let synth = self.synth
        return AVAudioSourceNode(format: format) { _, timestamp, frames, buffers in
            let stamp = timestamp.pointee
            let host = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
            guard let data = UnsafeMutableAudioBufferListPointer(buffers)[0].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            synth.render(into: data, count: Int(frames), hostTime: host)
            return noErr
        }
    }

    /// Plays on an engine of its own (no microphone), for the preview.
    func playStandalone() {
        stopStandalone()
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let node = makeSourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            log("Could not play the fire sound: \(error.localizedDescription)")
            return
        }
        synth.outputLatency = engine.outputNode.presentationLatency
        ownEngine = engine
    }

    func stopStandalone() {
        ownEngine?.stop()
        ownEngine = nil
    }

    /// Renders `seconds` of ambience to a mono 16-bit WAV, with a stoke at 5 s and
    /// the coil held from 10 s to 14 s, for listening and analysis.
    static func write(to url: URL, seconds: Double) -> Bool {
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
              ]),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)
        else { return false }
        let synth = FireAmbience(sampleRate: rate)
        synth.fade(to: 1, over: 2)
        let total = Int(seconds * rate)
        var done = 0
        var stoked = false
        while done < total {
            let count = min(4800, total - done)
            let t = Double(done) / rate
            if t >= 5, !stoked { synth.stoke(); stoked = true }
            synth.intensity = (t >= 10 && t < 14) ? 1 : 0
            synth.render(into: buffer.floatChannelData![0], count: count, hostTime: UInt64(t * 1e9))
            buffer.frameLength = AVAudioFrameCount(count)
            guard (try? file.write(from: buffer)) != nil else { return false }
            done += count
        }
        return true
    }
}
