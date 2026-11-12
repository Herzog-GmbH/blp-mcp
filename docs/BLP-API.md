# Was wir über die Designer-API wissen

Die REST-API des BLP-Designers ist nicht offiziell dokumentiert. Alles hier stammt aus dem Verhalten des Web-Designers (BLP 6) und aus eigenen Versuchen auf einer Test-Umgebung. Es kann sich mit jeder BLP-Version ändern – im Zweifel erst auf Test prüfen.

## Dienste

| Dienst | Aufgabe | Beispiele |
|---|---|---|
| Identity | Anmeldung, Benutzerinfo | `POST /api/v1/auth/login` `{user, password}` → `{token}`; `GET /api/v2/auth/info` |
| Projektdienst | alle Designer-Bausteine | `GET /api/v1/project` (Projekte mit `_id`), `…/api/v1/project/<Projekt-ID>/<Baustein>` |
| Client-Dienst | was die Sidebar ausliefert (veröffentlichter Stand) | `GET /api/v1/project` mit `last_update`, Kachelfarben `GET /api/v1/theme/sidebar/tiles/colors` |
| Prozessdienst | Prozesse ausführen | `…/api/v1/process/<Projekt>/<Prozess>/start` (vom MCP nicht benutzt) |
| Berichtsdienst | Laufberichte (bei uns Port …11) | `GET /api/v3/report?query=*&page=N`, `GET /api/v1/report/<transaction_id>`; siehe [Laufberichte](#laufberichte) |
| Designer | nur die Oberfläche; die Dienstadressen stehen in ihrer `config.js` | |

Jeder Aufruf braucht `Authorization: Bearer <token>` und `X-CLIENT-SYSTEM-ID: IoSidebarWebClient`. Das Token ist opak; bei 401 einfach neu anmelden.

**Konto:** An die Bausteine eines Projekts kommt nur ein Konto, das im Projekt berechtigt ist. Bei uns war das nur der BLP-eigene `admin`; Windows-Konten mit Designer-Rechten bekamen `400 PRJ050000 "User is not authorized"`.

## Bausteine (relativ zu `…/api/v1/project/<Projekt-ID>/`)

| Pfad | Inhalt |
|---|---|
| `processengine` | Prozessliste, **verschachtelt**: `server_processes`, `client_processes`, `sub_processes`, `templates` → Ordner → `processes[]` |
| `processengine/<id>` | Prozess: `nodes[]` (`module_id`, `processor_id`, `description`, `parameters`), `connectors[]` (`source_node`, `source_port`, `target_node`) |
| `objectmanager`, `objectmanager/<id>` | Geschäftsobjekte: Felder, `filling_rules`, `search`, `tiles`, `tiles_order` |
| `client/sidebar/tab/action` | Sidebar-Tabs mit ihren Kacheln (alle Tabs in einem Dokument; ändern je Tab unter `…/<id>`) |
| `client/selection` | Auswahlbaum des Desktop-Clients, **ein** Baustein ohne ID |
| `role` | Rollen mit `situations[].action_tabs[]` (`tab_id`, `include`, `actions[]`, `override_settings`) |
| `smartsearch` | Suchprofile (`lists`), einzeln unter `smartsearch/<id>` |
| `fieldmanager` | Parameter, Variablen, Datenfelder; **ein** Baustein ohne ID, checkout/commit/undo darunter wie beim Auswahlbaum. Die Parameter (z. B. Servernamen) gehen bei jedem Prozesslauf als `configuration` mit |
| `dataquerymanager/load/items` | alle Datenabfragen (nur Name, Add-in, Bedingungs- und Ergebnisfelder) |
| `dataquerymanager/<Modul-ID>/<Add-in-ID>` | Datenabfragen eines Add-ins mit Inhalt, z. B. SQL (`Module.DataConnect.DataQuery.SQL.Config` → `Sources[].DataQueries[]` mit `DataQueryString`, `FieldMappings`), GroupQueries (`…GroupQueries.Config` → `Queries[]`); `POST` speichert wie bei `module/<Modul-ID>` |
| `module/<Modul-ID>` | Modulkonfiguration, z. B. Validation (`Module.Document.Processing.Config` → `validatorConfig.documentTypes`), AI.Foundation (`aw_module_config.internal.config_key` → `promptSettings`, `modelProfiles`, `providerConfigs`); siehe Fallen |

Die Prozessor-Liste eines Moduls (also die Namen der Bausteine in einem Prozess) liegt **nicht** unter dem Projekt, sondern am Projektdienst unter `GET /api/v1/module/<Modul-ID>`. Alle Module mit ihren Prozessoren auf einmal: `GET /api/v1/module` → `{modules: [{module_id, name, processors: [{info: {id, name, display_text}, input_ports: [{id}], output_ports: [{id}]}]}]}`. Prozessknoten haben selbst keinen Namen, nur `description` und `processor_id`.

## Laufberichte

- **Liste:** `GET <Berichtsdienst>/api/v3/report?query=*&page=N` → `{reports[], page, pages, has_next_page, item_count, found_items, raw_query}`. 25 Berichte je Seite, **älteste zuerst**. `pages` und `has_next_page` stimmen nicht verlässlich (bei uns `pages` 321 bei 334 belegten Seiten, `has_next_page` auf allen Seiten `false`): Das Ende ist die erste Seite ohne `reports`. `sort`/`order` werden ignoriert, Datumsfilter in `query` beantwortet der Dienst mit HTTP 500. Weil die ältesten Berichte nach 28 Tagen (`retention_date`) wegfallen, rutschen die Seitennummern laufend nach vorn.
- **Listeneintrag:** `transaction_id`, `start_date` (UTC), `process.name`, `state` (`Done`, `Warning`, …), `execution_time` (ms), `children[]` (Kind-Läufe, z. B. Logikprozesse eines Containers, mit eigenem `state`).
- **Einzelbericht:** `GET <Berichtsdienst>/api/v1/report/<transaction_id>` → `owner` (Benutzer, Rechner), `configuration` (Parameter der Feldverwaltung zur Laufzeit), `services` (enthält Zugangsdaten der Message-Queue im Klartext!), `steps[]` (`diagram_node_id`, `state`, `exit_port`, `processor_execution_time`, `messages[]` mit `time`, `level` Debug/Message/Warning/Error, `language_code`, `text` mit Platzhaltern `{0}`, `args[]`), `children[]` als volle Berichte, `process.layout.nodes[]` (`id`, `module_id`, `processor_id`).
- **`Warning` ohne Warnmeldung:** kommt vor, wenn ein Schritt ohne Ausgang endet (`exit_port` leer, z. B. ein Prozessstarter am Ende ohne Nachfolger).
- Das Token des Projektdienstes (admin) gilt auch am Berichtsdienst.

## Full Export

`GET <Projektdienst>/api/v2/project/<Projekt-ID>/export?password=<Dateikennwort>` liefert das ganze Projekt wie *Dashboard → Export project → full export* (bei uns gut 7 MB). Ohne Kennwort lesbares JSON mit den Bereichen `Information`, `ClientDesigner`, `Processes`, `Triggers`, `FieldManager`, `DeploymentProfiles`, `ModuleConfigs`, `CredentialStore`, `BusinessObjects`, `SmartSearchProfiles`, `DataConnect`, `DesktopExtensions`, `ImageRepositryPackages` (sic, Bilder base64), `Repositories`, `RolesAndSituations`, `Translations`, `ColorSchemes`, `Layouts`, `ClientThemes`, `SidebarThemes`, `Policies` (mit `service_pools[]` der Sidebar-Richtlinie), `ObjectStorage`, `AiAssistant`, `OutputManager`, `ServicePools`. Die Elemente entsprechen den einzelnen Bausteinen, Pfade darin passen also zu `blp_change`. **Zugangsdaten stehen ohne Kennwort teils im Klartext** – nicht speichern, nicht weitergeben. `blp_search` hält ihn nur im Speicher.

## Prozessdefinition

```json
{ "internal_id": "00000000-…", "type": 1, "name": "…", "folder": "<Ordner-ID>",
  "nodes": [ { "id": "<GUID>", "offset": {"x": 15, "y": 15}, "module_id": "<Modul>", "processor_id": "<Prozessor>",
               "description": "", "parameters": { "Module.Core.Decision.Config": "{\"Content\":\"…\"}" },
               "fields": ["…"], "has_config_errors": false } ],
  "connectors": [ { "source_node": "<GUID>", "source_port": "<GUID>.output_true",
                    "target_node": "<GUID>", "target_port": "<GUID>.input", "comment": "" } ],
  "childs": null, "options": { "viewport": "{\"x\":0,\"y\":0,\"zoom\":1}" } }
```

- **Startknoten:** `id`, `module_id` und `processor_id` sind die Null-GUID, Ausgang `START`, `parameters` meist `{}` (manchmal `{"config": "{\"create_report\":true}"}`).
- **Ports:** `source_port` ist `<Knoten-ID>.<Ausgang>`, `target_port` immer `<Knoten-ID>.input`. Ausgänge je Prozessor stehen in `output_ports` (z. B. Decision `output_true`/`output_false`, Multi Decision `Port 1` … `Default`, End Process keiner). In vorhandenen Prozessen führt jeder Ausgang zu genau einem Ziel.
- **`fields`** (optional) sind die Ausgabefelder eines Knotens, z. B. die Feldnamen eines Eingabeformulars oder `ELO.AS.*` beim ELOas-Aufruf. Der Designer setzt sie beim Speichern eines Knotens.
- **`parameters` kann `null` sein** (z. B. File Upload ohne Einstellungen).
- **Typ** des Prozesses kommt vom Ordner: Prozessordner in `GET processengine` haben `type` (0 Server, 1 Client).

## Ändern: checkout → speichern → commit

1. `GET <Baustein>/<id>` – die Antwort enthält `_read_token`, `_version`, `_last_modified_date`.
2. `POST <Baustein>/<id>/checkout` mit `{"_read_token": "<Token aus 1>"}` → Arbeitskopie mit **neuem** `_read_token`.
3. `POST <Baustein>/<id>` mit dem ganzen, geänderten Baustein (Metadaten aus der Arbeitskopie).
4. `POST <Baustein>/<id>/commit` mit `{"_read_token": …}` – die Version springt auf die nächste Hauptnummer.
5. Bei Fehlern: `POST <Baustein>/<id>/undo` gibt die Arbeitskopie frei.

Neu anlegen: `PUT processengine` mit der ganzen Prozessdefinition (`internal_id` = Null-GUID, `type`, `name`, `folder`, `nodes`, `connectors`, `childs`, `options`) – der neue Prozess ist danach Version 1.0 und nicht gesperrt. `PUT client/sidebar/tab/action` mit dem Tab samt `tiles[]`. `PUT objectmanager` mit dem Objekt (ohne `_id`/`internal_id`, der Dienst vergibt beide): das neue Objekt ist danach **noch ausgecheckt** (`_locked`, Version 1.0) und wird erst mit `POST objectmanager/<id>/commit` (Lesetoken aus dem GET) festgeschrieben (Version 2.0). Löschen: `DELETE <Baustein>/<id>` mit Kopfzeile `X-READ-TOKEN`.

Fehlerbilder beim Speichern:

| Meldung | Ursache |
|---|---|
| `EOF` | Rumpf fehlt |
| `cannot unmarshal number …` | Rumpf kam als Zahlenfolge an (PowerShell: `byte[]` statt String gesendet) |
| `read token is invalid` | altes Token nach dem checkout benutzt |
| `The response ended prematurely` | eine Liste enthält `null` – der Dienst bricht die Verbindung ab |

## Fallen

- **Prozessparameter sind Text.** Jeder Wert unter `nodes[].parameters` muss ein String sein, auch eingebettetes JSON und `project.useditems` (`"[]"`). Deshalb gibt es in der Pfadsprache `#`.
- **`processengine/<id>/duplicate` taugt nicht:** Der Klon ignoriert Name und Ordner aus dem Rumpf und landet ohne Ordner – im Designer unsichtbar. Besser `PUT processengine` mit der kopierten Definition.
- **Modulkonfiguration (`module/<id>`):** `checkout`, `commit` und `undo` antworten 405, obwohl die `links` sie nennen. Gespeichert wird direkt mit `POST module/<id>` (ganze Konfiguration, `_read_token` aus dem GET); das ist sofort festgeschrieben (neue Hauptversion, neues Token). Ein veraltetes Token lehnt der Dienst ab (`400 PRJ050007 "read token is invalid"`) und **lässt das Modul dabei als gesperrt stehen** (`_locked`, `_locked_by_user`), bis es erfolgreich gespeichert wird (Befund 10.11.2026 am Modul Office). `blp_change` (`baustein: module`) schreibt deshalb vorher eine Sicherung; zurück mit `blp_module_restore`. Die Werte unter `parameters` sind JSON als Text; das Lesen und Zurückschreiben mit PowerShell ändert sie nicht (geprüft an Validation, AI.Foundation, AI OCR, PDF-Processor, elo). Office enthält Schlüssel, die sich nur in Groß-/Kleinschreibung unterscheiden – nur als Hashtable lesbar.
- **Modul-Software und Modulkonfiguration:** `GET /api/v1/module` (am Dienst) liefert die installierten Module mit Prozessoren; `GET project/<id>/module/<Modul-ID>` die Konfiguration im Projekt. Module ohne Konfiguration liefern dort `parameters` leer. Die Datenabfragen (SQL, OleDB, GroupQueries) gehören zu Add-ins des Moduls DataConnect (`data_query_addins` mit eigenen Routen wie `/api/v2/data-query/sql/config` am Moduldienst); ihre Inhalte stehen **nicht** in der Modulkonfiguration.
- **Datenabfragen lesen und speichern:** Die Route `config/LOAD` der Add-ins ist eine Webseite (React-App des Moduls), die ihre Daten per `postMessage` vom Designer bekommt. Der Designer selbst liest und speichert über `GET`/`POST project/<id>/dataquerymanager/<Modul-ID>/<Add-in-ID>` am Projektdienst (gefunden im Designer-Skript, Funktion „data query manager config“). Aufbau wie bei der Modulkonfiguration: `_version`, `_read_token`, `parameters` mit JSON als Text; `links` nur `self`/`update`/`delete`, kein checkout. Add-ins ohne Konfiguration im Projekt liefern `{}`. Die eingebetteten Texte von SQL und GroupQueries bleiben beim Aus- und Einpacken mit `ConvertFrom-Json`/`ConvertTo-Json -Compress` Zeichen für Zeichen gleich. Verbindungen: `Sources[].LoginProfile` verweist auf den Credential Store, `ConnectionString` ist dann leer.
- **Der Dienst lässt `false` und leere Listen beim Speichern weg** (z. B. `include: false` im Auswahlbaum, `tiles: []` bei einem neuen Tab). Fehlt ein Schlüssel, gilt er als `false`/leer. Zum Anhängen an eine fehlende Liste muss sie neu angelegt werden.
- **Neuer Tab = in allen Rollen sichtbar.** Beim Anlegen trägt der BLP den Tab in jede Rolle mit Situation ein, `include: true`.
- **Gelöschter Tab hinterlässt Rollen-Einträge** (`action_tabs` mit der alten ID). Aufräumen erst **nach** dem Löschen: Solange der Tab existiert, trägt der Dienst ihn beim Speichern einer Rolle wieder ein.
- **Neues Geschäftsobjekt = in allen Rollen sichtbar.** Beim Festschreiben trägt der Dienst es in `situations[].objects[]` jeder Rolle ein (`object_id`, `include: true`). Anders als bei Tabs entfernt das Löschen des Objekts diese Einträge wieder.
- **Ausgecheckte Bausteine bleiben ausgecheckt:** `_locked`, `_locked_by_user`, `_locked_on` zeigen, wer einen Baustein seit wann bearbeitet. Ein im Designer offen gelassener oder abgebrochener Bearbeitungsstand kann Monate stehen bleiben.
- **`type` und `Type` im selben Parameter:** Setter-Konfigurationen enthalten beide Schlüssel (`"type": 2, "Type": 4`). In PowerShell lässt sich so ein JSON nur als Hashtable lesen (`ConvertFrom-Json -AsHashtable`), nicht als Objekt.
- **Verwaiste Verbindungen:** `connectors` kann Einträge zu Knoten enthalten, die es im Prozess nicht mehr gibt. Der Designer zeigt sie nicht an.
- **Designer- und Client-Stand unterscheiden sich:** Im Designer ist `action_tabs[].tab_id` die Tab-ID, im veröffentlichten Stand am Client-Dienst der Tab-Name. Die Zuordnung Gruppe/Benutzer → Rolle kennt nur der Client-Dienst.
- **Kachelfarben und Hover:** Die `color_id`-Werte stehen am Client-Dienst unter `/api/v1/theme/sidebar/tiles/colors`. Einige Farben haben beim Darüberfahren einen weißen Hintergrund (`background_hover`) – weiße Symbole verschwinden dann. Vor der Wahl einer Farbe für weiße Symbole `background_hover` prüfen.
- **Auswahlbaum:** `client/selection` (`layers` Bereich/Dokument, `selections[].childs[]` mit `process` und `fields`) steht hinter `Selection: "Bereich;Dokument"` in Prozessstarter-Kacheln und hinter `Client.exe SELECTION=…`.
- **Prozessliste flach machen:** `GET processengine` ist nach Art und Ordner verschachtelt; wer einen Prozess per Name sucht, muss die Ordner durchlaufen.

## Bildpaket

Bilder hängen nicht am Projekt, sondern am Projektdienst:

| Aufruf | Wirkung |
|---|---|
| `GET /api/v1/image/package` | `{packages: [{_id, name, _read_token, container: [{id, name, images: [{id, file, type, data?}]}]}]}` |
| `PUT /api/v1/image/<neue GUID>?filename=<Datei>` | PNG als Rumpf (`Content-Type: image/png`), legt nur die Datei ab |
| `POST /api/v1/image/package/<id>/checkout`, `…/<id>`, `…/commit`, `…/undo` | Eintrag `{id, file, type: "Image"}` im Container, ganzes Paket speichern |
| `GET /api/v1/image/<id>` | die Datei |
| `DELETE /api/v1/image/<id>` | Datei löschen (so löscht auch der Designer) |

- **Container-IDs sind nicht eindeutig** – zwei Container können dieselbe ID haben. Container immer per Name ansprechen. Dieselbe Bild-ID kann in mehreren Containern stehen.
- Das Paket liefert die Bilddaten base64 im Feld `data` mit (schnell einige MB). Beim Speichern geht das ganze Paket zurück; neue Einträge brauchen nur `{id, file, type}`.
- Importierte Bilder können nur als `data` im Paket stehen, ohne Datei im Bildspeicher: `GET /api/v1/image/<id>` antwortet dann `PRJ050062 "file not found"`.
- Verweise: Kachel `layout.images.image_small/image_medium/image_large` (24/32/64 px), Tab `image` (24 px), je `{repository_id: "", item_id: "<Bild-ID>"}`.

## Prozessbausteine (Auszug)

- **Setter** (`Module.Core.Setter.Config`): `type 2 / Type 4` = Variable, `type 3 / Type 8` = Datenfeld. Ein Setter auf ein Datenfeld füllt keine `[VAR.x]`.
- **Gewähltes Geschäftsobjekt im Prozessdialog:** Die Kachel übergibt `SessionFields` (Type 512) mit `[OBJ.<Objekt>.<Feld>]`; das erste Eingabeformular braucht Felder mit **demselben Namen**, die damit vorbelegt werden. Weitere Objektfelder gibt es erst nach einem `Module.Core.ObjectFilling`-Baustein als `[NDF.<Objekt>.<Feld>]`.
- **ELOas-Aufruf** (`Module.Elo.ActionNode.EloAs`): `Parameter1` kommt in der Regel als `EM_PARAM2` an, `Parameter2` als `EM_PARAM3`, der Suchwert (Objekt-ID) als `EM_PARAM1`. Der Aufruf läuft asynchron.

## PowerShell-Fallen (für eigene Skripte)

- `$o | ConvertTo-Json` entrollt Listen: aus `["x"]` wird `"x"`. Immer `ConvertTo-Json -InputObject $o`, `ConvertFrom-Json -NoEnumerate` und Listen mit `return ,(...)` zurückgeben.
- `ConvertFrom-Json` macht in PowerShell 7 aus Datumstexten `DateTime` – beim Zurückschreiben ändern sich dann Zeitstempel. Immer `-DateKind String`.
- `$null | ForEach-Object { … }` läuft einmal mit `$null`: `@($x.liste | …)` ergibt bei fehlender Eigenschaft einen `null`-Eintrag – und der Dienst bricht ab. Vorher auf `$null` prüfen.
- JSON-Rumpf als **String** senden, nicht als `byte[]`.
- Git Bash wandelt Argumente wie `/api/v1/...` in Windows-Pfade um (404 „page not found“): `MSYS_NO_PATHCONV=1`.
