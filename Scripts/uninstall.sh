#!/bin/zsh
# Reverse of install-and-start.sh: stop the LaunchAgent, remove the app bundle,
# and optionally (--purge) remove Tilde's Application Support data.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "usage: $0 [--purge]"
      echo "  --purge   also remove ~/Library/Application Support/Tilde"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

LABEL="local.tilde.diagnostics"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
APP_DST="$HOME/Applications/Tilde.app"
SUPPORT_DIR="$HOME/Library/Application Support/Tilde"

removed=()

if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  removed+=("LaunchAgent ${LABEL} (booted out)")
fi

if [[ -f "$PLIST" ]]; then
  rm -f "$PLIST"
  removed+=("$PLIST")
fi

if pkill -f "${APP_DST}/Contents/MacOS/TildeDiagnostics" 2>/dev/null || pkill -x TildeDiagnostics 2>/dev/null; then
  sleep 0.4
  removed+=("running TildeDiagnostics process")
fi

if [[ -d "$APP_DST" ]]; then
  rm -rf "$APP_DST"
  removed+=("$APP_DST")
fi

if (( PURGE )); then
  if [[ -d "$SUPPORT_DIR" ]]; then
    rm -rf "$SUPPORT_DIR"
    removed+=("$SUPPORT_DIR")
  fi
fi

if (( ${#removed[@]} == 0 )); then
  echo "Nothing to remove: Tilde is not installed."
else
  echo "Removed:"
  for item in "${removed[@]}"; do
    echo "  - $item"
  done
fi

if (( ! PURGE )) && [[ -d "$SUPPORT_DIR" ]]; then
  echo "Kept $SUPPORT_DIR (receipts, spend counters, diary). Re-run with --purge to remove it."
fi
