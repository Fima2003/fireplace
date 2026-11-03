import AVFoundation

/// Tunables for clap detection. Override from the terminal, e.g.
/// `defaults write com.fima.Fireplace ClapThreshold -float 0.03`.
struct ClapSettings {
    /// Minimum high-passed RMS level (0...1) for a sound to count as a clap.
    var minLevel: Float = 0.015
    /// How many times louder than the background noise a clap's onset must be.
    var onsetRatio: Float = 6
    /// A clap peaks almost instantly and dies away fast; anything slower is ignored.
    var maxRiseTime: Double = 0.012
    var maxClapDuration: Double = 0.1
    /// Allowed spacing between the two claps of a double clap (onset to onset).
    var minGap: Double = 0.1
    var maxGap: Double = 0.8
    /// Ignore input for this long after a double clap fires.
    var cooldown: Double = 1.0

    static func fromDefaults() -> ClapSettings {
        var s = ClapSettings()
        let d = UserDefaults.standard
        if d.object(forKey: "ClapThreshold") != nil { s.minLevel = d.float(forKey: "ClapThreshold") }
        if d.object(forKey: "OnsetRatio") != nil { s.onsetRatio = d.float(forKey: "OnsetRatio") }
        if d.object(forKey: "MaxClapGap") != nil { s.maxGap = d.double(forKey: "MaxClapGap") }
        return s
    }
}

/// Pure signal-processing half of the detector: feed it samples, it emits events.
/// Knows nothing about audio devices, so it can also be run over a file (`--analyze`).
final class ClapAnalyzer {
    enum Event {
        case clap(time: Double, level: Float, duration: Double)
        case doubleClap(time: Double)
    }

    private enum State {
        case idle
        case rising(start: Double, peak: Float, peakTime: Double)
        case sustained
    }

    private let settings: ClapSettings
    private let sampleRate: Double
    private let chunkSize: Int
    private let hpCoeff: Float
    private let upRate: Float
    private let downRate: Float

    private var prevX: Float = 0
    private var prevY: Float = 0
    private var chunkSumSq: Float = 0
    private var chunkCount = 0
    private var samplesSeen: Int64 = 0

    private var state = State.idle
    private var background: Float
    private var pendingClap: (time: Double, level: Float)?
    private var mutedUntil: Double = 0
    private var previousRMS: Float = 0

    /// Seconds of audio processed so far; event times are on this clock.
    var elapsed: Double { Double(samplesSeen) / sampleRate }

    /// The onset of a first clap still waiting for its partner, if one could yet arrive.
    var pendingClapTime: Double? {
        guard let first = pendingClap, elapsed - first.time <= settings.maxGap else { return nil }
        return first.time
    }

    init(sampleRate: Double, settings: ClapSettings) {
        self.settings = settings
        self.sampleRate = sampleRate
        // Analyse in 5 ms windows regardless of how big the hardware buffers are.
        chunkSize = max(64, Int(sampleRate * 0.005))
        // One-pole high-pass at ~1.5 kHz: claps are broadband, voices and hum mostly aren't.
        let rc = 1.0 / (2 * Double.pi * 1500)
        let dt = 1.0 / sampleRate
        hpCoeff = Float(rc / (rc + dt))
        // Background level follows the room slowly upward and quickly downward.
        let chunkSeconds = Float(chunkSize) / Float(sampleRate)
        upRate = chunkSeconds / 2.0
        downRate = chunkSeconds / 0.5
        background = settings.minLevel / 4
    }

    /// Ignores onsets for the next `seconds` of audio; the background level still adapts.
    func mute(for seconds: Double) {
        mutedUntil = max(mutedUntil, elapsed + seconds)
    }

    /// Feeds `count` samples. `veto` is asked about each clap's onset time before it
    /// counts; a vetoed clap is neither reported nor taken as half of a double clap.
    func process(_ samples: UnsafePointer<Float>, count: Int, veto: ((Double) -> Bool)? = nil, emit: (Event) -> Void) {
        for i in 0..<count {
            let x = samples[i]
            let y = hpCoeff * (prevY + x - prevX)
            prevX = x
            prevY = y
            chunkSumSq += y * y
            chunkCount += 1
            if chunkCount == chunkSize {
                let rms = (chunkSumSq / Float(chunkSize)).squareRoot()
                let time = Double(samplesSeen + Int64(i)) / sampleRate
                step(rms: rms, time: time, veto: veto, emit: emit)
                chunkSumSq = 0
                chunkCount = 0
            }
        }
        samplesSeen += Int64(count)
    }

