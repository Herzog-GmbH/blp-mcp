<#
.SYNOPSIS
  MCP-Server fuer den BLP (ACTIWARE Business Logic Provider): Designer-Bausteine lesen und gezielt aendern.

.DESCRIPTION
  Wird vom MCP-Client (Claude Code, Claude Desktop, VS Code, Cursor, ...) gestartet: stdio, eine
  JSON-RPC-Nachricht je Zeile. Anmeldung per Passwort-Login an der BLP-Identity mit einem Konto, das
  Designer-Rechte hat. Zugangsdaten aus einer DPAPI-verschluesselten Datei (Set-BlpCredential.ps1)
  oder aus den Umgebungsvariablen BLP_USER/BLP_PASSWORD.

  Adressen, Projekt-ID und Zugangsdaten je Umgebung stehen in config.local.json (Vorlage: config.example.json).

  stdout gehoert dem Protokoll: keine Write-Host/Write-Output ausserhalb von Send, Meldungen nach stderr.
  Jede Antwort wird vor der Ausgabe maskiert (Passwoerter, Tokens, Verbindungszeichenfolgen).

.EXAMPLE
  claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1"
.EXAMPLE
  claude mcp add blp-prod --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" -Umgebung produktiv
.EXAMPLE
  claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" -Umgebung test,produktiv
