# blp-mcp-module.ps1 - Modulkonfigurationen (Validation, AI.Foundation, AI OCR, PDF-Processor, elo, ...) lesen und zuruecksetzen.
# Wird von blp-mcp.ps1 per Dot-Sourcing eingebunden (nutzt Lies, Blp-Get, Finde, L, Kurz, Werkzeug, Maskiere,
# JObj, JStr, ZweiSchritte, Blp-Send, Protokoll aus blp-mcp-aendern.ps1). Aendern laeuft ueber blp_change baustein=module.
#
# API (Befund 10.11.2026, BLP 6, Test):
#   GET /api/v1/module                         alle Module mit Prozessoren (Software, nicht Projekt)
#   GET  project/<id>/module/<Modul-ID>        Modulkonfiguration des Projekts: parameters { <Schluessel>: "<JSON als Text>" }
#   POST project/<id>/module/<Modul-ID>        ganze Konfiguration mit _read_token aus dem GET; sofort festgeschrieben (neue Hauptversion)
#   checkout / commit / undo                   405, obwohl die links sie nennen
#   veraltetes _read_token                     400 PRJ050007, Modul bleibt danach als gesperrt stehen, bis erfolgreich gespeichert wird

$MODUL_ORDNER = Join-Path $DATEN "module"

$script:Modulliste = $null
function Modulliste {
  if ($script:Modulliste) { return $script:Modulliste }
  $d = JObj (Blp-Get "$PROJEKT/api/v1/module")
  $mods = if ($d.modules) { $d.modules } else { $d }
  $script:Modulliste = @(L $mods | ForEach-Object { [pscustomobject]@{ module_id = "$($_.module_id)"; id = "$($_.module_id)"; name = "$($_.name)"; display_text = "$($_.display_text)"
      version = "$($_.version)"; beschreibung = "$($_.description)"; oberflaeche = "$($_.config_control.type)"; prozessoren = @(L $_.processors).Count } })
  $script:Modulliste
}
function ModulFinden([string] $wer) { Finde (Modulliste) $wer "Modul" }

# Parameterwerte sind JSON als Text; nicht-JSON bleibt Text.
function Entpacke($v) {
  if ($v -is [string] -and ($v.TrimStart().StartsWith("{") -or $v.TrimStart().StartsWith("["))) {
    try { return ,(JObj $v) } catch {}
    # Schluessel, die sich nur in Gross-/Kleinschreibung unterscheiden (z. B. Office: IntrusionBarValue/IntrusionBarvalue),
    # gehen nur als Hashtable - zum Anzeigen reicht das, Pfad-Aenderungen darin gehen nicht.
    try { return ,(ConvertFrom-Json -InputObject $v -Depth 100 -DateKind String -NoEnumerate -AsHashtable) } catch {}
  }
  ,$v
}

# Gliederung eines beliebigen JSON: Schluessel mit Art und Groesse, Listen mit Anzahl und Namen der Eintraege.
function Gliederung($o, [int] $tiefe = 3) {
  if ($o -is [array]) {
    $namen = @(L $o | ForEach-Object { if ($_ -is [System.Management.Automation.PSCustomObject]) { foreach ($f in "name", "key", "displayName", "title", "id") { if ($_.$f) { "$($_.$f)"; break } } } } | Select-Object -First 30)
    $r = [ordered]@{ liste = $o.Count }
    if ($namen.Count) { $r.eintraege = $namen }
    elseif ($o.Count -and $o[0] -is [System.Management.Automation.PSCustomObject] -and $tiefe -gt 1) { $r.aufbau = Gliederung $o[0] ($tiefe - 1) }
    return $r
  }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    if ($tiefe -le 0) { return "{$(@($o.PSObject.Properties).Count) Felder}" }
    $r = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { $r[$p.Name] = Gliederung $p.Value ($tiefe - 1) }
    return $r
  }
  if ($o -is [System.Collections.IDictionary]) {
    if ($tiefe -le 0) { return "{$($o.Count) Felder}" }
    $r = [ordered]@{}
    if ($tiefe -ge 3) { $r.hinweis = "Schluessel unterscheiden sich nur in Gross-/Kleinschreibung - nur lesbar, Pfad-Aenderungen hier nicht moeglich" }
    foreach ($k in $o.Keys) { $r["$k"] = Gliederung $o[$k] ($tiefe - 1) }
    return $r
  }
  Kurz $o 80
}