    private func step(rms: Float, time: Double, veto: ((Double) -> Bool)?, emit: (Event) -> Void) {
        defer { previousRMS = rms }
        switch state {
        case .idle:
            // Onset: loud, well above the room, and a near-instant jump from the last 5 ms.
            if time >= mutedUntil, rms > settings.minLevel, rms > background * settings.onsetRatio,
               rms > previousRMS * 4 {
                state = .rising(start: time, peak: rms, peakTime: time)
            } else {
                // Between the two claps of a double clap the room should go quiet.
                // Anything loud in that gap (like the vowels of speech) cancels it.
                if let first = pendingClap, time >= mutedUntil, rms > first.level * 0.35 {
                    pendingClap = nil
                }
                adaptBackground(rms)
            }

        case let .rising(start, oldPeak, oldPeakTime):
            let (peak, peakTime) = rms > oldPeak ? (rms, time) : (oldPeak, oldPeakTime)
            if peakTime - start > settings.maxRiseTime || time - start > settings.maxClapDuration {
                // Swelling or lasting too long to be a clap (speech, music, a ringing door slam).
                // It also breaks up any half-finished double clap.
                state = .sustained
                pendingClap = nil
            } else if rms < peak * 0.2 {
                // Sharp attack and a fast ~14 dB decay: that's a clap.
                state = .idle
                // Don't let the clap's own echo count as the next one.
                mutedUntil = max(mutedUntil, time + 0.06)
                if veto?(start) != true {
                    registerClap(at: start, level: peak, duration: time - start, emit: emit)
                }
            } else {
                state = .rising(start: start, peak: peak, peakTime: peakTime)
            }

        case .sustained:
            adaptBackground(rms)
            if rms < max(background * settings.onsetRatio * 0.5, settings.minLevel * 0.5) {
                state = .idle
            }
        }
    }

    private func registerClap(at time: Double, level: Float, duration: Double, emit: (Event) -> Void) {
        emit(.clap(time: time, level: level, duration: duration))
        if let first = pendingClap {
            let gap = time - first.time
            let loudnessRatio = max(level, first.level) / min(level, first.level)
            if gap >= settings.minGap, gap <= settings.maxGap, loudnessRatio < 6 {
                pendingClap = nil
                mutedUntil = time + settings.cooldown
                emit(.doubleClap(time: time))
                return
            }
        }
        pendingClap = (time, level)
    }

    private func adaptBackground(_ rms: Float) {
        let rate = rms > background ? upRate : downRate
        background = max(background + (rms - background) * rate, 1e-5)
    }
}

/// Listens to the default microphone and reports double claps on the main queue.
///
/// Event driven end to end: Core Audio hands each captured buffer to the tap
/// block, the analyzer runs over it, and only a detected double clap wakes the
/// main thread. There are no timers or polling loops anywhere.
///
/// While the fire is lit the fire sound plays on this same engine, because our
/// own crackles through the speakers look just like claps to the microphone.
/// Voice processing on the input node then cancels what we play (mode `.echoCancelled`).
/// If it can't be enabled, every crackle is stamped with the host time it left the
/// speaker and claps that land within [-20 ms, +60 ms] of one are dropped
/// (mode `.timeRejected`).
///
/// An engine with voice processing takes close to two seconds to come up, so
/// engines are built on a queue of their own and published on the main thread
/// once they run: the fire can appear the moment the clap is heard. Builds run
/// one at a time, and a `stop()` or a newer request makes the one in flight
/// moot; its engine is stopped as soon as it comes up.
final class ClapDetector {
    enum Mode {
        case inputOnly, echoCancelled, timeRejected
    }

    var onClap: ((Float) -> Void)?
    var onDoubleClap: (() -> Void)?
    /// Called on the main queue when a lit engine (or its replacement after a device
    /// change) is running, with `nil` when none could be started at all.
    var onModeChange: ((Mode?) -> Void)?
    private(set) var mode: Mode?
    /// RMS of the raw microphone input over the last second or so.
    private(set) var inputRMS: Float = 0

    private let settings: ClapSettings
    private var engine: AVAudioEngine?
    private var sound: FireSound?
    private var wantsEchoCancellation = true
    private var configObserver: NSObjectProtocol?