#>
[CmdletBinding()]
param(
  # Umgebung aus der Konfiguration (Schluessel unter "environments"); Standard: defaultEnvironment.
  # Mehrere mit Komma ("test,produktiv"): ein Server fuer alle, jedes Werkzeug bekommt den Parameter umgebung, die erste gilt ohne Angabe.
  [string] $Umgebung,
  # Kurzform fuer -Umgebung produktiv.
  [switch] $Produktiv,
  # Aendernde Werkzeuge auch in einer Umgebung mit "allowChanges": false freischalten (nur mit einer Umgebung).
  [Alias("AendernAufProduktiv")] [switch] $AendernErlauben,
  # Pfad zur Konfiguration; Standard: $env:BLP_MCP_CONFIG, sonst config.local.json neben diesem Skript.
  [string] $Config
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$STDOUT = [Console]::Out

$VERSION = "0.6.0"
$MAX_TEXT = 60000

function Log([string] $m) { [Console]::Error.WriteLine("[blp-mcp] $m") }

# ---------- Konfiguration ----------

. (Join-Path $PSScriptRoot "blp-mcp-konfig.ps1")
# Faellt das Laden aus, startet der Server trotzdem: jeder Werkzeugaufruf meldet dann den Fehler (sichtbarer als ein stiller Abbruch).
$script:KonfigFehler = $null
$KONTEXTE = [ordered]@{}
try {
  $namen = @(if ($Umgebung) { $Umgebung -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } elseif ($Produktiv) { "produktiv" })
  if ($namen.Count -eq 0) { $namen = @("") }
  foreach ($n in $namen) {
    $k1 = Lade-Konfig -Pfad $Config -Umgebung $n
    if ($KONTEXTE.Contains($k1.name)) { throw "Umgebung '$($k1.name)' doppelt angegeben." }
    $KONTEXTE[$k1.name] = $k1
  }
  if ($KONTEXTE.Count -gt 1 -and $AendernErlauben) { throw "-AendernErlauben gilt nur mit einer Umgebung. Bei mehreren Umgebungen allowChanges je Umgebung in der Konfiguration setzen." }
} catch { $script:KonfigFehler = "$($_.Exception.Message)"; Log "Konfiguration: $script:KonfigFehler"; $KONTEXTE = [ordered]@{} }
$MEHRERE = $KONTEXTE.Count -gt 1
$STANDARD = if ($KONTEXTE.Count) { @($KONTEXTE.Keys)[0] } else { $null }

function Erlaubt($k) { [bool] ($k -and ($k.aendernErlaubt -or $AendernErlauben)) }
function UmgebungText($k) { "$($k.name) = $($k.label) ($(if (Erlaubt $k) { "lesen und aendern" } else { "nur lesen" }))" }

# Alles, was an einer Umgebung haengt. Bei mehreren Umgebungen schaltet Rufe vor jedem Aufruf um;
# Anmeldung und Zwischenspeicher (Prozessliste, Module, Bausteinkatalog) behaelt jede Umgebung fuer sich.
$ZUSTAND = @{}
$UMGEBUNG_NAME = $null
function Setze-Umgebung([string] $name) {
  if ($script:UMGEBUNG_NAME -eq $name) { return }
  if ($script:UMGEBUNG_NAME) { $ZUSTAND[$script:UMGEBUNG_NAME] = @{ Token = $script:Token; Prozessliste = $script:Prozessliste; Module = $script:Module; Katalog = $script:Katalog } }
  $z = $ZUSTAND[$name]
  $script:Token = $z.Token; $script:Prozessliste = $z.Prozessliste; $script:Katalog = $z.Katalog
  $script:Module = if ($z) { $z.Module } else { @{} }
  $k = $KONTEXTE[$name]
  $script:K = $k; $script:UMGEBUNG_NAME = $name
  $script:UMGEBUNG = $k.label; $script:AUTH = $k.authUrl; $script:PROJEKT = $k.projectUrl; $script:CLIENT = $k.clientUrl; $script:PROJEKT_ID = $k.projectId
  $script:SYSTEM = $k.clientSystemId; $script:TLS = $k.tls
  $script:AENDERN_ERLAUBT = Erlaubt $k
}

if ($STANDARD) { Setze-Umgebung $STANDARD }
else {
  $K = $null; $UMGEBUNG = "(nicht konfiguriert)"; $AUTH = $PROJEKT = $CLIENT = $PROJEKT_ID = ""; $SYSTEM = "IoSidebarWebClient"; $TLS = @{}
}

# ---------- API ----------

$script:Token = $null
function Get-Token {
  $z = Zugangsdaten $K
  $body = @{ user = $z.user; password = $z.password } | ConvertTo-Json -Compress
  $r = Invoke-RestMethod -Uri "$AUTH/api/v1/auth/login" -Method Post -ContentType "application/json" -Body $body @TLS
  if (-not $r.token) { throw "Login lieferte kein Token." }
  $r.token
}

function Header { if (-not $script:Token) { $script:Token = Get-Token }; @{ Authorization = "Bearer $script:Token"; "X-CLIENT-SYSTEM-ID" = $SYSTEM; Accept = "application/json" } }

function Blp-Get([string] $Url) {
  for ($versuch = 1; $versuch -le 2; $versuch++) {
    try {
      $r = Invoke-WebRequest -Uri $Url -Headers (Header) -UseBasicParsing @TLS
      return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
      $code = $null; try { $code = [int] $_.Exception.Response.StatusCode } catch {}
      if ($code -eq 401 -and $versuch -eq 1) { Log "401, melde neu an"; $script:Token = $null; continue }
      $detail = $_.ErrorDetails.Message
      throw ("GET $Url -> " + $(if ($code) { "HTTP $code " } else { "" }) + $(if ($detail) { $detail.Substring(0, [Math]::Min(300, $detail.Length)) } else { $_.Exception.Message }))
    }
  }
}

function P([string] $Pfad) { "$PROJEKT/api/v1/project/$PROJEKT_ID/$($Pfad.TrimStart('/'))" }
function Lies([string] $Pfad) { Blp-Get (P $Pfad) | ConvertFrom-Json -Depth 100 }

# ---------- Hilfen ----------

# $null nie in eine Pipeline schicken: "$null | ForEach-Object" laeuft einmal mit $null und erzeugt
# leere Eintraege (@($null) - dieselbe Falle hat am 05.09.2026 den Projektdienst abbrechen lassen).
function L($x) { if ($null -ne $x) { $x } }

function Kurz($v, [int] $n = 300) {
  if ($null -eq $v) { return "" }
  $s = if ($v -is [string]) { $v } else { ConvertTo-Json -InputObject $v -Depth 20 -Compress }   # -InputObject: Pipeline wuerde ["x"] zu "x" entrollen
  if ($s.Length -gt $n) { $s.Substring(0, $n) + " ..." } else { $s }
}

function ParseJson([string] $s) { if (-not $s) { return $null }; try { return ($s | ConvertFrom-Json -Depth 100) } catch { return $s } }

# Alphabetisch wie im Woerterbuch (de-DE: Ae wie A, gross/klein egal), stabil. Objekte nach $feld, reine Werte nach dem Wert.
function SortiereListe($liste, [string] $feld = "display_text") {
  $i = 0
  $paare = @(foreach ($e in @(L $liste)) { [pscustomobject]@{ k = $(if ($e -is [System.Management.Automation.PSCustomObject]) { "$($e.$feld)" } else { "$e" }); i = $i++; e = $e } })
  if ($paare.Count -eq 0) { return ,@() }
  return ,@($paare | Sort-Object -Property @{ Expression = { $_.k } }, @{ Expression = { $_.i } } -Culture "de-DE" | ForEach-Object { $_.e })
}
function ListenText($liste, [string] $feld = "display_text") {
  (@(foreach ($e in @(L $liste)) { if ($e -is [System.Management.Automation.PSCustomObject]) { "$($e.$feld)" } else { "$e" } }) -join " | ")
}
function FelderText($f) { (@(L $f | ForEach-Object { "$($_.name)=$($_.value)" + $(if ($_.type -ne 1) { " (Typ $($_.type))" } else { "" }) }) -join "; ") }

# Passwoerter, Tokens, Verbindungszeichenfolgen in jeder Antwort ausblenden - auch in eingebetteten JSON-Strings.
function Maskiere([string] $t) {
  $t = [regex]::Replace($t, '("[^"\\]*(?i:pass|pwd|secret|token|credential|apikey|api_key)[^"\\]*"\s*:\s*)"[^"]*"', '$1"***"')
  $t = [regex]::Replace($t, '(\\"[^"\\]*(?i:pass|pwd|secret|token|credential|apikey|api_key)[^"\\]*\\"\s*:\s*)\\"(?:[^"\\]|\\\\)*\\"', '$1\"***\"')
  $t = [regex]::Replace($t, '(?i)((?:password|pwd|user\s*password)\s*=\s*)[^;"\\]*', '$1***')
  $t
}

$script:Prozessliste = $null
function Prozessliste {
  if ($script:Prozessliste) { return $script:Prozessliste }
  $d = Lies "processengine"; $out = @()
  foreach ($art in "server_processes", "client_processes", "sub_processes", "templates") {
    foreach ($ordner in @($d.$art)) {
      if ($null -eq $ordner) { continue }
      foreach ($p in @(L $ordner.processes)) {
        if ($null -eq $p) { continue }
        $out += [pscustomobject]@{ id = $p._id; name = $p.name; version = $p._version; art = $art -replace '_processes$|s$', ''; ordner = $ordner.name; geaendert = $p._last_modified_date; von = $p._last_author }
      }
    }
  }
  $script:Prozessliste = $out
  $out
}

function Finde($liste, [string] $wer, [string] $was) {
  # Reihenfolge: ID oder exakter Name/Anzeigename, dann "Name (Zusatz)" wie bei Rollen "IT (Firma)", dann Namensteil
  $treffer = @(L $liste | Where-Object { $_.id -eq $wer -or $_._id -eq $wer -or $_.name -eq $wer -or $_.display_text -eq $wer })
  if ($treffer.Count -eq 0) { $treffer = @(L $liste | Where-Object { $_.name -like "$wer (*" -or $_.name -like "$wer *" }) }
  if ($treffer.Count -eq 0) { $treffer = @(L $liste | Where-Object { $_.name -like "*$wer*" -or $_.display_text -like "*$wer*" }) }
  if ($treffer.Count -eq 0) { throw "$was nicht gefunden: $wer" }
  if ($treffer.Count -gt 1) { throw "$was mehrdeutig: " + (($treffer | Select-Object -First 15 | ForEach-Object { "$($_.name) [$(if ($_.id) { $_.id } else { $_._id })]" }) -join ", ") }
  $treffer[0]
}

$script:Module = @{}
function Modul([string] $id) {
  if (-not $id -or $id -eq "00000000-0000-0000-0000-000000000000") { return $null }
  if (-not $script:Module.ContainsKey($id)) {
    # Modul mit Prozessorliste liegt am Projektdienst unter /api/v1/module/<id> (nicht unter dem Projekt;
    # project/<id>/module/<id> ist die Modulkonfiguration ohne Prozessoren).
    try { $script:Module[$id] = Blp-Get "$PROJEKT/api/v1/module/$id" | ConvertFrom-Json -Depth 100 } catch { Log "Modul $id nicht lesbar: $_"; $script:Module[$id] = $null }
  }
  $script:Module[$id]
}
function Baustein([string] $modulId, [string] $procId) {
  if ($procId -eq "00000000-0000-0000-0000-000000000000") { return "Start" }
  $m = Modul $modulId
  if ($m) { foreach ($p in @(L $m.processors)) { if ($p.info.id -eq $procId) { return $p.info.display_text } } }
  "Baustein $($procId.Substring(0, 8))"
}

# Kachel kurz: Name, Aktion, Prozess/Auswahl, Farbe, Sichtbarkeit
function KachelKurz($t) {
  $o = [ordered]@{ id = $t.tile_id; name = $t.name; anzeige = $t.display_text; farbe = $t.layout.color_id; sichtbar = $t.options.is_visible }
  if ($t.options.auto_execute) { $o.automatisch = $true }
  if ($t.condition) { $o.bedingung = $t.condition }
  foreach ($k in @(L $t.parameters.PSObject.Properties | Where-Object { $_.Name -ne "version" })) {
    $v = ParseJson $k.Value
    if ($k.Name -like "*ProcessStarter*" -and $v -isnot [string]) {
      $o.aktion = "Prozessstarter"
      foreach ($f in "ProcessType", "ProcessId", "ProcessName", "Process", "Selection") { if ($null -ne $v.$f -and "$($v.$f)" -ne "") { $o["prozess_$f"] = $v.$f } }
    } elseif ($k.Name -like "*ClientCommands*") { $o.aktion = "ClientCommands"; $o.befehle = Kurz $v 400 }
    else { $o[$k.Name] = Kurz $v 400 }
  }
  $o
}

# ---------- Werkzeuge ----------

$TOOLS = [System.Collections.Generic.List[object]]::new()
$HANDLER = @{}
# Bei mehreren Umgebungen bekommt jedes Werkzeug den Parameter umgebung (Rufe nimmt ihn vor dem Aufruf wieder heraus).
$UMGEBUNG_PARAM = if ($MEHRERE) { @{ type = "string"; enum = @($KONTEXTE.Keys)
  description = "Umgebung: " + (@($KONTEXTE.Values | ForEach-Object { UmgebungText $_ }) -join ", ") + ". Ohne Angabe $STANDARD." } }
function Werkzeug([string] $name, [string] $beschreibung, [hashtable] $props, [string[]] $pflicht, [scriptblock] $fn, [switch] $Schreibt) {
  if ($UMGEBUNG_PARAM) { $props = $props.Clone(); $props.umgebung = $UMGEBUNG_PARAM }
  $ann = if ($Schreibt) { @{ readOnlyHint = $false; destructiveHint = $false; idempotentHint = $false; openWorldHint = $false } } else { @{ readOnlyHint = $true; openWorldHint = $false } }
  $TOOLS.Add([ordered]@{ name = $name; description = $beschreibung
    inputSchema = [ordered]@{ type = "object"; properties = $props; required = @($pflicht); additionalProperties = $false }
    annotations = $ann })
  $HANDLER[$name] = $fn
}
$S = @{ type = "string" }

Werkzeug "blp_whoami" "Zeigt Umgebung, Projekt, angemeldeten BLP-Benutzer, Designer-Rechte und ob aendernde Werkzeuge freigeschaltet sind." @{} @() {
  $h = Header
  $info = Invoke-RestMethod -Uri "$AUTH/api/v2/auth/info" -Headers @{ Authorization = $h.Authorization } @TLS
  $perm = $null; try { $perm = (Blp-Get "$PROJEKT/api/v1/designer/permission" | ConvertFrom-Json).permissions } catch {}
  $o = [ordered]@{ umgebung = $UMGEBUNG; projektdienst = $PROJEKT; projektId = $PROJEKT_ID; benutzer = $info.user_display_name
    gruppen = @(L $info.groups | ForEach-Object { $_.name }); designerRechte = @(L $perm).Count; mcpVersion = $VERSION; aendernErlaubt = $AENDERN_ERLAUBT
    zertifikatPruefung = -not $TLS.SkipCertificateCheck; konfiguration = $K.datei; hinweis = "Veroeffentlichen macht ein Mensch im Designer, nicht der MCP." }
  if ($MEHRERE) { $o.umgebungen = @($KONTEXTE.Values | ForEach-Object { UmgebungText $_ }) }
  $o
}

Werkzeug "blp_processes" "Listet alle BLP-Prozesse (Server, Client, Sub, Vorlagen) mit ID, Version, Ordner, letzter Aenderung. Optional nach Namensteil filtern." @{ filter = @{ type = "string"; description = "Namensteil, z. B. 'Rechnung'" } } @() {
  param($a)
  $l = Prozessliste
  if ($a.filter) { $l = @(L $l | Where-Object { $_.name -like "*$($a.filter)*" }) }
  [ordered]@{ anzahl = @(L $l).Count; prozesse = @(L $l | Sort-Object art, ordner, name) }
}

Werkzeug "blp_process" "Zeigt einen Prozess: Knoten mit Baustein-Namen, Beschreibung und Parametern (gekuerzt), Verbindungen. Mit knoten = ID (auch die ersten 8 Zeichen) die vollen Parameter eines Knotens; mit roh = true das ganze JSON." @{
  prozess = @{ type = "string"; description = "Prozess-ID oder Name (auch Namensteil, wenn eindeutig)" }
  knoten = @{ type = "string"; description = "Optional: Knoten-ID oder deren Anfang" }
  roh = @{ type = "boolean"; description = "Ganzes Prozess-JSON (gekuerzt auf 60000 Zeichen)" } } @("prozess") {
  param($a)
  $e = Finde (Prozessliste) $a.prozess "Prozess"
  $p = Lies "processengine/$($e.id)"
  if ($a.roh) { return $p }
  $namen = @{}
  foreach ($n in @(L $p.nodes)) { $namen[$n.id] = $(if ($n.description) { $n.description } else { Baustein $n.module_id $n.processor_id }) }
  if ($a.knoten) {
    $n = @(L $p.nodes | Where-Object { $_.id -eq $a.knoten -or $_.id -like "$($a.knoten)*" })
    if ($n.Count -ne 1) { throw "Knoten '$($a.knoten)' nicht eindeutig gefunden ($($n.Count) Treffer)." }
    $n = $n[0]; $par = [ordered]@{}
    foreach ($k in @(L $n.parameters.PSObject.Properties)) { $par[$k.Name] = ParseJson $k.Value }
    return [ordered]@{ prozess = $p.name; knoten = $n.id; baustein = (Baustein $n.module_id $n.processor_id); beschreibung = $n.description; modul = $n.module_id; prozessor = $n.processor_id; parameter = $par
      eingaenge = @(L $p.connectors | Where-Object { $_.target_node -eq $n.id } | ForEach-Object { "$($namen[$_.source_node]) [$($_.source_port -replace '^.*\.', '')]" })
      ausgaenge = @(L $p.connectors | Where-Object { $_.source_node -eq $n.id } | ForEach-Object { "[$($_.source_port -replace '^.*\.', '')] -> $($namen[$_.target_node])" }) }
  }
  $knoten = foreach ($n in @(L $p.nodes)) {
    $par = [ordered]@{}
    foreach ($k in @(L $n.parameters.PSObject.Properties | Where-Object { $_.Name -ne "project.useditems" })) { $par[$k.Name] = Kurz $k.Value 250 }
    [ordered]@{ id = $n.id.Substring(0, [Math]::Min(8, $n.id.Length)); baustein = (Baustein $n.module_id $n.processor_id); beschreibung = $n.description; parameter = $par; fehler = $n.has_config_errors }
  }
  $verb = foreach ($c in @(L $p.connectors)) { "$($namen[$c.source_node]) [$($c.source_port -replace '^.*\.', '')] -> $($namen[$c.target_node])" }
  [ordered]@{ id = $p._id; name = $p.name; version = $p._version; art = $e.art; ordner = $e.ordner; geaendert = $p._last_modified_date; von = $p._last_author
    knoten = @(L $knoten); verbindungen = @(L $verb); hinweis = "Volle Parameter eines Knotens: knoten = <ID-Anfang>" }
}

Werkzeug "blp_objects" "Listet die Geschaeftsobjekte (ID, Name, Version, Anzahl Felder/Fuellregeln/Kacheln). Optional filtern." @{ filter = @{ type = "string" } } @() {
  param($a)
  $l = (Lies "objectmanager").objects
  if ($a.filter) { $l = @(L $l | Where-Object { $_.name -like "*$($a.filter)*" -or $_.display_text -like "*$($a.filter)*" }) }
  [ordered]@{ anzahl = @(L $l).Count; objekte = @(L $l | Sort-Object name | ForEach-Object { [ordered]@{ id = $_._id; name = $_.name; anzeige = $_.display_text; version = $_._version; felder = $_.field_count; fuellregeln = $_.filling_rule_count; kacheln = $_.tile_count } }) }
}

Werkzeug "blp_object" "Zeigt ein Geschaeftsobjekt: Felder, Fuellregeln (Datenabfrage, Bedingungsfelder), Suche, Kacheln mit Aktion/Prozess/Farbe/Bedingung. roh = true fuer das ganze JSON." @{
  objekt = @{ type = "string"; description = "Objekt-ID oder Name" }; roh = @{ type = "boolean" } } @("objekt") {
  param($a)
  $e = Finde ((Lies "objectmanager").objects) $a.objekt "Objekt"
  $o = Lies "objectmanager/$($e._id)"
  if ($a.roh) { return $o }
  [ordered]@{ id = $o._id; name = $o.name; anzeige = $o.display_text; version = $o._version; geaendert = $o._last_modified_date; infotext = $o.info_text
    felder = @(L $o.fields | ForEach-Object { [ordered]@{ name = $_.name; anzeige = $_.display_text; typ = $_.data_type } })
    fuellregeln = @(L $o.filling_rules | ForEach-Object { [ordered]@{ name = $_.name; abfrage = $_.data_query.config_id; bedingung = @(L $_.condition_fields | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } }); zuordnungen = @(L $_.field_mapping).Count; bedingungstext = $_.condition } })
    suche = Kurz $o.search 600
    kacheln = @(L $o.tiles | ForEach-Object { KachelKurz $_ }) }
}