function Felderliste($node) { @(L $node.fields | ForEach-Object { if ($_.key) { "$($_.key)" } elseif ($_.name) { "$($_.name)" } else { Kurz $_ 40 } }) }

# Kurzansichten fuer bekannte Module; sonst die Gliederung.
function ModulUebersicht([string] $schluessel, $w) {
  if ($w -is [System.Collections.IDictionary]) { return (Gliederung $w 3) }
  if ($w -isnot [System.Management.Automation.PSCustomObject]) { return (Kurz $w 300) }
  if ($w.validatorConfig) {
    $v = $w.validatorConfig
    return [ordered]@{ art = "Validation"; projekt = $w.currentProjectName; schemaVersion = $v.schemaVersion
      dokumenttypen = @(L $v.documentTypes | ForEach-Object { $dt = $_
        [ordered]@{ key = $dt.key; anzeige = $dt.displayName; aktiv = $dt.enabled; geaendert = $dt.updatedAt
          bloecke = @(L $dt.blocks | ForEach-Object { [ordered]@{ key = $_.key; titel = $_.title; typ = $_.type
              felder = @(L $_.nodeTypes | ForEach-Object { Felderliste $_ }); regeln = @(L $_.rules.validation).Count } })
          pruefregeln = @(L $dt.validators.validation).Count; reviewRegeln = @(L $dt.reviewRules).Count
          speicheraktionen = @(L $dt.saveActions | ForEach-Object { "$($_.name)$(if (-not $_.enabled) { ' (aus)' })" })
          aiPrompts = @(L $dt.aiPrompts).Count; formeln = @(L $dt.localFormulas).Count } })
      status = @(L $v.documentStatuses | ForEach-Object { $_.key }); formelbibliothek = [ordered]@{ formeln = @(L $v.formulaLibrary.formulas).Count; pruefer = @(L $v.formulaLibrary.validators).Count }
      routings = @(L $v.routings).Count; externeDienste = @(L $v.externalServices).Count
      pfade = "parameters/$schluessel/#/validatorConfig/documentTypes/[key=<Dokumenttyp>]/blocks/[key=<Block>]/rules/validation ..." }
  }
  if ($null -ne $w.promptSettings -or $null -ne $w.modelProfiles) {
    return [ordered]@{ art = "AI Foundation"
      prompts = @(L $w.promptSettings | ForEach-Object { [ordered]@{ name = $_.name; typ = $_.promptType; geaendert = $_.lastModifiedAt
          eingaben = @(L $_.promptSchema.inputSchema.properties.PSObject.Properties | ForEach-Object { $_.Name })
          ausgaben = @(L $_.promptSchema.exportSchema.properties.PSObject.Properties | ForEach-Object { $_.Name })
          validationDokumenttyp = $_.selectedValidationDocumentTypeKey; getestet = -not $_.isNotTested } })
      modellprofile = @(L $w.modelProfiles | ForEach-Object { [ordered]@{ name = $_.name; anbieter = $_.provider; modell = $_.modelName; kreativitaet = $_.creativity; maxTokens = $_.maxTokens; timeout = $_.timeoutSeconds } })
      anbieter = @(L $w.providerConfigs | ForEach-Object { [ordered]@{ name = $_.name; anbieter = $_.provider; modell = $_.model.identifier } })
      gewaehlt = $w.selectedProviderConfig.name
      pfade = "parameters/$schluessel/#/promptSettings/[name=<Prompt>]/apmlTemplate | description | promptSchema/...; modelProfiles/[name=<Profil>]/..." }
  }
  Gliederung $w 3
}

