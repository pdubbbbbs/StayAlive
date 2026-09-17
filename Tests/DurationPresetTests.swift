import Foundation

// Pure logic mirrors of StayAlive duration deadlines for regression tests.
// No XCTest — works with Command Line Tools only via `swift Tests/DurationPresetTests.swift`.

enum TestSleepMode: String, CaseIterable {
    case both, display, system
}

enum TestDurationPreset: String, CaseIterable {
    case fifteenMin = "15m"
    case oneHour = "1h"
    case threeHours = "3h"
    case untilTomorrow = "tomorrow"
    case indefinite = "indefinite"

    func deadline(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMin:
            return now.addingTimeInterval(15 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .threeHours:
            return now.addingTimeInterval(3 * 60 * 60)
        case .untilTomorrow:
            let start = calendar.startOfDay(for: now)
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start),
                  let seven = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) else {
                return now.addingTimeInterval(12 * 60 * 60)
            }
            return seven
        case .indefinite:
            return nil
        }
    }
}

func clampOpacity(_ value: Double) -> Double {
    min(1.0, max(0.55, value))
}

func remainingLabel(isOn: Bool, endDate: Date?, now: Date = Date()) -> String {
    guard isOn else { return "" }
    guard let endDate else { return "∞" }
    let s = max(0, Int(endDate.timeIntervalSince(now)))
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    if m > 0 { return String(format: "%dm %02ds", m, sec) }
    return String(format: "%ds", sec)
}

struct Expect {
    static var failures = 0
    static func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
        if a != b {
            print("FAIL \(label): \(a) != \(b)")
            failures += 1
        } else {
            print("ok   \(label)")
        }
    }
    static func approx(_ a: Double, _ b: Double, _ label: String, eps: Double = 0.001) {
        if abs(a - b) > eps {
            print("FAIL \(label): \(a) !~ \(b)")
            failures += 1
        } else {
            print("ok   \(label)")
        }
    }
    static func `true`(_ v: Bool, _ label: String) {
        if !v {
            print("FAIL \(label)")
            failures += 1
        } else {
            print("ok   \(label)")
        }
    }
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
Expect.approx(TestDurationPreset.fifteenMin.deadline(from: now)!.timeIntervalSince(now), 15 * 60, "15m")
Expect.approx(TestDurationPreset.oneHour.deadline(from: now)!.timeIntervalSince(now), 3600, "1h")
Expect.approx(TestDurationPreset.threeHours.deadline(from: now)!.timeIntervalSince(now), 3 * 3600, "3h")
Expect.true(TestDurationPreset.indefinite.deadline() == nil, "indefinite nil")

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(secondsFromGMT: 0)!
let end = TestDurationPreset.untilTomorrow.deadline(from: now, calendar: cal)!
let comps = cal.dateComponents([.hour, .minute], from: end)
Expect.eq(comps.hour, 7, "tomorrow hour")
Expect.eq(comps.minute, 0, "tomorrow minute")
Expect.true(end > now, "tomorrow after now")

Expect.approx(clampOpacity(0.1), 0.55, "opacity low")
Expect.approx(clampOpacity(1.5), 1.0, "opacity high")
Expect.approx(clampOpacity(0.8), 0.8, "opacity mid")

let t0 = Date(timeIntervalSince1970: 0)
Expect.eq(remainingLabel(isOn: false, endDate: nil, now: t0), "", "off label")
Expect.eq(remainingLabel(isOn: true, endDate: nil, now: t0), "∞", "inf label")
Expect.eq(remainingLabel(isOn: true, endDate: t0.addingTimeInterval(65), now: t0), "1m 05s", "1m05")
Expect.eq(remainingLabel(isOn: true, endDate: t0.addingTimeInterval(3661), now: t0), "1h 01m", "1h01")
Expect.eq(remainingLabel(isOn: true, endDate: t0.addingTimeInterval(9), now: t0), "9s", "9s")
Expect.eq(TestSleepMode.allCases.count, 3, "modes")

if Expect.failures > 0 {
    print("\n\(Expect.failures) failure(s)")
    exit(1)
}
print("\nAll tests passed")
