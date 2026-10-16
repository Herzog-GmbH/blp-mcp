# Arbeiten mit dem BLP-MCP

## Beispiel-Prompts

**Nachsehen**

- „Welche Tabs hat die Sidebar, und welche Rollen sehen den Tab Buchhaltung?“
- „Zeig mir den Prozess ‚Rechnung prüfen‘: welche Knoten, welche ELOas-Regel wird aufgerufen?“
- „Welche Kacheln hat das Geschäftsobjekt Lieferant, und mit welcher Bedingung erscheinen sie?“
- „Wann wurde zuletzt veröffentlicht?“
- „Wo wird das Bild rechnung_32.png benutzt?“

**Ändern** (die KI zeigt jeweils erst die Vorschau)

- „Blende den Tab Einkauf für die Rolle Produktion aus.“
- „Ändere die Farbe der Kachel ‚Rechnungen‘ im Tab Buchhaltung auf Green.“
- „Hänge im Auswahlbaum unter Einkauf ein Dokument ‚Gutschrift‘ an, Prozess ‚Gutschrift erfassen‘, Feld Dokumententyp=Gutschrift.“
- „Sortier alle Dokumente im Bereich Einkauf alphabetisch.“

**Neu anlegen**

- „Leg einen Tab ‚Projekte‘ an und blende ihn überall aus außer bei der Rolle Projektleitung.“
- „Kopier den Prozess ‚Rechnung prüfen‘ als ‚Gutschrift prüfen‘ in denselben Ordner.“
- „Leg im Tab Projekte eine Kachel ‚Neues Projekt‘ an, wie die Kachel ‚Neuer Lieferant‘, aber mit dem Prozess ‚Projekt anlegen‘.“
- „Lade C:\Symbole\projekt_24.png, _32 und _64 hoch und häng sie an die Kachel ‚Neues Projekt‘.“
- „Leg ein Geschäftsobjekt ‚Projekt‘ an mit den Feldern Nummer (Schlüssel) und Bezeichnung.“

