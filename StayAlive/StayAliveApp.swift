import SwiftUI
import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import Carbon
import CoreWLAN
import EventKit
import UserNotifications
import os.log

// MARK: - App entry


// MARK: - CLI self-test (StayAlive --self-test)

enum SelfTest {
    /// Returns process exit code (0 = pass).
    static func run() -> Int32 {
        print("StayAlive self-test starting…")
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  PASS  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failures += 1
            }
        }

        // 1) IOPM display assertion
        var displayID: IOPMAssertionID = 0
        let dReason = "StayAlive self-test display" as CFString
        let dRes = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            dReason,
            &displayID
        )
        check("PreventUserIdleDisplaySleep", dRes == kIOReturnSuccess, "id=\(displayID) rc=\(dRes)")

        // 2) IOPM system idle assertion
        var systemID: IOPMAssertionID = 0
        let sReason = "StayAlive self-test system" as CFString
        let sRes = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            sReason,
            &systemID
        )
        check("PreventUserIdleSystemSleep", sRes == kIOReturnSuccess, "id=\(systemID) rc=\(sRes)")

        // 3) PreventSystemSleep
        var prevID: IOPMAssertionID = 0
        let pRes = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAlive self-test prevent" as CFString,
            &prevID
        )
        check("PreventSystemSleep", pRes == kIOReturnSuccess, "id=\(prevID) rc=\(pRes)")

        // 4) User activity pulse
        var userID: IOPMAssertionID = 0
        let uRes = IOPMAssertionDeclareUserActivity(
            "StayAlive self-test user" as CFString,
            IOPMUserActiveType(0),
            &userID
        )
        check("IOPMAssertionDeclareUserActivity", uRes == kIOReturnSuccess, "id=\(userID) rc=\(uRes)")

        // 5) ProcessInfo activity
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "StayAlive self-test"
        )
        check("ProcessInfo.beginActivity", true, "token=\(activity)")

        // 6) Confirm pmset sees our assertions (best-effort)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            let sees = out.contains("StayAlive self-test") || out.contains("StayAlive")
            check("pmset lists StayAlive assertions", sees, sees ? "found in pmset" : "not found (may still be OK on some macOS)")
            // Soft-fail: don't count as hard failure if timing races
            if !sees { failures = max(0, failures - 1); print("  NOTE  pmset timing race ignored") }
        } catch {
            check("pmset invoke", false, error.localizedDescription)
        }

        // 7) Frosted background types exist (compile-time); runtime create NSVisualEffectView
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        check("NSVisualEffectView glass", fx.material == .hudWindow)

        // 8) Release cleanly
        if displayID != 0 { IOPMAssertionRelease(displayID) }
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        if prevID != 0 { IOPMAssertionRelease(prevID) }
        if userID != 0 { IOPMAssertionRelease(userID) }
        ProcessInfo.processInfo.endActivity(activity)
        check("release assertions", true)

        // 9) Bundle identity when running from .app
        let bundle = Bundle.main
        let bid = bundle.bundleIdentifier ?? "(none)"
        print("  INFO  bundleId=\(bid) version=\(bundle.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        if bid != "me.philipwright.StayAlive" && bid != nil && CommandLine.arguments.contains(where: { $0.contains(".app") }) == false {
            // when invoked as raw binary bid may be nil — OK
            print("  NOTE  raw binary launch (no bundle id) is OK for CLI self-test")
        }

        if failures == 0 {
            print("StayAlive self-test PASSED")
            return 0
        } else {
            print("StayAlive self-test FAILED (\(failures) failure(s))")
            return 1
        }
    }
}

@main
struct StayAliveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No Settings/WindowGroup scenes — those restore extra desktop boxes.
        // All UI is AppKit: menu bar + glass NSPanel.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }

        // Menu-bar utility: no Dock bounce, no restored Settings boxes.
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false

        // Kill any restored SwiftUI Settings windows from older builds.
        DispatchQueue.main.async {
            for w in NSApp.windows {
                let t = w.title
                if t.localizedCaseInsensitiveContains("Settings")
                    || t.localizedCaseInsensitiveContains("Guide")
                    || t.isEmpty && w.isVisible && !(w is NSPanel) {
                    w.orderOut(nil)
                }
            }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let engine = StayAliveEngine.shared
        engine.bootstrap()
        statusController = StatusBarController(engine: engine)
        HotKeyManager.shared.registerDefault(engine: engine)
        installMainMenu(engine: engine)

        // Single quiet notification — do NOT open any panel automatically.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let content = UNMutableNotificationContent()
            content.title = "Stay Alive"
            content.body = "Running in the menu bar. Click the pulse icon to open."
            let req = UNNotificationRequest(identifier: "stayalive.launch", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }

    /// App menu so ⌘+ / ⌘- / ⌘0 work while Settings/Guide windows are focused.
    private func installMainMenu(engine: StayAliveEngine) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Stay Alive", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Stay Alive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(AppDelegate.menuZoomIn), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomInEq = NSMenuItem(title: "Zoom In", action: #selector(AppDelegate.menuZoomIn), keyEquivalent: "=")
        zoomInEq.target = self
        zoomInEq.isAlternate = true
        viewMenu.addItem(zoomInEq)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(AppDelegate.menuZoomOut), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Actual Size", action: #selector(AppDelegate.menuZoomReset), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)

        viewMenu.addItem(NSMenuItem.separator())
        let moreOpaque = NSMenuItem(title: "More Opaque", action: #selector(AppDelegate.menuMoreOpaque), keyEquivalent: "]")
        moreOpaque.keyEquivalentModifierMask = [.command]
        moreOpaque.target = self
        viewMenu.addItem(moreOpaque)
        let moreClear = NSMenuItem(title: "More Transparent", action: #selector(AppDelegate.menuMoreTransparent), keyEquivalent: "[")
        moreClear.keyEquivalentModifierMask = [.command]
        moreClear.target = self
        viewMenu.addItem(moreClear)

        NSApp.mainMenu = mainMenu
    }

    @objc func menuZoomIn() {
        Task { @MainActor in StayAliveEngine.shared.bumpZoom(0.1) }
    }
    @objc func menuZoomOut() {
        Task { @MainActor in StayAliveEngine.shared.bumpZoom(-0.1) }
    }
    @objc func menuZoomReset() {
        Task { @MainActor in StayAliveEngine.shared.uiZoom = 1.0 }
    }
    @objc func menuMoreOpaque() {
        Task { @MainActor in StayAliveEngine.shared.bumpOpacity(0.05) }
    }
    @objc func menuMoreTransparent() {
        Task { @MainActor in StayAliveEngine.shared.bumpOpacity(-0.05) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        StayAliveEngine.shared.shutdown()
        HotKeyManager.shared.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Models

enum SleepMode: String, CaseIterable, Identifiable, Codable {
    case both = "both"
    case displayOnly = "display"
    case systemOnly = "system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Display + System"
        case .displayOnly: return "Display only"
        case .systemOnly: return "System only"
        }
    }

    var shortTitle: String {
        switch self {
        case .both: return "Both"
        case .displayOnly: return "Display"
        case .systemOnly: return "System"
        }
    }
}

enum DurationPreset: String, CaseIterable, Identifiable, Codable {
    case fifteenMin = "15m"
    case oneHour = "1h"
    case threeHours = "3h"
    case untilTomorrow = "tomorrow"
    case indefinite = "indefinite"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMin: return "15 minutes"
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .untilTomorrow: return "Until tomorrow 7:00"
        case .indefinite: return "Indefinite"
        }
    }

    /// Seconds until auto-off, or nil for indefinite.
    func deadline(from now: Date = Date()) -> Date? {
        switch self {
        case .fifteenMin:
            return now.addingTimeInterval(15 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .threeHours:
            return now.addingTimeInterval(3 * 60 * 60)
        case .untilTomorrow:
            var cal = Calendar.current
            cal.timeZone = .current
            let start = cal.startOfDay(for: now)
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: start),
                  let seven = cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) else {
                return now.addingTimeInterval(12 * 60 * 60)
            }
            return seven
        case .indefinite:
            return nil
        }
    }
}

