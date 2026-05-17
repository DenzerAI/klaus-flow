#!/usr/bin/env bash
# Klaus Flow — portable installer for a fresh Mac.
# Creates the .app bundle in ~/Applications, compiles the binary,
# installs the LaunchAgent, and leaves Klaus ready to start.
#
# Prerequisites:
#   - Xcode Command Line Tools (`xcode-select --install`)
#   - GROQ_API_KEY env var or set later via Klaus preferences UI
#
# Usage:
#   ./install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
SRC_DIR="$HOME_DIR/.klaus-flow"
APP_DIR="$HOME_DIR/Applications/Klaus.app"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_AGENTS_DIR/ai.denzer.klaus.plist"

echo "[install] repo:  $REPO_DIR"
echo "[install] src:   $SRC_DIR"
echo "[install] app:   $APP_DIR"

# 1. Stage source files into ~/.klaus-flow
mkdir -p "$SRC_DIR/logs"
cp "$REPO_DIR/klaus-flow.swift" "$SRC_DIR/klaus-flow.swift"
cp "$REPO_DIR/dictionary.json" "$SRC_DIR/dictionary.json"
cp "$REPO_DIR/local_whisper_transcribe.py" "$SRC_DIR/local_whisper_transcribe.py" 2>/dev/null || true
cp "$REPO_DIR/klaus-flow.entitlements" "$SRC_DIR/klaus-flow.entitlements" 2>/dev/null || true
if [[ -d "$REPO_DIR/sounds" ]]; then
  rsync -a "$REPO_DIR/sounds/" "$SRC_DIR/sounds/"
fi

# 2. Build the binary
echo "[install] compiling klaus-flow.swift"
swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  "$SRC_DIR/klaus-flow.swift" \
  -o "$SRC_DIR/klaus-flow.build"
codesign --force --sign - "$SRC_DIR/klaus-flow.build"

# 3. Assemble the .app bundle
echo "[install] creating bundle at $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$REPO_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
[[ -f "$REPO_DIR/AppIcon.icns" ]] && cp "$REPO_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
mv "$SRC_DIR/klaus-flow.build" "$APP_DIR/Contents/MacOS/klaus-flow"
chmod +x "$APP_DIR/Contents/MacOS/klaus-flow"
codesign --force --deep --sign - --identifier ai.denzer.klaus "$APP_DIR"

# 4. Install LaunchAgent (HOME path substituted into template)
echo "[install] installing LaunchAgent"
mkdir -p "$LAUNCH_AGENTS_DIR"
sed "s|__HOME__|$HOME_DIR|g" "$REPO_DIR/ai.denzer.klaus.plist.template" > "$LAUNCH_PLIST"

# 5. Reload launchd
launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
launchctl load "$LAUNCH_PLIST"

cat <<EOF

[done] Klaus installiert.

Nächste Schritte:
  1. Systemeinstellungen → Datenschutz & Sicherheit:
     - Mikrofon: Klaus erlauben
     - Bedienungshilfen: Klaus erlauben (für globale Hotkeys + Auto-Paste)
  2. GROQ_API_KEY setzen — entweder im Klaus-Preferences-Fenster (Menübar)
     oder als Env-Var im LaunchAgent.
  3. Push-to-Talk: Right Cmd halten und sprechen.

Updates: ./build.sh   (im Repo; nimmt diesen install.sh-Layout an)
EOF
