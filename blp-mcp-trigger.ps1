# blp-mcp-trigger.ps1 - Zeitplan-Trigger (Designer: Trigger) lesen und anlegen.
# Wird von blp-mcp.ps1 per Dot-Sourcing eingebunden (nutzt Lies, Blp-Send, P, Finde, Prozessliste, L, Kurz, JObj, JStr,
# ZweiSchritte, Werkzeug, $SICHERUNG, $UMGEBUNG). Aendern und Aktivieren laeuft ueber blp_change mit baustein triggermanager.
#
# Designer-API (Bundle index-ddc35882.js, belegt 16.11.2026 an Test und Produktiv):
#   GET    triggermanager              -> {triggers: [...]} (ganze Trigger, mit _read_token)
#   GET    triggermanager/<id>         -> ein Trigger
#   PUT    triggermanager              -> neu anlegen (Rumpf ohne _id; Antwort der neue Trigger)
#   POST   triggermanager/<id>[/checkout|/commit|/undo] mit _read_token -> wie bei Prozessen (blp_change)
#   DELETE triggermanager/<id>         -> loeschen (bietet der MCP nicht an, das macht ein Mensch im Designer)
# Ein Trigger: _process (Prozess-ID), name, description, type 0, start, schedule, parameters, enabled, bei alten
# Triggern auch start_parameters und message_queue (password -> wird maskiert).
# schedule.type 1 = taeglich, 2 = woechentlich (weekdays mon..sun), 4 = monatlich (months jan, feb, mar, apr, may, june,
# july, aug, sept, oct, nov, dec; months_on). repeat.every_unit 0 = ms, 1 = Sekunden, 2 = Minuten, 3 = Stunden,
# 4 = Tage, 5 = Monate, 6 = Jahre. time_range start/end {hour, minute} = Zeitfenster am Tag, recur = jede n-te Woche.
# Wirksam wird ein Trigger wie alles andere erst nach dem Veroeffentlichen im Designer.

# Zahlen-Schluessel nur in normalen Hashtables: [ordered][1] waere der Eintrag an Stelle 1, nicht der Schluessel 1.
$ZEITPLAN_ART = @{ 1 = "taeglich"; 2 = "woechentlich"; 4 = "monatlich" }
$ZEIT_EINHEIT = @{ 0 = "Millisekunden"; 1 = "Sekunden"; 2 = "Minuten"; 3 = "Stunden"; 4 = "Tage"; 5 = "Monate"; 6 = "Jahre" }
# Wochentage: Schluessel im BLP -> Kurzname deutsch (Reihenfolge Mo..So)
$WOCHENTAGE = [ordered]@{ mon = "Mo"; tue = "Di"; wed = "Mi"; thu = "Do"; fri = "Fr"; sat = "Sa"; sun = "So" }
$MONATE = @("jan", "feb", "mar", "apr", "may", "june", "july", "aug", "sept", "oct", "nov", "dec")

function Uhrzeit($t) { if ($null -eq $t) { return "?" }; "{0:00}:{1:00}" -f [int] $t.hour, [int] $t.minute }

# "Mo-Sa", "Mo,Mi,Fr", @("mo","di"), "mon,tue" -> Liste der BLP-Schluessel in Wochenreihenfolge
function WochentageLesen($w) {
  $teile = @(foreach ($x in @(L $w)) { "$x" -split '[,;\s]+' } ) | Where-Object { $_ }
  if ($teile.Count -eq 0) { throw "wochentage ist leer (z. B. 'Mo-Fr' oder 'Mo,Mi,Fr')." }
  $schl = @($WOCHENTAGE.Keys); $kurz = @($WOCHENTAGE.Values | ForEach-Object { $_.ToLowerInvariant() })
  function Tag([string] $s) {
    $s = $s.Trim().ToLowerInvariant()
    for ($i = 0; $i -lt $schl.Count; $i++) { if ($s -eq $schl[$i] -or $s -eq $kurz[$i]) { return $i } }
    throw "Wochentag '$s' unbekannt (Mo, Di, Mi, Do, Fr, Sa, So)."
  }
  $an = [bool[]]::new(7)
  foreach ($t in $teile) {
    if ($t -match '^(.+?)-(.+)$') {
      $a = Tag $Matches[1]; $b = Tag $Matches[2]
      if ($b -lt $a) { throw "Bereich '$t' rueckwaerts - Mo-Sa statt Sa-Mo." }
      for ($i = $a; $i -le $b; $i++) { $an[$i] = $true }
    } else { $an[(Tag $t)] = $true }
  }
  ,@(for ($i = 0; $i -lt 7; $i++) { if ($an[$i]) { $schl[$i] } })
}

