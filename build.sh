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
APP_DIR="/Users/christian/Applications/Klaus Flow.app"
TARGET_BIN="$APP_DIR/Contents/MacOS/klaus-flow"
TMP_BIN="$SRC_DIR/klaus-flow.build"
LOG="$SRC_DIR/build.log"

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

if [[ "$DEPLOY" -eq 0 ]]; then
  echo "[build] --build-only: leaving binary at $TMP_BIN"
  exit 0
fi

if [[ "$RESTART" -eq 1 ]]; then
  RUNNING_PID="$(pgrep -f "Klaus Flow.app/Contents/MacOS/klaus-flow" || true)"
  if [[ -n "$RUNNING_PID" ]]; then
    echo "[deploy] killing running klaus-flow (pid $RUNNING_PID)"
    kill "$RUNNING_PID" || true
    sleep 0.4
  fi
fi

echo "[deploy] $TMP_BIN -> $TARGET_BIN"
cp "$TMP_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
rm -f "$TMP_BIN"

if [[ "$RESTART" -eq 1 ]]; then
  echo "[deploy] launching"
  open -a "$APP_DIR"
fi

echo "[done] klaus-flow updated"