Werkzeug "blp_tabs" "Listet die Sidebar-Tabs (Aktionsregister) mit ID, Version, Kachelzahl, Suchprofil." @{} @() {
  $t = (Lies "client/sidebar/tab/action").tabs
  [ordered]@{ anzahl = @(L $t).Count; tabs = @(L $t | ForEach-Object { [ordered]@{ id = $_._id; name = $_.name; anzeige = $_.display_text; version = $_._version; kacheln = @(L $_.tiles).Count; suchprofil = $_.smart_search_profile; geaendert = $_._last_modified_date } }) }
}

Werkzeug "blp_tab" "Zeigt einen Sidebar-Tab mit allen Kacheln (Aktion, Prozess/Auswahl, Farbe, Sichtbarkeit, Bedingung). roh = true fuer das ganze JSON." @{
  tab = @{ type = "string"; description = "Tab-ID oder Name" }; roh = @{ type = "boolean" } } @("tab") {
  param($a)
  $e = Finde ((Lies "client/sidebar/tab/action").tabs) $a.tab "Tab"
  if ($a.roh) { return $e }
  [ordered]@{ id = $e._id; name = $e.name; anzeige = $e.display_text; version = $e._version; geaendert = $e._last_modified_date; kacheln = @(L $e.tiles | ForEach-Object { KachelKurz $_ }) }
}

