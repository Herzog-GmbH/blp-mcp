<#
.SYNOPSIS
  Offline-Tests fuer den BLP-MCP-Server: kein BLP, kein Netz, keine Zugangsdaten noetig.
.DESCRIPTION
  1. Hilfsfunktionen der Zeitplan-Trigger (blp-mcp-trigger.ps1) mit Platzhaltern fuer Werkzeug/L geladen und geprueft.
  2. Modulpakete lesen und ungueltige Manifeste abweisen.
  3. Server ohne Konfiguration gestartet: startet trotzdem, listet alle Werkzeuge (auch blp_triggers, blp_create_trigger,
     triggermanager in blp_change) und meldet beim Aufruf "nicht eingerichtet" statt abzustuerzen.
  Ende mit Exit-Code 0 = alles gruen, sonst Anzahl Fehler.
.EXAMPLE
  pwsh -NoProfile -File test-offline.ps1
#>
$ErrorActionPreference = "Stop"
$script:Fehler = 0; $script:Gut = 0
function Gleich($ist, $soll, [string] $was) {
  $a = ConvertTo-Json -InputObject $ist -Depth 20 -Compress; $b = ConvertTo-Json -InputObject $soll -Depth 20 -Compress
  if ($a -ceq $b) { $script:Gut++ } else { $script:Fehler++; Write-Host "FEHLER $was`n  ist:  $a`n  soll: $b" -ForegroundColor Red }
}
function Wirft([scriptblock] $b, [string] $muster, [string] $was) {
  try { & $b; $script:Fehler++; Write-Host "FEHLER $was : keine Ausnahme" -ForegroundColor Red }
  catch { if ("$($_.Exception.Message)" -like "*$muster*") { $script:Gut++ } else { $script:Fehler++; Write-Host "FEHLER $was : '$($_.Exception.Message)' ohne '$muster'" -ForegroundColor Red } }
}

# ---------- 1. Trigger-Hilfen ----------

function Werkzeug { }   # Platzhalter: hier werden keine Werkzeuge registriert
function L($x) { if ($null -ne $x) { $x } }
. (Join-Path $PSScriptRoot "blp-mcp-trigger.ps1")

Gleich (WochentageLesen "Mo-Sa") @("mon", "tue", "wed", "thu", "fri", "sat") "Wochentage Mo-Sa"
Gleich (WochentageLesen "Mo,Mi, fr") @("mon", "wed", "fri") "Wochentage Liste"
Gleich (WochentageLesen @("so", "mo")) @("mon", "sun") "Wochentage als Array, sortiert"
Gleich (WochentageLesen "mon-wed") @("mon", "tue", "wed") "Wochentage englisch"
Wirft { WochentageLesen "Sa-Mo" } "rueckwaerts" "Bereich rueckwaerts"
Wirft { WochentageLesen "Xy" } "unbekannt" "Wochentag unbekannt"
Wirft { WochentageLesen "" } "leer" "Wochentage leer"

Gleich (UhrzeitLesen "06:00" "von") ([ordered]@{ hour = 6; minute = 0 }) "Uhrzeit 06:00"
Gleich (UhrzeitLesen "17" "bis") ([ordered]@{ hour = 17; minute = 0 }) "Uhrzeit 17"
Wirft { UhrzeitLesen "24:00" "bis" } "ausserhalb" "Uhrzeit 24:00"
Wirft { UhrzeitLesen "6 Uhr" "von" } "nicht lesbar" "Uhrzeit Text"

# Ein im Designer per Rohweg angelegter Trigger (16.11.2026) muss genau so herauskommen.
$prod = '{"type":2,"instances_to_start":1,"max_concurrency":1,"repeat":{"every":10,"every_unit":2},"time_range":{"start":{"hour":6,"minute":0},"end":{"hour":17,"minute":0}},"recur":1,"weekdays":{"mon":true,"tue":true,"wed":true,"thu":true,"fri":true,"sat":true}}'
$s = ZeitplanBauen ([pscustomobject]@{ art = "woechentlich"; wochentage = "Mo-Sa"; von = "06:00"; bis = "17:00"; alle = 10; einheit = "minuten" })
Gleich (ConvertTo-Json -InputObject $s -Depth 10 -Compress) $prod "ZeitplanBauen = Rumpf Belegabgleich"
Gleich (ZeitplanText ($prod | ConvertFrom-Json)) "woechentlich Mo-Sa, 06:00-17:00, alle 10 Minuten" "ZeitplanText woechentlich"

