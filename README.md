# Klaus Flow

Lokale macOS Push-to-Talk-Transkriptions-App. Hält Right-Cmd, spricht, lässt
Klaus per Groq Whisper transkribieren und pasted das Ergebnis in die fokussierte
App. Optional: Polish/Translate/Roleplay/Emoji-Postprocessing, WoW-aware
Chat-Insert, Forward an einen Klaus-Bot, Pane-Hotkeys (Cmd+1..4) für ein
remote Web-Frontend.

Verteilung: **kein App-Store, keine DMG.** Klaus wird per Claude Code aus
diesem Repo auf jedem neuen Rechner gebaut und installiert.

## Install auf einem neuen Mac

Voraussetzungen:
- macOS (arm64 oder x86_64)
- Xcode Command Line Tools — `xcode-select --install`
- Ein [Groq API Key](https://console.groq.com/keys) (für Whisper-Transkription)

```bash
git clone https://github.com/denzerai/klaus-flow.git ~/.klaus-flow
cd ~/.klaus-flow
./install.sh
```

`install.sh` baut die Binary, legt das Bundle in `~/Applications/Klaus.app`
an und installiert den LaunchAgent. Danach:

1. **Systemeinstellungen → Datenschutz & Sicherheit**:
   - Mikrofon → Klaus erlauben
   - Bedienungshilfen → Klaus erlauben (für globale Hotkeys + Auto-Paste)
2. Klaus-Menübar-Icon → Preferences → **GROQ_API_KEY** eintragen (`gsk_…`).
3. **Right Cmd halten und sprechen** → Loslassen pasted die Transkription.

Fallback-Hotkey falls Right Cmd nicht durchkommt: `Ctrl+Shift+Space`.

## Architektur (Kurz)

- **Source**: `klaus-flow.swift` (~150 KB, Swift + AppKit + Carbon.HIToolbox + AVFoundation)
- **Bundle-ID**: `ai.denzer.klaus`
- **Audio-Pipeline**: AVAudioRecorder → Groq Whisper → optional Postprocess → Auto-Paste
- **Persistenz**: `~/.klaus-flow/` (Logs, Dictionary, Sounds, optional pane-token)
- **LaunchAgent**: `~/Library/LaunchAgents/ai.denzer.klaus.plist` (KeepAlive=true)

## Dev-Workflow

Auf Christians Mac (oder mit angepassten Pfaden):

```bash
./build.sh                # rebuild + redeploy + LaunchAgent reload
./build.sh --no-restart   # nur deploy, kein launchctl reload
./build.sh --build-only   # nur compile, kein deploy
```

`build.sh` hat hartkodierte Pfade auf `~/.klaus-flow` und
`~/Applications/Klaus.app` — passen, sobald `install.sh` einmal lief.

## Konfiguration

Setzbar im Klaus-Preferences-Fenster (Menübar-Icon → Settings):
- **GROQ_API_KEY** — Groq Whisper Auth
- **Pane-Endpoint + Token** — optional, für Cmd+1..4 Forwarding ans Web-Frontend
- **Dictionary** — `dictionary.json`, custom transcription replacements

Optionale Env-Vars (im LaunchAgent setzen):
- `GROQ_API_KEY` — Override für UI-gespeicherten Key
- `KLAUSFLOW_PANE_TOKEN` — Override für Pane-Auth-Token

## Lizenz

Privat. Kein Public-License — nutzen auf eigene Verantwortung.
