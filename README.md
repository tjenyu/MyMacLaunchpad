# Launchpad for macOS 27

A personal re-creation of the classic Launchpad. It covers the P0 and P1 items of the "macOS 27 Launchpad 需求文件" spec.

## Build and run

```bash
./scripts/build-app.sh          # → build/Launchpad.app
open build/Launchpad.app
/usr/bin/swift test             # core tests (search, layout, legacy import)
```

Use `/usr/bin/swift` (Xcode's toolchain). The swiftly toolchain on PATH doesn't match the macOS 27 SDK.
To keep it in the Dock, copy `build/Launchpad.app` to `/Applications` and choose "Keep in Dock".

## Features

| ID | Feature | How |
|---|---|---|
| F-01 | Full-screen grid | Blurred background; scans /Applications, /System/Applications and ~/Applications |
| F-02 | Pages | Two-finger swipe, mouse wheel, click-drag on empty space, ←/→ (⌘←/→ always flips), page dots |
| F-03 | Drag to reorder | Drag an icon; hold it at the screen edge to move it to another page |
| F-04 | Folders | Hold one icon over another to make a folder; click the title to rename; folders page automatically |
| F-05 | Search | Type to filter: Chinese or English names, pinyin (`yinle`, `yl`), zhuyin initials (`ㄧㄌ`) and zhuyin keys typed with ABC (`ux`) |
| F-06 | Open / close | Click to open an app; Esc or click empty space to close |
| F-07 | Entry points | Dock icon, global shortcut (default ⌃⌘L, change it in Settings), menu bar icon |
| F-08 | Auto-update | FSEvents watch; new apps go to the last page, removed apps disappear |
| F-09 | Import old layout | Done automatically on first run when the old database exists; also under Settings › Layout (from this Mac or from a file, e.g. a Time Machine backup) |
| F-11 | Gestures / hot corner | Settings › Gestures: thumb + 3-finger pinch (private MultitouchSupport framework), hot corner |
| F-12 | Grid settings | Rows, columns, icon size, blur strength |
| F-13 | Edit mode | Long-press to jiggle; the ✕ badge moves the app to the Trash after you confirm |
| F-14 | Hide apps | Right-click › Hide; Settings › Hidden Apps brings them back |

Data lives in `~/Library/Application Support/Launchpad/layout.json` and stays on this Mac.