Werkzeug "blp_fields" "Feldverwaltung: Parameter (z. B. ECMServer, CFG.*), Variablen und Datenfelder." @{} @() {
  $f = Lies "fieldmanager"
  [ordered]@{ version = $f._version; geaendert = $f._last_modified_date
    parameter = @(L $f.parameters | ForEach-Object { [ordered]@{ name = $_.name; wert = $_.value } })
    variablen = @(L $f.variables | ForEach-Object { [ordered]@{ name = $_.name; wert = $_.value } })
    datenfelder = @(L $f.data_fields | ForEach-Object { $_.name }) }
}

Werkzeug "blp_roles" "Rollen und Situationen: welche Tabs (und wie viele Kacheln) je Rolle eingeschlossen sind. Mit rolle = Name die Kacheln je Tab (eingeschlossen/ausgeschlossen)." @{
  rolle = @{ type = "string"; description = "Optional: Rollenname fuer Details" } } @() {
  param($a)
  $roles = (Lies "role").roles
  $tabs = @{}; foreach ($t in @((Lies "client/sidebar/tab/action").tabs)) { $tabs[$t._id] = $t.name }
  if ($a.rolle) {
    $r = Finde $roles $a.rolle "Rolle"
    return [ordered]@{ rolle = $r.name; anzeige = $r.display_text; version = $r._version; situationen = @(L $r.situations | ForEach-Object {
      [ordered]@{ situation = $_.name; tabs = @(L $_.action_tabs | ForEach-Object {
        $n = if ($tabs[$_.tab_id]) { $tabs[$_.tab_id] } else { $_.settings.name }
        [ordered]@{ tab = $n; tabId = $_.tab_id; eingeschlossen = $_.include; ueberschrieben = $_.override_settings
          kachelnAus = @(L $_.actions | Where-Object { -not $_.include } | ForEach-Object { $_.settings.name }); kachelnAn = @(L $_.actions | Where-Object { $_.include }).Count } }) } }) }
  }
  [ordered]@{ anzahl = @(L $roles).Count; rollen = @(L $roles | ForEach-Object {
    $r = $_
    [ordered]@{ rolle = $r.name; version = $r._version; situationen = @(L $r.situations | ForEach-Object {
      [ordered]@{ situation = $_.name; tabsAn = @(L $_.action_tabs | Where-Object { $_.include } | ForEach-Object { if ($tabs[$_.tab_id]) { $tabs[$_.tab_id] } else { $_.settings.name } })
        tabsAus = @(L $_.action_tabs | Where-Object { -not $_.include } | ForEach-Object { if ($tabs[$_.tab_id]) { $tabs[$_.tab_id] } else { $_.settings.name } }) } }) } }) }
}

