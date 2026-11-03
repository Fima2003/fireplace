import AppKit

/// An electric charcoal-starter coil you press into the fire: a small floating
/// panel in the corner of the screen that never takes focus or activates the app.
/// Holding it heats the coil (and drives the fire); letting go lets it cool.
final class CoilPanel: NSPanel {
    static let size: CGFloat = 120

    let coil: CoilView

    /// Called once per press, as the coil touches the fire.
    var onPress: (() -> Void)? {
        get { coil.onPress }
        set { coil.onPress = newValue }
    }
    /// Called whenever the coil's heat (0 to 1) changes.
    var onHeat: ((Float) -> Void)? {
        get { coil.onHeat }
        set { coil.onHeat = newValue }
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        coil = CoilView(frame: frame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = coil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom-right corner of the main screen, `inset` points inside its visible frame.
    func placeInCorner(inset: CGFloat = 24) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - Self.size - inset, y: visible.minY + inset))
    }

    /// Holds the coil in the fire for `seconds`, as the menu item does.
    func press(for seconds: Double) { coil.press(for: seconds) }

    /// Lets go of the coil and stops its animation; call before closing the panel.
    func tearDown() { coil.tearDown() }
}

/// The button itself: a cast-iron disc with a heating element drawn in Core Graphics,
/// whose colour follows its heat from dark iron through dull red to yellow-white.
final class CoilView: NSView {
    var onPress: (() -> Void)?
    var onHeat: ((Float) -> Void)?

    /// 0 (cold) to 1 (glowing): ramps toward 1 while pressed and cools back after.
    private(set) var heat: Float = 0
    private(set) var isPressed = false
    private var mouseIsDown = false
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var scheduledRelease: DispatchWorkItem?

