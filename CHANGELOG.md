# Änderungen

## 0.10.0 – 2026-11-20

- **Kacheln umsortieren:** `blp_change` mit `aktion: verschieben` setzt ein Listenelement an eine andere Stelle derselben Liste; `wert` = Position ab 0, `anfang`, `ende`, `{vor: "[name=X]"}` oder `{nach: "[name=X]"}`. Gedacht für Kacheln im Tab (`baustein: client/sidebar/tab/action`, Pfad `tiles/[name=Kachel]`), geht aber in jeder Liste. Vorschau und Kontrolle nach dem Speichern vergleichen die ganze Reihenfolge. Auf Test erprobt (verschoben und zurück).
- **Kachel entfernen:** Die Vorschau von `blp_change … aktion entfernen` an einem Tab nennt die Rollen und Situationen, deren Tab-Einträge die Kachel noch führen; das Ergebnis (`rollenEintraege`) zeigt, ob nach dem Speichern noch welche stehen.
- **Veröffentlichungsstand:** `blp_published` vergleicht die Speicherzeiten von Prozessen, Geschäftsobjekten, Tabs, Rollen, Suchprofilen, Triggern, Auswahlbaum und Feldverwaltung mit der letzten Veröffentlichung am Client-Dienst und nennt, was danach gespeichert wurde (`stand`, `jeArt`, `bausteine`); `pruefen: false` zeigt nur die Projekte. Module und Datenabfragen prüft es nicht. Befund: Beim Speichern eines Tabs speichert der Dienst alle Rollen mit.
- Offline-Test um `verschieben` erweitert (66 Prüfungen).
- **Desktop-Plug-ins und Smart Search:** `blp_desktop_plugins` listet installierte Plug-ins mit Designer-Konfigurationsrouten. `blp_smartsearch_commands` zeigt Befehle, Plug-in-IDs, Optionen und Pfade zur Bearbeitung über `blp_change`.
- `blp_module_install` importiert lokale `.mod`-Pakete nach Vorschau und Freigabe, sichert ein vorhandenes Paket und vergleicht den anschließenden Download per SHA-256.
- **Zeitplan-Trigger:** `blp_triggers` listet die Trigger mit Prozess, Schalter und Zeitplan als Satz (z. B. „woechentlich Mo-Sa, 06:00-17:00, alle 10 Minuten“), mit `trigger` einen Trigger mit Rohzeitplan, Beschreibung und Pfaden zum Ändern.
- `blp_create_trigger` legt einen Trigger an (zweistufig, `PUT triggermanager`): täglich oder wöchentlich mit Wochentagen („Mo-Sa“, „Mo,Mi,Fr“), Zeitfenster, Wiederholung in Sekunden (ab 30), Minuten oder Stunden, `aktiv` Pflicht. Vorschau mit dem ganzen Rumpf, Warnung, wenn schon ein Trigger denselben Prozess startet; vorher wird die Triggerliste gesichert.
- `blp_change` und `blp_read_path` mit `baustein: triggermanager` (`objekt` = Triggername), z. B. `enabled` oder `schedule/repeat/every`. Geprüft wird vor dem Speichern (Art, Einheit, Uhrzeiten, wöchentlich ohne Tag). Speicherweg wie bei Prozessen (checkout, speichern, commit), erprobt auf Test.
- `test-offline.ps1`: Offline-Tests ohne BLP und Zugangsdaten (Zeitplan bauen und lesen, Prüfung, Werkzeugliste, Start ohne Konfiguration).
- `docs/BLP-API.md`: `triggermanager` mit Feldern und Zahlenwerten.

## 0.9.0 – 2026-11-12

