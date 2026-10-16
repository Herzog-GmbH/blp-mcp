<div align="center">

# BLP-MCP-Server

**Die ELO-Sidebar per KI pflegen: ACTIWARE Business Logic Provider lesen und gezielt ändern – mit Vorschau, Freigabe und Sicherung.**

[![PowerShell 7](https://img.shields.io/badge/PowerShell-7.4%2B-5391fe)](#kompatibilität)
[![MCP stdio](https://img.shields.io/badge/MCP-stdio-6f42c1)](https://modelcontextprotocol.io/)
[![24 Werkzeuge](https://img.shields.io/badge/Werkzeuge-24-2ea44f)](#werkzeuge)
[![Zweistufige Freigabe](https://img.shields.io/badge/%C3%84ndern-Vorschau%20%2B%20Freigabe-e36209)](#so-läuft-eine-änderung)
<br>
[![Windows](https://img.shields.io/badge/Plattform-Windows-0078d4)](#kompatibilität)
[![Lizenz MIT](https://img.shields.io/github/license/Herzog-GmbH/blp-mcp?label=Lizenz&color=blue)](LICENSE)
[![Letzter Commit](https://img.shields.io/github/last-commit/Herzog-GmbH/blp-mcp?label=letzter%20Commit)](https://github.com/Herzog-GmbH/blp-mcp/commits/main)

[Schnellstart](#schnellstart) · [Werkzeuge](#werkzeuge) · [Änderungen](#so-läuft-eine-änderung) · [Pfadsprache](#pfadsprache) · [Bauplan](#bauplan) · [Sicherheit](#sicherheit) · [Dokumentation](#dokumentation)

</div>

> [!NOTE]
> **English:** MCP server for the ACTIWARE Business Logic Provider (BLP), the designer behind the ELO sidebar. It reads processes, business objects, tabs and tiles, roles, the selection tree and the image package, and changes them through a two-step preview/approval flow with automatic backups, checkout/commit like the Designer and a post-save check. Processes can be exported as a JSON blueprint and built (new, copy or replace) from one. Publishing stays a manual step in the Designer. A single PowerShell 7 script, started by any MCP client over stdio. Docs are in German because BLP's user base is mostly DACH; issues in English are welcome.

Ein [MCP](https://modelcontextprotocol.io/)-Server für den **BLP (ACTIWARE Business Logic Provider)**, also das Werkzeug, mit dem ihr die Sidebar eures ELO-Clients baut: Tabs, Kacheln, Prozesse, Geschäftsobjekte, Rollen. Ihr sagt der KI in normaler Sprache, was ihr wollt, zum Beispiel:

- „Welche Kacheln hat der Tab Buchhaltung, und welcher Prozess hängt an der Kachel Rechnungen?“
- „Leg im Tab Buchhaltung eine Kachel ‚Mahnungen‘ an, wie die Kachel ‚Rechnungen‘, aber mit dem Prozess ‚Mahnung erfassen‘.“
- „Sortier den Bereich Einkauf im Auswahlbaum alphabetisch.“
- „Lade diese drei Symbole hoch und häng sie an die neue Kachel.“
- „Bau einen Prozess: Formular mit Name und Abteilung, dann eine Entscheidung, dann ELOas-Regel X aufrufen.“

Die KI liest die Bausteine über dieselbe REST-API wie der Web-Designer, zeigt euch vor jeder Änderung bisher/neu und ändert erst nach eurer Zustimmung. **Veröffentlichen macht ihr selbst im Designer** – vorher sieht keine Sidebar etwas.

## Auf einen Blick

- **Lesen:** Prozesse mit Knoten, Bausteinnamen und Verbindungen, Geschäftsobjekte mit Feldern, Füllregeln und Kacheln, Sidebar-Tabs, Rollen und Situationen, Feldverwaltung, Datenabfragen, Auswahlbaum, Bildpaket, Stand der Veröffentlichung.
- **Gezielt ändern:** über eine kleine [Pfadsprache](#pfadsprache) statt ganzer JSON-Dokumente – einen Parameter in einem Prozessknoten, eine Kachelfarbe, die Sichtbarkeit eines Tabs in einer Rolle, die Reihenfolge im Auswahlbaum.
- **Neu anlegen:** Prozess als Kopie eines vorhandenen, leerer Sidebar-Tab, Kachel als Kopie einer Vorlage-Kachel, Geschäftsobjekt (leer mit Feldern oder als Kopie).
- **Prozesse bauen:** Prozess als [Bauplan](#bauplan) exportieren (Knoten mit Bausteinnamen, Parameter lesbar entpackt, Verbindungen), ändern oder neu schreiben und daraus einen neuen Prozess, eine Kopie oder den Ersatz des vorhandenen bauen – mit Prüfung von Start, Ausgängen und Erreichbarkeit.
- **Bilder:** PNG-Symbole ins Bildpaket laden, an Kacheln und Tabs hängen, wieder entfernen.
- **Zweistufig:** Der erste Aufruf liefert Prüfung, Vorschau und einen Freigabe-Code. Erst der zweite Aufruf mit denselben Argumenten führt aus – fünf Minuten gültig, einmal, nur wenn sich der Baustein seitdem nicht geändert hat.
- **Abgesichert:** Sicherung vor jeder Änderung, checkout/commit wie im Designer, `undo` bei Fehlern, Kontrolle nach dem Speichern, Protokoll, Maskierung von Passwörtern und Tokens. Produktiv ist standardmäßig nur lesbar.
- **Kein Dienst, keine Installation:** ein PowerShell-Skript, das euer MCP-Client bei Bedarf startet.

## Kompatibilität

| | Getestet bzw. vorausgesetzt |
|---|---|
| **BLP** | Business Logic Provider 6 mit Web-Designer und REST-API (`/api/v1/…`) |
| **Konto** | ein Konto, das im BLP-Projekt Bausteine bearbeiten darf. Bei uns ging das nur mit dem BLP-eigenen `admin`; Windows-Konten bekamen trotz Designer-Rechten „User is not authorized“ |
| **PowerShell** | 7.4 oder neuer (`pwsh`), nicht Windows PowerShell 5.1 |
| **System** | Windows: Zugangsdaten verschlüsselt per DPAPI. Andere Systeme über `BLP_USER`/`BLP_PASSWORD`, nicht getestet |
| **MCP** | stdio (JSON-RPC 2.0), Protokollversion `2025-06-18` |
| **KI-Clients** | Vorlagen für Claude Code, Claude Desktop, VS Code/GitHub Copilot, Cursor, Codex CLI und Gemini CLI in [`docs/CLIENTS.md`](docs/CLIENTS.md) |

## Schnellstart

### A) Von eurer KI einrichten lassen

Repo klonen oder als ZIP entpacken, im Ordner einen KI-Agenten starten (Claude Code, Codex CLI, GitHub Copilot im Agent-Modus, Gemini CLI, Cursor o. Ä.) und eingeben:

```text
Richte diesen BLP-MCP-Server auf diesem Rechner ein. Folge AGENTS.md Schritt für Schritt
und frag mich nie nach Passwörtern im Chat.
```

[`AGENTS.md`](AGENTS.md) enthält den ganzen Ablauf mit Fehlersuche. Für Claude Code (`CLAUDE.md`), Gemini CLI (`GEMINI.md`) und GitHub Copilot (`.github/copilot-instructions.md`) liegen Verweise bei.

### B) Von Hand

1. **Konfiguration anlegen** und Adressen eintragen (Identity, Projektdienst, Client-Dienst je Umgebung):

   ```powershell
   Copy-Item config.example.json config.local.json
   notepad config.local.json
   ```

2. **Zugangsdaten hinterlegen.** Das Skript fragt Benutzer und Passwort ab, speichert sie verschlüsselt, meldet sich an und zeigt die Projekte mit ihren IDs. Die richtige ID kommt in `config.local.json` unter `projectId`.

   ```powershell
   .\Set-BlpCredential.ps1
   ```

3. **Im MCP-Client eintragen**, zum Beispiel in Claude Code:

   ```powershell
   claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1"
   ```

4. **Testen:** „Wer bin ich im BLP?“ – die KI ruft `blp_whoami` auf und zeigt Umgebung, Projekt, Benutzer und ob Ändern freigeschaltet ist.

Eine zweite Umgebung (z. B. Produktiv, nur lesen) registriert ihr als eigenen Server: `claude mcp add blp-prod … -File "…\blp-mcp.ps1" -Umgebung produktiv`.

## Konfiguration

`config.local.json` liegt neben `blp-mcp.ps1` (oder ihr gebt den Pfad mit `-Config` bzw. `BLP_MCP_CONFIG` an). Vorlage mit Erklärungen: [`config.example.json`](config.example.json).

| Schlüssel | Bedeutung |
|---|---|
| `environments.<name>` | je Umgebung `authUrl` (Identity), `projectUrl` (Projektdienst), `clientUrl` (Client-Dienst), `projectId`, `credentialFile`, `allowChanges`, optional `label` und `skipCertificateCheck` |
| `defaultEnvironment` | Umgebung ohne Startschalter; andere mit `-Umgebung <name>` |
| `allowChanges` | ändernde Werkzeuge frei (Standard in der Vorlage: Test ja, Produktiv nein). Überschreiben nur bewusst mit `-AendernErlauben` |
| `skipCertificateCheck` | nur für selbstsignierte Zertifikate, die der Rechner nicht kennt |
| `images` | Name des Bildpakets, eigener Symbolordner (`<farbe>\<motiv>_<24\|32\|64>.png`) und welcher Container zu welcher Farbe gehört |
| `organization`, `extraInstructions` | erscheinen in den Anweisungen an die KI (Firma, Hausregeln) |
| `dataDir` | Ordner für Sicherungen, Protokoll und exportierte Baupläne, Standard `%LOCALAPPDATA%\blp-mcp` |

Zugangsdaten stehen **nie** in der Konfiguration, sondern in der DPAPI-Datei aus `Set-BlpCredential.ps1` oder in `BLP_USER`/`BLP_PASSWORD`.

## Werkzeuge

### Lesen

| Werkzeug | Zweck |
|---|---|
| `blp_whoami` | Umgebung, Projekt, Benutzer, Designer-Rechte, ob Ändern freigeschaltet ist |
| `blp_processes` | alle Prozesse flach (Server, Client, Sub, Vorlagen) mit Ordner, Version, letzter Änderung; Filter |
| `blp_process` | Prozess mit Knoten (Bausteinname, Beschreibung, Parameter gekürzt) und Verbindungen; `knoten` = volle Parameter eines Knotens mit Ein- und Ausgängen; `roh` = ganzes JSON |
| `blp_objects` / `blp_object` | Geschäftsobjekte; Detail mit Feldern, Füllregeln, Suche und Kacheln |
| `blp_tabs` / `blp_tab` | Sidebar-Tabs; Detail mit allen Kacheln (Aktion, Prozess, Farbe, Sichtbarkeit, Bedingung) |
| `blp_roles` | Rollen und Situationen mit Tabs an/aus; mit `rolle` die Kacheln je Tab |
| `blp_fields` | Feldverwaltung: Parameter, Variablen, Datenfelder |
| `blp_dataqueries` | Datenabfragen (Name, Modul, Bedingungs- und Ergebnisfelder, ohne Verbindungsdaten) |
| `blp_selection` | Auswahlbaum des Clients (`client/selection`): Bereich › Dokument › Prozess › Felder, je Bereich ob sortiert |
| `blp_images` | Bildpaket: Container mit Bildern; mit `bild` auch, wo ein Bild benutzt wird |
| `blp_published` | letzte Veröffentlichung am Client-Dienst |
| `blp_read_path` | Wert an einem Pfad lesen (zum Vorbereiten einer Änderung) |
| `blp_get` | beliebiger lesender GET am Projekt- oder Client-Dienst (nur Pfade, keine fremden Adressen) |
| `blp_process_export` | Prozess als [Bauplan](#bauplan) (JSON); große Baupläne als Datei. Ohne `prozess`: Liste der Bausteine (Prozessoren aller Module) mit ihren Ausgängen |

Namen findet der Server tolerant: ID, exakter Name oder Anzeigetext, dann „Name (Zusatz)“, dann Namensteil. Bei mehreren Treffern kommt die Liste zurück.

### Ändern (zweistufig)

| Werkzeug | Zweck |
|---|---|
| `blp_change` | Baustein gezielt ändern: Liste von `{pfad, wert, aktion}`. Freigegeben für `processengine`, `objectmanager`, `client/sidebar/tab/action`, `smartsearch`, `role`, `client/selection` |
| `blp_create_process` | neuer Prozess als Kopie eines vorhandenen, optional mit Pfad-Änderungen an der Kopie |
| `blp_create_tab` | neuer, leerer Sidebar-Tab |
| `blp_add_tile` | neue Kachel an Tab oder Geschäftsobjekt als Kopie einer Vorlage-Kachel (Aktion, Bilder, Farbe), mit eigenem Namen und Änderungen |
| `blp_process_build` | Prozess aus einem Bauplan bauen: neu, als Kopie unter neuem Namen (`name`) oder als Ersatz eines vorhandenen (`prozess`); auch eine Sicherung zurückspielen |
| `blp_create_object` | neues Geschäftsobjekt, leer mit `felder` oder als Kopie einer `vorlage` (Felder, Füllregeln, Suche, ohne Kacheln) |
| `blp_image_upload` | PNGs ins Bildpaket laden und optional gleich an Kachel (24/32/64 px) oder Tab (24 px) hängen |
| `blp_image_remove` | Bilder aus einem Container nehmen; verweigert, solange sie noch benutzt werden; `endgueltig` löscht auch die Datei |

Bewusst **nicht** dabei: Veröffentlichen, Löschen ganzer Bausteine, Modulkonfiguration (dort ist Speichern sofort Festschreiben).

## So läuft eine Änderung

```text
Du:   Mach im Tab Buchhaltung die Kachel „Rechnungen“ grün.
KI:   (blp_change ohne freigabe)
      Vorschau – noch nichts geändert
      Tab Buchhaltung v3.0, Pfad tiles/[name=Rechnungen]/layout/color_id
      bisher "SkyBlue" → neu "Green"
      Wirksam erst nach Veröffentlichen im Designer. Soll ich?
Du:   Ja.
KI:   (blp_change mit denselben Argumenten + freigabe)
      Ausgeführt: v3.0 → v4.0, Kontrolle: alle Werte wie gewünscht.
      Sicherung: %LOCALAPPDATA%\blp-mcp\sicherung\client_sidebar_tab_action-…-vorher.json
```

Beim Ausführen: Baustein lesen → Sicherung als JSON → `checkout` → Änderung auf die Arbeitskopie → Prüfung (keine `null` in Listen, Prozessparameter nur Text) → Speichern → `commit` → nachlesen und je Pfad kontrollieren. Geht nach dem `checkout` etwas schief, verwirft `undo` die Arbeitskopie. Jede Ausführung landet im Protokoll `%LOCALAPPDATA%\blp-mcp\protokoll-JJJJ-MM.jsonl`.

## Pfadsprache

Segmente mit `/`:

| Segment | Bedeutung | Beispiel |
|---|---|---|
| Name | Eigenschaft (Punkte gehören zum Namen) | `nodes`, `parameters`, `Module.Elo.ActionNode.EloAs` |
| Zahl | Listenindex | `tiles/0` |
| `[feld=wert]`, `[feld^=anfang]` | Listenelement, genau ein Treffer | `tiles/[tile_id^=f8d0]`, `selections/[name=Einkauf]` |
| `[=wert]`, `[^=anfang]` | Element einer Liste aus reinen Werten | `tiles_order/[^=f8d0]` |
| `#` | in den eingebetteten JSON-Text hinein (Parameterwerte sind JSON als Text) | `…/Module.Core.Action.ProcessStarter.Config/#/ProcessName` |
| `-` | neues Listenelement (mit `aktion: anhaengen`) | `selections/[name=Einkauf]/childs/-` |

Aktionen: `setzen` (Standard), `anhaengen`, `entfernen`, `sortieren` (Liste am Pfad alphabetisch nach de-DE, Feld in `wert`, Standard `display_text`).

```json
{ "baustein": "processengine", "objekt": "Rechnung prüfen",
  "aenderungen": [ { "pfad": "nodes/[id^=1a2b3c4d]/parameters/Module.Elo.ActionNode.EloAs/#/AsDefinitions/0/RuleSetName",
                     "wert": "Rechnung_pruefen_v2" } ] }
```

Weitere Beispiele (Tab in einer Rolle ausblenden, Dokument im Auswahlbaum anhängen, Kachel entfernen) in [`docs/USAGE.md`](docs/USAGE.md).

## Bauplan

Für größere Umbauten oder ganz neue Prozesse arbeitet die KI nicht mit Pfaden, sondern mit dem ganzen Prozess als Bauplan: `blp_process_export` liefert ihn, `blp_process_build` baut daraus.

```json
{ "name": "Gutschrift prüfen", "ordner": "Logik",
  "knoten": [
    { "key": "start", "baustein": "Start", "x": 0, "y": 0 },
    { "key": "frage", "baustein": "Decision", "x": 0, "y": 150,
      "parameter": { "Module.Core.Decision.Config": { "Content": "\"[VAR.Betrag]\" != \"\"" } } },
    { "key": "regel", "baustein": "ELO Direct - Start AS Task", "x": 0, "y": 300, "parameter": { "…": "…" } },
    { "key": "stopp", "baustein": "Abort Process (deprecated)", "x": 300, "y": 300, "parameter": { "…": "…" } } ],
  "verbindungen": [ ["start", "START", "frage"], ["frage", "output_true", "regel"], ["frage", "output_false", "stopp"] ] }
```

- **Knoten:** `key` (kurz, eindeutig; der Export nimmt den Anfang der Knoten-ID), `baustein` (Anzeigename des Prozessors, Liste mit `blp_process_export` ohne `prozess`), `beschreibung`, Position `x`/`y`, `parameter` mit **entpacktem** eingebettetem JSON, `felder` (Ausgabefelder, z. B. die Feldnamen eines Eingabeformulars).
- **Verbindungen:** `[von, port, nach]`, optional mit Kommentar als viertem Wert. `port` ist ein Ausgang des Bausteins (`output`, `output_true`/`output_false`, beim Start `START`).
- **Bauen:** ohne `prozess` neu im Ordner aus dem Bauplan, mit `name` als Kopie, mit `prozess` als Ersatz des vorhandenen (Name und Ordner bleiben, vorhandene Knoten behalten ihre IDs). Eine Sicherungsdatei lässt sich direkt als `datei` zurückspielen.
- **Prüfungen vor dem Speichern:** genau ein Start, jeden Baustein und Ausgang gibt es, ein Ausgang hat genau ein Ziel, alle Knoten sind vom Start aus erreichbar, Parameter sind Text, keine `null` in Listen, keine maskierten Werte (`***`) aus einer Antwort. Nach dem Speichern wird der Prozess gegen den Bauplan verglichen.

Format, Beispiele und Fallen: [`docs/USAGE.md`](docs/USAGE.md#bauplan).

## Sicherheit

- **Ändern nur, wo erlaubt:** `allowChanges` je Umgebung, in der Vorlage nur für Test. Produktiv bleibt lesend, bis ein Mensch es bewusst freischaltet.
- **Nichts ohne Zustimmung:** Ändernde Werkzeuge liefern zuerst eine Vorschau. Der Freigabe-Code gilt fünf Minuten, einmal, nur für dieselben Argumente und nur, solange sich Version und Zeitstempel des Bausteins nicht geändert haben.
- **Veröffentlichen bleibt beim Menschen:** Der Server kann es nicht. Erst nach dem Veröffentlichen im Designer sieht die Sidebar eine Änderung.
- **Sicherung und Protokoll:** vor jeder Änderung der ganze Baustein als JSON, jede Ausführung mit Argumenten und Ergebnis im Protokoll.
- **Keine maskierten Werte zurückschreiben:** Ein Bauplan mit `***` (aus einer maskierten Antwort) wird abgelehnt; zum Kopieren solcher Prozesse dient die Bauplan-Datei.
- **Maskierung:** Schlüssel mit pass/pwd/secret/token/credential/apikey (auch in eingebetteten JSON-Texten) und `Password=…` in Verbindungszeichenfolgen werden in jeder Antwort zu `***`.
- **Zugangsdaten:** DPAPI-verschlüsselt, nur für das eigene Windows-Konto lesbar. Nie in der Konfiguration, nie im Chat.
- **Nur die eigenen Dienste:** `blp_get` nimmt nur Pfade, keine Adressen.
- Sicherheitslücken bitte **nicht** als öffentliches Issue melden, sondern wie in [`SECURITY.md`](SECURITY.md) beschrieben.

## Dokumentation

| Datei | Inhalt |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Einrichtung für KI-Agenten, inkl. Fehlersuche |
| [`docs/CLIENTS.md`](docs/CLIENTS.md) | Eintrag für alle gängigen MCP-Clients |
| [`docs/USAGE.md`](docs/USAGE.md) | Beispiel-Prompts und Änderungsrezepte |
| [`docs/BLP-API.md`](docs/BLP-API.md) | Was wir über die Designer-API wissen: Endpunkte, checkout/commit, Eigenheiten und Fallen |
| [`config.example.json`](config.example.json) | kommentierte Beispiel-Konfiguration |
| [`SECURITY.md`](SECURITY.md) | Sicherheitslücken vertraulich melden |

## Entwickeln

Der Server besteht aus `blp-mcp.ps1` (Protokoll, Anmeldung, Lesewerkzeuge) und den per Dot-Sourcing eingebundenen Dateien `blp-mcp-konfig.ps1`, `blp-mcp-aendern.ps1` (Pfadsprache, Ändern, Neuanlage), `blp-mcp-bilder.ps1` (Bildpaket) und `blp-mcp-bauen.ps1` (Bauplan, Geschäftsobjekt anlegen). Testlauf ohne MCP-Client:

```powershell
python -I test-blp-mcp.py beispiel-aufrufe.json
```

`MCP_ARGS` reicht Schalter an den Server durch (z. B. `-Umgebung produktiv`), `MCP_TEST_LIMIT` kürzt die Ausgabe. Ändernde Aufrufe paarweise: erst ohne `freigabe`, dann mit `"freigabe": "$TOKEN"` (= Code der letzten Vorschau). Nach Änderungen am Code den Server im Client neu laden.

## Mitmachen

Issues und Pull Requests sind willkommen. Bitte in Issues **keine** Logs mit Hostnamen, Projekt-IDs, Benutzernamen oder Tokens posten, sondern vorher schwärzen. Neue Bausteine für `blp_change` bitte erst auf einer Test-Umgebung erproben und den Weg (checkout, Speichern, commit) im Pull Request beschreiben.

## Lizenz

[MIT](LICENSE). Entstanden bei der herzog GmbH für die eigene ELO-Sidebar. Kein offizielles Produkt der ACTIWARE GmbH oder der ELO Digital Office GmbH; die Schnittstelle ist nicht offiziell dokumentiert und kann sich mit jeder BLP-Version ändern. Business Logic Provider ist ein Produkt der ACTIWARE GmbH, ELO ist eine Marke der ELO Digital Office GmbH.
