import SwiftUI
import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import Carbon
import UserNotifications

// MARK: - Entry

@main
struct StayAliveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // No WindowGroup/Settings scenes — avoids ghost restored windows.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }

        // Visible in Dock when double-clicked from Applications
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let controller = AppController()
        self.controller = controller
        controller.start()

        // Double-click must show something immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            controller.showPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Self test

enum SelfTest {
    static func run() -> Int32 {
        print("StayAlive self-test…")
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  PASS \(name) \(detail)" : "  FAIL \(name) \(detail)")
            if !ok { fails += 1 }
        }

        var d: IOPMAssertionID = 0
        let dr = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAlive test display" as CFString,
            &d
        )
        check("display assertion", dr == kIOReturnSuccess, "\(dr)")

        var s: IOPMAssertionID = 0
        let sr = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAlive test system" as CFString,
            &s
        )
        check("system assertion", sr == kIOReturnSuccess, "\(sr)")

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        fx.blendingMode = .behindWindow
        fx.material = .hudWindow
        check("visual effect glass", fx.blendingMode == .behindWindow)

        if d != 0 { IOPMAssertionRelease(d) }
        if s != 0 { IOPMAssertionRelease(s) }

        // Glass stack unit check
        let stack = GlassStack(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        stack.setFillOpacity(0.0)
        check("glass fill 0", abs(Double(stack.fillView.alphaValue) - 0.0) < 0.01, "\(stack.fillView.alphaValue)")
        stack.setFillOpacity(1.0)
        check("glass fill 1", abs(Double(stack.fillView.alphaValue) - 1.0) < 0.01, "\(stack.fillView.alphaValue)")
        stack.setFillOpacity(0.4)
        check("glass fill 0.4", abs(Double(stack.fillView.alphaValue) - 0.4) < 0.01, "\(stack.fillView.alphaValue)")

        if fails == 0 {
            print("StayAlive self-test PASSED")
            return 0
        }
        print("StayAlive self-test FAILED (\(fails))")
        return 1
    }
}

// MARK: - Real glass stack (this is what other apps do)

/// Layer order (bottom → top):
/// 1. NSVisualEffectView (.behindWindow)  ← desktop shows through
/// 2. fillView (black, alpha = solidity)  ← slider controls THIS
/// 3. content (clear hosting)            ← controls only
final class GlassStack: NSView {
    let effectView = NSVisualEffectView()
    let fillView = NSView()
    private var contentHost: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true
        addSubview(effectView)

        fillView.frame = bounds
        fillView.autoresizingMask = [.width, .height]
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.black.cgColor
        fillView.layer?.cornerRadius = 16
        fillView.layer?.masksToBounds = true
        fillView.alphaValue = 0.2
        // Do not steal clicks
        addSubview(fillView)

        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ view: NSView) {
        contentHost?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(view)
        contentHost = view
    }

    /// 0 = full glass (desktop visible), 1 = solid black fill
    func setFillOpacity(_ value: CGFloat) {
        let v = min(1, max(0, value))
        fillView.alphaValue = v
        // Keep effect alive
        effectView.state = .active
        effectView.blendingMode = .behindWindow
    }
}

