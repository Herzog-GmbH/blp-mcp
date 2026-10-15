# Was wir über die Designer-API wissen

Die REST-API des BLP-Designers ist nicht offiziell dokumentiert. Alles hier stammt aus dem Verhalten des Web-Designers (BLP 6) und aus eigenen Versuchen auf einer Test-Umgebung. Es kann sich mit jeder BLP-Version ändern – im Zweifel erst auf Test prüfen.

## Dienste

| Dienst | Aufgabe | Beispiele |
|---|---|---|
| Identity | Anmeldung, Benutzerinfo | `POST /api/v1/auth/login` `{user, password}` → `{token}`; `GET /api/v2/auth/info` |
| Projektdienst | alle Designer-Bausteine | `GET /api/v1/project` (Projekte mit `_id`), `…/api/v1/project/<Projekt-ID>/<Baustein>` |
| Client-Dienst | was die Sidebar ausliefert (veröffentlichter Stand) | `GET /api/v1/project` mit `last_update`, Kachelfarben `GET /api/v1/theme/sidebar/tiles/colors` |
| Prozessdienst | Prozesse ausführen | `…/api/v1/process/<Projekt>/<Prozess>/start` (vom MCP nicht benutzt) |
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
| `fieldmanager` | Parameter, Variablen, Datenfelder |
| `dataquerymanager/load/items` | alle Datenabfragen |
| `module/<Modul-ID>` | Modulkonfiguration (siehe Fallen) |

Die Prozessor-Liste eines Moduls (also die Namen der Bausteine in einem Prozess) liegt **nicht** unter dem Projekt, sondern am Projektdienst unter `GET /api/v1/module/<Modul-ID>`. Prozessknoten haben selbst keinen Namen, nur `description` und `processor_id`.

## Ändern: checkout → speichern → commit

1. `GET <Baustein>/<id>` – die Antwort enthält `_read_token`, `_version`, `_last_modified_date`.
2. `POST <Baustein>/<id>/checkout` mit `{"_read_token": "<Token aus 1>"}` → Arbeitskopie mit **neuem** `_read_token`.
3. `POST <Baustein>/<id>` mit dem ganzen, geänderten Baustein (Metadaten aus der Arbeitskopie).
4. `POST <Baustein>/<id>/commit` mit `{"_read_token": …}` – die Version springt auf die nächste Hauptnummer.
5. Bei Fehlern: `POST <Baustein>/<id>/undo` gibt die Arbeitskopie frei.

Neu anlegen: `PUT processengine` mit der ganzen Prozessdefinition (`internal_id` = Null-GUID, `type`, `name`, `folder`, `nodes`, `connectors`, `childs`, `options`), `PUT client/sidebar/tab/action` mit dem Tab samt `tiles[]`. Löschen: `DELETE <Baustein>/<id>` mit Kopfzeile `X-READ-TOKEN`.

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
- **Modulkonfiguration (`module/<id>`):** Speichern ist sofort Festschreiben (neue Hauptversion), `commit` antwortet 405. Deshalb ist sie für `blp_change` nicht freigegeben.
- **Der Dienst lässt `false` und leere Listen beim Speichern weg** (z. B. `include: false` im Auswahlbaum, `tiles: []` bei einem neuen Tab). Fehlt ein Schlüssel, gilt er als `false`/leer. Zum Anhängen an eine fehlende Liste muss sie neu angelegt werden.
- **Neuer Tab = in allen Rollen sichtbar.** Beim Anlegen trägt der BLP den Tab in jede Rolle mit Situation ein, `include: true`.
- **Gelöschter Tab hinterlässt Rollen-Einträge** (`action_tabs` mit der alten ID). Aufräumen erst **nach** dem Löschen: Solange der Tab existiert, trägt der Dienst ihn beim Speichern einer Rolle wieder ein.
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