Werkzeug "blp_modules" ("Listet die Module des Projektdienstes (Name, Modul-ID, Softwareversion) mit ihrer Modulkonfiguration im Projekt: Version, letzte Aenderung, Parameter-Schluessel und Groesse. " +
  "Einzelheiten mit blp_module, aendern mit blp_change baustein=module.") @{ filter = @{ type = "string"; description = "Optional: Namensteil" } } @() {
  param($a)
  $l = @(Modulliste)
  if ($a.filter) { $l = @($l | Where-Object { $_.name -like "*$($a.filter)*" -or $_.display_text -like "*$($a.filter)*" }) }
  [ordered]@{ anzahl = $l.Count; module = @(foreach ($m in ($l | Sort-Object name)) {
    $o = [ordered]@{ name = $m.name; anzeige = $m.display_text; id = $m.module_id; software = $m.version }
    try {
      $c = JObj (Blp-Get (P "module/$($m.module_id)"))
      $keys = @(L $c.parameters.PSObject.Properties)
      $o.konfiguration = $(if ($keys.Count) { "v$($c._version)" } else { "keine" })
      if ($keys.Count) { $o.geaendert = $c._last_modified_date; $o.von = $c._last_author; $o.parameter = @($keys | ForEach-Object { "$($_.Name) ($("$($_.Value)".Length) Zeichen)" }) }
      if ($c._locked) { $o.gesperrt = "$($c._locked_by_user) seit $($c._locked_on)" }
    } catch { $o.konfiguration = "nicht lesbar: $(Kurz "$($_.Exception.Message)" 120)" }
    $o }) }
}