final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Engine

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var isOn = false
    @Published var mode: Mode = .both
    @Published var duration: Duration = .indefinite
    @Published var endDate: Date?
    @Published var remaining = ""
    /// 0 = glass (see desktop), 1 = solid. Slider in UI is inverted for "Glass amount".
    @Published var solidFill: Double = 0.15 {
        didSet {
            let c = min(1, max(0, solidFill))
            if abs(c - solidFill) > 0.0001 { solidFill = c; return }
            UserDefaults.standard.set(solidFill, forKey: "solidFill")
            NotificationCenter.default.post(name: .glassChanged, object: solidFill)
        }
    }
    @Published var statusText = "Sleep allowed"
    @Published var assertionText = "No assertions"

    enum Mode: String, CaseIterable, Identifiable {
        case both, display, system
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "Both"
            case .display: return "Display"
            case .system: return "System"
            }
        }
    }

    enum Duration: String, CaseIterable, Identifiable {
        case m15, h1, h3, indefinite
        var id: String { rawValue }
        var label: String {
            switch self {
            case .m15: return "15 min"
            case .h1: return "1 hour"
            case .h3: return "3 hours"
            case .indefinite: return "Indefinite"
            }
        }
        func end(from now: Date = Date()) -> Date? {
            switch self {
            case .m15: return now.addingTimeInterval(15 * 60)
            case .h1: return now.addingTimeInterval(3600)
            case .h3: return now.addingTimeInterval(3 * 3600)
            case .indefinite: return nil
            }
        }
    }

    private var displayID: IOPMAssertionID = 0
    private var systemID: IOPMAssertionID = 0
    private var userID: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?
    private var tick: Timer?

    private init() {
        if UserDefaults.standard.object(forKey: "solidFill") != nil {
            solidFill = UserDefaults.standard.double(forKey: "solidFill")
        }
        if UserDefaults.standard.bool(forKey: "restoreOnLaunch"),
           UserDefaults.standard.bool(forKey: "isOn") {
            setOn(true, user: false)
        }
    }

    func toggle() { setOn(!isOn, user: true) }

    func setOn(_ on: Bool, user: Bool) {
        if on {
            if user { endDate = duration.end() }
            guard acquire() else {
                isOn = false
                UserDefaults.standard.set(false, forKey: "isOn")
                statusText = "Failed to stay awake"
                return
            }
            isOn = true
            UserDefaults.standard.set(true, forKey: "isOn")
            statusText = "Keeping Mac awake"
            startTick()
        } else {
            release()
            isOn = false
            endDate = nil
            remaining = ""
            UserDefaults.standard.set(false, forKey: "isOn")
            statusText = "Sleep allowed"
            tick?.invalidate()
            tick = nil
        }
        updateRemaining()
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    func setMode(_ m: Mode) {
        mode = m
        if isOn {
            release()
            _ = acquire()
        }
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    func setDuration(_ d: Duration) {
        duration = d
        if isOn {
            endDate = d.end()
            startTick()
            updateRemaining()
        }
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    private func acquire() -> Bool {
        release()
        let reason = "Stay Alive" as CFString
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        var ok = false
        var parts: [String] = []

        if mode == .both || mode == .display {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString, level, reason, &id
            )
            if r == kIOReturnSuccess {
                displayID = id
                ok = true
                parts.append("display")
            }
        }
        if mode == .both || mode == .system {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, level, reason, &id
            )
            if r == kIOReturnSuccess {
                systemID = id
                ok = true
                parts.append("system")
            }
        }

        // User activity pulse (helps idle lock)
        var uid: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Stay Alive" as CFString, IOPMUserActiveType(0), &uid) == kIOReturnSuccess {
            userID = uid
            parts.append("active")
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Stay Alive"
        )

        assertionText = parts.isEmpty ? "No assertions" : "Active: " + parts.joined(separator: " + ")
        return ok
    }

    private func release() {
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
        if userID != 0 { IOPMAssertionRelease(userID); userID = 0 }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        assertionText = "No assertions"
    }

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRemaining() }
        }
    }

    private func updateRemaining() {
        guard isOn else { remaining = ""; return }
        guard let endDate else { remaining = "∞"; return }
        let s = max(0, Int(endDate.timeIntervalSinceNow))
        if Date() >= endDate {
            setOn(false, user: false)
            return
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { remaining = String(format: "%dh %02dm", h, m) }
        else if m > 0 { remaining = String(format: "%dm %02ds", m, sec) }
        else { remaining = "\(sec)s" }

        // Keep idle timers pushed back while on
        var uid: IOPMAssertionID = 0
        if userID != 0 { IOPMAssertionRelease(userID); userID = 0 }
        if IOPMAssertionDeclareUserActivity("Stay Alive" as CFString, IOPMUserActiveType(0), &uid) == kIOReturnSuccess {
            userID = uid
        }
    }

    func shutdown() {
        tick?.invalidate()
        release()
    }
}

extension Notification.Name {
    static let stateChanged = Notification.Name("stayAlive.state")
    static let glassChanged = Notification.Name("stayAlive.glass")
}

// MARK: - App controller (status item + glass panel)