$taeglich = '{"type":1,"instances_to_start":1,"max_concurrency":1,"repeat":{"every":15,"every_unit":1},"time_range":{"start":{"hour":0,"minute":0},"end":{"hour":23,"minute":59}},"recur":1,"weekdays":{},"months":{"jan":true,"feb":true,"mar":true,"apr":true,"may":true,"june":true,"july":true,"aug":true,"sept":true,"oct":true,"nov":true,"dec":true},"months_on":{"weekdays":{}}}' | ConvertFrom-Json
Gleich (ZeitplanText $taeglich) "taeglich, 00:00-23:59, alle 15 Sekunden" "ZeitplanText taeglich (Bestand Test)"
$st = ZeitplanBauen ([pscustomobject]@{ art = "taeglich"; alle = 30; einheit = "sekunden" })
Gleich $st.type 1 "taeglich = type 1"
Gleich @($st.months.Keys).Count 12 "taeglich mit allen Monaten"
Gleich (ZeitplanText ([pscustomobject] $st)) "taeglich, 00:00-23:59, alle 30 Sekunden" "ZeitplanText aus ZeitplanBauen"
Gleich (ZeitplanText ('{"type":2,"recur":2,"weekdays":{"mon":true,"wed":true},"repeat":{"every":0,"every_unit":2},"time_range":{"start":{"hour":8,"minute":30},"end":{"hour":9,"minute":0}},"max_concurrency":2}' | ConvertFrom-Json)) `
  "woechentlich Mo,Mi (jede 2. Woche), 08:30-09:00, einmal, bis 2 parallel" "ZeitplanText Sonderfaelle"
Gleich (ZeitplanText $null) "(kein Zeitplan)" "ZeitplanText ohne Zeitplan"

Wirft { ZeitplanBauen ([pscustomobject]@{ alle = 0 }) } "ganze Zahl" "alle 0"
Wirft { ZeitplanBauen ([pscustomobject]@{ alle = 5; einheit = "sekunden"; art = "taeglich" }) } "30 Sekunden" "zu kurz"
Wirft { ZeitplanBauen ([pscustomobject]@{ alle = 5; art = "monatlich" }) } "Designer" "monatlich"
Wirft { ZeitplanBauen ([pscustomobject]@{ alle = 5; von = "17:00"; bis = "06:00"; wochentage = "Mo" }) } "nach von" "bis vor von"
Wirft { ZeitplanBauen ([pscustomobject]@{ alle = 5 }) } "leer" "woechentlich ohne Tage"

$gueltig = '{"_process":"0123456789abcdef01234567","name":"X","enabled":true,"schedule":' + $prod + '}' | ConvertFrom-Json
Gleich @(TriggerPruefen $gueltig).Count 0 "TriggerPruefen gueltig"
$kaputt = '{"_process":"","name":" ","enabled":"ja","schedule":{"type":3,"repeat":{"every":"x","every_unit":9},"time_range":{"start":{"hour":25,"minute":0},"end":{"hour":1,"minute":0}}}}' | ConvertFrom-Json
Gleich @(TriggerPruefen $kaputt).Count 7 "TriggerPruefen findet alle sieben Fehler (name, _process, enabled, type, every, every_unit, start)"
$ohneTag = '{"_process":"a","name":"X","schedule":{"type":2,"weekdays":{"mon":false}}}' | ConvertFrom-Json
Gleich @(TriggerPruefen $ohneTag) @("woechentlich ohne Wochentag - der Trigger liefe nie.") "TriggerPruefen woechentlich ohne Tag"

$t = ('{"_id":"6afaf771","_process":"p1","name":"EK","enabled":false,"_version":"2.0","schedule":' + $prod + '}') | ConvertFrom-Json
$k = TriggerKurz $t @{ p1 = "Belegabgleich" }
Gleich $k.prozess "Belegabgleich [p1]" "TriggerKurz Prozessname"
Gleich $k.aktiv $false "TriggerKurz aktiv"
Gleich (TriggerKurz $t @{}).prozess "(Prozess nicht gefunden) [p1]" "TriggerKurz ohne Prozess"

# ---------- 2. Modulpakete ----------

function JObj([string] $json) { $json | ConvertFrom-Json -Depth 100 }
$DATEN = [IO.Path]::GetTempPath()
. (Join-Path $PSScriptRoot "blp-mcp-module.ps1")

function BeispielModulpaket([string] $manifest) {
  $pfad = Join-Path $DATEN ("blp-modulprobe-" + [guid]::NewGuid() + ".mod")
  $archiv = [IO.Compression.ZipFile]::Open($pfad, [IO.Compression.ZipArchiveMode]::Create)
  try {
    if ($manifest) {
      $eintrag = $archiv.CreateEntry("info.json")
      $text = [IO.StreamWriter]::new($eintrag.Open())
      try { $text.Write($manifest) } finally { $text.Dispose() }
    }
  } finally { $archiv.Dispose() }
  $pfad
}

$paket = BeispielModulpaket '{"module_id":"cd308f43-df8c-48eb-aa9c-a95ccaddacac","name":"Probe","version":"1.2.3.4"}'
$kaputtesPaket = BeispielModulpaket '{"module_id":"keine-guid","name":"Probe","version":"1.2.3.4"}'
$leeresPaket = BeispielModulpaket ""
try {
  Gleich (ModulpaketManifest $paket).version "1.2.3.4" "Modulpaket liest Version aus info.json"
  Wirft { ModulpaketManifest $kaputtesPaket } "module_id" "Modulpaket weist ungültige ID ab"
  Wirft { ModulpaketManifest $leeresPaket } "fehlt info.json" "Modulpaket braucht Manifest"
} finally {
  foreach ($datei in @($paket, $kaputtesPaket, $leeresPaket)) { [IO.File]::Delete($datei) }
}

# ---------- 2b. Aendern-Hilfen (verschieben) ----------

function Erlaubt($k) { $false }
$K = $null
. (Join-Path $PSScriptRoot "blp-mcp-aendern.ps1")
$tab = '{"name":"Beispiel","tiles":[{"name":"A","tile_id":"t1"},{"name":"B","tile_id":"t2"},{"name":"C","tile_id":"t3"},{"name":"D","tile_id":"t4"}]}'
function Reihe($o) { (@($o.tiles | ForEach-Object { $_.name })) -join "" }
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[name=C]"; aktion = "verschieben"; wert = 0 }))) "CABD" "verschieben an Position 0"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[name=A]"; aktion = "verschieben"; wert = "ende" }))) "BCDA" "verschieben ans Ende"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[name=D]"; aktion = "verschieben"; wert = "anfang" }))) "DABC" "verschieben an den Anfang"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[name=A]"; aktion = "verschieben"; wert = @{ nach = "[name=C]" } }))) "BCAD" "verschieben nach C"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[tile_id^=t4]"; aktion = "verschieben"; wert = @{ vor = "[name=B]" } }))) "ADBC" "verschieben vor B, Auswahl per tile_id"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/1"; aktion = "verschieben"; wert = "3" }))) "ACDB" "verschieben per Index, Position als Text"
Gleich (Reihe (Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "entfernen" }))) "ACD" "entfernen einer Kachel"
Wirft { Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "verschieben"; wert = 1 }) } "steht schon" "verschieben an dieselbe Stelle"
Wirft { Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "verschieben"; wert = 9 }) } "gibt es nicht" "verschieben hinter das Ende"
Wirft { Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "verschieben"; wert = @{ vor = "[name=X]" } }) } "0 Treffer" "verschieben vor unbekannte Kachel"
Wirft { Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "verschieben" }) } "wert fehlt" "verschieben ohne Ziel"
Wirft { Wende (JObj $tab) @(@{ pfad = "name"; aktion = "verschieben"; wert = 0 }) } "Listenelement" "verschieben ohne Liste"
Wirft { Wende (JObj $tab) @(@{ pfad = "tiles/[name=B]"; aktion = "verschieben"; wert = @{ vor = "[name=A]"; nach = "[name=C]" } }) } "vor: auswahl" "vor und nach zugleich"

# ---------- 3. Server ohne Konfiguration ----------

$cfg = Join-Path ([IO.Path]::GetTempPath()) "blp-mcp-offline-gibt-es-nicht.json"
$psi = [Diagnostics.ProcessStartInfo]::new("pwsh", "-NoProfile -NoLogo -NonInteractive -File `"$(Join-Path $PSScriptRoot 'blp-mcp.ps1')`" -Config `"$cfg`"")
$psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$pr = [Diagnostics.Process]::Start($psi)
$null = $pr.StandardError.ReadToEndAsync()
function Rpc($id, $method, $params) {
  $pr.StandardInput.WriteLine((@{ jsonrpc = "2.0"; id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress)); $pr.StandardInput.Flush()
  $z = $pr.StandardOutput.ReadLine(); if (-not $z) { throw "Server antwortet nicht (abgestuerzt?)" }
  $z | ConvertFrom-Json -Depth 50
}
try {
  $init = Rpc 1 "initialize" @{ protocolVersion = "2025-06-18"; capabilities = @{}; clientInfo = @{ name = "offline"; version = "1" } }
  Gleich ([bool] ($init.result.instructions -like "*blp_triggers*")) $true "Anleitung nennt blp_triggers"
  $tools = (Rpc 2 "tools/list" @{}).result.tools
  $namen = @($tools | ForEach-Object { $_.name })
  foreach ($n in "blp_triggers", "blp_create_trigger", "blp_change", "blp_reports", "blp_desktop_plugins", "blp_smartsearch_commands", "blp_module_install") { Gleich ($n -in $namen) $true "Werkzeug $n vorhanden" }
  Gleich (@($namen | Select-Object -Unique).Count) $namen.Count "Werkzeugnamen eindeutig"
  $change = $tools | Where-Object name -eq "blp_change"
  Gleich ("triggermanager" -in @($change.inputSchema.properties.baustein.enum)) $true "blp_change kennt triggermanager"
  Gleich ("verschieben" -in @($change.inputSchema.properties.aenderungen.items.properties.aktion.enum)) $true "blp_change kennt verschieben"
  Gleich ([bool] (($tools | Where-Object name -eq "blp_published").inputSchema.properties.pruefen)) $true "blp_published hat pruefen"
  $ct = $tools | Where-Object name -eq "blp_create_trigger"
  Gleich $ct.annotations.readOnlyHint $false "blp_create_trigger ist schreibend markiert"
  Gleich @($ct.inputSchema.required) @("name", "prozess", "alle", "aktiv") "blp_create_trigger Pflichtfelder"
  Gleich (($tools | Where-Object name -eq "blp_triggers").annotations.readOnlyHint) $true "blp_triggers ist lesend markiert"
  Gleich (($tools | Where-Object name -eq "blp_module_install").annotations.readOnlyHint) $false "blp_module_install ist schreibend markiert"
  Gleich (($tools | Where-Object name -eq "blp_desktop_plugins").annotations.readOnlyHint) $true "blp_desktop_plugins ist lesend markiert"
  Gleich (($tools | Where-Object name -eq "blp_smartsearch_commands").annotations.readOnlyHint) $true "blp_smartsearch_commands ist lesend markiert"
  $r = (Rpc 3 "tools/call" @{ name = "blp_triggers"; arguments = @{} }).result
  Gleich ([bool] $r.isError) $true "blp_triggers ohne Konfiguration = Fehler"
  Gleich ([bool] ($r.content[0].text -like "*nicht eingerichtet*")) $true "Fehlertext nennt 'nicht eingerichtet'"
} catch { $script:Fehler++; Write-Host "FEHLER Serverteil: $_" -ForegroundColor Red }
finally { $pr.StandardInput.Close(); if (-not $pr.WaitForExit(30000)) { $pr.Kill() } }

Write-Host ("{0} ok, {1} Fehler" -f $script:Gut, $script:Fehler) -ForegroundColor $(if ($script:Fehler) { "Red" } else { "Green" })
exit $script:Fehler