# "06:00" / "6" -> @{hour; minute}
function UhrzeitLesen([string] $s, [string] $was) {
  if ("$s".Trim() -notmatch '^(\d{1,2})(?::(\d{2}))?$') { throw "$was '$s' nicht lesbar, Form 06:00." }
  $h = [int] $Matches[1]; $m = if ($Matches[2]) { [int] $Matches[2] } else { 0 }
  if ($h -gt 23 -or $m -gt 59) { throw "$was '$s' ausserhalb 00:00 bis 23:59." }
  [ordered]@{ hour = $h; minute = $m }
}

# Zeitplan als Satz, z. B. "woechentlich Mo-Sa, 06:00-17:00, alle 10 Minuten"
function ZeitplanText($s) {
  if ($null -eq $s) { return "(kein Zeitplan)" }
  $art = $ZEITPLAN_ART[[int] $s.type]; if (-not $art) { $art = "Art $($s.type)" }
  $teile = @($art)
  if ([int] $s.type -eq 2) {
    $tage = @(foreach ($k in $WOCHENTAGE.Keys) { if ($s.weekdays -and $s.weekdays.$k) { $WOCHENTAGE[$k] } })
    $teile[0] = "$art " + $(if ($tage.Count -eq 0) { "(kein Wochentag!)" } else { TageText $tage })
    if ([int] $s.recur -gt 1) { $teile[0] += " (jede $($s.recur). Woche)" }
  }
  if ([int] $s.type -eq 4) {
    $m = @(foreach ($k in $MONATE) { if ($s.months -and $s.months.$k) { $k } })
    $teile[0] = "$art " + $(if ($m.Count -eq 12) { "(alle Monate)" } else { "(" + ($m -join ",") + ")" })
  }
  if ($s.time_range) { $teile += "$(Uhrzeit $s.time_range.start)-$(Uhrzeit $s.time_range.end)" }
  if ($s.repeat -and [int] $s.repeat.every -gt 0) {
    $e = $ZEIT_EINHEIT[[int] $s.repeat.every_unit]; if (-not $e) { $e = "Einheit $($s.repeat.every_unit)" }
    $teile += "alle $($s.repeat.every) $e"
  } else { $teile += "einmal" }
  if ([int] $s.max_concurrency -gt 1) { $teile += "bis $($s.max_concurrency) parallel" }
  $teile -join ", "
}
# Mo,Di,Mi,Do,Fr,Sa -> "Mo-Sa"; Luecken bleiben als Liste
function TageText([string[]] $tage) {
  $alle = @($WOCHENTAGE.Values); $idx = @($tage | ForEach-Object { [array]::IndexOf($alle, $_) })
  $zus = $idx.Count -gt 2 -and ($idx[-1] - $idx[0] + 1) -eq $idx.Count
  if ($zus) { "$($tage[0])-$($tage[-1])" } else { $tage -join "," }
}

# Kurzform fuer Listen; $prozesse = Hashtable Prozess-ID -> Name
function TriggerKurz($t, $prozesse) {
  $pn = if ($prozesse -and $prozesse.ContainsKey("$($t._process)")) { $prozesse["$($t._process)"] } else { "(Prozess nicht gefunden)" }
  [ordered]@{ id = $t._id; name = $t.name; aktiv = [bool] $t.enabled; prozess = "$pn [$($t._process)]"; zeitplan = (ZeitplanText $t.schedule)
    version = $t._version; geaendert = $t._last_modified_date; von = $t._last_author }
}