Werkzeug "blp_module" ("Zeigt die Modulkonfiguration eines Moduls im Projekt (module/<Modul-ID>), eingebettetes JSON ausgepackt. Ohne weitere Angaben eine Kurzansicht: " +
  "bei Validation Dokumenttypen mit Bloecken, Feldern und Regeln, bei AI.Foundation Prompts, Modellprofile und Anbieter, sonst die Gliederung. " +
  "voll = true: die ganze Konfiguration (grosse als Datei im Datenordner, maskiert). Einzelne Teile mit blp_read_path baustein=module, aendern mit blp_change baustein=module.") @{
  modul = @{ type = "string"; description = "Modulname (z. B. Validation, AI.Foundation, 'AI OCR', PDF-Processor, elo) oder Modul-ID" }
  voll = @{ type = "boolean"; description = "Ganze Konfiguration statt Kurzansicht" } } @("modul") {
  param($a)
  $m = ModulFinden "$($a.modul)"
  $c = JObj (Blp-Get (P "module/$($m.module_id)"))
  $kopf = [ordered]@{ modul = $m.name; anzeige = $m.display_text; id = $m.module_id; software = $m.version; version = $c._version; geaendert = $c._last_modified_date; von = $c._last_author }
  if ($c._locked) { $kopf.gesperrt = "$($c._locked_by_user) seit $($c._locked_on)" }
  $par = [ordered]@{}; foreach ($p in @(L $c.parameters.PSObject.Properties)) { $par[$p.Name] = Entpacke $p.Value }
  if ($par.Count -eq 0) { $kopf.hinweis = "Dieses Modul hat im Projekt keine Konfiguration."; return $kopf }
  if ($a.voll) {
    $text = Maskiere (ConvertTo-Json -InputObject $par -Depth 100)
    if ($text.Length -le 50000) { $kopf.parameter = $par; return $kopf }
    New-Item -ItemType Directory -Force $MODUL_ORDNER | Out-Null
    $datei = Join-Path $MODUL_ORDNER ("{0}-v{1}-{2}.json" -f ($m.name -replace '[^\w.-]', '_'), $c._version, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    [IO.File]::WriteAllText($datei, $text, [Text.UTF8Encoding]::new($false))
    $kopf.datei = $datei; $kopf.zeichen = $text.Length
    $kopf.hinweis = "Zu gross fuer die Antwort - ganze Konfiguration (maskiert, nur zum Lesen) in der Datei. Teile gezielt mit blp_read_path baustein=module."
    $kopf.gliederung = [ordered]@{}; foreach ($k in $par.Keys) { $kopf.gliederung[$k] = Gliederung $par[$k] 3 }
    return $kopf
  }
  $kopf.parameter = [ordered]@{}; foreach ($k in $par.Keys) { $kopf.parameter[$k] = ModulUebersicht $k $par[$k] }
  $kopf.hinweis = "Pfade fuer blp_read_path/blp_change: parameters/<Schluessel>/#/... ('#' oeffnet das eingebettete JSON). Speichern ist sofort festgeschrieben; vorher Sicherung, zurueck mit blp_module_restore."
  $kopf
}

Werkzeug "blp_module_restore" ("Spielt eine Sicherung einer Modulkonfiguration zurueck (zweistufig), z. B. die Datei aus dem Ergebnis von blp_change baustein=module (Datenordner\sicherung\module-<ID>-...-vorher.json). " +
  "Ersetzt alle parameters des Moduls durch die aus der Sicherung; der Stand davor wird selbst wieder gesichert. Nur in Umgebungen mit allowChanges.") @{
  datei = @{ type = "string"; description = "Voller Pfad der Sicherung (.json, rohes Modul-JSON mit module_id und parameters)" }
  freigabe = @{ type = "string" } } @("datei") {
  param($a)
  ZweiSchritte "blp_module_restore" $a {
    $f = "$($a.datei)"
    if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or $f -notlike "*.json") { throw "Sicherung nicht gefunden oder keine .json: $f" }
    $text = [IO.File]::ReadAllText($f)
    if ($text -match '"\*\*\*"|\\"\*\*\*\\"') { throw "Die Datei enthaelt maskierte Werte (***) - das ist keine Sicherung, sondern eine Leseansicht. Nur Dateien aus dem Ordner sicherung zurueckspielen." }
    $s = JObj $text
    if (-not $s.module_id -or $null -eq $s.parameters) { throw "Keine Modul-Sicherung (module_id oder parameters fehlt)." }
    $m = ModulFinden "$($s.module_id)"
    $roh = Blp-Get (P "module/$($m.module_id)"); $ist = JObj $roh
    $diff = @(foreach ($k in @(@($s.parameters.PSObject.Properties.Name) + @(L $ist.parameters.PSObject.Properties.Name) | Select-Object -Unique)) {
      $alt = "$($ist.parameters.$k)"; $neu = "$($s.parameters.$k)"
      if ($alt -cne $neu) { [ordered]@{ parameter = $k; jetzt = "$($alt.Length) Zeichen"; sicherung = $(if ($null -eq $s.parameters.$k) { "(fehlt - wird entfernt)" } else { "$($neu.Length) Zeichen" }) } }
    })
    if ($diff.Count -eq 0) { throw "Die Konfiguration entspricht schon der Sicherung." }
    $warn = @("Speichern ist sofort festgeschrieben (neue Hauptversion); der jetzige Stand wird vorher gesichert.", "Wirksam erst nach Veroeffentlichen im Designer.")
    if ($ist._locked) { $warn += "Modul steht als gesperrt von $($ist._locked_by_user) - Speichern hebt das auf; vorher klaeren, ob jemand im Designer daran arbeitet." }
    @{ vorschau = [ordered]@{ aktion = "Modulkonfiguration zuruecksetzen"; modul = $m.name; id = $m.module_id; versionJetzt = $ist._version; versionSicherung = $s._version; sicherungVom = $s._last_modified_date; umgebung = $UMGEBUNG; unterschiede = $diff }
       warnungen = $warn; fp = "$($m.module_id)|$($ist._version)|$($ist._last_modified_date)|$((Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks)"; m = $m; roh = $roh; s = $s }
  } {
    param($plan)
    $ist = JObj $plan.roh
    New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
    $sich = Join-Path $SICHERUNG ("module-{0}-{1}-vorher.json" -f $plan.m.module_id, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    [IO.File]::WriteAllText($sich, $plan.roh, [Text.UTF8Encoding]::new($false))
    $ist.parameters = $plan.s.parameters
    $fehler = @(L (Pruefe $ist "module")); if ($fehler.Count) { throw ("Pruefung: " + ($fehler -join "; ")) }
    $null = Blp-Send "POST" (P "module/$($plan.m.module_id)") (JStr $ist)
    $nach = JObj (Blp-Get (P "module/$($plan.m.module_id)"))
    [ordered]@{ modul = $plan.m.name; versionVorher = (JObj $plan.roh)._version; versionNachher = $nach._version
      kontrolle = $(if (@(foreach ($k in @(@($plan.s.parameters.PSObject.Properties.Name) + @(L $nach.parameters.PSObject.Properties.Name) | Select-Object -Unique)) { if ("$($nach.parameters.$k)" -cne "$($plan.s.parameters.$k)") { $k } }).Count -eq 0) { "Konfiguration entspricht der Sicherung" } else { "Konfiguration weicht nach dem Speichern von der Sicherung ab - im Designer pruefen" })
      sicherung = $sich; danach = "Im Designer veroeffentlichen, erst dann wirkt die Aenderung." }
  }
} -Schreibt
