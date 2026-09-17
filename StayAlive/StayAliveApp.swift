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

@main
struct StayAliveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(StayAliveEngine.shared)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let engine = StayAliveEngine.shared
        engine.bootstrap()
        statusController = StatusBarController(engine: engine)
        HotKeyManager.shared.registerDefault(engine: engine)
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
    /// 0.55 ... 1.0 — panel / menu visual opacity
    @Published var panelOpacity: Double = 1.0 {
        didSet {
            defaults.set(panelOpacity, forKey: Key.panelOpacity)
            NotificationCenter.default.post(name: .stayAliveOpacityChanged, object: panelOpacity)
        }
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
            panelOpacity = min(1.0, max(0.55, defaults.double(forKey: Key.panelOpacity)))
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

// MARK: - Status bar

@MainActor
final class StatusBarController: NSObject {
    private let engine: StayAliveEngine
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var settingsWindow: NSWindow?
    private var popover: NSPopover?
    private var observations: [NSObjectProtocol] = []

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
            Task { @MainActor in self?.applyOpacity() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .stayAliveOpenGuide, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openGuide() }
        })

        // Refresh title every second while on
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        applyOpacity()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let view = PopoverRootView()
            .environmentObject(engine)
            .preferredColorScheme(.dark)
        let host = NSHostingController(rootView: view)
        pop.contentViewController = host
        pop.contentSize = NSSize(width: 320, height: 420)
        self.popover = pop
        applyOpacity()
        if let button = statusItem.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func applyOpacity() {
        let alpha = CGFloat(engine.panelOpacity)
        popover?.contentViewController?.view.window?.alphaValue = alpha
        // Also tint status bar text opacity slightly when not fully opaque
        statusItem.button?.alphaValue = alpha < 0.99 ? max(0.75, alpha) : 1.0
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
        applyOpacity()
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

        if let fail = engine.lastFailure, !fail.isEmpty {
            let f = NSMenuItem(title: "⚠ \(fail)", action: nil, keyEquivalent: "")
            f.isEnabled = false
            menu.addItem(f)
        }

        menu.addItem(NSMenuItem.separator())

        let guide = NSMenuItem(title: "Guide…", action: #selector(openGuide), keyEquivalent: "g")
        guide.target = self
        menu.addItem(guide)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    private var guideWindow: NSWindow?

    @objc private func openGuide() {
        NSApp.activate(ignoringOtherApps: true)
        if guideWindow == nil {
            let host = NSHostingController(rootView: GuideView().preferredColorScheme(.dark))
            let window = NSWindow(contentViewController: host)
            window.title = "Stay Alive Guide"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 520))
            window.center()
            window.isReleasedWhenClosed = false
            guideWindow = window
        }
        guideWindow?.alphaValue = CGFloat(engine.panelOpacity)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Stay Alive Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 440, height: 560))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.alphaValue = CGFloat(engine.panelOpacity)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func makeIcon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let base = active ? NSColor.systemOrange : NSColor.secondaryLabelColor
            base.setFill()
            // Simple cup shape
            let body = NSBezierPath(roundedRect: NSRect(x: 5, y: 3, width: 8, height: 10), xRadius: 1.5, yRadius: 1.5)
            body.fill()
            let handle = NSBezierPath(ovalIn: NSRect(x: 12, y: 6, width: 4, height: 5))
            handle.lineWidth = 1.2
            base.setStroke()
            handle.stroke()
            if active {
                NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
                let steam = NSBezierPath()
                steam.move(to: NSPoint(x: 7, y: 14))
                steam.curve(to: NSPoint(x: 8, y: 17), controlPoint1: NSPoint(x: 6, y: 15.5), controlPoint2: NSPoint(x: 9, y: 15.5))
                steam.lineWidth = 1.0
                steam.stroke()
            }
            return true
        }
        image.isTemplate = !active
        return image
    }
}

// MARK: - SwiftUI views