Werkzeug "blp_selection" ("Auswahlbaum des Desktop-Clients (client/selection; steht hinter 'Selection: Bereich;Dokument' in Prozessstarter-Kacheln und hinter Client.exe SELECTION=...) kompakt: " +
  "Bereich > Dokument > Prozess > Felder, je Bereich ob die Dokumente alphabetisch nach Anzeigetext sortiert sind. Aendern mit blp_change baustein=client/selection " +
  "(Pfad selections/[name=<Bereich>]/childs/...; Sortieren mit aktion sortieren). roh = true fuer das JSON (mit bereich nur dieser Bereich).") @{
  bereich = @{ type = "string"; description = "Optional: nur dieser Bereich (Name oder Anzeigetext, auch Namensteil)" }
  roh = @{ type = "boolean" } } @() {
  param($a)
  $s = Lies "client/selection"
  $bereiche = @(L $s.selections)
  if ($a.bereich) { $bereiche = @(Finde $bereiche "$($a.bereich)" "Bereich") }
  if ($a.roh) { if ($a.bereich) { return $bereiche[0] } else { return $s } }
  $leer = $false   # include fehlt = false: der Dienst laesst false beim Speichern weg (Befund 15.10.2026)
  [ordered]@{ version = $s._version; geaendert = $s._last_modified_date; von = $s._last_author; ebenen = @(L $s.layers | ForEach-Object { $_.name })
    bereiche = @(foreach ($b in $bereiche) {
      $kinder = @(L $b.childs)
      $o = [ordered]@{ bereich = $b.name }
      if ($b.display_text -ne $b.name) { $o.anzeige = $b.display_text }
      $o.eingeschlossen = $(if ($null -ne $b.include) { $b.include } else { $leer })
      if (@(L $b.fields).Count) { $o.felder = FelderText $b.fields }
      $o.anzahl = $kinder.Count
      $o.sortiert = ((ListenText $kinder) -eq (ListenText (SortiereListe $kinder)))
      $o.dokumente = @(foreach ($k in $kinder) {
        $d = [ordered]@{ dokument = $k.name }
        if ($k.display_text -ne $k.name) { $d.anzeige = $k.display_text }
        $d.prozess = $k.process; $d.felder = FelderText $k.fields
        if ($k.include -ne $true) { $d.eingeschlossen = $(if ($null -ne $k.include) { $k.include } else { $leer }) }
        if (@(L $k.childs).Count) { $d.unterknoten = @(L $k.childs).Count }
        $d })
      $o })
    hinweis = "eingeschlossen false = include fehlt im JSON (der Dienst laesst false weg). Pfade: selections/[name=<Bereich>]/childs/- (anhaengen), selections/[name=<Bereich>]/childs/[name=<Dokument>]/include; sortieren: {pfad: selections/[name=<Bereich>]/childs, aktion: sortieren}" }
}

