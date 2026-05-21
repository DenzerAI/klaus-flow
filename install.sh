#!/usr/bin/env bash
# Klaus Flow — portable installer for a fresh Mac.
#
# Usage (One-Liner für frische Macs):
#   curl -fsSL https://raw.githubusercontent.com/denzerai/klaus-flow/main/install.sh | bash
#
# Usage (aus geclontem Repo):
#   ./install.sh
#
# Was passiert:
#   1. Xcode-CLT-Check (Hinweis falls fehlt)
#   2. Repo nach ~/.klaus-flow clonen (falls nicht schon da)
#   3. klaus-flow.swift kompilieren + signieren
#   4. App-Bundle in ~/Applications/Klaus.app anlegen
#   5. LaunchAgent installieren und starten
#   6. Systemeinstellungen für Mikrofon-Permission aufrufen
#   7. Klaus' Settings-Fenster öffnen, damit du den Groq-API-Key eintragen kannst

set -euo pipefail

REPO_URL="https://github.com/denzerai/klaus-flow.git"
HOME_DIR="$HOME"
SRC_DIR="$HOME_DIR/.klaus-flow"
APP_DIR="$HOME_DIR/Applications/Klaus.app"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_AGENTS_DIR/ai.denzer.klaus.plist"

echo
echo "╭─────────────────────────────────────────────────╮"
echo "│  Klaus Flow — Installer                         │"
echo "╰─────────────────────────────────────────────────╯"
echo

# --- 1) Xcode Command Line Tools ---
if ! xcode-select -p >/dev/null 2>&1; then
  echo "[install] Xcode Command Line Tools fehlen."
  echo "[install] Bitte einmal ausführen:"
  echo
  echo "    xcode-select --install"
  echo
  echo "[install] Wenn die Installation durch ist, diesen Installer erneut starten."
  exit 1
fi

# --- 2) Repo lokalisieren (oder clonen) ---
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
REPO_DIR=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  CANDIDATE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  if [[ -f "$CANDIDATE/klaus-flow.swift" ]]; then
    REPO_DIR="$CANDIDATE"
  fi
fi

if [[ -z "$REPO_DIR" ]]; then
  echo "[install] Lade Klaus Flow von $REPO_URL"
  if [[ -d "$SRC_DIR/.git" ]]; then
    echo "[install]   existierendes Repo gefunden → pull"
    (cd "$SRC_DIR" && git pull --ff-only)
  else
    if [[ -d "$SRC_DIR" && ! -d "$SRC_DIR/.git" ]]; then
      BACKUP="$SRC_DIR.bak.$(date +%s)"
      echo "[install]   $SRC_DIR existiert ohne .git → backup nach $BACKUP"
      mv "$SRC_DIR" "$BACKUP"
    fi
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
  fi
  REPO_DIR="$SRC_DIR"
fi

echo "[install] repo:  $REPO_DIR"
echo "[install] src:   $SRC_DIR"
echo "[install] app:   $APP_DIR"

# --- 3) Source-Dateien in ~/.klaus-flow stagen (nur falls REPO_DIR != SRC_DIR) ---
mkdir -p "$SRC_DIR/logs"
if [[ "$REPO_DIR" != "$SRC_DIR" ]]; then
  cp "$REPO_DIR/klaus-flow.swift" "$SRC_DIR/klaus-flow.swift"
  cp "$REPO_DIR/dictionary.json" "$SRC_DIR/dictionary.json"
  cp "$REPO_DIR/local_whisper_transcribe.py" "$SRC_DIR/local_whisper_transcribe.py" 2>/dev/null || true
  cp "$REPO_DIR/klaus-flow.entitlements" "$SRC_DIR/klaus-flow.entitlements" 2>/dev/null || true
  if [[ -d "$REPO_DIR/sounds" ]]; then
    rsync -a "$REPO_DIR/sounds/" "$SRC_DIR/sounds/"
  fi
fi

# --- 4) Binary kompilieren ---
echo "[install] kompiliere klaus-flow.swift…"
swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  "$SRC_DIR/klaus-flow.swift" \
  -o "$SRC_DIR/klaus-flow.build"
codesign --force --sign - "$SRC_DIR/klaus-flow.build" 2>&1 | sed 's/^/[install]   /' || true

# --- 5) App-Bundle ---
echo "[install] baue Bundle in $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$REPO_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
[[ -f "$REPO_DIR/AppIcon.icns" ]] && cp "$REPO_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
[[ -f "$REPO_DIR/klaus.svg" ]] && cp "$REPO_DIR/klaus.svg" "$APP_DIR/Contents/Resources/klaus.svg"
[[ -f "$REPO_DIR/klaus-light.svg" ]] && cp "$REPO_DIR/klaus-light.svg" "$APP_DIR/Contents/Resources/klaus-light.svg"
mv "$SRC_DIR/klaus-flow.build" "$APP_DIR/Contents/MacOS/klaus-flow"
chmod +x "$APP_DIR/Contents/MacOS/klaus-flow"
codesign --force --deep --sign - --identifier ai.denzer.klaus "$APP_DIR" 2>&1 | sed 's/^/[install]   /' || true

# --- 6) LaunchAgent (HOME path substituted into template) ---
echo "[install] installiere LaunchAgent"
mkdir -p "$LAUNCH_AGENTS_DIR"
sed "s|__HOME__|$HOME_DIR|g" "$REPO_DIR/ai.denzer.klaus.plist.template" > "$LAUNCH_PLIST"

launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
launchctl load "$LAUNCH_PLIST"

# --- 7) Erfolgs-Meldung + Settings öffnen ---
cat <<'EOF'

╭─────────────────────────────────────────────────────────╮
│  ✓ Klaus läuft.                                         │
╰─────────────────────────────────────────────────────────╯

Letzte Schritte (einmalig):

  1. Mikrofon erlauben
     System­einstellungen öffnet sich gleich.

  2. Bedienungshilfen erlauben (für globale Hotkeys + Auto-Paste)
     System­einstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Klaus

  3. Groq API Key eintragen
     Klaus-Menüleisten-Icon → Einstellungen
     (Key holen: https://console.groq.com/keys)

Wenn alles erlaubt + Key gesetzt:
  → Right ⌘ halten · sprechen · loslassen.

EOF

# Mikrofon-Berechtigung-Panel öffnen, damit der User nicht selbst suchen muss
if command -v open >/dev/null 2>&1; then
  sleep 1
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
fi
