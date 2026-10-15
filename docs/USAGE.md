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