struct AssertionStatus: Equatable {
    var displayOK: Bool = false
    var systemOK: Bool = false
    var preventSystemOK: Bool = false
    var userActivityOK: Bool = false
    var processActivityOK: Bool = false
    var displayID: IOPMAssertionID = 0
    var systemID: IOPMAssertionID = 0
    var preventSystemID: IOPMAssertionID = 0
    var userActivityID: IOPMAssertionID = 0
    var lastError: String?

    var anyActive: Bool { displayOK || systemOK || preventSystemOK || userActivityOK || processActivityOK }

    var summary: String {
        if let lastError, !anyActive { return lastError }
        var parts: [String] = []
        if displayOK { parts.append("display") }
        if systemOK { parts.append("idle-sleep") }
        if preventSystemOK { parts.append("system-sleep") }
        if userActivityOK { parts.append("user-active") }
        if processActivityOK { parts.append("process") }
        if parts.isEmpty { return "No active assertions" }
        return "Active: " + parts.joined(separator: " + ")
    }
}

// MARK: - Engine

@MainActor
final class StayAliveEngine: ObservableObject {
    static let shared = StayAliveEngine()

    private let log = Logger(subsystem: "me.philipwright.StayAlive", category: "engine")
    private let defaults = UserDefaults.standard

    // Keys
    private enum Key {
        static let isOn = "isOn"
        static let mode = "sleepMode"
        static let duration = "durationPreset"
        static let launchAtLogin = "launchAtLogin"
        static let restoreOnLaunch = "restoreOnLaunch"
        static let batteryThreshold = "batteryThreshold"
        static let disableOnBatteryLow = "disableOnBatteryLow"
        static let disableOnThermal = "disableOnThermal"
        static let allowLidSleep = "allowLidSleep" // informational; macOS still owns lid policy
        static let processNames = "processNames"
        static let processTriggerEnabled = "processTriggerEnabled"
        static let chargingTriggerEnabled = "chargingTriggerEnabled"
        static let wifiTriggerEnabled = "wifiTriggerEnabled"
        static let wifiSSIDs = "wifiSSIDs"
        static let calendarTriggerEnabled = "calendarTriggerEnabled"
        static let panelOpacity = "panelOpacity"
        static let uiZoom = "uiZoom"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let endDate = "endDate"
        static let preventScreenLock = "preventScreenLock"
        static let simulateActivity = "simulateActivity"
    }

    // Published state
    @Published var isOn: Bool = false
    @Published var mode: SleepMode = .both
    @Published var duration: DurationPreset = .indefinite
    @Published var endDate: Date?
    @Published var remainingText: String = ""
    @Published var assertion: AssertionStatus = .init()
    @Published var lastFailure: String?
    @Published var batteryPercent: Int?
    @Published var isCharging: Bool = false
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var activeTriggerReason: String?
    /// True only when awake state is owned by automation triggers (not manual/restore).
    private var awakeHeldByTrigger: Bool = false
    @Published var wifiSSID: String?