struct PopoverRootView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        VStack(spacing: 0) {
            ContentView()
            Divider().opacity(0.3)
            HStack {
                Text("Opacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $engine.panelOpacity, in: 0.55...1.0, step: 0.05)
                    .controlSize(.small)
                Text("\(Int(engine.panelOpacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Panel opacity")

            // Guide + Settings on the desktop popover box
            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .stayAliveOpenGuide, object: nil)
                } label: {
                    Label("Guide", systemImage: "book.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityLabel("Open Stay Alive guide")

                Button {
                    NotificationCenter.default.post(name: .stayAliveOpenSettings, object: nil)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open settings")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor).opacity(engine.panelOpacity))
        .opacity(engine.panelOpacity)
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(engine.isOn ? Color.orange.opacity(0.28) : Color.gray.opacity(0.12))
                    .frame(width: 84, height: 84)
                Text("☕️")
                    .font(.system(size: 40))
                    .accessibilityHidden(true)
            }

            Text("Stay Alive")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text(engine.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(engine.isOn ? Color.orange : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

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
            .tint(.orange)
            .accessibilityLabel("Keep Mac awake")
            .accessibilityValue(engine.isOn ? "On" : "Off")

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
            .accessibilityLabel("Sleep prevention mode")

            Picker("Duration", selection: Binding(
                get: { engine.duration },
                set: { engine.setDuration($0) }
            )) {
                ForEach(DurationPreset.allCases) { d in
                    Text(d.title).tag(d)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Auto-off duration")

            VStack(alignment: .leading, spacing: 4) {
                Label(engine.assertion.summary, systemImage: engine.assertion.anyActive ? "checkmark.shield" : "moon.zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let fail = engine.lastFailure, !fail.isEmpty {
                    Text(fail)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pct = engine.batteryPercent {
                    Text("Battery \(pct)%\(engine.isCharging ? " · charging" : "") · thermal \(engine.thermalLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if engine.preventScreenLock {
                Text("Idle lock/logout blocked while On")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            Text("Hotkey ⌃⌥⌘S · Right-click menu")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }
}

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stay Alive Guide")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done") {
                    dismiss()
                    NSApp.keyWindow?.close()
                }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideSection("Quick start", """
1. Click the coffee-cup icon in the menu bar.
2. Flip On.
3. Mode: Both (or Display / System only).
4. Pick a Duration, or Indefinite.
5. Opacity slider dims the popover if you want it translucent.
""")
                    guideSection("Hotkey", "⌃⌥⌘S toggles On/Off from anywhere. Disable under Settings → General.")
                    guideSection("Right-click menu", "Turn On/Off · Mode · Duration · assertion status · Settings… · Quit")
                    guideSection("Session lock / logout", """
Your Mac may lock after a short screensaver idle (~3 min here).

While On, Stay Alive holds sleep assertions and pulses user-activity so idle lock / logout timers reset.

Does not block: manual Log Out, some lid-close sleeps, or MDM force-logout.
""")
                    guideSection("Safeguards", "Auto-off on low battery and serious/critical thermal pressure (configurable in Settings).")
                    guideSection("Automation", "Optional local triggers: processes, AC power, Wi‑Fi SSIDs, calendar events.")
                    guideSection("Install", "~/Applications/StayAlive.app\nhttps://github.com/pdubbbbbs/StayAlive")
                    Text("MIT © 2026 Philip S. Wright")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(16)
            }
        }
        .frame(width: 360, height: 480)
        .preferredColorScheme(.dark)
    }

    private func guideSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: StayAliveEngine

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $engine.launchAtLogin)
                Toggle("Restore awake state on launch", isOn: $engine.restoreOnLaunch)
                Toggle("Global hotkey ⌃⌥⌘S", isOn: $engine.hotkeyEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Panel opacity")
                        Spacer()
                        Text(engine.panelOpacity >= 0.99 ? "Opaque" : "\(Int(engine.panelOpacity * 100))% transparent")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $engine.panelOpacity, in: 0.55...1.0, step: 0.05)
                    Text("Controls popover, settings window, and menu bar dimming. 100% is fully opaque.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Panel opacity")
            }

            Section("Session lock / logout") {
                Toggle("Prevent screen lock & idle logout", isOn: $engine.preventScreenLock)
                Toggle("Heartbeat: reset idle timers", isOn: $engine.simulateActivity)
                Text("Your screensaver idle is short (~3 min). Stay Alive declares user activity while On so lock/logout timers do not fire. This cannot block a manual logout or MDM force-logout.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Safeguards") {
                Toggle("Disable when battery is low", isOn: $engine.disableOnBatteryLow)
                if engine.disableOnBatteryLow {
                    Stepper("Threshold: \(engine.batteryThreshold)%", value: $engine.batteryThreshold, in: 5...50, step: 5)
                }
                Toggle("Disable under serious/critical thermal pressure", isOn: $engine.disableOnThermal)
                Text("Lid sleep is still controlled by macOS; closing the lid may sleep regardless of assertions.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Automation triggers (local only)") {
                Toggle("While processes are running", isOn: $engine.processTriggerEnabled)
                TextField("Process names (comma-separated)", text: $engine.processNamesCSV)
                    .disabled(!engine.processTriggerEnabled)

                Toggle("While charging / on AC", isOn: $engine.chargingTriggerEnabled)

                Toggle("On selected Wi‑Fi networks", isOn: $engine.wifiTriggerEnabled)
                TextField("SSIDs (comma-separated)", text: $engine.wifiSSIDsCSV)
                    .disabled(!engine.wifiTriggerEnabled)
                if let ssid = engine.wifiSSID {
                    Text("Current SSID: \(ssid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("During calendar events", isOn: $engine.calendarTriggerEnabled)
                Button("Request calendar access") { engine.requestCalendarAccess() }
                    .disabled(!engine.calendarTriggerEnabled)
            }

            Section("About") {
                LabeledContent("Version", value: "2.0")
                LabeledContent("Bundle", value: "me.philipwright.StayAlive")
                LabeledContent("Author", value: "Philip S. Wright")
                LabeledContent("License", value: "MIT")
                Text("Self-hosted utility. No cloud accounts. philipwright.me")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("GitHub: pdubbbbbs/StayAlive", destination: URL(string: "https://github.com/pdubbbbbs/StayAlive")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 520)
        .padding()
        .opacity(engine.panelOpacity)
    }
}