# Zeitplan aus den Argumenten von blp_create_trigger
function ZeitplanBauen($a) {
  $art = "$($a.art)"; if (-not $art) { $art = "woechentlich" }
  if ($art -notin "taeglich", "woechentlich") { throw "art '$art': moeglich sind taeglich und woechentlich (monatlich im Designer anlegen)." }
  $alle = 0; if (-not [int]::TryParse("$($a.alle)", [ref] $alle) -or $alle -lt 1) { throw "alle muss eine ganze Zahl ab 1 sein (z. B. 10)." }
  $einheiten = @{ sekunden = 1; minuten = 2; stunden = 3 }
  $einheit = "$($a.einheit)"; if (-not $einheit) { $einheit = "minuten" }
  if (-not $einheiten.ContainsKey($einheit)) { throw "einheit '$einheit': sekunden, minuten oder stunden." }
  if ($einheit -eq "sekunden" -and $alle -lt 30) { throw "Kuerzer als alle 30 Sekunden legt der MCP nicht an (Last auf dem Prozessdienst)." }
  $von = UhrzeitLesen $(if ($a.von) { "$($a.von)" } else { "00:00" }) "von"
  $bis = UhrzeitLesen $(if ($a.bis) { "$($a.bis)" } else { "23:59" }) "bis"
  if (($bis.hour * 60 + $bis.minute) -le ($von.hour * 60 + $von.minute)) { throw "bis ($(Uhrzeit $bis)) muss nach von ($(Uhrzeit $von)) liegen." }
  $s = [ordered]@{ type = $(if ($art -eq "taeglich") { 1 } else { 2 }); instances_to_start = 1; max_concurrency = 1
    repeat = [ordered]@{ every = $alle; every_unit = $einheiten[$einheit] }
    time_range = [ordered]@{ start = $von; end = $bis }; recur = 1 }
  if ($art -eq "woechentlich") {
    $w = [ordered]@{}; foreach ($k in (WochentageLesen $a.wochentage)) { $w[$k] = $true }
    $s.weekdays = $w
  } else {
    # wie die taeglichen Trigger im Bestand (Test, 2021): weekdays leer, alle Monate an
    $s.weekdays = [ordered]@{}; $m = [ordered]@{}; foreach ($k in $MONATE) { $m[$k] = $true }; $s.months = $m
  }
  $s
}

# Pruefung eines Triggers vor dem Speichern (auch fuer blp_change baustein triggermanager)
function TriggerPruefen($t) {
  $f = [System.Collections.Generic.List[string]]::new()
  if (-not "$($t.name)".Trim()) { $f.Add("name ist leer.") }
  if (-not "$($t._process)") { $f.Add("_process (Prozess-ID) fehlt.") }
  if ($null -ne $t.enabled -and $t.enabled -isnot [bool]) { $f.Add("enabled muss true oder false sein.") }
  $s = $t.schedule
  if ($null -eq $s) { $f.Add("schedule fehlt."); return $f.ToArray() }
  if ([int] $s.type -notin 1, 2, 4) { $f.Add("schedule/type $($s.type) unbekannt (1 taeglich, 2 woechentlich, 4 monatlich).") }
  if ($s.repeat) {
    if ("$($s.repeat.every)" -notmatch '^\d+$') { $f.Add("schedule/repeat/every muss eine ganze Zahl sein.") }
    if ("$($s.repeat.every_unit)" -notmatch '^[0-6]$') { $f.Add("schedule/repeat/every_unit 0..6 (2 = Minuten).") }
  }
  foreach ($e in "start", "end") {
    $z = if ($s.time_range) { $s.time_range.$e } else { $null }
    if ($null -ne $z -and (("$($z.hour)" -notmatch '^\d+$') -or [int] $z.hour -gt 23 -or ("$($z.minute)" -notmatch '^\d+$') -or [int] $z.minute -gt 59)) { $f.Add("schedule/time_range/$e ausserhalb 00:00 bis 23:59.") }
  }
  if ([int] $s.type -eq 2 -and -not @($WOCHENTAGE.Keys | Where-Object { $s.weekdays -and $s.weekdays.$_ -eq $true }).Count) { $f.Add("woechentlich ohne Wochentag - der Trigger liefe nie.") }
  $f.ToArray()
}

function Triggerliste { @(L (Lies "triggermanager").triggers) }
function Prozessnamen { $h = @{}; foreach ($p in @(L (Prozessliste))) { $h["$($p.id)"] = $p.name }; $h }