    /// Engines are built and old ones stopped here, in order, off the main thread.
    private let buildQueue = DispatchQueue(label: "com.fima.Fireplace.ClapDetector", qos: .userInitiated)
    /// Bumped by every start and stop; a build or a tap buffer from an older
    /// generation is thrown away. Written on the main thread, read on the others.
    private var generation = 0
    private let generationLock = NSLock()

    init(settings: ClapSettings = .fromDefaults()) {
        self.settings = settings
    }

    struct NoInputError: LocalizedError {
        var errorDescription: String? { "No microphone input is available." }
    }

    /// Microphone only, no voice processing: the mic path stays untouched and nothing is
    /// ducked. Quick (well under a second), so it waits for the engine before returning.
    func start() throws {
        sound = nil
        let (old, gen) = retire()
        let started = DispatchTime.now()
        let built = try buildQueue.sync { () -> Built in
            Self.shutDown(old)
            return try build(cancelling: false, sound: nil, generation: gen)
        }
        publish(built, generation: gen, builtIn: Self.millisecondsSince(started))
    }

    /// Microphone plus the fire sound on one engine: echo cancellation if it can be had,
    /// time-based rejection if not, and the microphone alone if the sound can't start at all.
    /// Returns at once; `onModeChange` reports the engine that came up.
    func start(with sound: FireSound, echoCancellation: Bool = true) {
        self.sound = sound
        wantsEchoCancellation = echoCancellation
        rebuild()
    }

    /// Takes the engine out of service now; it is stopped and released on the build
    /// queue (letting go of a voice-processing engine costs a quarter of a second). A
    /// build still in flight stops its own engine when it is done; `completion` runs
    /// on the main queue once nothing of ours is left running.
    func stop(completion: (() -> Void)? = nil) {
        let (old, _) = retire()
        buildQueue.async {
            Self.shutDown(old)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - Building engines

    private struct Built {
        let engine: AVAudioEngine
        let mode: Mode
        let format: AVAudioFormat
        let inputLatency: Double
    }

    /// Takes the current engine out of service (the caller stops it) and starts a new
    /// generation, so whatever is still being built for the old one is discarded.
    private func retire() -> (engine: AVAudioEngine?, generation: Int) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let old = engine
        engine = nil
        mode = nil
        generationLock.lock()
        generation += 1
        let gen = generation
        generationLock.unlock()
        return (old, gen)
    }

    private func isCurrent(_ gen: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == gen
    }

    private static func shutDown(_ engine: AVAudioEngine?) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    private static func millisecondsSince(_ t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
    }

    /// Retires the current engine and builds its replacement on the build queue:
    /// the lit chain when there is a sound to play, the plain microphone otherwise.
    private func rebuild() {
        let (old, gen) = retire()
        let sound = self.sound
        let wantsAEC = wantsEchoCancellation
        buildQueue.async { [weak self] in
            Self.shutDown(old)
            guard let self, self.isCurrent(gen) else { return }
            let started = DispatchTime.now()
            var built: Built?
            do {
                built = try sound.map { try self.buildLit(sound: $0, cancelling: wantsAEC, generation: gen) }
                    ?? self.build(cancelling: false, sound: nil, generation: gen)
            } catch {
                log("Could not start the microphone: \(error.localizedDescription)")
            }
            let ms = Self.millisecondsSince(started)
            // Superseded while building (a stop, or another device change): nobody wants this one.
            guard self.isCurrent(gen) else { return Self.shutDown(built?.engine) }
            DispatchQueue.main.async {
                // Releasing a voice-processing engine takes a quarter second: not on this thread.
                guard self.isCurrent(gen) else { return self.buildQueue.async { Self.shutDown(built?.engine) } }
                if let built { self.publish(built, generation: gen, builtIn: ms) }
                self.onModeChange?(built?.mode)
            }
        }
    }

    /// The lit engine, trying the ways of hearing claps through our own sound in turn.
    private func buildLit(sound: FireSound, cancelling wantsAEC: Bool, generation gen: Int) throws -> Built {
        if wantsAEC {
            do { return try build(cancelling: true, sound: sound, generation: gen) } catch {
                log("Echo cancellation unavailable (\(error.localizedDescription)); rejecting our own crackles by time instead.")
            }
        }
        do { return try build(cancelling: false, sound: sound, generation: gen) } catch {
            log("Could not play the fire sound with the microphone (\(error.localizedDescription)); listening without it.")
        }
        return try build(cancelling: false, sound: nil, generation: gen)
    }

    /// Builds and starts one engine. Runs on the build queue, so it reads nothing of
    /// `self` that the main thread writes; what it needs comes in as arguments.
    private func build(cancelling: Bool, sound: FireSound?, generation gen: Int) throws -> Built {
        // Voice processing reconfigures the input node, so each mode gets a fresh engine.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if cancelling {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false
            if #available(macOS 14, *) {
                // Turn other apps down as little as voice processing allows.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInputError() }

        let analyzer = ClapAnalyzer(sampleRate: format.sampleRate, settings: settings)
        if sound != nil {
            // A fresh analyzer has forgotten the double clap that lit the fire, and with echo
            // cancellation the canceller takes a few seconds to converge on our sound: what
            // gets through meanwhile must not put the fire straight out again. (The fallback
            // gets the same 3 s for the first reason alone.)
            analyzer.mute(for: 3)
        }
        // Without echo cancellation, our crackles are told apart from claps by when they happened.
        let rejectOurs = cancelling ? nil : sound
        sound?.synth.tickRate = cancelling ? 3 : 1.5
        // The tap's buffers carry the host time they left the input device; the sound
        // reached the microphone that much earlier. (Taken as fixed for the life of the
        // engine, and assumed to be what the stamp leaves out; on a Bluetooth
        // microphone it is tens of milliseconds.)
        let inputLatency = input.presentationLatency
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sumSq: Float = 0
            for i in 0..<count { sumSq += channel[i] * channel[i] }
            inputRMS += ((sumSq / Float(max(1, count))).squareRoot() - inputRMS) * 0.05
            // Where this buffer sits on the host clock, to date each clap against our crackles.
            let hostStart = (when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(count) / format.sampleRate)
                - inputLatency
            let analyzerStart = analyzer.elapsed
            let veto: ((Double) -> Bool)? = rejectOurs.map { sound in
                { onset in sound.recentCrackle(near: hostStart + (onset - analyzerStart)) }
            }
            analyzer.process(channel, count: count, veto: veto) { event in
                DispatchQueue.main.async { self.deliver(event, from: gen) }
            }
            // While a first clap waits for its partner, hold our crackles back so they can't
            // veto the second one (a second's pause in the crackling goes unnoticed).
            if let sound = rejectOurs, let first = analyzer.pendingClapTime {
                sound.synth.holdCracklesUntil = hostStart + (first - analyzerStart) + self.settings.maxGap + 0.1
            }
        }

        if let sound {
            // Mono at the engine's rate; with voice processing in and out must share a format.
            let rate = cancelling ? format.sampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw NoInputError() }
            let node = sound.makeSourceNode(format: mono)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        }

