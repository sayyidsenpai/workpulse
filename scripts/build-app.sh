#!/bin/bash
# Builds build/WorkPulse.app: release binary + Info.plist + icon, ad-hoc signed.
#
# By project convention this script uses no `set -e` and no `exit`: every step is chained
# with &&, so the first failure skips the rest and the outcome is printed on the last line.
#
#   ./scripts/build-app.sh             build for this Mac's architecture
#   ./scripts/build-app.sh universal   build a universal (arm64 + x86_64) binary

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/WorkPulse.app"
ARCHS=""
[ "$1" = "universal" ] && ARCHS="--arch arm64 --arch x86_64"

cd "$ROOT" &&
swift build -c release $ARCHS &&
BIN="$(swift build -c release $ARCHS --show-bin-path)/WorkPulse" &&
{ [ -f Packaging/AppIcon.icns ] || {
    swift scripts/make-icon.swift build/AppIcon.iconset &&
    iconutil -c icns build/AppIcon.iconset -o Packaging/AppIcon.icns; }; } &&
rm -rf "$APP" &&
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" &&
cp "$BIN" "$APP/Contents/MacOS/WorkPulse" &&
cp Packaging/Info.plist "$APP/Contents/Info.plist" &&
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" &&
cp scripts/agent-hook.sh "$APP/Contents/Resources/agent-hook.sh" &&
chmod 755 "$APP/Contents/Resources/agent-hook.sh" &&
# Ad-hoc signature ("-"): needs no Apple Developer account. It satisfies macOS on the Mac that
# built it; it is not a Developer ID signature and the app is not notarized.
codesign --force --sign - --identifier com.workpulse.app "$APP" &&
codesign --verify --strict "$APP" &&
echo "OK: built $APP" || echo "FAILED: WorkPulse.app was not built (see the first error above)" >&2
