# Änderungen

## 0.6.0 – 2026-10-29

- **Mehrere Umgebungen in einem Server**, z. B. Test und Produktiv: `-Umgebung test,produktiv`. Jedes Werkzeug hat dann den Parameter `umgebung`, ohne Angabe gilt die erste. Die Hinweise an die KI nennen alle Umgebungen und ob dort geändert werden darf.
- Je Umgebung eigene Anmeldung und eigene Zwischenspeicher (Prozessliste, Module, Bausteinkatalog). Ein Freigabe-Code gilt nur in der Umgebung seiner Vorschau. `blp_whoami` listet die Umgebungen.
- `allowChanges` gilt je Umgebung. `-AendernErlauben` gibt es nur noch mit einer Umgebung.
- **MCPB-Paket für Claude Desktop**: `blp-mcp-<version>.mcpb` per Doppelklick installieren. In den Einstellungen Umgebung 1 und optional Umgebung 2 mit Adressen, Projekt-ID, Zugangsdatei und eigenem Schalter fürs Ändern. Projektdienst und Client-Dienst darf man leer lassen, wenn sie einen bzw. acht Ports über dem Identity-Dienst liegen.
- `mcpb\manifest.json`, Startskript `mcpb\mcpb-start.ps1` (schreibt die Einstellungen nach `%LOCALAPPDATA%\blp-mcp\mcpb-config.json`) und `tools\build-mcpb.ps1` (baut reproduzierbar, prüft Version, eingebundene Skripte und Einstellungen, trägt SHA-256 in `server.json` ein).
- `server.json` für die offizielle MCP Registry (`io.github.Herzog-GmbH/blp-mcp`, Paket `mcpb`).
- `Set-BlpCredential.ps1` findet die Einstellungen des Pakets, wenn neben ihm keine `config.local.json` liegt. Fehlen Zugangsdaten, nennt die Meldung den vollen Befehl.
- Mindestens PowerShell 7.5, nicht 7.4: `ConvertFrom-Json -DateKind` gibt es erst ab 7.5. README und AGENTS.md berichtigt.

## 0.5.0 – 2026-10-16

- `blp_process_export`: Prozess als Bauplan (Knoten mit Baustein, Parametern, Feldern, Lage; Verbindungen), große Baupläne als Datei. Ohne `prozess` die Liste der Bausteine mit Ein- und Ausgängen.
- `blp_process_build`: Prozess aus einem Bauplan neu anlegen, als Kopie oder als Ersatz eines vorhandenen, zweistufig.
- `blp_create_object`: Geschäftsobjekt anlegen, leer oder als Kopie einer Vorlage.

## 0.4.0 – 2026-10-16

- Erste öffentliche Fassung: Lesen, Ändern über Pfade (`blp_change`), Neuanlage von Prozessen, Tabs und Kacheln, Auswahlbaum, Bildpaket. Alles Firmenspezifische in `config.local.json`.
