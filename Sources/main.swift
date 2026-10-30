import AppKit
import AVFoundation

func log(_ message: String) {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fireplace = FireplaceController()
    private let detector = ClapDetector()
    private let sound = FireSound()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Light the Fire", action: #selector(toggle), keyEquivalent: "")
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

    /// A double clap lights the fire; every one after that stokes it.
    @objc private func toggle() {
        guard !quitting else { return }
        if fireplace.isLit {
            fireplace.stoke()
            sound.play()
            detector.ignore(for: FireCrackle.duration + 0.5)
        } else {
            fireplace.light()
            statusLine.title = "Fire's lit — clap twice to stoke it"
            toggleItem.title = "Stoke the Fire"
            quitItem.title = "Put Out the Fire and Quit"
            statusItem.button?.image = Self.icon("flame.fill")
        }
    }

    @objc private func putOutAndQuit() {
        guard !quitting else { return }
        quitting = true
        sound.stop()
        statusLine.title = "Putting out the fire…"
        fireplace.putOut { NSApp.terminate(nil) }
    }

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon("flame")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        quitItem.target = self
        menu.addItem(quitItem)
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
//   Fireplace --preview                 show the live fire in a normal window (quits nothing)
//   Fireplace --make-icon AppIcon.iconset   render the app icon
//   Fireplace --sound out.wav           write the stoking sound to a file
func runCommandLine(_ args: [String]) -> Int32? {
    if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[i + 1]))
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
    if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
        let seed = FireSeed()
        print(String(format: "seed %016llx", seed.raw))
        let seconds = args.firstIndex(of: "--seconds").flatMap { Double(args[$0 + 1]) } ?? 4
        guard let renderer = FireRenderer(layoutAspect: 1.6, seed: seed),
              let image = renderer.renderImage(width: 2880, height: 1800, warmUp: seconds,
                                               stokeAt: args.contains("--stoke") ? seconds - 0.5 : nil),
              (try? writePNG(image, to: URL(fileURLWithPath: args[i + 1]))) != nil else { return 1 }
        return 0
    }
    if let i = args.firstIndex(of: "--sound"), i + 1 < args.count {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(FireCrackle.duration * rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: args[i + 1]),
                                          settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                     AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        else { return 1 }
        buffer.frameLength = frames
        FireCrackle(sampleRate: rate).render(into: buffer.floatChannelData![0], count: Int(frames))
        do { try file.write(from: buffer) } catch { return 1 }
        return 0
    }
    if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
        do {
            try AppIcon.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
            return 0
        } catch {
            print("Could not make icon: \(error)")
            return 1
        }
    }
    return nil
}

if let status = runCommandLine(CommandLine.arguments) { exit(status) }

let app = NSApplication.shared
if CommandLine.arguments.contains("--preview") {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 750),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Fireplace Preview"
    window.contentView = FireplaceView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750), seed: FireSeed())
    window.makeKeyAndOrderFront(nil)
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
