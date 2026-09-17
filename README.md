# Stay Alive 3.0

Keep your Mac awake. **MIT © Philip S. Wright**

## Features
- Double-click opens Dock icon + glass panel
- **Desktop glass** slider — drag right to see wallpaper through the panel
- Red heartbeat icon
- Display / system sleep prevention (IOPM)
- Menu bar control + ⌃⌥⌘S
- Timed auto-off

## Install
```bash
./scripts/build.sh
open /Applications/StayAlive.app
```

## Verify glass
Self-test includes fill opacity 0 / 0.4 / 1 checks:
```bash
/Applications/StayAlive.app/Contents/MacOS/StayAlive --self-test
```
