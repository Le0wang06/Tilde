#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TildeDiagnostics "$@"

BIN="$ROOT/.build/debug/TildeDiagnostics"
if [[ ! -x "$BIN" ]]; then
  BIN="$ROOT/.build/release/TildeDiagnostics"
fi

APP="$ROOT/.build/Tilde.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TildeDiagnostics"
cp "$ROOT/Sources/TildeDiagnosticsApp/Info.plist" "$APP/Contents/Info.plist"

# Register the tilde:// scheme with Launch Services for this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

open "$APP"