    var isAnimating: Bool { timer != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Hold to stoke the fire"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Stoke the fire")
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    // MARK: - Pressing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isInsideButton(convert(event.locationInWindow, from: nil)) else { return }
        mouseIsDown = true
        scheduledRelease?.cancel()
        beginPress()
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseIsDown, !isInsideButton(convert(event.locationInWindow, from: nil)) { mouseUp(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        endPress()
    }

    override func mouseExited(with event: NSEvent) {
        if mouseIsDown { mouseUp(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        press(for: 1.5)
        return true
    }

    /// A programmatic press, released after `seconds` unless the mouse is holding it by then.
    func press(for seconds: Double) {
        scheduledRelease?.cancel()
        beginPress()
        let release = DispatchWorkItem { [weak self] in
            guard let self, !mouseIsDown else { return }
            endPress()
        }
        scheduledRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: release)
    }

    func tearDown() {
        scheduledRelease?.cancel()
        isPressed = false
        mouseIsDown = false
        stopAnimating()
    }

    private func beginPress() {
        guard !isPressed else { return }
        isPressed = true
        onPress?()
        startAnimating()
    }

    private func endPress() {
        guard isPressed else { return }
        isPressed = false
        startAnimating()
    }

    // MARK: - Heat

    /// Runs at 60 Hz only while the heat is changing: the app is meant to stay idle otherwise.
    private func startAnimating() {
        needsDisplay = true
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTick)
        lastTick = now
        // Heats up fast (τ ≈ 0.35 s) and cools slowly (τ ≈ 2 s), like a real element.
        let target: Float = isPressed ? 1 : 0
        let tau: Float = isPressed ? 0.35 : 2
        heat += (target - heat) * (1 - exp(-dt / tau))
        if abs(target - heat) < 0.01 {
            heat = target
            stopAnimating()
        }
        onHeat?(heat)
        needsDisplay = true
    }

    // MARK: - Drawing

    private var diameter: CGFloat { min(bounds.width, bounds.height) * 0.86 }

    private func isInsideButton(_ point: NSPoint) -> Bool {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        return hypot(point.x - center.x, point.y - center.y) <= diameter / 2
    }

    /// Black-body-style ramp: iron grey → dull red → orange → yellow-white.
    static func coilColor(heat: Float) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let stops: [(Float, (CGFloat, CGFloat, CGFloat))] = [
            (0.00, (0.24, 0.24, 0.26)),
            (0.30, (0.48, 0.07, 0.03)),
            (0.55, (0.92, 0.23, 0.04)),
            (0.80, (1.00, 0.62, 0.16)),
            (1.00, (1.00, 0.94, 0.74)),
        ]
        let h = min(max(heat, 0), 1)
        for i in 1..<stops.count where h <= stops[i].0 {
            let (h0, c0) = stops[i - 1], (h1, c1) = stops[i]
            let f = CGFloat((h - h0) / (h1 - h0))
            return (c0.0 + (c1.0 - c0.0) * f, c0.1 + (c1.1 - c0.1) * f, c0.2 + (c1.2 - c0.2) * f)
        }
        return stops.last!.1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let d = diameter
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = d / 2
        let heat = CGFloat(self.heat)

        ctx.saveGState()
        if isPressed {
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 0.96, y: 0.96)
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        func disc(_ r: CGFloat) -> CGRect { CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r) }
        func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: v, alpha: a) }
        let space = CGColorSpaceCreateDeviceRGB()

        // Cast-iron body with a soft shadow on the desktop.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: gray(0, 0.55))
        ctx.setFillColor(gray(0.17))
        ctx.fillEllipse(in: disc(radius))
        ctx.restoreGState()

        // Bevelled rim: lit from above, so the top edge catches light and the bottom falls into shadow.
        ctx.saveGState()
        ctx.addEllipse(in: disc(radius))
        ctx.clip()
        let rim = CGGradient(colorsSpace: space, colors: [gray(0.46), gray(0.26), gray(0.09)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: center.x, y: center.y + radius), end: CGPoint(x: center.x, y: center.y - radius), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        let faceRadius = radius - d * 0.045
        ctx.addEllipse(in: disc(faceRadius))
        ctx.clip()
        let face = CGGradient(colorsSpace: space, colors: [gray(0.30), gray(0.20), gray(0.16)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawRadialGradient(face, startCenter: CGPoint(x: center.x - d * 0.12, y: center.y + d * 0.14), startRadius: 0,
                               endCenter: center, endRadius: faceRadius, options: [])
        ctx.restoreGState()

        // The well the element sits in, slightly sunk.
        let wellRadius = faceRadius - d * 0.035
        ctx.saveGState()
        ctx.addEllipse(in: disc(wellRadius))
        ctx.clip()
        let well = CGGradient(colorsSpace: space, colors: [gray(0.12), gray(0.085)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(well, startCenter: center, startRadius: wellRadius * 0.3, endCenter: center, endRadius: wellRadius, options: [])
        // Inner shadow along the top of the well.
        ctx.setStrokeColor(gray(0, 0.5))
        ctx.setLineWidth(d * 0.03)
        ctx.strokeEllipse(in: disc(wellRadius + d * 0.012).offsetBy(dx: 0, dy: -d * 0.012))
        ctx.restoreGState()
        // A hot element lights the iron around it.
        if heat > 0.05 {
            ctx.saveGState()
            ctx.addEllipse(in: disc(wellRadius))
            ctx.clip()
            let c = Self.coilColor(heat: self.heat)
            let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: c.r, green: c.g, blue: c.b, alpha: 0.35 * heat),
                                                              CGColor(red: c.r, green: c.g, blue: c.b, alpha: 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: wellRadius, options: [])
            ctx.restoreGState()
        }

        // The element: an Archimedean spiral of 3.5 turns that ends on the left, then a
        // quarter arc round to the bottom, and two straight legs down to the terminals.
        let lineWidth = d * 0.07
        let r0 = d * 0.035, r1 = d * 0.355
        let gap = d * 0.07                               // between the two legs
        let turns: CGFloat = 3.5
        let thetaMax = turns * 2 * .pi
        let spiral = CGMutablePath()
        let steps = 240
        for i in 0...steps {
            let theta = thetaMax * CGFloat(i) / CGFloat(steps)
            let r = r0 + (r1 - r0) * theta / thetaMax
            let p = CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
            i == 0 ? spiral.move(to: p) : spiral.addLine(to: p)
        }
        // Continue at full radius from the left round to just left of bottom centre.
        let legX = center.x - gap / 2
        let endAngle = CGFloat.pi + acos((center.x - legX) / r1)
        spiral.addArc(center: center, radius: r1, startAngle: .pi, endAngle: endAngle, clockwise: false)
        let terminalY = center.y - wellRadius + lineWidth * 0.9
        spiral.addLine(to: CGPoint(x: legX, y: terminalY))
        // The inner end dives under the turns and comes out beside the other leg.
        let innerLeg = CGMutablePath()
        innerLeg.move(to: CGPoint(x: center.x + r0, y: center.y))
        innerLeg.addLine(to: CGPoint(x: center.x + r0, y: terminalY))

        let c = Self.coilColor(heat: self.heat)
        let color = CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Terminal block the legs run into.
        ctx.setFillColor(gray(0.07))
        let block = CGRect(x: center.x - d * 0.13, y: terminalY - lineWidth * 1.2, width: d * 0.26, height: lineWidth * 1.3)
        ctx.addPath(CGPath(roundedRect: block, cornerWidth: lineWidth * 0.3, cornerHeight: lineWidth * 0.3, transform: nil))
        ctx.fillPath()

        // Leg passing underneath: darker, so it reads as below the turns.
        ctx.setLineWidth(lineWidth * 0.85)
        ctx.setStrokeColor(CGColor(red: c.r * 0.55, green: c.g * 0.55, blue: c.b * 0.55, alpha: 1))
        ctx.addPath(innerLeg)
        ctx.strokePath()

        // Glow grows with heat, then the crisp element on top.
        if heat > 0.02 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3 + 20 * heat, color: CGColor(red: c.r, green: c.g, blue: c.b, alpha: 0.9 * heat))
            ctx.setLineWidth(lineWidth)
            ctx.setStrokeColor(color)
            ctx.addPath(spiral)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(color)
        ctx.addPath(spiral)
        ctx.strokePath()
        // Shading on a cold element; an incandescent core on a hot one.
        if heat < 0.5 {
            var shift = CGAffineTransform(translationX: 0, y: -lineWidth * 0.25)
            ctx.setLineWidth(lineWidth * 0.3)
            ctx.setStrokeColor(gray(0, 0.35 * (1 - 2 * heat)))
            ctx.addPath(spiral.copy(using: &shift)!)
            ctx.strokePath()
        } else {
            ctx.setLineWidth(lineWidth * 0.35)
            ctx.setStrokeColor(CGColor(red: min(1, c.r + 0.1), green: min(1, c.g + 0.15), blue: min(1, c.b + 0.25), alpha: 2 * heat - 1))
            ctx.addPath(spiral)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
