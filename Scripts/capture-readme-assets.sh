#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TildeDiagnostics

BIN="$ROOT/.build/debug/TildeDiagnostics"
APP="$ROOT/.build/Tilde.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TildeDiagnostics"
cp "$ROOT/Sources/TildeDiagnosticsApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/TildeDiagnosticsApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$ROOT/Sources/TildeDiagnosticsApp/Resources/tilde-logo.png" "$APP/Contents/Resources/tilde-logo.png" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

pkill -f '/Tilde.app/Contents/MacOS/TildeDiagnostics' 2>/dev/null || true
pkill -f 'TildeDiagnostics --capture-readme' 2>/dev/null || true
sleep 0.3

# Screen Recording permission may be required the first time.
"$APP/Contents/MacOS/TildeDiagnostics" --capture-readme