Werkzeug "blp_dataqueries" "Listet die Datenabfragen (Name, Modul, Bedingungsfelder, Ergebnisfelder). Verbindungsdaten werden nicht gezeigt." @{ filter = @{ type = "string" } } @() {
  param($a)
  $l = Lies "dataquerymanager/load/items"
  if ($a.filter) { $l = @(L $l | Where-Object { $_.name -like "*$($a.filter)*" }) }
  [ordered]@{ anzahl = @(L $l).Count; abfragen = @(L $l | ForEach-Object { [ordered]@{ name = $_.name; modul = $_.module; typ = $_.type; bedingung = @(L $_.condition_fields | ForEach-Object { $_.name }); felder = @(L $_.fields) } }) }
}

Werkzeug "blp_published" "Stand der Veroeffentlichung am Client-Dienst (was die Sidebar gerade ausliefert): Projekte mit last_update." @{} @() {
  $j = Blp-Get "$CLIENT/api/v1/project" | ConvertFrom-Json -Depth 50
  $liste = if ($j.projects) { $j.projects } else { $j }
  [ordered]@{ clientDienst = $CLIENT; hinweis = "last_update = letzte Veroeffentlichung, die die Sidebar ausliefert"
    projekte = @(L $liste | ForEach-Object { [ordered]@{ id = $_._id; name = $_.name; version = $_._version; veroeffentlicht = $_.last_update } }) }
}

