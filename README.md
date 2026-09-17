# Stay Alive

**Menu-bar utility that keeps your Mac awake and your session unlocked.**

Local-only. No accounts. No cloud.

[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](#)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](#)

**Author:** Philip S. Wright (`pdubbbbbs`)  
**Bundle ID:** `me.philipwright.StayAlive`  
**Version:** 2.1  
**License:** MIT

---

## What it does

When **On**, Stay Alive:

- Prevents **display** and **system idle sleep** (IOPM assertions)
- Optionally holds **PreventSystemSleep**
- Runs a **user-activity heartbeat** so short screensaver / lock / idle-logout timers do not fire
- Shows live status in the menu bar (countdown or ON)

It cannot block a **manual** logout, lid-close sleep on all hardware, or MDM force-logout.

## Install (production app)

```bash
git clone https://github.com/pdubbbbbs/StayAlive.git
cd StayAlive
./scripts/build.sh
# Installs to: ~/Applications/StayAlive.app
open ~/Applications/StayAlive.app
```

Or copy `StayAlive.app` into `/Applications` if you prefer the system Applications folder.

## Usage

| Action | How |
|--------|-----|
| Toggle awake | Left-click menu-bar cup → switch, or `⌃⌥⌘S` |
| Modes | Display / System / Both |
| Duration | 15m · 1h · 3h · until tomorrow 7:00 · indefinite |
| Guide | **Guide** button on the popover |
| Settings | Right-click menu bar → Settings… |
| Opacity | Slider on popover (55%–100%) |

## Features

1. Menu-bar app (no Dock icon by default — `LSUIElement`)
2. Display / System / Both sleep modes
3. Timed auto-off
4. Restore state + Launch at Login
5. Global hotkey `⌃⌥⌘S`
6. Live status + assertion summary
7. Failure notifications
8. Battery & thermal safeguards
9. Local triggers (process, AC, Wi‑Fi SSID, calendar)
10. Packaging script + icon
11. Panel opacity / transparency
12. Session lock / idle-logout prevention heartbeat
13. In-app **Guide**

## Build

```bash
./scripts/build.sh
```

Logic tests:

```bash
swift Tests/DurationPresetTests.swift
```

## Privacy

- Core function needs no network
- Calendar / Wi‑Fi SSID are optional and local
- Preferences in standard `UserDefaults`

## License

MIT © 2026 Philip S. Wright — see [LICENSE](LICENSE).
