import AppKit

/// Lights the fireplace (wallpaper + live desktop-level window + sound + the coil
/// button + quitting other apps) and puts it out again, restoring the original wallpaper.
final class FireplaceController {
    private(set) var isLit = false
    private var windows: [NSWindow] = []
    private var coil: CoilPanel?
    /// Plays for as long as the fire burns; its engine belongs to the clap detector.
    private let sound: FireSound
    private var occlusionObservers: [NSObjectProtocol] = []
    private var savedWallpapers: [CGDirectDisplayID: (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])] = [:]

    private let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fireplace", isDirectory: true)
    /// Written while lit so a crash or force-quit doesn't leave the wallpaper changed.
    private var recoveryFile: URL { supportDir.appendingPathComponent("original-wallpapers.json") }

    init(sound: FireSound) {
        self.sound = sound
    }

    func light() {
        guard !isLit else { return }
        isLit = true
        // One hardware-random seed per fire, shared by the wallpaper and the live view.
        let seed = FireSeed()
        log(String(format: "Lighting fire %016llx", seed.raw))
        setFireplaceWallpaper(seed: seed)
        showWindows(seed: seed)
        showCoil()
        // The ramp runs from the sound's first rendered sample, i.e. once its engine is up.
        sound.fadeIn(over: 2)
        quitOtherApps()
    }

    /// Flares the fire up with a shower of sparks on every screen.
    func stoke() {
        for window in windows { (window.contentView as? FireplaceView)?.stoke() }
    }

    /// Drives the fire harder (0 to 1) for as long as the coil is held against it.
    func setBoost(_ boost: Float) {
        for window in windows { (window.contentView as? FireplaceView)?.setBoost(boost) }
    }

    /// Presses the coil into the fire for a moment, as the menu item does.
    func pressCoil(for seconds: Double = 1.5) { coil?.press(for: seconds) }

    /// Fades the fire, its sound and the coil out together, then restores the wallpaper.
    func putOut(completion: @escaping () -> Void) {
        guard isLit else { return completion() }
        coil?.tearDown()
        sound.fadeOut(over: 0.8)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.8
            for window in windows { window.animator().alphaValue = 0 }
            coil?.animator().alphaValue = 0
        }, completionHandler: { [self] in
            windows.forEach { $0.orderOut(nil) }
            windows = []
            occlusionObservers.forEach { NotificationCenter.default.removeObserver($0) }
            occlusionObservers = []
            coil?.orderOut(nil)
            coil = nil
            restoreWallpaper()
            isLit = false
            completion()
        })
    }

    // MARK: - Wallpaper

    private func setFireplaceWallpaper(seed: FireSeed) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        // Each fire is unique, so clear out stills from earlier ones.
        for old in (try? FileManager.default.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("fireplace-") {
            try? FileManager.default.removeItem(at: old)
        }
        let workspace = NSWorkspace.shared
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if savedWallpapers[id] == nil, let url = workspace.desktopImageURL(for: screen) {
                savedWallpapers[id] = (url, workspace.desktopImageOptions(for: screen) ?? [:])
            }
            let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                              height: screen.frame.height * screen.backingScaleFactor)
            let file = supportDir.appendingPathComponent(String(format: "fireplace-%016llx-%dx%d.png", seed.raw, Int(size.width), Int(size.height)))
            do {
                guard let renderer = FireRenderer(layoutAspect: Float(size.width / size.height), seed: seed),
                      let image = renderer.renderImage(width: Int(size.width), height: Int(size.height)) else { continue }
                try writePNG(image, to: file)
                try workspace.setDesktopImageURL(file, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            } catch {
                log("Could not set wallpaper on \(screen.localizedName): \(error.localizedDescription)")
            }
        }
        let recovery = Dictionary(uniqueKeysWithValues: savedWallpapers.map { (String($0.key), $0.value.url.absoluteString) })
        if let data = try? JSONEncoder().encode(recovery) { try? data.write(to: recoveryFile) }
    }

    func restoreWallpaper() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let saved = savedWallpapers[id] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(saved.url, for: screen, options: saved.options)
        }
        savedWallpapers = [:]
        try? FileManager.default.removeItem(at: recoveryFile)
    }

    /// If the app died while lit last time, put the user's wallpaper back.
    func restoreWallpaperAfterCrash() {
        guard let data = try? Data(contentsOf: recoveryFile),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let string = saved[String(id)], let url = URL(string: string) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        try? FileManager.default.removeItem(at: recoveryFile)
        log("Restored wallpaper left over from a previous run.")
    }

    // MARK: - Live fire

    private func showWindows(seed: FireSeed) {
        for screen in NSScreen.screens {
            guard let view = FireplaceView(frame: NSRect(origin: .zero, size: screen.frame.size), seed: seed) else {
                log("Metal is unavailable; showing the still wallpaper only.")
                continue
            }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // Desktop level: above the wallpaper, below desktop icons and every app window.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = view
            // Only simulate while the fire can actually be seen.
            occlusionObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak window, weak view] _ in
                guard let window, let view else { return }
                view.isPaused = !window.occlusionState.contains(.visible)
            })
            window.alphaValue = 0
            window.orderFront(nil)
            windows.append(window)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.5
            for window in windows { window.animator().alphaValue = 1 }
        }
    }

    // MARK: - The coil

    private func showCoil() {
        let panel = CoilPanel()
        panel.onPress = { [weak self] in
            self?.stoke()
            self?.sound.stoke()
        }
        panel.onHeat = { [weak self] heat in
            self?.setBoost(heat)
            self?.sound.intensity = heat
        }
        panel.placeInCorner()
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.5
            panel.animator().alphaValue = 1
        }
        coil = panel
        log("Coil button shown at \(NSStringFromRect(panel.frame))")
    }

    // MARK: - Other apps

    private func quitOtherApps() {
        // Finder can't really quit (it owns the desktop), so its windows are hidden instead.
        var keep: Set<String> = ["com.apple.finder"]
        keep.formUnion(UserDefaults.standard.stringArray(forKey: "KeepRunning") ?? [])
        let me = NSRunningApplication.current.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me {
            if app.bundleIdentifier == "com.apple.finder" {
                app.hide()
            } else if !keep.contains(app.bundleIdentifier ?? "") {
                // A polite quit: apps with unsaved work still get to ask about it.
                log("Quitting \(app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)")")
                app.terminate()
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