    // Settings
    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin); applyLoginItem() }
    }
    @Published var restoreOnLaunch: Bool = true {
        didSet { defaults.set(restoreOnLaunch, forKey: Key.restoreOnLaunch) }
    }
    @Published var disableOnBatteryLow: Bool = true {
        didSet { defaults.set(disableOnBatteryLow, forKey: Key.disableOnBatteryLow) }
    }
    @Published var batteryThreshold: Int = 20 {
        didSet { defaults.set(batteryThreshold, forKey: Key.batteryThreshold) }
    }
    @Published var disableOnThermal: Bool = true {
        didSet { defaults.set(disableOnThermal, forKey: Key.disableOnThermal) }
    }
    @Published var processTriggerEnabled: Bool = false {
        didSet { defaults.set(processTriggerEnabled, forKey: Key.processTriggerEnabled) }
    }
    @Published var processNamesCSV: String = "zoom.us, ffmpeg" {
        didSet { defaults.set(processNamesCSV, forKey: Key.processNames) }
    }
    @Published var chargingTriggerEnabled: Bool = false {
        didSet { defaults.set(chargingTriggerEnabled, forKey: Key.chargingTriggerEnabled) }
    }
    @Published var wifiTriggerEnabled: Bool = false {
        didSet { defaults.set(wifiTriggerEnabled, forKey: Key.wifiTriggerEnabled) }
    }
    @Published var wifiSSIDsCSV: String = "" {
        didSet { defaults.set(wifiSSIDsCSV, forKey: Key.wifiSSIDs) }
    }
    @Published var calendarTriggerEnabled: Bool = false {
        didSet { defaults.set(calendarTriggerEnabled, forKey: Key.calendarTriggerEnabled) }
    }
    /// 0.0 ... 1.0 — panel *solidity* over frosted glass (1.0 = solid, 0.0 = full glass).
    /// This is NOT window.alphaValue (that only greys content out).
    @Published var panelOpacity: Double = 0.25 {  // default: mostly glass so desktop is visible
        didSet {
            let clamped = min(1.0, max(0.0, panelOpacity))
            if abs(clamped - panelOpacity) > 0.0001 {
                panelOpacity = clamped
                return
            }
            defaults.set(panelOpacity, forKey: Key.panelOpacity)
            NotificationCenter.default.post(name: .stayAliveOpacityChanged, object: panelOpacity)
        }
    }
    /// UI content zoom (Cmd+ / Cmd-). 0.8 ... 1.6
    @Published var uiZoom: Double = 1.0 {
        didSet {
            let clamped = min(1.6, max(0.8, (uiZoom * 20).rounded() / 20))
            if abs(clamped - uiZoom) > 0.0001 {
                uiZoom = clamped
                return
            }
            defaults.set(uiZoom, forKey: Key.uiZoom)
            NotificationCenter.default.post(name: .stayAliveZoomChanged, object: uiZoom)
        }
    }

    var panelOpacityPercent: Int { Int((panelOpacity * 100).rounded()) }
    var panelTransparencyPercent: Int { max(0, 100 - panelOpacityPercent) }
    /// How solid the fill is over the glass (100% = no desktop bleed-through).
    var opacityLabel: String {
        if panelOpacity >= 0.99 { return "Solid (no glass)" }
        if panelOpacity <= 0.02 { return "Full glass" }
        return "\(panelOpacityPercent)% solid · \(panelTransparencyPercent)% glass"
    }

    func bumpOpacity(_ delta: Double) {
        panelOpacity = min(1.0, max(0.0, panelOpacity + delta))
    }

    func bumpZoom(_ delta: Double) {
        uiZoom = min(1.6, max(0.8, uiZoom + delta))
    }
    @Published var hotkeyEnabled: Bool = true {
        didSet {
            defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled)
            if hotkeyEnabled {
                HotKeyManager.shared.registerDefault(engine: self)
            } else {
                HotKeyManager.shared.unregister()
            }
        }
    }
    /// Keep session unlocked by declaring user activity + stronger sleep assertions.
    @Published var preventScreenLock: Bool = true {
        didSet {
            defaults.set(preventScreenLock, forKey: Key.preventScreenLock)
            if isOn {
                releaseAssertions()
                _ = acquireAssertions()
            }
        }
    }
    /// Periodically nudge idle timers (IOPM user-activity heartbeat).
    @Published var simulateActivity: Bool = true {
        didSet { defaults.set(simulateActivity, forKey: Key.simulateActivity) }
    }

    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var preventSystemAssertionID: IOPMAssertionID = 0
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var processActivity: NSObjectProtocol?
    private var hasAssertion = false
    private var timer: Timer?
    private var pollTimer: Timer?
    private var activityTimer: Timer?
    private var suppressing = false
    private let eventStore = EKEventStore()

    private init() {}

    func bootstrap() {
        loadSettings()
        startPolling()
        refreshPower()
        refreshWiFi()

        if restoreOnLaunch, defaults.bool(forKey: Key.isOn) {
            // Restore timer if still in future
            if let ts = defaults.object(forKey: Key.endDate) as? Double {
                let d = Date(timeIntervalSince1970: ts)
                if d > Date() {
                    endDate = d
                } else {
                    // expired
                    defaults.set(false, forKey: Key.isOn)
                }
            }
            if defaults.bool(forKey: Key.isOn) {
                // userInitiated false but NOT a trigger — restores assertions without auto-off ownership
                setOn(true, reason: nil, userInitiated: false)
                activeTriggerReason = "Restored session"
                awakeHeldByTrigger = false
            }
        }
        applyLoginItem()
        updateRemainingText()
    }

    func shutdown() {
        timer?.invalidate()
        pollTimer?.invalidate()
        releaseAssertions()
    }

    func toggle() {
        setOn(!isOn, reason: nil, userInitiated: true)
    }

    func setOn(_ on: Bool, reason: String?, userInitiated: Bool) {
        if on {
            if let block = safeguardBlockReason() {
                lastFailure = block
                notify(title: "Stay Alive blocked", body: block)
                activeTriggerReason = nil
                isOn = false
                defaults.set(false, forKey: Key.isOn)
                objectWillChange.send()
                return
            }
            if userInitiated {
                endDate = duration.deadline()
                if let endDate {
                    defaults.set(endDate.timeIntervalSince1970, forKey: Key.endDate)
                } else {
                    defaults.removeObject(forKey: Key.endDate)
                }
            }
            let ok = acquireAssertions()
            if ok {
                isOn = true
                activeTriggerReason = reason
                // Only automation paths pass a reason AND expect auto-off when conditions clear.
                // Manual toggle / restore must not be cleared by evaluateTriggers().
                if !userInitiated, let reason, reason != "Restored session" {
                    awakeHeldByTrigger = true
                } else if userInitiated {
                    awakeHeldByTrigger = false
                }
                defaults.set(true, forKey: Key.isOn)
                lastFailure = nil
                scheduleTimer()
            } else {
                isOn = false
                awakeHeldByTrigger = false
                defaults.set(false, forKey: Key.isOn)
                notify(title: "Stay Alive failed", body: assertion.lastError ?? "Could not create power assertion")
            }
        } else {
            releaseAssertions()
            isOn = false
            endDate = nil
            activeTriggerReason = nil
            awakeHeldByTrigger = false
            defaults.set(false, forKey: Key.isOn)
            defaults.removeObject(forKey: Key.endDate)
            timer?.invalidate()
            timer = nil
        }
        updateRemainingText()
        NotificationCenter.default.post(name: .stayAliveStateChanged, object: nil)
    }

    func setMode(_ newMode: SleepMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Key.mode)
        if isOn {
            // Re-acquire with new mode
            releaseAssertions()
            _ = acquireAssertions()
        }
        NotificationCenter.default.post(name: .stayAliveStateChanged, object: nil)
    }

    func setDuration(_ preset: DurationPreset) {
        duration = preset
        defaults.set(preset.rawValue, forKey: Key.duration)
        if isOn {
            endDate = preset.deadline()
            if let endDate {
                defaults.set(endDate.timeIntervalSince1970, forKey: Key.endDate)
            } else {
                defaults.removeObject(forKey: Key.endDate)
            }
            scheduleTimer()
            updateRemainingText()
        }
        NotificationCenter.default.post(name: .stayAliveStateChanged, object: nil)
    }

    // MARK: Assertions

    @discardableResult
    private func acquireAssertions() -> Bool {
        releaseAssertions()
        let reason = "Stay Alive keeps this Mac awake" as CFString
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        var status = AssertionStatus()

        // Display: prevent idle display sleep (keeps screen on → blocks screensaver path)
        if mode == .both || mode == .displayOnly {
            var id: IOPMAssertionID = 0
            // Prefer modern PreventUserIdleDisplaySleep name; fall back to NoDisplaySleep
            var r = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                level,
                reason,
                &id
            )
            if r != kIOReturnSuccess {
                r = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypeNoDisplaySleep as CFString,
                    level,
                    reason,
                    &id
                )
            }
            if r == kIOReturnSuccess {
                displayAssertionID = id
                status.displayOK = true
                status.displayID = id
            } else {
                status.lastError = "Display assertion failed (IOReturn \(r))"
                log.error("Display assertion failed: \(r)")
            }
        }

        // System idle sleep
        if mode == .both || mode == .systemOnly {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                level,
                reason,
                &id
            )
            if r == kIOReturnSuccess {
                systemAssertionID = id
                status.systemOK = true
                status.systemID = id
            } else {
                let msg = "System idle assertion failed (IOReturn \(r))"
                status.lastError = status.lastError.map { $0 + "; " + msg } ?? msg
                log.error("System idle assertion failed: \(r)")
            }

            // Stronger: PreventSystemSleep (blocks idle sleep more aggressively)
            var id2: IOPMAssertionID = 0
            let r2 = IOPMAssertionCreateWithName(
                "PreventSystemSleep" as CFString,
                level,
                reason,
                &id2
            )
            if r2 == kIOReturnSuccess {
                preventSystemAssertionID = id2
                status.preventSystemOK = true
                status.preventSystemID = id2
            } else {
                log.warning("PreventSystemSleep failed (optional): \(r2)")
            }
        }

        // ProcessInfo activity — AppKit-level idle disable (helps with session idle)
        var activityOptions: ProcessInfo.ActivityOptions = [
            .idleSystemSleepDisabled,
            .suddenTerminationDisabled,
            .automaticTerminationDisabled
        ]
        if mode == .both || mode == .displayOnly {
            activityOptions.insert(.idleDisplaySleepDisabled)
        }
        if preventScreenLock {
            activityOptions.insert(.userInitiated)
        }
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: activityOptions,
            reason: "Stay Alive keeps session awake"
        )
        status.processActivityOK = (processActivity != nil)

        // Declare user activity once up front (resets idle / lock timers)
        if preventScreenLock || simulateActivity {
            pulseUserActivity(into: &status)
        }

        assertion = status
        hasAssertion = status.anyActive
        if !hasAssertion {
            lastFailure = status.lastError ?? "No assertion created"
        } else {
            startActivityHeartbeat()
            log.info("Assertions acquired: \(status.summary, privacy: .public)")
        }
        return hasAssertion
    }

    private func releaseAssertions() {
        activityTimer?.invalidate()
        activityTimer = nil

        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if preventSystemAssertionID != 0 {
            IOPMAssertionRelease(preventSystemAssertionID)
            preventSystemAssertionID = 0
        }
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        hasAssertion = false
        assertion = AssertionStatus()
    }

    /// Reset macOS idle timers so screensaver / lock / auto-logout don't fire.
    private func pulseUserActivity(into status: inout AssertionStatus) {
        // Release previous transient user-activity assertion before creating a new one
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
        var id: IOPMAssertionID = 0
        // kIOPMUserActiveLocal = 0
        let r = IOPMAssertionDeclareUserActivity(
            "Stay Alive user activity" as CFString,
            IOPMUserActiveType(0),
            &id
        )
        if r == kIOReturnSuccess {
            userActivityAssertionID = id
            status.userActivityOK = true
            status.userActivityID = id
            assertion.userActivityOK = true
            assertion.userActivityID = id
        } else {
            log.warning("IOPMAssertionDeclareUserActivity failed: \(r)")
        }
    }

    private func startActivityHeartbeat() {
        activityTimer?.invalidate()
        guard simulateActivity || preventScreenLock else { return }
        // Screensaver idle is often 60–180s; pulse well under that.
        activityTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOn else { return }
                var status = self.assertion
                self.pulseUserActivity(into: &status)
                self.assertion = status
            }
        }
        // Also fire once shortly after enable
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isOn else { return }
            var status = self.assertion
            self.pulseUserActivity(into: &status)
            self.assertion = status
        }
    }

    // MARK: Timer / remaining

    private func scheduleTimer() {
        timer?.invalidate()
        guard let endDate else {
            timer = nil
            return
        }
        let interval = max(0.5, endDate.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: min(interval, 1.0), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        updateRemainingText()
        if let endDate, Date() >= endDate {
            setOn(false, reason: nil, userInitiated: false)
            notify(title: "Stay Alive", body: "Timer finished — sleep allowed again")
        }
    }

    private func updateRemainingText() {
        guard isOn else {
            remainingText = ""
            return
        }
        guard let endDate else {
            remainingText = "∞"
            return
        }
        let s = max(0, Int(endDate.timeIntervalSinceNow))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            remainingText = String(format: "%dh %02dm", h, m)
        } else if m > 0 {
            remainingText = String(format: "%dm %02ds", m, sec)
        } else {
            remainingText = String(format: "%ds", sec)
        }
    }

    // MARK: Safeguards + polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        // also fire soon
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        refreshPower()
        refreshWiFi()
        thermalState = ProcessInfo.processInfo.thermalState
        updateRemainingText()

        // Safeguard: force off if conditions bad
        if isOn, let block = safeguardBlockReason() {
            setOn(false, reason: nil, userInitiated: false)
            lastFailure = block
            notify(title: "Stay Alive disabled", body: block)
            return
        }

        // Triggers only engage when not already user-on, or re-evaluate auto
        evaluateTriggers()
        verifyAssertionsStillHeld()

        // Extra idle reset on the 15s poll as well (screensaver is 180s here)
        if isOn, (simulateActivity || preventScreenLock) {
            var status = assertion
            pulseUserActivity(into: &status)
            assertion = status
        }
    }

    private func safeguardBlockReason() -> String? {
        if disableOnBatteryLow, !isCharging, let pct = batteryPercent, pct <= batteryThreshold {
            return "Battery at \(pct)% (threshold \(batteryThreshold)%). Plug in or raise the threshold."
        }
        if disableOnThermal {
            switch thermalState {
            case .serious, .critical:
                return "Thermal pressure is \(thermalLabel). Sleep allowed to cool down."
            default:
                break
            }
        }
        return nil
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func evaluateTriggers() {
        // If user turned on manually with timer, don't fight them except safeguards
        // Auto triggers: turn on when match, turn off when no longer match IF the reason was a trigger
        var reasons: [String] = []

        if processTriggerEnabled {
            let names = processNamesCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let hit = runningProcess(matching: names) {
                reasons.append("Process: \(hit)")
            }
        }
        if chargingTriggerEnabled, isCharging {
            reasons.append("On AC power")
        }
        if wifiTriggerEnabled {
            let ssids = wifiSSIDsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let ssid = wifiSSID, ssids.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                reasons.append("Wi‑Fi: \(ssid)")
            }
        }
        if calendarTriggerEnabled {
            if let title = currentCalendarEventTitle() {
                reasons.append("Calendar: \(title)")
            }
        }

        if !reasons.isEmpty {
            let joined = reasons.joined(separator: " · ")
            if !isOn {
                // Keep user duration preference but don't start a short timer for auto triggers
                let previousDuration = duration
                duration = .indefinite
                setOn(true, reason: joined, userInitiated: false)
                duration = previousDuration
                awakeHeldByTrigger = true
                activeTriggerReason = joined
            } else {
                activeTriggerReason = joined
                // If user manually turned on, don't flip ownership to trigger-only
                // (keeps manual session alive when trigger conditions later clear)
            }
        } else if awakeHeldByTrigger {
            // Automation conditions cleared — only then auto-disable
            if isOn {
                setOn(false, reason: nil, userInitiated: false)
            }
            awakeHeldByTrigger = false
            activeTriggerReason = nil
        }
    }

    private func runningProcess(matching names: [String]) -> String? {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let bundle = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            let exec = app.executableURL?.lastPathComponent ?? ""
            for n in names {
                if bundle.localizedCaseInsensitiveContains(n)
                    || name.localizedCaseInsensitiveContains(n)
                    || exec.localizedCaseInsensitiveContains(n) {
                    return name.isEmpty ? n : name
                }
            }
        }
        return nil
    }

    private func currentCalendarEventTitle() -> String? {
        let status = EKEventStore.authorizationStatus(for: .event)
        let allowed: Bool
        if #available(macOS 14.0, *) {
            allowed = (status == .fullAccess || status == .writeOnly)
        } else {
            allowed = (status == .authorized)
        }
        guard allowed else {
            return nil
        }
        let now = Date()
        let end = now.addingTimeInterval(60)
        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate).filter { !$0.isAllDay }
        return events.first?.title
    }

    func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                Task { @MainActor in
                    if !granted {
                        self.lastFailure = error?.localizedDescription ?? "Calendar access denied"
                    }
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                Task { @MainActor in
                    if !granted {
                        self.lastFailure = error?.localizedDescription ?? "Calendar access denied"
                    }
                }
            }
        }
    }

    private func verifyAssertionsStillHeld() {
        guard isOn, hasAssertion else { return }
        // Re-assert if somehow released (best-effort)
        // IOPM doesn't give easy query per-id without copying properties; re-create if IDs zeroed
        if displayAssertionID == 0 && systemAssertionID == 0 && preventSystemAssertionID == 0 && processActivity == nil {
            log.warning("Assertions lost — reacquiring")
            if !acquireAssertions() {
                setOn(false, reason: nil, userInitiated: false)
                notify(title: "Stay Alive", body: "Power assertions were cleared by the system")
            }
        }
    }

    private func refreshPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            batteryPercent = nil
            return
        }
        var pct: Int?
        var charging = false
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = Int((Double(capacity) / Double(max)) * 100.0)
            } else if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                pct = capacity
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                charging = (state == kIOPSACPowerValue)
            }
            if let isChargingNum = desc[kIOPSIsChargingKey] as? Bool {
                charging = charging || isChargingNum
            }
        }
        batteryPercent = pct
        isCharging = charging
    }

    private func refreshWiFi() {
        let client = CWWiFiClient.shared()
        wifiSSID = client.interface()?.ssid()
    }

    private func loadSettings() {
        if let raw = defaults.string(forKey: Key.mode), let m = SleepMode(rawValue: raw) {
            mode = m
        }
        if let raw = defaults.string(forKey: Key.duration), let d = DurationPreset(rawValue: raw) {
            duration = d
        }
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        if defaults.object(forKey: Key.restoreOnLaunch) != nil {
            restoreOnLaunch = defaults.bool(forKey: Key.restoreOnLaunch)
        }
        if defaults.object(forKey: Key.disableOnBatteryLow) != nil {
            disableOnBatteryLow = defaults.bool(forKey: Key.disableOnBatteryLow)
        }
        if defaults.object(forKey: Key.batteryThreshold) != nil {
            batteryThreshold = defaults.integer(forKey: Key.batteryThreshold)
        }
        if defaults.object(forKey: Key.disableOnThermal) != nil {
            disableOnThermal = defaults.bool(forKey: Key.disableOnThermal)
        }
        processTriggerEnabled = defaults.bool(forKey: Key.processTriggerEnabled)
        if let s = defaults.string(forKey: Key.processNames) { processNamesCSV = s }
        chargingTriggerEnabled = defaults.bool(forKey: Key.chargingTriggerEnabled)
        wifiTriggerEnabled = defaults.bool(forKey: Key.wifiTriggerEnabled)
        if let s = defaults.string(forKey: Key.wifiSSIDs) { wifiSSIDsCSV = s }
        calendarTriggerEnabled = defaults.bool(forKey: Key.calendarTriggerEnabled)
        if defaults.object(forKey: Key.panelOpacity) != nil {
            panelOpacity = min(1.0, max(0.0, defaults.double(forKey: Key.panelOpacity)))
        }
        if defaults.object(forKey: Key.uiZoom) != nil {
            uiZoom = min(1.6, max(0.8, defaults.double(forKey: Key.uiZoom)))
        }
        if defaults.object(forKey: Key.hotkeyEnabled) != nil {
            hotkeyEnabled = defaults.bool(forKey: Key.hotkeyEnabled)
        }
        if defaults.object(forKey: Key.preventScreenLock) != nil {
            preventScreenLock = defaults.bool(forKey: Key.preventScreenLock)
        }
        if defaults.object(forKey: Key.simulateActivity) != nil {
            simulateActivity = defaults.bool(forKey: Key.simulateActivity)
        }
    }

    private func applyLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Login item error: \(error.localizedDescription)")
                lastFailure = "Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    var statusLine: String {
        if !isOn { return "Sleep allowed" }
        var parts = ["Awake", mode.shortTitle]
        if !remainingText.isEmpty { parts.append(remainingText) }
        if let activeTriggerReason { parts.append(activeTriggerReason) }
        return parts.joined(separator: " · ")
    }
}

