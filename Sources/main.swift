import AppKit
import AVFoundation

func log(_ message: String) {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sound = FireSound()
    private lazy var fireplace = FireplaceController(sound: sound)
    private let detector = ClapDetector()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let lightItem = NSMenuItem(title: "Light the Fire", action: #selector(toggle), keyEquivalent: "")
    private let stokeItem = NSMenuItem(title: "Stoke the Fire", action: #selector(stoke), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Fireplace", action: #selector(putOutAndQuit), keyEquivalent: "q")
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        fireplace.restoreWallpaperAfterCrash()
        setUpMenuBar()

        detector.onClap = { level in log(String(format: "clap (level %.3f)", level)) }
        detector.onDoubleClap = { [weak self] in
            log("double clap")
            self?.toggle()
        }
        detector.onModeChange = { [weak self] mode in self?.audioModeChanged(mode) }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { granted ? self.startListening() : self.microphoneDenied() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
        fireplace.restoreWallpaper()
    }

    private func startListening() {
        do {
            try detector.start()
            statusLine.title = "Listening — clap twice to light the fire"
            log("Listening for a double clap…")
        } catch {
            statusLine.title = "Microphone unavailable"
            log("Could not start microphone: \(error.localizedDescription)")
        }
    }

    /// The first double clap lights the fire; the next one puts it out and quits.
    @objc private func toggle() {
        guard !quitting else { return }
        if fireplace.isLit {
            putOutAndQuit()
        } else {
            light()
        }
    }

    private func light() {
        // The sound joins the microphone's engine so echo cancellation can hear it. That
        // engine takes a couple of seconds to build, so it is built in the background:
        // the fire appears now, and the sound fades in once audioModeChanged hears it's up.
        detector.start(with: sound)
        fireplace.light()
        statusLine.title = "Fire's lit — clap twice to put it out"
        lightItem.isHidden = true
        stokeItem.isHidden = false
        quitItem.title = "Put Out the Fire and Quit"
        statusItem.button?.image = Self.icon("flame.fill")
    }

    /// The lit engine (or its replacement after a device change) is up, or nothing could be started.
    private func audioModeChanged(_ mode: ClapDetector.Mode?) {
        guard fireplace.isLit, !quitting else { return }
        switch mode {
        case .echoCancelled, .timeRejected:
            statusLine.title = "Fire's lit — clap twice to put it out"
        case .inputOnly:
            statusLine.title = "Fire's lit, but its sound could not start — clap twice to put it out"
        case nil:
            // No microphone to hear a clap: the fire still roars on an engine of its own,
            // and the menu is the way to put it out.
            sound.playStandalone()
            statusLine.title = "Fire's lit — microphone unavailable, put it out from this menu"
            log("Microphone unavailable; the fire sound plays on its own and the menu puts the fire out.")
        }
    }

    /// Like holding the coil in the fire for a moment and a half.
    @objc private func stoke() {
        guard !quitting else { return }
        fireplace.pressCoil(for: 1.5)
    }

    @objc private func putOutAndQuit() {
        guard !quitting else { return }
        quitting = true
        statusLine.title = "Putting out the fire…"
        fireplace.putOut { [self] in
            // Waits for any engine still being built, so nothing is left half started.
            detector.stop { NSApp.terminate(nil) }
        }
    }

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon("flame")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for item in [lightItem, stokeItem, quitItem] {
            item.target = self
            menu.addItem(item)
        }
        stokeItem.isHidden = true
        statusItem.menu = menu
    }

    private static func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Fireplace")
        image?.isTemplate = true
        return image
    }

    private func microphoneDenied() {
        statusLine.title = "Microphone access denied"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fireplace needs the microphone"
        alert.informativeText = "It listens for a double clap. Allow Fireplace under Privacy & Security → Microphone, then open it again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        NSApp.terminate(nil)
    }
}

// Developer commands, handy for tuning without touching the desktop:
//   Fireplace --analyze recording.wav   print the claps found in an audio file
//   Fireplace --render out.png          write a still of a fresh fire (2880x1800)
//   Fireplace --preview                 show the live fire, the coil and the sound in a normal window (quits nothing)
//   Fireplace --make-icon AppIcon.iconset   render the app icon
//   Fireplace --sound out.wav           write the fire sound to a file (--seconds N, default 20)
//   Fireplace --listen N [--no-aec]     run the lit-mode audio (sound + clap detector) for N seconds
let usage = """
    usage: Fireplace --analyze recording.wav
           Fireplace --render out.png [--seconds N] [--stoke]
           Fireplace --sound out.wav [--seconds N]
           Fireplace --listen N [--no-aec]
           Fireplace --make-icon AppIcon.iconset
           Fireplace --preview
    """