Werkzeug "blp_get" "Beliebiger lesender GET am Projektdienst (Pfad relativ zum Projekt, z. B. 'smartsearch' oder 'client/selection') oder mit fuehrendem '/' relativ zum Dienst (z. B. '/api/v1/image/package'). Antwort maskiert und gekuerzt." @{
  pfad = @{ type = "string" }; dienst = @{ type = "string"; enum = @("projekt", "client"); description = "Standard projekt" } } @("pfad") {
  param($a)
  $basis = if ($a.dienst -eq "client") { $CLIENT } else { $PROJEKT }
  if ($a.pfad -match '^[a-z]+://') { throw "Nur Pfade, keine vollstaendigen Adressen." }
  $url = if ($a.pfad.StartsWith("/")) { "$basis$($a.pfad)" } elseif ($a.dienst -eq "client") { "$basis/$($a.pfad)" } else { P $a.pfad }
  ParseJson (Blp-Get $url)
}

# ---------- Stufe 2: aendern ----------

. (Join-Path $PSScriptRoot "blp-mcp-aendern.ps1")
. (Join-Path $PSScriptRoot "blp-mcp-bilder.ps1")
. (Join-Path $PSScriptRoot "blp-mcp-bauen.ps1")

# ---------- Protokoll ----------

function Anleitung {
  "BLP (ACTIWARE Business Logic Provider)$(if ($K -and $K.organisation) { " - $($K.organisation)" }), " +
  $(if ($MEHRERE) {
    "Umgebungen: " + (@($KONTEXTE.Values | ForEach-Object { UmgebungText $_ }) -join ", ") + ". Jedes Werkzeug hat den Parameter umgebung, ohne Angabe gilt $STANDARD. " +
    "Die Umgebung nur wechseln, wenn der Anwender es will, und in der Antwort nennen. "
  } else { "Umgebung $UMGEBUNG, " + $(if ($AENDERN_ERLAUBT) { "lesen und aendern. " } else { "nur lesen (aendernde Werkzeuge gesperrt). " }) }) +
  "Aendernde Werkzeuge arbeiten zweistufig: erster Aufruf ohne freigabe liefert Pruefung und Vorschau (bisher/neu je Pfad) und einen Freigabe-Code; " +
  "erst der zweite Aufruf mit denselben Argumenten plus freigabe fuehrt aus. Vorschau dem Anwender zeigen und Zustimmung abwarten. " +
  "Prozesse, Objekte, Kacheln, Tabs, Rollen, Feldverwaltung, Auswahlbaum (client/selection), Bildpaket. " +
  "Veroeffentlichen macht ein Mensch im Designer; vorher sieht keine Sidebar eine Aenderung." +
  $(if ($K -and $K.hinweise) { " $($K.hinweise)" } else { "" })
}