Werkzeug "blp_triggers" ("Zeitplan-Trigger (Designer: Trigger): welcher Prozess wann laeuft, aktiv oder nicht, als Satz (z. B. 'woechentlich Mo-Sa, 06:00-17:00, alle 10 Minuten'). " +
  "Mit trigger = Name oder ID der ganze Trigger mit Zeitplan und Pfaden zum Aendern; roh = true das JSON. " +
  "Aendern/aktivieren mit blp_change baustein=triggermanager (Pfade enabled, schedule/...), neu anlegen mit blp_create_trigger. Wirksam erst nach Veroeffentlichen.") @{
  trigger = @{ type = "string"; description = "Optional: Triggername oder ID fuer Details" }
  filter = @{ type = "string"; description = "Optional: Teil des Trigger- oder Prozessnamens" }
  roh = @{ type = "boolean"; description = "Mit trigger: ganzes JSON" } } @() {
  param($a)
  $liste = Triggerliste; $pn = Prozessnamen
  if ($a.trigger) {
    $t = Finde $liste "$($a.trigger)" "Trigger"
    if ($a.roh) { return $t }
    $o = TriggerKurz $t $pn
    $o.beschreibung = $t.description; $o.start = $t.start; $o.typ = $t.type; $o.zeitplanRoh = $t.schedule
    if ($t.parameters -and @($t.parameters.PSObject.Properties).Count) { $o.parameter = $t.parameters }
    if ($t.message_queue -and ([int] $t.message_queue.type -ne 0 -or $t.message_queue.address)) { $o.messageQueue = $t.message_queue }
    $andere = @($liste | Where-Object { $_._process -eq $t._process -and $_._id -ne $t._id })
    if ($andere.Count) { $o.auchFuerDiesenProzess = @($andere | ForEach-Object { "$($_.name) [$($_._id)]" }) }
    $o.pfade = "blp_change baustein=triggermanager objekt='$($t.name)': enabled (true/false), schedule/repeat/every, schedule/repeat/every_unit (1 s, 2 min, 3 h), " +
      "schedule/time_range/start/hour, schedule/time_range/end/hour, schedule/weekdays/<mon..sun>, description"
    return $o
  }
  if ($a.filter) { $f = "$($a.filter)"; $liste = @($liste | Where-Object { $_.name -like "*$f*" -or $pn["$($_._process)"] -like "*$f*" }) }
  [ordered]@{ anzahl = $liste.Count; aktiv = @($liste | Where-Object { $_.enabled }).Count
    trigger = @($liste | Sort-Object name | ForEach-Object { TriggerKurz $_ $pn })
    hinweis = "Stand im Designer; die Sidebar-/Prozessdienste sehen Aenderungen erst nach dem Veroeffentlichen. Ob ein Trigger laeuft: blp_reports mit prozess." }
}

