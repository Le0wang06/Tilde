#!/bin/zsh
# Build a release binary and wrap it as dist/Tilde.app plus a versioned zip.
# Usage: ./Scripts/package-app.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/TildeDiagnosticsApp/Info.plist)}"
DIST="$ROOT/dist"
APP="$DIST/Tilde.app"
ZIP="$DIST/Tilde-${VERSION}.zip"

swift build -c release --product TildeDiagnostics

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/TildeDiagnostics" "$APP/Contents/MacOS/TildeDiagnostics"
cp "$ROOT/Sources/TildeDiagnosticsApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/TildeDiagnosticsApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/TildeDiagnosticsApp/Resources/tilde-logo.png" "$APP/Contents/Resources/tilde-logo.png"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# ditto preserves the bundle structure and resource forks the way Finder does.
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

echo "Packaged $APP"
echo "Archive  $ZIP"
cat "$ZIP.sha256"