**Prozesse bauen** (siehe [Bauplan](#bauplan))

- „Exportier den Prozess ‚Rechnung prüfen‘ als Bauplan und erklär mir den Ablauf.“
- „Bau ‚Rechnung prüfen‘ als ‚Gutschrift prüfen‘ nach, aber ohne die Freigabeseite.“
- „Füg in ‚Rechnung prüfen‘ nach dem Formular eine Entscheidung ein: ist der Betrag leer, Prozess abbrechen.“
- „Welche Bausteine gibt es für ELO, und welche Ausgänge haben sie?“
- „Spiel die Sicherung von heute Morgen für ‚Rechnung prüfen‘ zurück.“

## Änderungsrezepte für `blp_change`

| Vorhaben | `baustein` / `objekt` | `aenderungen` |
|---|---|---|
| Tab in einer Rolle ausblenden | `role` / Rollenname | `{pfad: "situations/0/action_tabs/[tab_id=<Tab-ID>]/include", wert: false}` |
| Kachelfarbe | `client/sidebar/tab/action` / Tab | `{pfad: "tiles/[name=Rechnungen]/layout/color_id", wert: "Green"}` |
| Anzeigetext einer Kachel | `client/sidebar/tab/action` / Tab | `{pfad: "tiles/[name=Rechnungen]/display_text", wert: "Eingangsrechnungen"}` |
| Prozess hinter einer Kachel | `client/sidebar/tab/action` / Tab | `{pfad: "tiles/[name=Rechnungen]/parameters/Module.Core.Action.ProcessStarter.Config/#/ProcessName", wert: "Rechnung erfassen v2"}` |
| Kachel aus einem Tab entfernen | `client/sidebar/tab/action` / Tab | `{pfad: "tiles/[tile_id=<ID>]", aktion: "entfernen"}` |
| Kachel aus einem Geschäftsobjekt entfernen | `objectmanager` / Objekt | `{pfad: "tiles/[tile_id=<ID>]", aktion: "entfernen"}` und `{pfad: "tiles_order/[=<ID>]", aktion: "entfernen"}` |
| Parameter eines Prozessknotens | `processengine` / Prozess | `{pfad: "nodes/[id^=<ID-Anfang>]/parameters/<Parametername>/#/<Feld>", wert: …}` |
| Dokument im Auswahlbaum anhängen | `client/selection` (ohne `objekt`) | `{pfad: "selections/[name=Einkauf]/childs/-", aktion: "anhaengen", wert: {name, display_text, language_code, process, fields: [{name, value, type: 1}], include: true}}` |
| Dokument im Auswahlbaum ein/aus | `client/selection` | `{pfad: "selections/[name=Einkauf]/childs/[name=Gutschrift]/include", wert: false}` |
| Bereich alphabetisch sortieren | `client/selection` | `{pfad: "selections/[name=Einkauf]/childs", aktion: "sortieren"}` |
| Dokument aus dem Auswahlbaum entfernen | `client/selection` | `{pfad: "selections/[name=Einkauf]/childs/[name=Gutschrift]", aktion: "entfernen"}` |
| Kachelbild auf ein vorhandenes Bild umstellen | `client/sidebar/tab/action` / Tab | `{pfad: "tiles/[name=Rechnungen]/layout/images/image_medium/item_id", wert: "<Bild-ID>"}` |

Tipp: Den genauen Pfad findet die KI mit `blp_tab … roh: true`, `blp_object … roh: true`, `blp_process … knoten: <ID-Anfang>` und `blp_read_path`.

## Neuanlage

```json
// blp_create_process
{ "vorlage": "Rechnung prüfen", "name": "Gutschrift prüfen" }

// blp_create_tab
{ "name": "Projekte", "anzeige": "Projekte", "beschreibung": "Projektakten und -prozesse" }

// blp_add_tile
{ "ziel": "tab", "zielname": "Projekte", "vorlage": "Neuer Lieferant", "name": "Neues Projekt",
  "aenderungen": [ { "pfad": "parameters/Module.Core.Action.ProcessStarter.Config/#/ProcessName", "wert": "Projekt anlegen" } ] }

// blp_image_upload: eigene Dateien, gleich an die Kachel
{ "dateien": ["C:\\Symbole\\projekt_24.png", "C:\\Symbole\\projekt_32.png", "C:\\Symbole\\projekt_64.png"],
  "container": "Symbole", "ziel": "tab", "zielname": "Projekte", "kachel": "Neues Projekt" }
```

Jedes dieser Werkzeuge antwortet zuerst mit einer Vorschau und einem Freigabe-Code; ausgeführt wird erst der zweite Aufruf mit `freigabe`.

Kachelbilder: 24 px = `image_small`, 32 px = `image_medium`, 64 px = `image_large`; ein Tab-Bild ist 24 px (`tabbild: true`). Eine Datei gleichen Namens im Container wird wiederverwendet, nicht ersetzt – ein geändertes Symbol braucht einen neuen Dateinamen.

## Bauplan

Ein Bauplan ist der ganze Prozess als JSON, so geschrieben, dass Mensch und KI ihn lesen und ändern können. `blp_process_export` liefert ihn, `blp_process_build` baut daraus.

| Schlüssel | Bedeutung |
|---|---|
| `name` | Prozessname |
| `ordner` | Prozessordner (Name oder ID). Ob Server- oder Client-Prozess, folgt aus dem Ordner |
| `art` | `client` oder `server`; beim Export zur Information, beim Bauen gegen den Ordner geprüft |
| `optionen` | Prozessoptionen, z. B. `{"viewport": {"x": 0, "y": 0, "zoom": 1}}` (Ansicht im Designer); fehlt = Standardansicht |
| `knoten` | Liste der Knoten (siehe unten) |
| `verbindungen` | `[von, port, nach]` oder `[von, port, nach, kommentar]` |

Ein Knoten:

| Schlüssel | Bedeutung |
|---|---|
| `key` | kurzer, eindeutiger Schlüssel. Der Export nimmt den Anfang der Knoten-ID (8 Zeichen), der Startknoten heißt `start`. Selbst geschriebene Baupläne dürfen sprechende Schlüssel nehmen (`formular`, `pruefen`) |
| `baustein` | Anzeigename des Prozessors, z. B. `Input Form`, `Decision`, `Setter`, `ELO Direct - Start AS Task`; `Start` für den Startknoten. Bei Mehrdeutigkeit `Modul/Name`. Die Liste mit Ausgängen liefert `blp_process_export` ohne `prozess` |
| `beschreibung` | Beschreibung im Designer |
| `x`, `y` | Position im Designer |
| `parameter` | Parameter des Knotens; eingebettetes JSON ist **entpackt** (Objekt statt Text) und wird beim Bauen wieder zu Text. Fehlt = keine Parameter (`{}`), `null` = so wie der Designer z. B. einen unkonfigurierten File Upload speichert |
| `felder` | Ausgabefelder des Knotens, z. B. die Feldnamen eines Eingabeformulars – Folgeknoten sehen sie darüber |
| `id` | optional die volle Knoten-ID. Sonst: beim Ersetzen die vorhandene ID, deren Anfang der `key` ist; für neue Knoten eine feste ID aus Prozessname und `key` (gleicher Bauplan = gleiche IDs) |

### Abläufe

```json
// Bausteine und ihre Ausgänge
{ "filter": "Decision" }                                   // blp_process_export

// Prozess als Bauplan (kleine direkt in der Antwort, große als Datei im Datenordner)
{ "prozess": "Rechnung prüfen" }                            // blp_process_export
{ "prozess": "Rechnung prüfen", "datei": "C:\Temp\rechnung.json" }

// Kopie unter neuem Namen
{ "datei": "C:\Temp\rechnung.json", "name": "Gutschrift prüfen" }                 // blp_process_build

// geänderten Bauplan zurückschreiben (Name im Bauplan = Name des Prozesses)
{ "datei": "C:\Temp\rechnung-neu.json", "prozess": "Rechnung prüfen" }            // blp_process_build

// Sicherung zurückspielen (Datei aus %LOCALAPPDATA%\blp-mcp\sicherung, Knoten-IDs wie damals)
{ "datei": "C:\…\sicherung\processengine-…-vorher.json", "prozess": "Rechnung prüfen" }

// neues Geschäftsobjekt
{ "name": "Projekt", "felder": [ { "name": "Nummer", "schluessel": true }, { "name": "Bezeichnung" } ] }   // blp_create_object
{ "name": "Projekt (Kopie)", "vorlage": "Projekt" }
```

Die Vorschau von `blp_process_build` zeigt jeden Knoten mit Baustein und Kern (Überschrift eines Formulars, Bedingung einer Entscheidung, aufgerufene Regel), alle Verbindungen und beim Ersetzen die Änderungen: neue, entfernte und geänderte Knoten (welcher Teil: Parameter, Beschreibung, Position, Felder) und Verbindungen.

### Prüfungen

Abgelehnt wird ein Bauplan, wenn

- es nicht genau einen Startknoten gibt,
- ein Baustein oder ein Ausgang nicht existiert oder in eine Verbindung zum Start führt,
- ein Ausgang zu mehr als einem Knoten führt,
- ein Knoten vom Start aus nicht erreichbar ist,
- ein Parameter weder Text noch Objekt noch Liste ist, eine Liste `null` enthält,
- ein Wert maskiert ist (`***` aus einer Antwort),
- ein Knoten unbekannte Schlüssel hat (z. B. `parameters` statt `parameter`).

Warnungen (kein Abbruch): Ausgänge ohne Verbindung (der Prozess endet dort), Eingabeformular ohne `felder`.

### Fallen

- **Große Baupläne als Datei:** Antworten sind auf 60 000 Zeichen begrenzt. Der Export schreibt größere Baupläne in den Datenordner (`bauplan\`) und nennt den Pfad; `blp_process_build` nimmt ihn mit `datei`.
- **Maskierte Werte:** Parameter mit `pass`, `pwd`, `secret`, `token` oder `credential` im Namen erscheinen in Antworten als `***`. Solche Prozesse nur über die Datei kopieren.
- **`type` und `Type`:** Setter-Parameter haben beide Schlüssel nebeneinander. Der Export lässt solche Werte als Text stehen, wenn sie sich nicht als Objekt darstellen lassen; beim Bauen bleiben sie unverändert.
- **Eingabeformulare:** `felder` und `parameter."project.useditems"` sollten die Feldnamen des Formulars enthalten (ohne Zwischenüberschriften, Typ 19). Die Vorschau schlägt sie vor, wenn sie fehlen.
- **Verwaiste Verbindungen:** Der Designer hinterlässt manchmal Verbindungen zu Knoten, die es nicht mehr gibt. Der Export lässt sie weg und warnt.
- **Neue Geschäftsobjekte** stehen danach in allen Rollen auf eingeschlossen (wie neue Tabs). Abwählen mit `blp_change` (`role`, Pfad `situations/0/objects/[object_id=<ID>]/include`, Wert `false`).