Werkzeug "blp_create_trigger" ("Legt einen Zeitplan-Trigger fuer einen Serverprozess an (zweistufig: Vorschau, dann mit freigabe; PUT triggermanager). " +
  "Zeitplan: art taeglich oder woechentlich (mit wochentage, z. B. 'Mo-Sa'), Zeitfenster von/bis, Wiederholung alle + einheit. " +
  "Vorher wird die Triggerliste gesichert. Wirksam erst nach Veroeffentlichen im Designer. Nur in Umgebungen mit allowChanges.") @{
  name = @{ type = "string"; description = "Name des Triggers, z. B. 'Belegabgleich'" }
  prozess = @{ type = "string"; description = "Prozess, den der Trigger startet (ID oder Name)" }
  beschreibung = @{ type = "string" }
  art = @{ type = "string"; enum = @("woechentlich", "taeglich"); description = "Standard woechentlich" }
  wochentage = @{ type = "string"; description = "Bei woechentlich: z. B. 'Mo-Fr', 'Mo-Sa' oder 'Mo,Mi,Fr'" }
  von = @{ type = "string"; description = "Beginn des Zeitfensters, z. B. '06:00' (Standard 00:00)" }
  bis = @{ type = "string"; description = "Ende des Zeitfensters, z. B. '17:00' (Standard 23:59)" }
  alle = @{ type = "integer"; description = "Wiederholung im Zeitfenster, z. B. 10" }
  einheit = @{ type = "string"; enum = @("minuten", "stunden", "sekunden"); description = "Standard minuten" }
  aktiv = @{ type = "boolean"; description = "Trigger eingeschaltet anlegen (true) oder aus (false)" }
  freigabe = @{ type = "string" } } @("name", "prozess", "alle", "aktiv") {
  param($a)
  ZweiSchritte "blp_create_trigger" $a {
    $name = "$($a.name)".Trim(); if (-not $name) { throw "name ist leer." }
    $liste = Triggerliste
    if (@($liste | Where-Object { $_.name -eq $name }).Count) { throw "Es gibt schon einen Trigger '$name' - aendern mit blp_change baustein=triggermanager." }
    $p = Finde (Prozessliste) "$($a.prozess)" "Prozess"
    $s = ZeitplanBauen $a
    $def = [pscustomobject][ordered]@{ _process = $p.id; item_id = "00000000-0000-0000-0000-000000000000"; module_id = "00000000-0000-0000-0000-000000000000"
      trigger_id = "00000000-0000-0000-0000-000000000000"; name = $name; description = "$($a.beschreibung)"; type = 0
      start = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"); schedule = $s; parameters = [pscustomobject]@{}; enabled = [bool] $a.aktiv }
    $def = JObj (JStr $def)
    $fehler = @(L (TriggerPruefen $def)); if ($fehler.Count) { throw ("Trigger waere ungueltig:`n- " + ($fehler -join "`n- ")) }
    $warn = @()
    if ($p.art -ne "server") { $warn += "Prozess '$($p.name)' ist kein Serverprozess (Art $($p.art)) - Trigger starten normalerweise Serverprozesse." }
    $schon = @($liste | Where-Object { $_._process -eq $p.id })
    if ($schon.Count) { $warn += "Diesen Prozess startet schon: " + (($schon | ForEach-Object { "$($_.name) ($(if ($_.enabled) { 'aktiv' } else { 'aus' }), $(ZeitplanText $_.schedule))" }) -join "; ") + " - doppelte Laeufe vermeiden." }
    if (-not $a.aktiv) { $warn += "Wird ausgeschaltet angelegt; einschalten mit blp_change baustein=triggermanager objekt='$name', pfad enabled, wert true." }
    $warn += "Wirksam erst nach Veroeffentlichen im Designer; danach mit blp_reports prozess='$($p.name)' pruefen, ob er laeuft."
    @{ vorschau = [ordered]@{ aktion = "Zeitplan-Trigger anlegen"; name = $name; prozess = "$($p.name) [$($p.id)] v$($p.version)"; zeitplan = (ZeitplanText $s); aktiv = [bool] $a.aktiv
         beschreibung = "$($a.beschreibung)"; umgebung = $UMGEBUNG; rumpf = $def }
       warnungen = $warn; fp = "neu|$name|$($liste.Count)|$($p.id)|$($p.version)"; def = $def; name = $name }
  } {
    param($plan)
    New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
    $sich = Join-Path $SICHERUNG ("triggermanager-liste-{0}-vorher.json" -f (Get-Date).ToString("yyyyMMdd-HHmmss-fff"))
    [IO.File]::WriteAllText($sich, (Blp-Get (P "triggermanager")), [Text.UTF8Encoding]::new($false))
    $antwort = Blp-Send "PUT" (P "triggermanager") (JStr $plan.def)
    $t = @(Triggerliste | Where-Object { $_.name -eq $plan.name })
    if ($t.Count -ne 1) { throw "Anlage unklar: $($t.Count) Trigger '$($plan.name)' gefunden. Antwort: $(Kurz $antwort 300)" }
    $o = TriggerKurz $t[0] (Prozessnamen)
    $o.kontrolle = $(if ((ZeitplanText $t[0].schedule) -eq (ZeitplanText $plan.def.schedule) -and [bool] $t[0].enabled -eq [bool] $plan.def.enabled) { "Zeitplan und Schalter wie gewuenscht" } else { "weicht ab: gespeichert '$(ZeitplanText $t[0].schedule)', aktiv $($t[0].enabled)" })
    $o.sicherung = $sich
    $o.danach = "Im Designer veroeffentlichen, erst dann startet der Trigger. Danach blp_reports pruefen."
    $o
  }
} -Schreibt
