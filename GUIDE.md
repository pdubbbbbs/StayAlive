# Stay Alive Guide

## Quick start
1. Click the coffee-cup icon in the menu bar.
2. Flip **On**.
3. Leave **Mode** on **Both** unless you only need the display or only the CPU awake.
4. Pick a **Duration** (or Indefinite).
5. Use the **Opacity** slider if you want a translucent popover.

## Hotkey
**⌃⌥⌘S** — toggle On/Off from anywhere (disable in Settings).

## Right-click menu
- Turn On/Off
- Mode & Duration
- Assertion status
- Settings…
- Quit

## Session lock / “logout”
macOS may lock or idle-logout after a short screensaver idle (often ~3 minutes).

While Stay Alive is **On**, it:
- Holds power assertions (display + system)
- Declares **user activity** on a heartbeat so idle lock timers reset

This does **not** block:
- You choosing Log Out
- Some lid-close sleep policies
- MDM / forced logout

Toggles live under **Settings → Session lock / logout**.

## Safeguards
- Auto-disable on low battery (threshold configurable)
- Auto-disable under serious/critical thermal pressure

## Automation (local only)
Optional triggers in Settings:
- Named processes running (e.g. Zoom, ffmpeg)
- On AC power
- Specific Wi‑Fi SSIDs
- During calendar events (requires permission)

## Install path
Production app: `~/Applications/StayAlive.app`  
Source: this repository.

## Support
GitHub: https://github.com/pdubbbbbs/StayAlive  
Author: Philip S. Wright
