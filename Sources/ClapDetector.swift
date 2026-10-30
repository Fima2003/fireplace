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

    func process(_ samples: UnsafePointer<Float>, count: Int, emit: (Event) -> Void) {
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
                step(rms: rms, time: time, emit: emit)
                chunkSumSq = 0
                chunkCount = 0
            }
        }
        samplesSeen += Int64(count)
    }

    private func step(rms: Float, time: Double, emit: (Event) -> Void) {
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
                registerClap(at: start, level: peak, duration: time - start, emit: emit)
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
final class ClapDetector {
    var onClap: ((Float) -> Void)?
    var onDoubleClap: (() -> Void)?

    private let settings: ClapSettings
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var ignoreUntil = Date.distantPast

    /// Ignores claps for a while, e.g. while our own crackling sound is playing:
    /// a crackle through the speakers looks just like a clap to the microphone.
    func ignore(for seconds: TimeInterval) {
        ignoreUntil = max(ignoreUntil, Date().addingTimeInterval(seconds))
    }

    init(settings: ClapSettings = .fromDefaults()) {
        self.settings = settings
    }

    struct NoInputError: LocalizedError {
        var errorDescription: String? { "No microphone input is available." }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInputError() }

        let analyzer = ClapAnalyzer(sampleRate: format.sampleRate, settings: settings)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            analyzer.process(channel, count: Int(buffer.frameLength)) { event in
                DispatchQueue.main.async { self?.deliver(event) }
            }
        }
        engine.prepare()
        try engine.start()

        // Rebuild the tap if the input device or its format changes (e.g. AirPods connect).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stop()
            do { try self.start() } catch { log("Could not restart microphone: \(error.localizedDescription)") }
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func deliver(_ event: ClapAnalyzer.Event) {
        guard Date() >= ignoreUntil else { return }
        switch event {
        case let .clap(_, level, _): onClap?(level)
        case .doubleClap: onDoubleClap?()
        }
    }
}
