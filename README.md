# Stay Alive

Menu-bar utility that keeps your Mac awake — local only, no cloud accounts.

**Bundle ID:** `me.philipwright.StayAlive`  
**Version:** 2.0  
**macOS:** 13+

## Features

1. **Menu bar app** — left-click popover, right-click menu (no Dock icon)
2. **Modes** — Display only / System only / Both
3. **Timed auto-off** — 15m, 1h, 3h, until tomorrow 7:00, indefinite
4. **Persist + Launch at Login** — restores last session; optional login item
5. **Hotkey** — `⌃⌥⌘S` toggle (can disable in Settings)
6. **Live status** — menu-bar countdown / ON, assertion summary, tooltips
7. **Assertion health** — failure notifications if IOPM assertions fail
8. **Safeguards** — auto-disable on low battery or serious/critical thermal pressure
9. **Local triggers** — process names, AC power, Wi‑Fi SSID, calendar events
10. **Packaging** — `scripts/build.sh`, app icon, this README
11. **Opacity / transparency** — slider in popover + Settings (55%–100%)

## Build & install

```bash
/Users/dubsf3/Applications/StayAlive/scripts/build.sh
open -a /Users/dubsf3/Applications/StayAlive.app
```

Tests (pure logic):

```bash
swift /Users/dubsf3/Applications/StayAlive/Tests/DurationPresetTests.swift
```

## Privacy

- No network calls required for core function
- Calendar access is optional and local (EventKit)
- Wi‑Fi SSID read is local (CoreWLAN)
- Preferences stored in standard `UserDefaults`

## Notes

- Closing the MacBook lid is still governed by macOS; power assertions cannot fully override lid-close sleep on all hardware.
- First calendar use: enable the trigger in Settings and click **Request calendar access**.
