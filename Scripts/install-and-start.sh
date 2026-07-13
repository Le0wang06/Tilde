#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TildeDiagnostics

BIN="$ROOT/.build/debug/TildeDiagnostics"
APP_SRC="$ROOT/.build/Tilde.app"
APP_DST="$HOME/Applications/Tilde.app"

rm -rf "$APP_SRC"
mkdir -p "$APP_SRC/Contents/MacOS"
cp "$BIN" "$APP_SRC/Contents/MacOS/TildeDiagnostics"
cp "$ROOT/Sources/TildeDiagnosticsApp/Info.plist" "$APP_SRC/Contents/Info.plist"

mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

LABEL="local.tilde.diagnostics"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_DST}/Contents/MacOS/TildeDiagnostics</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null || true

pkill -f 'TildeDiagnostics' 2>/dev/null || true
sleep 0.4
open "$APP_DST"
echo "Tilde installed to $APP_DST and set to launch at login."