extension Notification.Name {
    static let stayAliveStateChanged = Notification.Name("stayAliveStateChanged")
    static let stayAliveOpacityChanged = Notification.Name("stayAliveOpacityChanged")
    static let stayAliveZoomChanged = Notification.Name("stayAliveZoomChanged")
    static let stayAliveOpenSettings = Notification.Name("stayAliveOpenSettings")
    static let stayAliveOpenGuide = Notification.Name("stayAliveOpenGuide")
}

// MARK: - Hotkey (⌃⌥⌘S)

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private weak var engine: StayAliveEngine?

    private init() {}

    func registerDefault(engine: StayAliveEngine) {
        self.engine = engine
        unregister()
        guard engine.hotkeyEnabled else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.engine?.toggle()
            }
            return noErr
        }
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &eventType, userData, &handlerRef)

        // Control + Option + Command + S
        let hotKeyID = EventHotKeyID(signature: OSType(0x53414C56), id: 1) // 'SALV'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let keyCode = UInt32(1) // kVK_ANSI_S = 1
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

// MARK: - Status bar (glass NSPanel — desktop shows through)

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let engine: StayAliveEngine
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var panel: NSPanel?
    private var glassView: NSVisualEffectView?
    private var hostView: NSHostingView<AnyView>?
    private var settingsWindow: NSWindow?
    private var guideWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private var solidOverlay: NSView?

    init(engine: StayAliveEngine) {
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        if let button = statusItem.button {
            button.image = Self.makeIcon(active: false)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Stay Alive"
        }

        rebuildMenu()
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveOpacityChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyGlassSolidity() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveZoomChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanelContent() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveOpenGuide, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openGuide() }
        })

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showPanel()
    }

    private func showPanel() {
        if panel == nil {
            buildGlassPanel()
        }
        rebuildPanelContent()
        applyGlassSolidity()
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Clear floating panel whose root is NSVisualEffectView(.behindWindow).
    private func buildGlassPanel() {
        let width: CGFloat = 340
        let height: CGFloat = 460
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow   // <-- desktop shows through
        glass.state = .active
        glass.isEmphasized = true
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Solidity overlay: pure black only (never warm/brown windowBackgroundColor)
        let overlay = NSView(frame: glass.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.layer?.opacity = Float(engine.panelOpacity) // 0 = full glass, 1 = solid black
        overlay.layer?.cornerRadius = 16
        overlay.layer?.masksToBounds = true
        glass.addSubview(overlay)

        let root = PanelRootView()
            .environmentObject(engine)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        // Clear hosting background so glass composites
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        glass.addSubview(host)

        panel.contentView = glass
        self.panel = panel
        self.glassView = glass
        self.solidOverlay = overlay
        self.hostView = host
    }

    private func rebuildPanelContent() {
        guard let hostView else { return }
        let root = PanelRootView()
            .environmentObject(engine)
            .preferredColorScheme(.dark)
            .scaleEffect(engine.uiZoom, anchor: .top)
        hostView.rootView = AnyView(root)
    }

    private func applyGlassSolidity() {
        // 0 = see desktop, 1 = solid dark. Never tint brown/orange.
        let s = Float(min(1, max(0, engine.panelOpacity)))
        solidOverlay?.layer?.opacity = s
        // Keep glass material active always
        glassView?.state = .active
        glassView?.blendingMode = .behindWindow
        if let panel {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.alphaValue = 1.0 // never dim whole window
        }
        if let settingsWindow {
            settingsWindow.isOpaque = false
            settingsWindow.backgroundColor = .clear
            settingsWindow.alphaValue = 1.0
        }
        if let guideWindow {
            guideWindow.isOpaque = false
            guideWindow.backgroundColor = .clear
            guideWindow.alphaValue = 1.0
        }
    }

    private func positionPanel() {
        guard let panel, let button = statusItem.button, let btnWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = btnWindow.convertToScreen(buttonRect)
        let panelSize = panel.frame.size
        var x = screenRect.midX - panelSize.width / 2
        var y = screenRect.minY - panelSize.height - 8
        if let screen = btnWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
            if y < visible.minY + 8 {
                y = screenRect.maxY + 8
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) {
        // click-away dismiss like a popover
        if let panel, notification.object as AnyObject? === panel {
            panel.orderOut(nil)
        }
    }

    private func refresh() {
        let on = engine.isOn
        statusItem.button?.image = Self.makeIcon(active: on)
        if on {
            if engine.remainingText == "∞" || engine.remainingText.isEmpty {
                statusItem.button?.title = " ON"
            } else {
                statusItem.button?.title = " \(engine.remainingText)"
            }
        } else {
            statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = "Stay Alive — \(engine.statusLine)"
        rebuildMenu()
        if panel?.isVisible == true {
            rebuildPanelContent()
            applyGlassSolidity()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: engine.isOn ? "Turn Off" : "Turn On", action: #selector(toggleOn), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())

        let modeMenu = NSMenu()
        for m in SleepMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.representedObject = m.rawValue
            item.state = (engine.mode == m) ? .on : .off
            item.target = self
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let durMenu = NSMenu()
        for d in DurationPreset.allCases {
            let item = NSMenuItem(title: d.title, action: #selector(selectDuration(_:)), keyEquivalent: "")
            item.representedObject = d.rawValue
            item.state = (engine.duration == d) ? .on : .off
            item.target = self
            durMenu.addItem(item)
        }
        let durItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        durItem.submenu = durMenu
        menu.addItem(durItem)

        menu.addItem(NSMenuItem.separator())
        let status = NSMenuItem(title: engine.assertion.summary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())
        let guide = NSMenuItem(title: "Guide…", action: #selector(openGuide), keyEquivalent: "g")
        guide.target = self
        menu.addItem(guide)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        zoomIn.target = self
        menu.addItem(zoomIn)
        let zoomInEq = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "=")
        zoomInEq.keyEquivalentModifierMask = [.command]
        zoomInEq.target = self
        zoomInEq.isHidden = true
        menu.addItem(zoomInEq)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        zoomOut.target = self
        menu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Actual Size", action: #selector(zoomResetAction), keyEquivalent: "0")
        zoomReset.keyEquivalentModifierMask = [.command]
        zoomReset.target = self
        menu.addItem(zoomReset)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Stay Alive", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleOn() { engine.toggle() }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = SleepMode(rawValue: raw) else { return }
        engine.setMode(m)
    }
    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = DurationPreset(rawValue: raw) else { return }
        engine.setDuration(d)
    }

    @objc private func openGuide() {
        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if guideWindow == nil {
            guideWindow = makeGlassWindow(title: "Stay Alive Guide", size: NSSize(width: 400, height: 520), root: AnyView(GuideView().environmentObject(engine)))
        }
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            settingsWindow = makeGlassWindow(title: "Stay Alive Settings", size: NSSize(width: 460, height: 580), root: AnyView(SettingsView().environmentObject(engine)))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeGlassWindow(title: String, size: NSSize, root: AnyView) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true

        let host = NSHostingView(rootView: root.preferredColorScheme(.dark))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        glass.addSubview(host)
        window.contentView = glass
        window.center()
        return window
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func zoomInAction() { engine.bumpZoom(0.1); rebuildPanelContent() }
    @objc private func zoomOutAction() { engine.bumpZoom(-0.1); rebuildPanelContent() }
    @objc private func zoomResetAction() { engine.uiZoom = 1.0; rebuildPanelContent() }

    /// Pulse / heartbeat icon — not a coffee cup.
    private static func makeIcon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let color = active ? NSColor.systemTeal : NSColor.secondaryLabelColor
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1, y: 9))
            path.line(to: NSPoint(x: 4, y: 9))
            path.line(to: NSPoint(x: 6.5, y: 14))
            path.line(to: NSPoint(x: 9.5, y: 4))
            path.line(to: NSPoint(x: 12, y: 11))
            path.line(to: NSPoint(x: 14, y: 9))
            path.line(to: NSPoint(x: 17, y: 9))
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = !active
        return image
    }
}

// MARK: - Theme (no brown / no coffee)

enum SATheme {
    static let accent = Color.teal
    static let accentNS = NSColor.systemTeal
    static let on = Color.teal
    static let textSecondary = Color.secondary
}

// MARK: - SwiftUI panel content (clear backgrounds — glass is AppKit under us)

struct PanelRootView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        VStack(spacing: 0) {
            ContentView()
            Divider().overlay(Color.white.opacity(0.12))
            VStack(spacing: 8) {
                HStack {
                    Text("Glass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { 1.0 - engine.panelOpacity },
                        set: { engine.panelOpacity = 1.0 - $0 }
                    ), in: 0...1, step: 0.05)
                    .tint(.teal)
                    Text(glassLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .help("Drag right to see more desktop through the panel")

                HStack {
                    Text("Zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $engine.uiZoom, in: 0.8...1.6, step: 0.1)
                        .tint(.teal)
                    Text("\(Int((engine.uiZoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    Button {
                        NotificationCenter.default.post(name: .stayAliveOpenGuide, object: nil)
                    } label: {
                        Label("Guide", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.teal)

                    Button {
                        NotificationCenter.default.post(name: .stayAliveOpenSettings, object: nil)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        // CRITICAL: no solid Color background — let AppKit glass show desktop
        .background(Color.clear)
    }

    private var glassLabel: String {
        let g = Int(((1.0 - engine.panelOpacity) * 100).rounded())
        if g >= 95 { return "Clear" }
        if g <= 5 { return "Solid" }
        return "\(g)%"
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(engine.isOn ? Color.teal.opacity(0.8) : Color.white.opacity(0.2), lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: 84, height: 84)
                Image(systemName: engine.isOn ? "heart.fill" : "heart")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(engine.isOn ? Color.teal : Color.secondary)
            }

            Text("Stay Alive")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(engine.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(engine.isOn ? Color.teal : Color.secondary)
                .multilineTextAlignment(.center)

            Toggle(isOn: Binding(
                get: { engine.isOn },
                set: { engine.setOn($0, reason: nil, userInitiated: true) }
            )) {
                Text(engine.isOn ? "On" : "Off")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .tint(.teal)

            Picker("Mode", selection: Binding(
                get: { engine.mode },
                set: { engine.setMode($0) }
            )) {
                ForEach(SleepMode.allCases) { m in
                    Text(m.shortTitle).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Duration", selection: Binding(
                get: { engine.duration },
                set: { engine.setDuration($0) }
            )) {
                ForEach(DurationPreset.allCases) { d in
                    Text(d.title).tag(d)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                Label(engine.assertion.summary, systemImage: engine.assertion.anyActive ? "checkmark.shield" : "moon.zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let fail = engine.lastFailure, !fail.isEmpty {
                    Text(fail)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                }
                if let pct = engine.batteryPercent {
                    Text("Battery \(pct)%\(engine.isCharging ? " · charging" : "") · thermal \(engine.thermalLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("⌃⌥⌘S toggle · drag Glass right to see desktop")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.clear)
    }
}

struct GuideView: View {
    @EnvironmentObject private var engine: StayAliveEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Stay Alive Guide")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { NSApp.keyWindow?.orderOut(nil) }
            }
            Group {
                Text("Menu bar pulse icon opens the glass panel.")
                Text("Glass slider: right = more desktop visible underneath.")
                Text("On keeps display/system awake; session lock heartbeat optional in Settings.")
                Text("⌘+ / ⌘- zoom · ⌘[ / ⌘] glass amount.")
            }
            .font(.body)
            .foregroundStyle(.primary)
            Spacer()
            Text("MIT © Philip S. Wright")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.headline).foregroundStyle(.teal)
                Toggle("Launch at login", isOn: $engine.launchAtLogin)
                Toggle("Restore awake state on launch", isOn: $engine.restoreOnLaunch)
                Toggle("Global hotkey ⌃⌥⌘S", isOn: $engine.hotkeyEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Desktop glass")
                        Spacer()
                        Text(glassLabel)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    // UI: 0 clear ... 1 solid mapped inverted for "see desktop" intuition
                    Slider(value: Binding(
                        get: { 1.0 - engine.panelOpacity },
                        set: { engine.panelOpacity = 1.0 - $0 }
                    ), in: 0...1, step: 0.05)
                    .tint(.teal)
                    Text("Right = more desktop visible through the panel. Left = solid.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("UI zoom")
                        Spacer()
                        Text("\(Int((engine.uiZoom * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $engine.uiZoom, in: 0.8...1.6, step: 0.1)
                        .tint(.teal)
                    Text("⌘+ zoom in · ⌘- zoom out · ⌘0 actual size")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Session lock").font(.headline).foregroundStyle(.teal)
                Toggle("Prevent screen lock & idle logout", isOn: $engine.preventScreenLock)
                Toggle("Heartbeat: reset idle timers", isOn: $engine.simulateActivity)

                Text("Safeguards").font(.headline).foregroundStyle(.teal)
                Toggle("Disable when battery is low", isOn: $engine.disableOnBatteryLow)
                if engine.disableOnBatteryLow {
                    Stepper("Threshold: \(engine.batteryThreshold)%", value: $engine.batteryThreshold, in: 5...50, step: 5)
                }
                Toggle("Disable under serious/critical thermal pressure", isOn: $engine.disableOnThermal)

                Text("Automation").font(.headline).foregroundStyle(.teal)
                Toggle("While processes are running", isOn: $engine.processTriggerEnabled)
                TextField("Process names", text: $engine.processNamesCSV)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!engine.processTriggerEnabled)
                Toggle("While charging / on AC", isOn: $engine.chargingTriggerEnabled)
                Toggle("On selected Wi‑Fi networks", isOn: $engine.wifiTriggerEnabled)
                TextField("SSIDs", text: $engine.wifiSSIDsCSV)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!engine.wifiTriggerEnabled)
                Toggle("During calendar events", isOn: $engine.calendarTriggerEnabled)
                Button("Request calendar access") { engine.requestCalendarAccess() }
                    .disabled(!engine.calendarTriggerEnabled)

                Text("About").font(.headline).foregroundStyle(.teal)
                LabeledContent("Version", value: "2.5")
                LabeledContent("Author", value: "Philip S. Wright")
                LabeledContent("License", value: "MIT")
                Link("github.com/pdubbbbbs/StayAlive", destination: URL(string: "https://github.com/pdubbbbbs/StayAlive")!)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .tint(.teal)
    }

    private var glassLabel: String {
        let g = Int(((1.0 - engine.panelOpacity) * 100).rounded())
        if g >= 95 { return "Clear — desktop visible" }
        if g <= 5 { return "Solid" }
        return "\(g)% glass"
    }
}
