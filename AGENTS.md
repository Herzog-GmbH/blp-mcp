# Anleitung für KI-Agenten (Claude Code, Codex, GitHub Copilot, Gemini CLI, Cursor, …)

Ein Mensch hat dich gebeten, diesen BLP-MCP-Server auf seinem Rechner einzurichten oder mit ihm zu arbeiten. Diese Datei ist dein Ablauf. Arbeite die Schritte der Reihe nach ab und melde nach jedem Schritt kurz den Stand.

## Grundregeln

- **Passwörter fasst du nicht an.** Benutzer und Passwort fragt `Set-BlpCredential.ps1` selbst ab, verdeckt. Bitte den Menschen nie, dir ein Passwort in den Chat zu schreiben, und setze `BLP_USER`/`BLP_PASSWORD` nicht selbst.
- **`Set-BlpCredential.ps1` führt der Mensch aus**, in einer eigenen PowerShell-7-Konsole, weil es interaktiv fragt. Danach prüfst du mit `.\Set-BlpCredential.ps1 -NurPruefen` (fragt nichts, speichert nichts).
- **Produktiv bleibt lesend.** Setze `allowChanges` nicht auf `true` und verwende `-AendernErlauben` nicht, außer der Mensch verlangt es ausdrücklich für genau diese Umgebung.
- **Ändern nur zweistufig.** Ruf ein änderndes Werkzeug zuerst ohne `freigabe` auf, zeig dem Menschen die Vorschau (bisher/neu) und warte auf sein Ja. Erst dann denselben Aufruf mit `freigabe`. Den Freigabe-Code nie „auf Vorrat“ verwenden.
- **Veröffentlichen kannst du nicht** und sollst es nicht versuchen. Sag dem Menschen nach einer Änderung, dass sie erst nach dem Veröffentlichen im Designer wirkt.
- `config.local.json` und `blp-credential*.xml` werden nie committet (siehe `.gitignore`).

## Schritt 0 – Voraussetzungen (verändert nichts)

```powershell
pwsh -v
```

Nötig ist PowerShell 7.5 oder neuer. Fehlt `pwsh`, sag dem Menschen, dass er PowerShell 7 installieren muss (z. B. `winget install Microsoft.PowerShell`), und hör hier auf. Windows PowerShell 5.1 reicht nicht.

Wurde das Repo als ZIP heruntergeladen, sind die Skripte eventuell gesperrt. Dann im Repo-Ordner:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

## Schritt 1 – Konfiguration anlegen

```powershell
Copy-Item config.example.json config.local.json
```

Frag den Menschen nach den Adressen seines BLP und trag sie in `config.local.json` ein:

- `authUrl` – Identity-Dienst (Anmeldung, `…/api/v1/auth/login`)
- `projectUrl` – Projektdienst (Designer-API, `…/api/v1/project/…`)
- `clientUrl` – Client-Dienst (liefert die veröffentlichte Sidebar aus)

Weiß der Mensch die Ports nicht: Im Web-Designer im Browser die Entwicklerwerkzeuge öffnen (F12 → Netzwerk), neu laden und nachsehen, wohin die Aufrufe `auth/login` und `api/v1/project/…` gehen. Bei vielen Installationen liegen die drei Dienste auf demselben Server mit fortlaufenden Ports (z. B. `…01` Identity, `…02` Projektdienst, `…09` Client-Dienst), das ist aber nicht festgelegt.

`projectId` bleibt vorerst leer bzw. Platzhalter – die ID zeigt Schritt 2. `skipCertificateCheck` nur auf `true`, wenn Schritt 2 an einem Zertifikatsfehler scheitert und der Mensch das so will (besser: das Zertifikat der internen CA vertrauen).

## Schritt 2 – Zugangsdaten (Mensch)

Der Mensch führt in einer PowerShell-7-Konsole im Repo-Ordner aus:

```powershell
.\Set-BlpCredential.ps1
```

Das Skript fragt Benutzer und Passwort (Konto mit Designer-Rechten), speichert sie DPAPI-verschlüsselt, meldet sich an und listet die Projekte des Projektdienstes mit ID. Frag den Menschen nur nach dem Ergebnis: „Steht ‚Anmeldung ok‘ da, und wie heißt das Projekt?“ Die ID trägst du unter `projectId` ein. Danach prüfen:

```powershell
.\Set-BlpCredential.ps1 -NurPruefen
```

Bei der konfigurierten ID muss `<- konfiguriert` stehen.

## Schritt 3 – Im MCP-Client eintragen

Vorlagen für alle gängigen Clients stehen in [`docs/CLIENTS.md`](docs/CLIENTS.md). Für Claude Code:

```powershell
claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "<voller Pfad>\blp-mcp.ps1"
```

Danach muss der Client den Server neu laden (in Claude Code: neue Sitzung oder `/mcp`).

## Schritt 4 – Testen

Ruf `blp_whoami` auf. Erwartet: Umgebung, Projekt, Benutzer, `designerRechte` größer 0, `aendernErlaubt` wie konfiguriert. Dann `blp_tabs` – die Liste muss zu dem passen, was der Mensch im Designer sieht.

## Schritt 5 (optional) – Weitere Umgebung

