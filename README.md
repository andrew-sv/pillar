# SamsungBrowser

A small native macOS app for browsing a connected Samsung (or any Android) device's
filesystem over ADB. Single-column drill-down UI. Read, write, push, pull, rename,
delete, and drag-and-drop with Finder.

## Prerequisites

1. **Install ADB** (Android platform tools):
   ```sh
   brew install --cask android-platform-tools
   ```
2. **Enable USB debugging on the phone**:
   - Settings → About phone → tap *Build number* seven times to unlock Developer options.
   - Settings → Developer options → enable *USB debugging*.
3. Plug the phone into the Mac with a data-capable USB cable. The phone will prompt
   you to allow this computer to debug — accept (and check "always allow" if you like).

## Run

From this directory:

```sh
swift run
```

Or open `Package.swift` in Xcode and press ⌘R.

## What it does

- Lists connected devices in the toolbar; pick one.
- Starts at `/sdcard` (the user-visible storage on Samsung devices).
- Tap a folder row to drill in; the back button (or ⌘[) goes up.
- Right-click a row for **Open**, **Save As…**, **Rename**, **Delete**.
- Toolbar buttons: **New folder**, **Push file…**, **Refresh**.
- Drag a file from Finder into the list to push it to the current directory.
- Drag a file or folder *out* of the list into Finder to pull it.

## Notes

- "Open" pulls the file to a temp directory and hands it to the system default app.
  Edits to the temp file are **not** automatically pushed back — use *Save As…* to
  pull to a known location, edit, then drag the result back into the app.
- App-private directories (`/data/data/<pkg>`) require root or `run-as` and are not
  exposed by this app — stick to `/sdcard` and friends.
- Some Samsung firmware buffers writes; if a file looks stale, hit Refresh.