@MainActor
final class AppController: NSObject, NSWindowDelegate {
    private let engine = Engine.shared
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var panel: NSPanel?
    private var stack: GlassStack?
    private var host: ClearHostingView<AnyView>?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.pulseIcon(active: false)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Stay Alive"
        }
        rebuildMenu()
        registerHotkey()

        NotificationCenter.default.addObserver(forName: .stateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .glassChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyGlass() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        installMenu()
    }

    func shutdown() {
        engine.shutdown()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    @objc private func clicked(_ sender: Any?) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if panel?.isVisible == true {
                panel?.orderOut(nil)
            } else {
                showPanel()
            }
        }
    }

    func showPanel() {
        if panel == nil { buildPanel() }
        applyGlass()
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPanel() {
        let size = NSSize(width: 360, height: 480)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let stack = GlassStack(frame: NSRect(origin: .zero, size: size))
        let root = AnyView(
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        )
        let host = ClearHostingView(rootView: root)
        host.frame = stack.bounds
        host.autoresizingMask = [.width, .height]
        stack.setContent(host)

        panel.contentView = stack
        self.panel = panel
        self.stack = stack
        self.host = host
        applyGlass()
    }

    private func applyGlass() {
        // THIS is the slider effect — fillView.alphaValue
        stack?.setFillOpacity(CGFloat(engine.solidFill))
        panel?.isOpaque = false
        panel?.backgroundColor = .clear
        panel?.alphaValue = 1.0 // never grey the whole window
    }

    private func positionPanel() {
        guard let panel, let button = statusItem.button, let win = button.window else {
            panel?.center()
            return
        }
        let br = button.convert(button.bounds, to: nil)
        let scr = win.convertToScreen(br)
        var origin = NSPoint(
            x: scr.midX - panel.frame.width / 2,
            y: scr.minY - panel.frame.height - 10
        )
        if let screen = win.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - panel.frame.width - 8)
            if origin.y < v.minY + 8 {
                origin.y = scr.maxY + 10
            }
        }
        panel.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) {
        // keep panel until user toggles; don't auto-dismiss (more reliable)
    }

    private func refresh() {
        let on = engine.isOn
        statusItem.button?.image = Self.pulseIcon(active: on)
        if on {
            statusItem.button?.title = engine.remaining.isEmpty || engine.remaining == "∞" ? " ON" : " \(engine.remaining)"
        } else {
            statusItem.button?.title = ""
        }
        rebuildMenu()
        // Refresh SwiftUI
        if let host {
            host.rootView = AnyView(
                RootView().environmentObject(engine).preferredColorScheme(.dark)
            )
        }
        applyGlass()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let t = NSMenuItem(title: engine.isOn ? "Turn Off" : "Turn On", action: #selector(toggle), keyEquivalent: "s")
        t.keyEquivalentModifierMask = [.control, .option, .command]
        t.target = self
        menu.addItem(t)
        menu.addItem(NSMenuItem.separator())
        let open = NSMenuItem(title: "Open Panel", action: #selector(openPanel), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem.separator())
        let q = NSMenuItem(title: "Quit Stay Alive", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc private func toggle() { engine.toggle() }
    @objc private func openPanel() { showPanel() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        appItem.submenu = app
        app.addItem(withTitle: "Quit Stay Alive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
    }

    private func registerHotkey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.engine.toggle() }
            return noErr
        }
        let data = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &type, data, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x53414C56), id: 1)
        // ⌃⌥⌘S
        RegisterEventHotKey(UInt32(1), UInt32(controlKey | optionKey | cmdKey), id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    /// Red pulse icon
    private static func pulseIcon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let color = active ? NSColor.systemRed : NSColor.secondaryLabelColor
            color.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 1, y: 9))
            p.line(to: NSPoint(x: 4, y: 9))
            p.line(to: NSPoint(x: 6.5, y: 14))
            p.line(to: NSPoint(x: 9.5, y: 4))
            p.line(to: NSPoint(x: 12, y: 11))
            p.line(to: NSPoint(x: 14, y: 9))
            p.line(to: NSPoint(x: 17, y: 9))
            p.lineWidth = 1.7
            p.lineJoinStyle = .round
            p.lineCapStyle = .round
            p.stroke()
            return true
        }
        img.isTemplate = !active
        return img
    }
}

// MARK: - SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        VStack(spacing: 18) {
            // RED heart
            ZStack {
                Circle()
                    .strokeBorder(engine.isOn ? Color.red.opacity(0.95) : Color.white.opacity(0.25), lineWidth: 2)
                    .frame(width: 88, height: 88)
                Image(systemName: engine.isOn ? "heart.fill" : "heart")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(engine.isOn ? Color.red : Color.secondary)
            }
            .padding(.top, 8)

            Text("Stay Alive")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(engine.statusText + (engine.remaining.isEmpty ? "" : " · \(engine.remaining)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(engine.isOn ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)

            Toggle(isOn: Binding(
                get: { engine.isOn },
                set: { engine.setOn($0, user: true) }
            )) {
                Text(engine.isOn ? "On" : "Off")
                    .font(.headline)
                    .frame(width: 32, alignment: .leading)
            }
            .toggleStyle(.switch)
            .tint(.red)
            .controlSize(.large)

            Picker("Mode", selection: Binding(
                get: { engine.mode },
                set: { engine.setMode($0) }
            )) {
                ForEach(Engine.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Duration", selection: Binding(
                get: { engine.duration },
                set: { engine.setDuration($0) }
            )) {
                ForEach(Engine.Duration.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            // GLASS SLIDER — right = more desktop
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Desktop glass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(glassLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { 1.0 - engine.solidFill },
                        set: { engine.solidFill = 1.0 - $0 }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .tint(.red)
                Text("Drag right to see your desktop through this panel.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Text(engine.assertionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("⌃⌥⌘S toggle · menu bar pulse icon")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(22)
        // CRITICAL: no opaque background — glass stack shows desktop
        .background(Color.clear)
        .frame(width: 360, height: 480)
    }

    private var glassLabel: String {
        let g = Int(((1.0 - engine.solidFill) * 100).rounded())
        if g >= 95 { return "Clear" }
        if g <= 5 { return "Solid" }
        return "\(g)% clear"
    }
}
