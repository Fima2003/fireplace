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
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Light the Fire", action: #selector(toggle), keyEquivalent: "")
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

    @objc private func toggle() {
        guard !quitting else { return }
        if fireplace.isLit {
            quitting = true
            statusLine.title = "Putting out the fire…"
            fireplace.putOut { NSApp.terminate(nil) }
        } else {
            fireplace.light()
            statusLine.title = "Fire's lit — clap twice to put it out and quit"
            toggleItem.title = "Put Out the Fire and Quit"
            statusItem.button?.image = Self.icon("flame.fill")
        }
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
        menu.addItem(NSMenuItem(title: "Quit Fireplace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
//   Fireplace --render out.png          write the wallpaper art (2880x1800)
//   Fireplace --preview                 show the live fire in a normal window (quits nothing)
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
        guard let image = FireplaceArt.render(size: CGSize(width: 2880, height: 1800), flames: !args.contains("--no-flames")),
              (try? FireplaceArt.writePNG(image, to: URL(fileURLWithPath: args[i + 1]))) != nil else { return 1 }
        return 0
    }
    return nil
}

if let status = runCommandLine(CommandLine.arguments) { exit(status) }

let app = NSApplication.shared
if CommandLine.arguments.contains("--preview") {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 750),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Fireplace Preview"
    window.contentView = FireplaceView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750),
                                       scale: window.backingScaleFactor)
    window.makeKeyAndOrderFront(nil)
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