- **Laufberichte:** `blp_reports` liest den Berichtsdienst des BLP. Ohne `bericht` eine Übersicht für einen Zeitraum (`seit`/`bis`: `05:40`, `2026-11-12 05:40`, `4h`, `2d`): Läufe je Prozess mit Status, Kind-Läufe, die nicht `Done` sind, auffällige Läufe mit `transaction_id`, mit `alle` jeder Lauf. Mit `bericht` ein Einzelbericht: Benutzer, mitgegebene Parameter der Feldverwaltung, Schritte mit Baustein, Status, Ausgang und Laufzeit, Warn- und Fehlermeldungen, Kind-Läufe; mit `suche` alle Meldungen mit einem Text. Der Server umgeht die unzuverlässige Seitenzählung des Dienstes (sucht das Ende selbst, springt per Halbierung zum Zeitraum) und zeigt Ortszeit statt UTC.
- **Suche im ganzen Projekt:** `blp_search` holt den Full Export (wie im Designer) und durchsucht ihn ganz, auch eingebettetes JSON. Treffer mit Bereich, Objekt, Pfad und Ausschnitt; für Prozesse, Objekte, Feldverwaltung, Rollen, Suchprofile und Module passend für `blp_change`. Der Export bleibt nur im Speicher (drei Minuten), Geheimnisse erscheinen als `***`, das Bildpaket nur auf Wunsch.
- **Feldverwaltung ändern:** `blp_change` und `blp_read_path` mit `baustein: fieldmanager` (ohne `objekt`), z. B. `parameters/[name=ECMServer]/value`. Gleicher Weg wie beim Auswahlbaum (checkout, speichern, commit), auf Test und Produktiv erprobt.
- Neue optionale Einstellung `reportUrl` je Umgebung (Berichtsdienst); ohne Angabe der Port zehn über dem Identity-Dienst. Im Paket für Claude Desktop als „Berichtsdienst (optional)“.
- Behoben: Zwei Änderungen in derselben Sekunde schrieben ihre Sicherung in dieselbe Datei, die erste ging verloren. Sicherungen tragen jetzt Version und Millisekunden im Namen.
- `docs/BLP-API.md`: Berichtsdienst und Full Export.

## 0.8.0 – 2026-11-11

Erstes Release seit 0.6.0, enthält auch 0.7.0 (Pull Requests #1 und #2).

- **Datenabfragen mit Inhalt:** `blp_dataquery` zeigt eine Abfrage mit SQL-Text, Feldzuordnung, Schaltern, Quelle und Anmeldeprofil (SQL, OleDb) bzw. Teilabfragen und Spalten (GroupQueries), dazu die Gruppenabfragen, die eine SQL-Abfrage benutzen, und die Pfade zum Ändern. Ohne `abfrage` die Übersicht je Add-in.
- `blp_change` und `blp_read_path` mit `baustein: dataquery` (`objekt` = Add-in wie SQL oder GroupQueries). Gespeichert wird wie bei der Modulkonfiguration ohne checkout/undo, vorher Sicherung; `blp_module_restore` spielt auch Sicherungen von Datenabfragen zurück.
- Verbindungszeichenfolgen (`ConnectionString`) werden in allen Antworten ausgeblendet.
- `docs/BLP-API.md`: `dataquerymanager/<Modul-ID>/<Add-in-ID>` und wie der Designer die Add-in-Seiten versorgt.
- Aufgeräumt: `Entpacke` gibt es nur noch einmal (in `blp-mcp-bauen.ps1`); die gleichlautende Kopie in `blp-mcp-module.ps1` hat sie beim Laden überschrieben.

## 0.7.0 – 2026-11-10

- **Modulkonfigurationen** (Validation, AI.Foundation, AI OCR, PDF-Processor, elo, …): `blp_modules` listet die Module mit ihrer Konfiguration im Projekt, `blp_module` zeigt eine Konfiguration ausgepackt (Kurzansicht für Validation und AI.Foundation, sonst Gliederung, `voll` als Datei).
- `blp_change` und `blp_read_path` mit `baustein: module`. Speichern ohne checkout/undo, sofort festgeschrieben; vorher Sicherung, zurück mit dem neuen `blp_module_restore`.
- Werte mit `***` (abgeschriebene, maskierte Antworten) lehnt `blp_change` ab, damit keine Zugangsdaten oder Schlüssel überschrieben werden.
- Klarere Meldung bei JSON mit Schlüsseln, die sich nur in Groß-/Kleinschreibung unterscheiden.
- `docs/BLP-API.md`: Speicherweg der Modulkonfiguration, Sperre nach veraltetem Token, wo die Datenabfragen liegen.

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
