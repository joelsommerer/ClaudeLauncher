# ClaudeLauncher

Eine native macOS-App, die sich in den Finder integriert und Claude Code im Terminal am aktuellen Pfad öffnet — wahlweise mit der Anthropic-API oder einem lokalen LLM (Ollama / LM Studio).

## Features

- **Finder-Toolbar-Integration** mit einem Klick: Picker-Popup zeigt alle konfigurierten Verbindungen, Default ganz oben mit Stern-Badge.
- **Quick Actions** pro Verbindung im Rechtsklick-Menü auf Ordner.
- **Settings-UI** zum Verwalten von Verbindungen (Anthropic API, Ollama-Modelle, LM Studio-Modelle) — Default markieren, Auto-Discovery installierter Modelle.
- **Eingebauter HTTP-Proxy** (in Swift, keine externen Dependencies wie `npm` oder `python` nötig). Übersetzt:
  - Anthropic `/v1/messages` ↔ OpenAI Chat Completions (LM Studio)
  - Anthropic `/v1/messages` ↔ Ollama `/api/chat`
  - Vollständige **Tool-Use-Translation** in beide Richtungen — Claude Codes Bash/Read/Edit-Tools werden zu OpenAI-Function-Calls und tool_calls vom Modell wieder zurück zu Anthropic `tool_use`-Blocks. Streaming und non-streaming.
- **Auto-Sync** der Finder-Integrationen: wenn du eine Verbindung hinzufügst/umbenennst/löschst, werden Quick Actions automatisch aktualisiert.
- Konfiguration als JSON in `~/Library/Application Support/ClaudeLauncher/config.json`.

## Installation (Endnutzer)

1. Aktuelles `ClaudeLauncher-X.Y.dmg` aus den [Releases](../../releases) herunterladen.
2. DMG öffnen und `ClaudeLauncher.app` nach `Applications` ziehen.
3. **Beim ersten Start:** Rechtsklick auf die App in `/Applications` → "Öffnen" → "Öffnen" bestätigen. (Gatekeeper-Prompt, weil die App nur ad-hoc-signiert ist — eine offizielle Apple-Developer-Signatur kostet $99/Jahr und ist nicht enthalten.)
4. App öffnet sich, Settings-UI erscheint. Verbindungen anlegen, Default markieren.
5. Über `Installieren → In Finder-Toolbar einfügen` wird ein `Claude ▾`-Button automatisch in die Finder-Toolbar gepatcht (Finder restartet einmal kurz).

## Verwendung

- **Klick auf `Claude ▾`** in der Finder-Toolbar → Popup-Menü mit allen Verbindungen erscheint, Default ganz oben.
- Auswahl → Terminal öffnet am aktuellen Finder-Pfad, Claude Code startet mit der gewählten Verbindung. Ein Banner zeigt welche.
- **Rechtsklick auf einen Ordner** im Finder → unter "Quick Actions" eine `Claude · <Name>`-Action pro Verbindung (sofern installiert).

## Selber bauen

Voraussetzungen: macOS 14+, Apple Silicon, Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh        # erzeugt build/ClaudeLauncher.app
./package.sh      # erzeugt zusätzlich dist/ClaudeLauncher-1.0.dmg
```

Kein Xcode-Projekt nötig — `swiftc` baut direkt in ein `.app`-Bundle.

## Architektur

```
Sources/                  Swift-Code (SwiftUI + Network.framework HTTP-Server)
├── main.swift            CLI args, NSApp bootstrap
├── AppDelegate.swift     Settings-Window
├── Connection*.swift     Datenmodell + JSON-Persistenz
├── ContentView.swift     SwiftUI Settings-UI
├── ConnectionEditView.swift
├── Picker.swift          Finder-Toolbar-Popup mit eigenem Window
├── ProxyServer.swift     HTTP-Server (Network.framework)
├── ProxyTranslator.swift Anthropic ↔ OpenAI Format-Translation
├── ProxyManager.swift    Proxy-Daemon-Lifecycle
├── HTTPParser.swift      HTTP/1.1 Request-Parser
├── FinderService.swift   Aktuelle Finder-Pfade via AppleScript
├── TerminalLauncher.swift Terminal.app öffnen + claude starten
├── ClaudeFinder.swift    Auffinden des `claude`-Binaries
├── ModelDiscovery.swift  Ollama/LM Studio Modell-Listen
├── QuickActionInstaller.swift   Generiert Automator .workflow-Bundles
├── ToolbarAppInstaller.swift    Generiert Wrapper-.app für Toolbar
├── FinderToolbarManager.swift   Patcht Finder-Prefs für Auto-Toolbar
└── AutoSync.swift        Hält Integrationen mit Connection-Edits in Sync

Resources/
├── Info.plist            Bundle-Metadaten
└── AppIcon.icns          App-Icon (10 Auflösungen, 16-1024px)

build.sh                  Kompiliert + erzeugt .app-Bundle
package.sh                Codesignt + erzeugt DMG
import-icon.sh            PNG → AppIcon.icns
make-icon.swift           Generiert prozedurales Fallback-Icon
```

## Wichtig — `--bare`-Modus für lokale LLMs

Wenn du Claude Code via Pro/Max-Subscription nutzt, ignoriert es normalerweise `ANTHROPIC_BASE_URL` und `ANTHROPIC_API_KEY` und verwendet die OAuth-Anmeldung. Damit Claude Code durch unseren Proxy spricht, startet der Launcher es mit `--bare` für lokale Verbindungen — das deaktiviert OAuth/Keychain. Skills und Slash-Commands funktionieren weiter; deaktiviert werden Hooks, LSP, Plugin-Sync, Auto-Memory, CLAUDE.md-Auto-Discovery. Anthropic-Verbindungen laufen ohne `--bare`.

## Tool-Use mit lokalen LLMs

Die Tool-Translation ist implementiert — `Bash`, `Read`, `Edit` etc. funktionieren auch lokal, sofern das Modell selbst Function-Calling beherrscht. Empfohlen: tool-fähige Modelle wie `qwen3-coder-next`, `qwen2.5-coder:32b`, oder `llama3.3:70b`. Kleinere Modelle erkennen das Tool-Schema oft nicht zuverlässig.

## License

Apache License 2.0 — siehe [LICENSE](LICENSE) und [NOTICE](NOTICE).