        engine.prepare()
        try engine.start()
        sound?.synth.outputLatency = engine.outputNode.presentationLatency
        let mode: Mode = sound == nil ? .inputOnly : cancelling ? .echoCancelled : .timeRejected
        return Built(engine: engine, mode: mode, format: format, inputLatency: inputLatency)
    }

    /// Makes a freshly started engine the current one. Main thread.
    private func publish(_ built: Built, generation gen: Int, builtIn ms: Double) {
        let engine = built.engine
        self.engine = engine
        mode = built.mode
        let format = built.format
        switch built.mode {
        case .inputOnly:
            // Lit and here: the sound could not start, so it stays off until the next light.
            if sound != nil { sound = nil }
            log(String(format: "Listening on the microphone (%.0f Hz, %d ch; up in %.0f ms).",
                       format.sampleRate, format.channelCount, ms))
        case .echoCancelled:
            log(String(format: "Microphone and fire sound on one engine; voice processing cancels our own sound (mode: AEC, %.0f Hz, %d ch; up in %.0f ms off the main thread).",
                       format.sampleRate, format.channelCount, ms))
        case .timeRejected:
            wantsEchoCancellation = false
            log(String(format: "Microphone and fire sound without echo cancellation; dropping claps that coincide with our crackles (mode: fallback, %.0f Hz, %d ch, input latency %.1f ms; up in %.0f ms off the main thread).",
                       format.sampleRate, format.channelCount, built.inputLatency * 1000, ms))
        }

        // Rebuild if the input or output device changes (e.g. AirPods connect).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            log("Audio device changed; rebuilding.")
            self.rebuild()
        }
    }

    private func deliver(_ event: ClapAnalyzer.Event, from gen: Int) {
        guard isCurrent(gen) else { return }
        switch event {
        case let .clap(_, level, _): onClap?(level)
        case .doubleClap: onDoubleClap?()
        }
    }
}
