// CircleScroll – kreisförmiges Scrollen à la Panasonic Let's Note für macOS.
//
// Modifier-Taste gedrückt halten und mit dem Finger auf dem Trackpad kreisen:
// im Uhrzeigersinn = nach unten scrollen, gegen den Uhrzeigersinn = nach oben.
// Der Mauszeiger bleibt dabei stehen.

import Cocoa
import ServiceManagement

// MARK: - Einstellungen

enum Modifier: String, CaseIterable {
    case option, control, command, shift, fn

    var flag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        case .fn: return "fn / Globus"
        }
    }

    static let allFlags: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand, .maskShift, .maskSecondaryFn]
}

/// Scroll-Distanz in Pixeln pro voller Umdrehung.
let sensitivityLevels: [(title: String, pixelsPerTurn: Double)] = [
    ("Langsam", 300),
    ("Mittel", 600),
    ("Schnell", 1200),
    ("Sehr schnell", 2400),
]

/// Exponent der Beschleunigung: 0 = konstant, höher = schnelles Kreisen scrollt überproportional weiter.
let accelerationLevels: [(title: String, exponent: Double)] = [
    ("Aus", 0),
    ("Leicht", 0.5),
    ("Mittel", 1.0),
    ("Stark", 1.5),
]

final class Settings {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "enabled": true,
            "modifier": Modifier.option.rawValue,
            "pixelsPerTurn": 600.0,
            "inverted": false,
            "acceleration": 1.0,
        ])
    }

    var acceleration: Double {
        get { defaults.double(forKey: "acceleration") }
        set { defaults.set(newValue, forKey: "acceleration") }
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var modifier: Modifier {
        get { Modifier(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .option }
        set { defaults.set(newValue.rawValue, forKey: "modifier") }
    }

    var pixelsPerTurn: Double {
        get { defaults.double(forKey: "pixelsPerTurn") }
        set { defaults.set(newValue, forKey: "pixelsPerTurn") }
    }

    var inverted: Bool {
        get { defaults.bool(forKey: "inverted") }
        set { defaults.set(newValue, forKey: "inverted") }
    }
}

// MARK: - Kreis-Erkennung und Scroll-Erzeugung

final class CircleScroller {
    let settings: Settings
    var onActiveChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var armed = false   // Modifier ist (allein) gedrückt
    private var active = false  // Zeiger eingefroren, Bewegungen werden zu Scrolls
    private var anchor = CGPoint.zero

    private var accX = 0.0, accY = 0.0
    private var prevDir: (x: Double, y: Double)?
    private var lastMove: TimeInterval = 0
    private var lastSegment: TimeInterval = 0
    private var angularSpeed: Double?   // geglättet, in Umdrehungen pro Sekunde
    private var pixelRemainder = 0.0

    /// Mindestlänge eines Bewegungssegments, bevor dessen Richtung ausgewertet wird.
    /// Langsame Bewegungen liefern nur 1–2 px große Deltas; zu kurze Segmente hätten stark gerasterte Richtungen.
    private let minSegment = 5.0
    /// Größere Richtungswechsel pro Segment gelten als Zacke/Umkehr, nicht als Kreisbewegung.
    private let maxTurn = 2.0
    /// Nach dieser Pause beginnt eine neue Geste.
    private let idleReset = 0.25
    /// Bei dieser Kreisgeschwindigkeit (Umdrehungen/s) gilt die eingestellte Grund-Geschwindigkeit 1:1.
    private let referenceSpeed = 1.0
    private let gainRange = 0.25...6.0
    /// Glättung der gemessenen Kreisgeschwindigkeit (0…1, höher = reagiert schneller).
    private let speedSmoothing = 0.3
    /// Gegenbewegung (rad), ab der die Drehrichtung tatsächlich wechselt (~23°). Kleinere Wackler werden verrechnet.
    private let reverseThreshold = 0.4
    private var direction = 0.0   // +1 = Uhrzeigersinn, −1 = gegen, 0 = noch offen
    private var heldBack = 0.0    // zurückgehaltene Gegenbewegung (rad)

    init(settings: Settings) {
        self.settings = settings
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved, .flagsChanged, .keyDown,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<CircleScroller>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func reset() {
        armed = false
        deactivate()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reset()
            return pass

        case .flagsChanged:
            let held = event.flags.intersection(Modifier.allFlags)
            let shouldArm = settings.enabled && held == settings.modifier.flag
            if !shouldArm { reset() } else { armed = true }
            return pass

        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Modifier wird für einen Shortcut oder Klick benutzt → nicht scrollen.
            reset()
            return pass

        case .mouseMoved:
            guard armed else { return pass }
            if !active { activate(at: event.location) }
            track(dx: event.getDoubleValueField(.mouseEventDeltaX),
                  dy: event.getDoubleValueField(.mouseEventDeltaY))
            // Zeiger festhalten; das Bewegungs-Event wird verschluckt.
            CGWarpMouseCursorPosition(anchor)
            CGAssociateMouseAndMouseCursorPosition(1) // hebt die Warp-Sperre von ~250 ms auf
            return nil

        default:
            return pass
        }
    }

    private func activate(at point: CGPoint) {
        active = true
        anchor = point
        startGesture()
        onActiveChange?(true)
    }

    private func deactivate() {
        guard active else { return }
        active = false
        onActiveChange?(false)
    }

    private func startGesture() {
        accX = 0; accY = 0
        prevDir = nil
        angularSpeed = nil
        direction = 0
        heldBack = 0
        pixelRemainder = 0
    }

    /// Hält kurze Gegenbewegungen zurück und verrechnet sie mit der folgenden Vorwärtsdrehung,
    /// damit Rauschen bei langsamen Bewegungen nicht hin- und herscrollt.
    private func debounce(_ turn: Double) -> Double {
        if turn * direction > 0 {
            let used = min(abs(turn), heldBack)
            heldBack -= used
            return turn - used * direction
        }
        heldBack += abs(turn)
        guard heldBack > reverseThreshold else { return 0 }
        direction = turn > 0 ? 1 : -1
        let out = heldBack * direction
        heldBack = 0
        return out
    }

    /// Summiert die Drehung der Bewegungsrichtung. Über eine volle Kreisbahn
    /// ergibt das 2π – unabhängig vom Kreisradius, wie bei einem Jog-Dial.
    private func track(dx: Double, dy: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMove > idleReset { startGesture() }
        lastMove = now

        accX += dx; accY += dy
        let len = hypot(accX, accY)
        guard len >= minSegment else { return }
        let dir = (x: accX / len, y: accY / len)
        accX = 0; accY = 0
        let dt = max(now - lastSegment, 0.004)
        lastSegment = now
        defer { prevDir = dir }
        guard let prev = prevDir else { return }

        // Bildschirmkoordinaten: y zeigt nach unten → positiv = im Uhrzeigersinn.
        let cross = prev.x * dir.y - prev.y * dir.x
        let dot = prev.x * dir.x + prev.y * dir.y
        let turn = atan2(cross, dot)
        guard abs(turn) <= maxTurn else { return }

        // Variable Geschwindigkeit: schnelles Kreisen scrollt weiter pro Umdrehung, langsames feiner.
        let speed = abs(turn) / (2 * .pi) / dt
        let smoothed = angularSpeed.map { $0 + (speed - $0) * speedSmoothing } ?? speed
        angularSpeed = smoothed
        let gain = pow(smoothed / referenceSpeed, settings.acceleration)
            .clamped(to: gainRange)

        // Uhrzeigersinn → nach unten scrollen (negativer Wheel-Wert).
        var pixels = -debounce(turn) / (2 * .pi) * settings.pixelsPerTurn * gain
        if settings.inverted { pixels = -pixels }
        scroll(pixels)
    }

    private func scroll(_ pixels: Double) {
        pixelRemainder += pixels
        let whole = pixelRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        pixelRemainder -= whole
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(whole), wheel2: 0, wheel3: 0)
        else { return }
        // Ohne Flags posten, sonst würde z. B. ⌃+Scroll zoomen oder ⇧+Scroll horizontal scrollen.
        ev.flags = []
        ev.location = anchor
        ev.post(tap: .cgSessionEventTap)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Menüleisten-App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings()
    lazy var scroller = CircleScroller(settings: settings)
    var statusItem: NSStatusItem!
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(active: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        scroller.onActiveChange = { [weak self] active in self?.setIcon(active: active) }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startScroller()
    }

    /// Ohne Bedienungshilfen-Freigabe schlägt der Event-Tap fehl – dann so lange erneut versuchen.
    func startScroller() {
        if scroller.start() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.scroller.start() else { return }
            timer.invalidate()
            self.retryTimer = nil
        }
    }

    func setIcon(active: Bool) {
        let name = active ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "CircleScroll")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !settings.enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !scroller.isRunning {
            let warn = NSMenuItem(title: "⚠︎ Bedienungshilfen-Zugriff erforderlich…",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: "Kreis-Scrollen aktiv", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        let modMenu = NSMenu()
        for mod in Modifier.allCases {
            let item = NSMenuItem(title: mod.title, action: #selector(selectModifier(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mod.rawValue
            item.state = settings.modifier == mod ? .on : .off
            modMenu.addItem(item)
        }
        let modItem = NSMenuItem(title: "Taste: \(settings.modifier.title)", action: nil, keyEquivalent: "")
        modItem.submenu = modMenu
        menu.addItem(modItem)

        let sensMenu = NSMenu()
        for (index, level) in sensitivityLevels.enumerated() {
            let item = NSMenuItem(title: level.title, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = settings.pixelsPerTurn == level.pixelsPerTurn ? .on : .off
            sensMenu.addItem(item)
        }
        let sensItem = NSMenuItem(title: "Geschwindigkeit", action: nil, keyEquivalent: "")
        sensItem.submenu = sensMenu
        menu.addItem(sensItem)

        let accelMenu = NSMenu()
        for (index, level) in accelerationLevels.enumerated() {
            let item = NSMenuItem(title: level.title, action: #selector(selectAcceleration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = settings.acceleration == level.exponent ? .on : .off
            accelMenu.addItem(item)
        }
        let accelItem = NSMenuItem(title: "Beschleunigung", action: nil, keyEquivalent: "")
        accelItem.submenu = accelMenu
        menu.addItem(accelItem)

        let invert = NSMenuItem(title: "Richtung umkehren", action: #selector(toggleInverted), keyEquivalent: "")
        invert.target = self
        invert.state = settings.inverted ? .on : .off
        menu.addItem(invert)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let help = NSMenuItem(title: "\(settings.modifier.title) halten + Kreis ziehen ↻ = runter, ↺ = hoch",
                              action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleEnabled() {
        settings.enabled.toggle()
        scroller.reset()
        setIcon(active: false)
    }

    @objc func selectModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mod = Modifier(rawValue: raw) else { return }
        settings.modifier = mod
        scroller.reset()
    }

    @objc func selectSensitivity(_ sender: NSMenuItem) {
        settings.pixelsPerTurn = sensitivityLevels[sender.tag].pixelsPerTurn
    }

    @objc func selectAcceleration(_ sender: NSMenuItem) {
        settings.acceleration = accelerationLevels[sender.tag].exponent
    }

    @objc func toggleInverted() {
        settings.inverted.toggle()
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
