# Klaus Flow

Lokale macOS Push-to-Talk-Transkriptions-App. Halte **Right ⌘**, sprich, lass los — Klaus
transkribiert per **Groq Whisper** (turbo) und pasted das Ergebnis in die fokussierte App.
Optional: Polish/Translate/Roleplay/Emoji-Postprocessing, Pane-Hotkeys (Cmd+1..4) für ein
eigenes Web-Frontend.

Kein App Store, kein DMG. Wird per Source aus diesem Repo auf jedem Mac gebaut.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/denzerai/klaus-flow/main/install.sh | bash
```

Das war's. Der Installer klont das Repo, baut die Binary, signiert sie ad-hoc, legt das
App-Bundle in `~/Applications/Klaus.app` an, installiert den LaunchAgent und startet
Klaus. Danach öffnet sich automatisch das Mikrofon-Berechtigungs-Fenster.

### Was du danach noch machst (einmalig)

1. **Mikrofon erlauben** — Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon → Klaus ✓
2. **Bedienungshilfen erlauben** (für globale Hotkeys + Auto-Paste) — Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Klaus ✓
3. **Groq API Key eintragen** — Klaus-Menüleisten-Icon → Einstellungen → `gsk_…` einfügen
   ([Key holen](https://console.groq.com/keys), Free-Tier reicht zum Testen)

Dann **Right ⌘ halten · sprechen · loslassen** → der Text landet in deiner aktuellen App.

## Voraussetzungen

- macOS 13+ (Apple Silicon oder Intel)
- Xcode Command Line Tools — `xcode-select --install`

## Features

- **Push-to-Talk** mit Right ⌘ (oder beliebige andere Modifier-Taste, einstellbar)
- **Whisper-Large-v3-Turbo** via Groq (~216× Realtime, multilingual, $0.04/h)
- **Polish-Mode** — gesprochenes Deutsch grammatikalisch glätten (Llama 3.3 70B)
- **Translate-Mode** — Deutsch → Englisch
- **Emoji-Mode** — kuratierte Auswahl, nur gelbe Gesichter + Hände + ❤️🔥💯✅
- **Wörterbuch** — eigene Fachbegriffe, die als Whisper-Prompt mitgeschickt werden
  und als Post-Process-Replacement greifen
- **Auto-Paste** — Cmd+V in fokussiertes Feld, optional auch Enter für direktes Senden
- **Pane-Hotkeys** (Cmd+1..4) — optional, schickt Transkripte an einen eigenen Server
  (nur aktiv wenn ein Pane-Token konfiguriert ist; sonst bleiben die Hotkeys frei)
- **Lokaler Fallback** — wenn Groq nicht erreichbar, wird MLX-Whisper-Turbo lokal verwendet
  (benötigt `pip install mlx-whisper`)
- **PTT-Taste umbelegbar** — in den Einstellungen jederzeit auf eine andere Modifier-Taste
  setzen

## Update

Aus dem Repo:

```bash
cd ~/.klaus-flow
git pull
./build.sh
```

Oder einfach den One-Liner nochmal laufen lassen — der Installer pulled automatisch.

## Architektur (Kurz)

- **Source**: `klaus-flow.swift` (~3800 Zeilen Swift, AppKit + AVFoundation + Carbon)
- **Bundle-ID**: `ai.denzer.klaus`
- **Audio-Pipeline**: AVAudioRecorder (16 kHz Mono AAC) → Groq Whisper Turbo → optional Postprocess → Auto-Paste
- **Persistenz**: `~/.klaus-flow/` (logs, dictionary, sounds, optional pane-token)
- **LaunchAgent**: `~/Library/LaunchAgents/ai.denzer.klaus.plist` (KeepAlive=true)

## Dev-Workflow

```bash
cd ~/.klaus-flow
./build.sh                # rebuild + redeploy + LaunchAgent reload
./build.sh --no-restart   # nur deploy, kein launchctl reload
./build.sh --build-only   # nur compile, kein deploy
```

## Konfiguration

In den Klaus-Einstellungen (Menüleisten-Icon → Einstellungen):

- **Groq API Key** — Pflicht für Transkription
- **Polish-Modell** — Groq-Chat-Modell für Polish/Translate/Emoji. Default: `llama-3.3-70b-versatile`
- **Push-to-Talk-Taste** — beliebige Modifier-Taste (⌘/⌥/⌃/⇧/fn, links oder rechts)
- **Wörterbuch** — Hörweise → Schreibweise. Default mit ~30 Tech-Terms vorbefüllt

Optionale Env-Vars (im LaunchAgent setzen):

- `GROQ_API_KEY` — Override für den UI-gespeicherten Key
- `KLAUSFLOW_PANE_TOKEN` — Bearer-Token für Pane-Backend (aktiviert Cmd+1..4)
- `KLAUSFLOW_PANE_ENDPOINT` — URL des Pane-Backends

## Lizenz

MIT — siehe [LICENSE](LICENSE). Nutzen auf eigene Verantwortung; Klaus drückt globale
Hotkeys und liest dein Mikrofon, also nur in eigenen Builds laufen lassen.
