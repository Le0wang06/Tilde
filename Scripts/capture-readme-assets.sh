#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TildeDiagnostics

BIN="$ROOT/.build/debug/TildeDiagnostics"
APP="$ROOT/.build/Tilde.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TildeDiagnostics"
cp "$ROOT/Sources/TildeDiagnosticsApp/Info.plist" "$APP/Contents/Info.plist"

pkill -f '/Tilde.app/Contents/MacOS/TildeDiagnostics' 2>/dev/null || true
sleep 0.3

# Screen Recording permission may be required the first time.
"$APP/Contents/MacOS/TildeDiagnostics" --capture-readme
