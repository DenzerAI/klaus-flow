#!/usr/bin/env bash
# KlausFlow build + deploy script.
# Compiles klaus-flow.swift, swaps the running .app binary, restarts the app.
#
# Usage:
#   ./build.sh             # build + deploy + restart
#   ./build.sh --no-restart
#   ./build.sh --build-only

set -euo pipefail

SRC_DIR="/Users/christian/.klaus-flow"
SRC="$SRC_DIR/klaus-flow.swift"
APP_DIR="/Users/christian/Applications/Klaus.app"
TARGET_BIN="$APP_DIR/Contents/MacOS/klaus-flow"
TMP_BIN="$SRC_DIR/klaus-flow.build"
LOG="$SRC_DIR/build.log"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/ai.denzer.klaus.plist"

RESTART=1
DEPLOY=1
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    --build-only) RESTART=0; DEPLOY=0 ;;
    -h|--help)
      echo "Usage: $0 [--no-restart|--build-only]"
      exit 0
      ;;
  esac
done

echo "[build] swiftc -> $TMP_BIN"
swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  "$SRC" \
  -o "$TMP_BIN" 2>&1 | tee "$LOG"

if [[ ! -x "$TMP_BIN" ]]; then
  echo "[build] FAILED — binary not produced"
  exit 1
fi

echo "[build] ok ($(stat -f%z "$TMP_BIN") bytes)"

# Ad-hoc re-sign so the embedded signing ID matches the final filename.
# Without this, launchctl-based restarts trip Launch Constraint Violations
# because swiftc embeds "klaus-flow.build" as the codesigning ID.
codesign --force --sign - "$TMP_BIN" 2>&1 | sed 's/^/[build] /' || true

if [[ "$DEPLOY" -eq 0 ]]; then
  echo "[build] --build-only: leaving binary at $TMP_BIN"
  exit 0
fi

# Copy binary BEFORE touching the running process — launchd has KeepAlive=true,
# so any kill triggers an instant respawn. We need the new binary on disk first.
echo "[deploy] $TMP_BIN -> $TARGET_BIN"
cp "$TMP_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
rm -f "$TMP_BIN"

# Deep re-sign the whole bundle so Gatekeeper/TCC accept it after the binary swap.
# Required because copying a new binary invalidates the bundle-level seal.
echo "[deploy] deep-resign bundle"
codesign --force --deep --sign - --identifier ai.denzer.klaus "$APP_DIR" 2>&1 | sed 's/^/[deploy] /' || true

if [[ "$RESTART" -eq 1 ]]; then
  echo "[deploy] reload launchd service ($LAUNCH_PLIST)"
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  sleep 0.3
  launchctl load "$LAUNCH_PLIST"
fi

echo "[done] klaus-flow updated"