function Send($obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 100 -Compress -EscapeHandling EscapeNonAscii
  $STDOUT.Write($json + "`n"); $STDOUT.Flush()
}

function Rufe([string] $name, $args2) {
  $fn = $HANDLER[$name]
  if (-not $fn) { return @{ content = @(@{ type = "text"; text = "Unbekanntes Werkzeug: $name" }); isError = $true } }
  if ($script:KonfigFehler) { return @{ content = @(@{ type = "text"; text = "Fehler: BLP-MCP ist nicht eingerichtet. $script:KonfigFehler" }); isError = $true } }
  $ziel = $STANDARD
  if ($args2.PSObject.Properties["umgebung"]) {
    $w = "$($args2.umgebung)"; $args2.PSObject.Properties.Remove("umgebung")
    if ($w) {
      $ziel = @($KONTEXTE.Keys | Where-Object { $_ -eq $w -or $KONTEXTE[$_].label -eq $w })[0]
      if (-not $ziel) { return @{ content = @(@{ type = "text"; text = "Fehler: Umgebung '$w' ist in diesem Server nicht eingerichtet (vorhanden: $(@($KONTEXTE.Keys) -join ', '))." }); isError = $true } }
    }
  }
  Setze-Umgebung $ziel
  $wo = if ($MEHRERE) { " [$ziel]" } else { "" }
  $t0 = Get-Date
  try {
    $r = & $fn $args2
    $text = Maskiere (ConvertTo-Json -InputObject $r -Depth 60)
    if ($text.Length -gt $MAX_TEXT) { $text = $text.Substring(0, $MAX_TEXT) + "`n... (gekuerzt, $($text.Length) Zeichen insgesamt - enger fragen, z. B. knoten oder filter)" }
    Log "$name$wo ok ($([int]((Get-Date) - $t0).TotalMilliseconds) ms)"
    @{ content = @(@{ type = "text"; text = $text }) }
  } catch {
    $m = Maskiere "$($_.Exception.Message)"
    Log "$name$wo FEHLER $m"
    @{ content = @(@{ type = "text"; text = "Fehler: $m" }); isError = $true }
  }
}

if ($MEHRERE) { Log "gestartet: v$VERSION, Umgebungen $(@($KONTEXTE.Values | ForEach-Object { UmgebungText $_ }) -join ', '), $($TOOLS.Count) Werkzeuge" }
else { Log "gestartet: v$VERSION, Umgebung $UMGEBUNG, Projekt $PROJEKT_ID, $($TOOLS.Count) Werkzeuge, aendern $(if ($AENDERN_ERLAUBT) { "erlaubt" } else { "gesperrt" })" }
while ($null -ne ($zeile = [Console]::In.ReadLine())) {
  if (-not $zeile.Trim()) { continue }
  try { $msg = $zeile | ConvertFrom-Json -AsHashtable -Depth 100 } catch { Send @{ jsonrpc = "2.0"; id = $null; error = @{ code = -32700; message = "Kein gueltiges JSON" } }; continue }
  $id = $msg.id; $m = "$($msg.method)"
  try {
    switch ($m) {
      "initialize" {
        $pv = if ($msg.params -and $msg.params.protocolVersion) { $msg.params.protocolVersion } else { "2025-06-18" }
        Send @{ jsonrpc = "2.0"; id = $id; result = @{ protocolVersion = $pv; capabilities = @{ tools = @{ listChanged = $false } }
          serverInfo = @{ name = "blp"; version = $VERSION }
          instructions = (Anleitung) } }
      }
      "ping" { Send @{ jsonrpc = "2.0"; id = $id; result = @{} } }
      "tools/list" { Send @{ jsonrpc = "2.0"; id = $id; result = @{ tools = $TOOLS } } }
      "tools/call" {
        $a = if ($msg.params.arguments) { [pscustomobject] $msg.params.arguments } else { [pscustomobject] @{} }
        Send @{ jsonrpc = "2.0"; id = $id; result = (Rufe "$($msg.params.name)" $a) }
      }
      default {
        if ($m -like "notifications/*" -or $null -eq $id) { continue }
        Send @{ jsonrpc = "2.0"; id = $id; error = @{ code = -32601; message = "Methode nicht unterstuetzt: $m" } }
      }
    }
  } catch {
    Send @{ jsonrpc = "2.0"; id = $id; error = @{ code = -32603; message = (Maskiere "$($_.Exception.Message)") } }
  }
}
Log "stdin geschlossen, beende"
