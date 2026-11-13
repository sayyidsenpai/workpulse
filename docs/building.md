# Build, sign and run

How to build WorkPulse from source, what the signature means, and which permissions it needs. [Back to the README](../README.md)

## Build, install, launch

```bash
./scripts/build-app.sh
```

This compiles a release binary, assembles `build/WorkPulse.app` and signs it ad hoc.
`./scripts/build-app.sh universal` builds arm64 + x86_64.

```bash
cp -R build/WorkPulse.app /Applications/
```

```bash
open /Applications/WorkPulse.app
```

WorkPulse appears in the menu bar (stopwatch icon), not in the Dock. The first launch shows a
short setup: your work hours, your daily goal and your work applications. Click the menu bar icon
for the status and its two actions; the row of icons at the bottom opens History, Reports, Work,
Apps, Sleep and Settings.
Turn on **Settings › Launch at login** after copying the app to `/Applications` (the login item
points at the app's current location).

Tests and development:

```bash
swift test
```

```bash
swift build
```

`Package.swift` opens directly in Xcode. Setting `WORKPULSE_DATA_DIR=/some/folder` makes the app
use that folder instead of the real data folder, which is handy for experiments.

## Code signing, Gatekeeper, notarization

- The build script signs with an **ad-hoc signature** (`codesign --sign -`). This needs no Apple
  Developer membership and is what Apple Silicon requires to run locally built code.
- An app built on your own Mac carries no quarantine flag, so Gatekeeper does not block it.
- The app is **not notarized** and has no Developer ID. If you copy the `.app` to another Mac by
  download, AirDrop or chat, macOS quarantines it and Gatekeeper will refuse to open it. The clean
  options are: build it from source on that Mac, or sign with a Developer ID certificate and
  notarize it (both require the paid Apple Developer Program). macOS also offers its own per-app
  override under System Settings › Privacy & Security › "Open Anyway". WorkPulse does not and
  should not work around these protections.
- macOS ties notification permission and the login item to the app's signature. An ad-hoc
  signature changes on every rebuild, so after rebuilding you may be asked again or need to
  re-enable "Launch at login".

## Permissions

| Feature | Permission | If denied |
| --- | --- | --- |
| Activity tracking | none | n/a |
| Sleep reminders | Notifications (asked when you enable reminders) | reminders are skipped; nothing else changes |
| Launch at login | Login Items entry (visible in System Settings › General) | app simply does not auto-start |

Tracking uses `NSWorkspace` (frontmost application) and the system's "seconds since last input"
counter. It does **not** use Accessibility, Screen Recording or Input Monitoring, and never sees
keystrokes, window titles, screen contents, URLs or browser tabs.