Produktiv in denselben Eintrag nehmen (nur lesend, solange `allowChanges` dort `false` ist): den Eintrag aus Schritt 3 mit `-Umgebung test,produktiv` neu anlegen (`claude mcp remove blp --scope user`, dann `claude mcp add …` mit dem Zusatz). Jedes Werkzeug hat dann den Parameter `umgebung`, ohne Angabe gilt die erste. Wechsle die Umgebung nur, wenn der Mensch es will.

Zugangsdaten dafür: `.\Set-BlpCredential.ps1 -Umgebung produktiv` (Mensch).

Für **Claude Desktop** gibt es das Paket `blp-mcp-<version>.mcpb` aus dem Release. Das installiert der Mensch selbst per Doppelklick und trägt die Adressen in den Einstellungen der Erweiterung ein; du nennst ihm nur die Werte. Fehlen danach Zugangsdaten, nennt `blp_whoami` den genauen Befehl für `Set-BlpCredential.ps1`.

## Fehlersuche

| Meldung | Ursache und Abhilfe |
|---|---|
| „BLP-MCP ist nicht eingerichtet. Keine Konfiguration gefunden“ | `config.local.json` fehlt neben `blp-mcp.ps1` oder `-Config`/`BLP_MCP_CONFIG` zeigt ins Leere |
| „… fehlt oder ist noch ein Platzhalter“ | in `config.local.json` steht noch `HIER_…` |
| „Keine Zugangsdaten (…xml)“ | Schritt 2 für diese Umgebung fehlt. Die Datei ist an Windows-Konto und Rechner gebunden – auf einem anderen Rechner neu anlegen |
| SSL-/Zertifikatsfehler | Zertifikat des BLP-Servers ist dem Rechner unbekannt: interne CA vertrauen oder `skipCertificateCheck` |
| HTTP 401 oder „User is not authorized“ | Konto ohne Designer-Rechte oder falsches Passwort – Schritt 2 wiederholen |
| HTTP 404 „page not found“ bei `/api/...` aus Git Bash | Git Bash wandelt `/api/...` in Windows-Pfade um: `MSYS_NO_PATHCONV=1` setzen |
| „Aendern ist in der Umgebung … gesperrt“ | gewollt: `allowChanges` ist `false`. Nur der Mensch entscheidet, das zu ändern |
| „Der Baustein (oder die Bauplan-Datei) hat sich seit der Vorschau geaendert“ | jemand hat inzwischen im Designer gespeichert oder die Bauplan-Datei wurde geändert: neue Vorschau holen |
| „Bauplan fehlerhaft: …“ | `blp_process_build` hat den Bauplan geprüft und abgelehnt; jede Zeile nennt Knoten oder Verbindung und den Grund |
| Server startet nicht, Client meldet „failed“ | `pwsh` nicht im PATH, Skripte gesperrt (Schritt 0) oder Syntaxfehler nach eigenen Änderungen: `python -I test-blp-mcp.py` zeigt die Fehlerausgabe |
| Claude Desktop (Paket): „Verbindung zum Erweiterungs-Server nicht möglich“ | Grund steht in `mcp-server-BLP-MCP-Server.log` im Log-Ordner von Claude Desktop. Meist fehlt PowerShell 7 (`pwsh` im PATH). Fehlende Adressen oder Zugangsdaten meldet dagegen jeder Werkzeugaufruf im Chat |
| „Umgebung '…' ist in diesem Server nicht eingerichtet“ | der Parameter `umgebung` nennt eine Umgebung, die beim Start nicht in `-Umgebung` stand |

## Mit dem Server arbeiten

- Erst lesen, dann ändern: `blp_tab`, `blp_object`, `blp_process`, `blp_read_path` zeigen dir die Pfade, die du in `blp_change` brauchst.
- Kachel-, Prozess- und Tab-Namen sind oft mehrdeutig. Kommt „mehrdeutig“ zurück, nimm die ID aus der Liste.
- Ein neuer Tab steht sofort in **allen** Rollen auf sichtbar. Weise den Menschen darauf hin und blende ihn mit `blp_change` (`baustein: role`, Pfad `situations/0/action_tabs/[tab_id=<ID>]/include`, Wert `false`) dort aus, wo er nicht hingehört.
- Wird ein Tab gelöscht (im Designer), bleiben seine Einträge in den Rollen stehen. Aufräumen mit `blp_change … aktion entfernen`, aber erst **nach** dem Löschen.
- Ein neues Geschäftsobjekt (`blp_create_object`) steht ebenfalls sofort in allen Rollen auf sichtbar; abwählen mit `blp_change` (`baustein: role`, Pfad `situations/0/objects/[object_id=<ID>]/include`, Wert `false`).
- Prozesse umbauen oder neu bauen: erst `blp_process_export` (Bauplan), dann den Bauplan ändern und mit `blp_process_build` bauen – als Kopie mit `name`, als Ersatz mit `prozess`. Große Baupläne kommen als Datei; die Datei weiterreichen (`datei`) statt den Bauplan abzuschreiben. Einen Bauplan aus einer Antwort mit `***` nie zurückschreiben. Welche Bausteine und Ausgänge es gibt, zeigt `blp_process_export` ohne `prozess`.
- Mehr Eigenheiten der API: [`docs/BLP-API.md`](docs/BLP-API.md).