/// Runs a developer command if the arguments name one. A command with a bad or
/// missing argument is an error, never a reason to start the real app (which
/// quits every other app on a double clap).
func runCommandLine(_ args: [String]) -> Int32? {
    /// The word after `flag`, if there is one and it isn't another flag.
    func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }
    func misuse(_ what: String) -> Int32 {
        print(what)
        print(usage)
        return 1
    }
    /// `--seconds N` where given, `fallback` where not; nil if N isn't a number.
    func seconds(default fallback: Double) -> Double? {
        guard args.contains("--seconds") else { return fallback }
        guard let n = value(after: "--seconds").flatMap(Double.init), n >= 0 else { return nil }
        return n
    }

    if args.contains("--analyze") {
        guard let path = value(after: "--analyze") else { return misuse("--analyze needs an audio file") }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return 1 }
            try file.read(into: buffer)
            let analyzer = ClapAnalyzer(sampleRate: format.sampleRate, settings: .fromDefaults())
            var doubles = 0
            analyzer.process(buffer.floatChannelData![0], count: Int(buffer.frameLength)) { event in
                switch event {
                case let .clap(t, level, duration):
                    print(String(format: "%7.3fs  clap         level %.3f  %3.0f ms", t, level, duration * 1000))
                case let .doubleClap(t): print(String(format: "%7.3fs  DOUBLE CLAP", t)); doubles += 1
                }
            }
            print("\(doubles) double clap(s)")
            return 0
        } catch {
            print("Could not read audio: \(error.localizedDescription)")
            return 1
        }
    }
    if args.contains("--render") {
        guard let path = value(after: "--render") else { return misuse("--render needs an output file") }
        guard let seconds = seconds(default: 4) else { return misuse("--seconds needs a number") }
        let seed = FireSeed()
        print(String(format: "seed %016llx", seed.raw))
        guard let renderer = FireRenderer(layoutAspect: 1.6, seed: seed),
              let image = renderer.renderImage(width: 2880, height: 1800, warmUp: seconds,
                                               stokeAt: args.contains("--stoke") ? seconds - 0.5 : nil),
              (try? writePNG(image, to: URL(fileURLWithPath: path))) != nil else { return 1 }
        return 0
    }
    if args.contains("--sound") {
        guard let path = value(after: "--sound") else { return misuse("--sound needs an output file") }
        guard let seconds = seconds(default: 20) else { return misuse("--seconds needs a number") }
        return FireSound.write(to: URL(fileURLWithPath: path), seconds: seconds) ? 0 : 1
    }
    if args.contains("--listen") {
        guard let seconds = value(after: "--listen").flatMap(Double.init), seconds > 0 else {
            return misuse("--listen needs a number of seconds")
        }
        // Lit-mode audio in the terminal: the sound plays, the detector listens through it.
        let sound = FireSound()
        let detector = ClapDetector()
        detector.onClap = { level in print(String(format: "clap         level %.3f", level)); fflush(stdout) }
        detector.onDoubleClap = { print("DOUBLE CLAP"); fflush(stdout) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            print("Microphone permission not yet granted to this process; macOS is asking (the prompt names the app that launched this)…")
            fflush(stdout)
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { print("Microphone access denied."); exit(1) }
                // The engine builds in the background; a fast timer shows the main thread stays free.
                let requested = Date()
                var ticks = 0, lastTick = requested, longestGap = 0.0
                let ticker = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                    let now = Date()
                    ticks += 1
                    longestGap = max(longestGap, now.timeIntervalSince(lastTick))
                    lastTick = now
                }
                var meter: Timer?
                detector.onModeChange = { mode in
                    if meter == nil {
                        ticker.invalidate()
                        print(String(format: "engine up after %.0f ms; meanwhile the main thread ran %d 20 ms ticks, longest gap %.0f ms",
                                     Date().timeIntervalSince(requested) * 1000, ticks, longestGap * 1000))
                    } else {
                        // A device change while listening: the engine was rebuilt in the background.
                        print("engine rebuilt")
                    }
                    switch mode {
                    case .echoCancelled: print("mode: AEC")
                    case .timeRejected: print("mode: fallback")
                    case .inputOnly: print("mode: microphone only (the sound could not start)")
                    case nil: print("Could not start audio."); exit(1)
                    }
                    print("Claps are ignored for the first 3 s after the engine starts; then clap twice.")
                    fflush(stdout)
                    if meter == nil {
                        sound.fadeIn(over: 2)
                        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                            print(String(format: "input RMS %.4f", detector.inputRMS))
                            fflush(stdout)
                        }
                    }
                }
                detector.start(with: sound, echoCancellation: !args.contains("--no-aec"))
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    sound.fadeOut(over: 0.3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        detector.stop { exit(0) }
                    }
                }
            }
        }
        RunLoop.main.run()
        // The run loop never returns here (the timers call exit), but if it ever did this
        // must still be a finished command, not the start of the real app.
        return 0
    }
    if args.contains("--make-icon") {
        guard let path = value(after: "--make-icon") else { return misuse("--make-icon needs an output folder") }
        do {
            try AppIcon.writeIconset(to: URL(fileURLWithPath: path))
            return 0
        } catch {
            print("Could not make icon: \(error)")
            return 1
        }
    }
    // A mistyped flag must not start the real app either.
    let known: Set<String> = ["--preview", "--seconds", "--stoke", "--no-aec"]
    if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
        return misuse("Unknown option \(unknown)")
    }
    return nil
}

if let status = runCommandLine(CommandLine.arguments) { exit(status) }

let app = NSApplication.shared
if CommandLine.arguments.contains("--preview") {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 750),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Fireplace Preview"
    let view = FireplaceView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750), seed: FireSeed())
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    // The sound and the coil behave as they do when lit; the coil sits beside the window.
    let sound = FireSound()
    sound.playStandalone()
    sound.fadeIn(over: 2)
    let coil = CoilPanel()
    coil.onPress = { [weak view] in
        view?.stoke()
        sound.stoke()
    }
    coil.onHeat = { [weak view] heat in
        view?.setBoost(heat)
        sound.intensity = heat
    }
    coil.setFrameOrigin(NSPoint(x: window.frame.maxX + 16, y: window.frame.minY))
    coil.orderFront(nil)
    log("Coil button shown at \(NSStringFromRect(coil.frame))")
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
