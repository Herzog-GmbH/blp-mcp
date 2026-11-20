# blp-mcp-module.ps1 - Modulkonfigurationen (Validation, AI.Foundation, AI OCR, PDF-Processor, elo, ...) lesen und zuruecksetzen.
# Wird von blp-mcp.ps1 per Dot-Sourcing eingebunden (nutzt Lies, Blp-Get, Finde, L, Kurz, Werkzeug, Maskiere,
# JObj, JStr, ZweiSchritte, Blp-Send, Protokoll aus blp-mcp-aendern.ps1, Entpacke aus blp-mcp-bauen.ps1 - darum nach diesen laden).
# Aendern laeuft ueber blp_change baustein=module bzw. dataquery.
#
# API (Befund 10.11.2026, BLP 6, Test):
#   GET /api/v1/module                         alle Module mit Prozessoren (Software, nicht Projekt)
#   GET  project/<id>/module/<Modul-ID>        Modulkonfiguration des Projekts: parameters { <Schluessel>: "<JSON als Text>" }
#   POST project/<id>/module/<Modul-ID>        ganze Konfiguration mit _read_token aus dem GET; sofort festgeschrieben (neue Hauptversion)
#   checkout / commit / undo                   405, obwohl die links sie nennen
#   veraltetes _read_token                     400 PRJ050007, Modul bleibt danach als gesperrt stehen, bis erfolgreich gespeichert wird

$MODUL_ORDNER = Join-Path $DATEN "module"

$script:Modulliste = $null
$script:Addinliste = $null
function InstallierteModule {
  $antwort = JObj (Blp-Get "$PROJEKT/api/v1/module")
  if ($antwort.PSObject.Properties["modules"]) { L $antwort.modules } else { L $antwort }
}

function Modulliste {
  if ($script:Modulliste) { return $script:Modulliste }
  $mods = @(InstallierteModule)
  $script:Modulliste = @(L $mods | ForEach-Object { [pscustomobject]@{ module_id = "$($_.module_id)"; id = "$($_.module_id)"; name = "$($_.name)"; display_text = "$($_.display_text)"
      version = "$($_.version)"; beschreibung = "$($_.description)"; oberflaeche = "$($_.config_control.type)"; prozessoren = @(L $_.processors).Count } })
  # Datenabfrage-Add-ins (SQL, OleDb, GroupQueries, IX Query, OData, SAP SOAP ...) haengen an ihren Modulen.
  # id = "<Modul-ID>/<Add-in-ID>", so wie der Pfad dataquerymanager/<Modul-ID>/<Add-in-ID>.
  $script:Addinliste = @(foreach ($m in @(L $mods)) { foreach ($ad in @(L $m.data_query_addins)) {
    [pscustomobject]@{ id = "$($m.module_id)/$($ad.info.id)"; module_id = "$($m.module_id)"; addin_id = "$($ad.info.id)"; name = "$($ad.info.name)"
      display_text = "$($ad.info.display_text)"; modul = "$($m.name)"; version = "$($ad.info.version)" } } })
  $script:Modulliste
}
function ModulFinden([string] $wer) { Finde (Modulliste) $wer "Modul" }
function Addinliste { if ($null -eq $script:Addinliste) { $null = Modulliste }; $script:Addinliste }
function AddinFinden([string] $wer) {
  $l = @(Addinliste)
  $t = @($l | Where-Object { $_.addin_id -eq $wer })
  if ($t.Count -eq 1) { return $t[0] }
  Finde $l $wer "Datenabfrage-Add-in"
}

function ModulpaketManifest([string] $pfad) {
  $archiv = [IO.Compression.ZipFile]::OpenRead($pfad)
  try {
    $eintrag = $archiv.GetEntry("info.json")
    if (-not $eintrag) { throw "Im Modulpaket fehlt info.json." }
    $leser = [IO.StreamReader]::new($eintrag.Open())
    try { $manifest = JObj ($leser.ReadToEnd()) } finally { $leser.Dispose() }
  } finally { $archiv.Dispose() }

  $id = [guid]::Empty
  if (-not [guid]::TryParse($manifest.module_id, [ref] $id) -or $id -eq [guid]::Empty -or
      [string]::IsNullOrWhiteSpace($manifest.name) -or [string]::IsNullOrWhiteSpace($manifest.version)) {
    throw "info.json braucht module_id (GUID), name und version."
  }
  $manifest
}

function ModulpaketHerunterladen([guid] $id, [string] $ziel) {
  Invoke-WebRequest -Uri "$PROJEKT/api/v1/module/$id/download" -Headers (Header) -OutFile $ziel @TLS
}

Werkzeug "blp_module_install" ("Importiert ein lokales BLP-Modulpaket (.mod) am Projektdienst. Zweistufig mit Vorschau und Freigabe. " +
  "Beim Ersetzen wird das bisherige Paket gesichert. Anschliessend wird das ausgelieferte Paket per SHA-256 verglichen. " +
  "Das Modul wird erst nach Veroeffentlichen im Designer an den Client verteilt.") @{
  datei = @{ type = "string"; description = "Lokaler Dateipfad eines .mod-Pakets" }
  freigabe = @{ type = "string"; description = "Leer fuer die Vorschau; danach Freigabe-Code der Vorschau" }
} @("datei") {
  param($a)
  ZweiSchritte "blp_module_install" $a {
    $file = Get-Item -LiteralPath $a.datei -ErrorAction Stop
    if ($file -isnot [IO.FileInfo] -or $file.Extension -ine ".mod") { throw "Eine .mod-Datei angeben." }
    $manifest = ModulpaketManifest $file.FullName
    $id = [guid] $manifest.module_id
    $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $vorher = InstallierteModule | Where-Object { [string]$_.module_id -eq "$id" } | Select-Object -First 1
    $vorschau = [ordered]@{ modul = $manifest.name; id = "$id"; vorher = $vorher.version; nachher = $manifest.version
      datei = $file.FullName; sha256 = $sha; umgebung = $UMGEBUNG }
    $warnungen = @("Der Modulimport wirkt sofort im Projektdienst. Die Verteilung an Clients erfolgt nach Veroeffentlichen im Designer.")
    if ($vorher) { $warnungen += "Das bisherige Modulpaket wird vor dem Import gesichert." }
    @{ vorschau = $vorschau; warnungen = $warnungen; fp = "$id|$sha|$($vorher.version)|$($vorher._checksum)"
       datei = $file.FullName; sha = $sha; id = $id; manifest = $manifest; vorher = $vorher }
  } {
    param($plan)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("blp-modul-" + [guid]::NewGuid())
    $null = [IO.Directory]::CreateDirectory($temp)
    $paket = Join-Path $temp ([IO.Path]::GetFileName($plan.datei))
    $download = Join-Path $temp ("pruefung-" + [guid]::NewGuid() + ".mod")
    $sicherung = $null
    try {
      Copy-Item -LiteralPath $plan.datei -Destination $paket
      if ((Get-FileHash -LiteralPath $paket -Algorithm SHA256).Hash -ne $plan.sha) { throw "Die Paketdatei hat sich seit der Vorschau geaendert." }
      if ($plan.vorher) {
        ModulpaketHerunterladen $plan.id $download
        $alt = ModulpaketManifest $download
        if ([guid]$alt.module_id -ne $plan.id -or $alt.version -ne $plan.vorher.version) { throw "Das installierte Modul hat sich vor dem Import geaendert." }
        $null = New-Item -ItemType Directory -Path $MODUL_ORDNER -Force
        $sicherung = Join-Path $MODUL_ORDNER ("{0}-{1}-vorher.mod" -f $plan.id, (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
        Copy-Item -LiteralPath $download -Destination $sicherung
      }
      $null = Invoke-WebRequest -Uri "$PROJEKT/api/v1/module" -Method Put -Headers (Header) -Form @{ file = (Get-Item -LiteralPath $paket) } @TLS
      $script:Modulliste = $script:Addinliste = $script:Katalog = $null
      try {
        ModulpaketHerunterladen $plan.id $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $plan.sha) { throw "SHA-256 weicht ab." }
      } catch {
        throw "Import beantwortet, Nachpruefung des Modulpakets fehlgeschlagen: $($_.Exception.Message) Sicherung: $sicherung"
      }
      [ordered]@{ modul = $plan.manifest.name; id = "$($plan.id)"; vorher = $plan.vorher.version; version = $plan.manifest.version
        sha256 = $plan.sha; sicherung = $sicherung; hinweis = "Wirksam nach Veroeffentlichen im Designer." }
    } finally {
      [IO.File]::Delete($paket)
      [IO.File]::Delete($download)
      [IO.Directory]::Delete($temp)
    }
  }
} -Schreibt

Werkzeug "blp_desktop_plugins" "Listet installierte Desktop-Plug-ins mit Modul, IDs und Designer-Konfigurationsrouten. Optional nach einem Modul filtern." @{
  modul = @{ type = "string"; description = "Modulname, Anzeigename oder Modul-ID" }
} @() {
  param($a)
  $module = @(InstallierteModule)
  if ($a.modul) {
    $id = (ModulFinden $a.modul).module_id
    $module = @($module | Where-Object module_id -eq $id)
  }
  [ordered]@{ desktopPlugins = @(foreach ($m in $module) {
    foreach ($p in @(L $m.desktop_plugins)) {
      $konfig = @(L $p.routes.config)
      [ordered]@{ modul = $m.name; modulId = $m.module_id; modulVersion = $m.version; name = $p.info.name
        anzeige = $p.info.display_text; pluginId = $p.info.id; designerKonfiguration = ($konfig.function -contains "LOAD")
        konfigurationsrouten = $konfig }
    }
  }) }
}

Werkzeug "blp_smartsearch_commands" ("Listet die Befehle eines Smart-Search-Profils oder zeigt einen einzelnen Befehl, mit Plug-in-IDs, Optionen " +
  "und Pfaden fuer blp_read_path und blp_change baustein=smartsearch. Liefert Parameterschluessel ohne ihre Werte.") @{
  profil = @{ type = "string"; description = "Name oder ID des Suchprofils" }
  befehl = @{ type = "string"; description = "Optionaler Befehlsname, Anzeigename oder ID" }
} @("profil") {
  param($a)
  $profilId = BausteinFinden "smartsearch" $a.profil
  $profil = Lies "smartsearch/$profilId"
  $befehle = @($profil.commands | Where-Object { $_ } | ForEach-Object {
    $p = $_.action.desktop_plugin
    $pfad = "commands/[id=$($_.id)]"
    [pscustomobject]@{ id = $_.id; name = $_.name; display_text = $_.display_text; typ = $_.action.type
      reihenfolge = $_.order; optionen = $_.options; modulId = $p.module_id; pluginId = $p.plugin_id; pfad = $pfad
      parameter = @(foreach ($feld in $p.parameters.PSObject.Properties) { "$pfad/action/desktop_plugin/parameters/$($feld.Name)" }) }
  })
  if ($a.befehl) { $befehle = @(Finde $befehle $a.befehl "Smart-Search-Befehl") }
  [ordered]@{ profil = $profil.name; id = $profilId; version = $profil._version; befehle = $befehle }
}

# Parameterwerte sind JSON als Text: Entpacke aus blp-mcp-bauen.ps1. Schluessel, die sich nur in Gross-/Kleinschreibung
# unterscheiden (z. B. Office: IntrusionBarValue/IntrusionBarvalue), kommen dort als Hashtable zurueck - zum Anzeigen
# reicht das, Pfad-Aenderungen darin gehen nicht.

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

Werkzeug "blp_module_restore" ("Spielt eine Sicherung einer Modulkonfiguration oder der Datenabfragen eines Add-ins zurueck (zweistufig), z. B. die Datei aus dem Ergebnis von blp_change baustein=module oder dataquery " +
  "(Datenordner\sicherung\module-<ID>-...-vorher.json bzw. dataquery-<Modul-ID>_<Add-in-ID>-...-vorher.json). " +
  "Ersetzt alle parameters durch die aus der Sicherung; der Stand davor wird selbst wieder gesichert. Nur in Umgebungen mit allowChanges.") @{
  datei = @{ type = "string"; description = "Voller Pfad der Sicherung (.json, rohes JSON mit module_id, bei Datenabfragen addin_id, und parameters)" }
  freigabe = @{ type = "string" } } @("datei") {
  param($a)
  ZweiSchritte "blp_module_restore" $a {
    $f = "$($a.datei)"
    if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or $f -notlike "*.json") { throw "Sicherung nicht gefunden oder keine .json: $f" }
    $text = [IO.File]::ReadAllText($f)
    if ($text -match '"\*\*\*"|\\"\*\*\*\\"') { throw "Die Datei enthaelt maskierte Werte (***) - das ist keine Sicherung, sondern eine Leseansicht. Nur Dateien aus dem Ordner sicherung zurueckspielen." }
    $s = JObj $text
    if (-not $s.module_id -or $null -eq $s.parameters) { throw "Keine Sicherung einer Modulkonfiguration oder Datenabfrage (module_id oder parameters fehlt)." }
    # Datenabfragen (dataquerymanager) tragen zusaetzlich addin_id.
    if ($s.addin_id) { $ad = AddinFinden "$($s.addin_id)"; $m = [pscustomobject]@{ name = "$($ad.modul)/$($ad.name)"; module_id = $ad.id; adr = "dataquerymanager/$($ad.id)"; datei = "dataquery-$($ad.id -replace '/', '_')" } }
    else { $mm = ModulFinden "$($s.module_id)"; $m = [pscustomobject]@{ name = $mm.name; module_id = $mm.module_id; adr = "module/$($mm.module_id)"; datei = "module-$($mm.module_id)" } }
    $roh = Blp-Get (P $m.adr); $ist = JObj $roh
    $diff = @(foreach ($k in @(@($s.parameters.PSObject.Properties.Name) + @(L $ist.parameters.PSObject.Properties.Name) | Select-Object -Unique)) {
      $alt = "$($ist.parameters.$k)"; $neu = "$($s.parameters.$k)"
      if ($alt -cne $neu) { [ordered]@{ parameter = $k; jetzt = "$($alt.Length) Zeichen"; sicherung = $(if ($null -eq $s.parameters.$k) { "(fehlt - wird entfernt)" } else { "$($neu.Length) Zeichen" }) } }
    })
    if ($diff.Count -eq 0) { throw "Die Konfiguration entspricht schon der Sicherung." }
    $warn = @("Speichern ist sofort festgeschrieben (neue Hauptversion); der jetzige Stand wird vorher gesichert.", "Wirksam erst nach Veroeffentlichen im Designer.")
    if ($ist._locked) { $warn += "Steht als gesperrt von $($ist._locked_by_user) - Speichern hebt das auf; vorher klaeren, ob jemand im Designer daran arbeitet." }
    @{ vorschau = [ordered]@{ aktion = $(if ($s.addin_id) { "Datenabfragen zuruecksetzen" } else { "Modulkonfiguration zuruecksetzen" }); modul = $m.name; id = $m.module_id; versionJetzt = $ist._version; versionSicherung = $s._version; sicherungVom = $s._last_modified_date; umgebung = $UMGEBUNG; unterschiede = $diff }
       warnungen = $warn; fp = "$($m.module_id)|$($ist._version)|$($ist._last_modified_date)|$((Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks)"; m = $m; roh = $roh; s = $s }
  } {
    param($plan)
    $ist = JObj $plan.roh
    New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
    $sich = Join-Path $SICHERUNG ("{0}-{1}-vorher.json" -f $plan.m.datei, (Get-Date).ToString("yyyyMMdd-HHmmss-fff"))
    [IO.File]::WriteAllText($sich, $plan.roh, [Text.UTF8Encoding]::new($false))
    $ist.parameters = $plan.s.parameters
    $fehler = @(L (Pruefe $ist "module")); if ($fehler.Count) { throw ("Pruefung: " + ($fehler -join "; ")) }
    $null = Blp-Send "POST" (P $plan.m.adr) (JStr $ist)
    $nach = JObj (Blp-Get (P $plan.m.adr))
    [ordered]@{ modul = $plan.m.name; versionVorher = (JObj $plan.roh)._version; versionNachher = $nach._version
      kontrolle = $(if (@(foreach ($k in @(@($plan.s.parameters.PSObject.Properties.Name) + @(L $nach.parameters.PSObject.Properties.Name) | Select-Object -Unique)) { if ("$($nach.parameters.$k)" -cne "$($plan.s.parameters.$k)") { $k } }).Count -eq 0) { "Konfiguration entspricht der Sicherung" } else { "Konfiguration weicht nach dem Speichern von der Sicherung ab - im Designer pruefen" })
      sicherung = $sich; danach = "Im Designer veroeffentlichen, erst dann wirkt die Aenderung." }
  }
} -Schreibt

# ---------- Datenabfragen (Add-ins von DataConnect, elo, OData, SAP ...) ----------
# API (Befund 10.11.2026, BLP 6, Test; aus dem Designer-Skript):
#   GET  project/<id>/dataquerymanager/<Modul-ID>/<Add-in-ID>   parameters { Module.DataConnect.DataQuery.SQL.Config: "<JSON als Text>" }
#   POST dieselbe Adresse                                        speichern (wie module: links nur self/update/delete, kein checkout)
#   GET  project/<id>/dataquerymanager/load/items                alle Abfragen aller Add-ins (nur Namen und Felder, siehe blp_dataqueries)
#   Add-in ohne Konfiguration im Projekt liefert {} (OleDb, IX Query, OData, SAP SOAP auf Test).
# SQL/OleDb: Sources[] { Name, LoginProfile, ConnectionString, DataQueries[] { Name, DataQueryString, FieldMappings[] { FieldName, MappingName } }, DataWriters }
# GroupQueries: Queries[] { Name, NoOfIndexField, ExecutionMode, Queries[] { ModuleName, QueryName, Condition, ConditionFieldMapping }, Columns[] { Name, UseColumn, Filter, Function, QueryColumns[] } }

function AbfrageKonfig($ad) {
  $roh = Blp-Get (P "dataquerymanager/$($ad.id)"); $o = JObj $roh
  $schl = @(L $o.parameters.PSObject.Properties | ForEach-Object { $_.Name }) | Select-Object -First 1
  [pscustomobject]@{ ad = $ad; o = $o; schluessel = $schl; inhalt = $(if ($schl) { Entpacke $o.parameters.$schl } else { $null }) }
}

# Pfadsegment fuer ein Listenelement: [Name=...] wenn eindeutig und ohne '/', sonst Index.
function ListenSeg($liste, [int] $i, [string] $feld = "Name") {
  $n = "$($liste[$i].$feld)"
  if ($n -and $n -notmatch '[/\]]' -and @(L $liste | Where-Object { "$($_.$feld)" -eq $n }).Count -eq 1) { "[$feld=$n]" } else { "$i" }
}

# Alle Abfragen eines Add-ins mit Vollname (SQL: "<Quelle>.<Abfrage>" wie in blp_dataqueries) und Pfad.
function AbfragenVon($k) {
  $w = $k.inhalt; $basis = "parameters/$($k.schluessel)/#"
  if ($w -isnot [System.Management.Automation.PSCustomObject]) { return }
  if ($null -ne $w.Sources) {
    $src = @(L $w.Sources)
    for ($i = 0; $i -lt $src.Count; $i++) { $s = $src[$i]; $dq = @(L $s.DataQueries)
      for ($j = 0; $j -lt $dq.Count; $j++) {
        [pscustomobject]@{ art = "quelle"; name = "$($dq[$j].Name)"; voll = "$($s.Name).$($dq[$j].Name)"; quelle = $s; q = $dq[$j]
          pfad = "$basis/Sources/$(ListenSeg $src $i)/DataQueries/$(ListenSeg $dq $j)" } } }
  } elseif ($null -ne $w.Queries) {
    $ql = @(L $w.Queries)
    for ($i = 0; $i -lt $ql.Count; $i++) { [pscustomobject]@{ art = "gruppe"; name = "$($ql[$i].Name)"; voll = "$($ql[$i].Name)"; q = $ql[$i]; pfad = "$basis/Queries/$(ListenSeg $ql $i)" } }
  }
}

function AbfrageDetail($k, $a, $alle) {
  $q = $a.q
  $r = [ordered]@{ addin = "$($k.ad.modul)/$($k.ad.name)"; name = $a.voll; version = $k.o._version; geaendert = $k.o._last_modified_date; von = $k.o._last_author }
  if ($a.art -eq "quelle") {
    $r.quelle = "$($a.quelle.Name)"; $r.anmeldeprofil = $(if ($a.quelle.LoginProfile) { "$($a.quelle.LoginProfile)" } else { "(keins)" })
    if ("$($a.quelle.ConnectionString)") { $r.verbindung = "eigene Verbindungszeichenfolge (ausgeblendet)" }
    if ("$($q.Description)") { $r.beschreibung = "$($q.Description)" }
    $r.sql = "$($q.DataQueryString)"
    $r.schreibend = [bool] $q.IsWriteCommand; $r.parameter = [bool] $q.UseParameters; $r.nurDbFelder = [bool] $q.ContainsOnlyDbFields
    $r.mehrfachwerte = $(if ($q.MultiValueEnabled) { "an, Trenner '$($q.MultiValueDelimiter)'" } else { "aus" })
    $r.felder = @(L $q.FieldMappings | ForEach-Object { "$($_.FieldName) <- $($_.MappingName)" })
    $andere = @($q.PSObject.Properties.Name | Where-Object { $_ -notin "Id", "Name", "Description", "DataQueryString", "IsWriteCommand", "MultiValueEnabled", "MultiValueDelimiter", "UseParameters", "ContainsOnlyDbFields", "FieldMappings" })
    if ($andere.Count) { $r.weitereFelder = $andere }
    # Wer benutzt die Abfrage? Gruppenabfragen, die sie als Teilabfrage nennen.
    $nutzer = @(foreach ($g in @($alle | Where-Object { $_.art -eq "gruppe" })) { if (@(L $g.q.Queries | Where-Object { "$($_.QueryName)" -eq $a.voll -and "$($_.ModuleName)" -eq $k.ad.name }).Count) { $g.voll } })
    if ($nutzer.Count) { $r.inGruppenabfragen = $nutzer }
    $r.pfade = [ordered]@{ abfrage = $a.pfad; sql = "$($a.pfad)/DataQueryString"; feld = "$($a.pfad)/FieldMappings/[FieldName=<Feld>]/MappingName"; neuesFeld = "$($a.pfad)/FieldMappings/- (aktion anhaengen, wert {FieldName, MappingName})" }
  } else {
    if ("$($q.Description)") { $r.beschreibung = "$($q.Description)" }
    $r.indexfelder = $q.NoOfIndexField; $r.ausfuehrung = $q.ExecutionMode
    if ("$($q.MultiValueDelimiter)$($q.MultiValuePrefix)$($q.MultiValuePostfix)") { $r.mehrfachwerte = "Praefix '$($q.MultiValuePrefix)', Trenner '$($q.MultiValueDelimiter)', Suffix '$($q.MultiValuePostfix)'" }
    $r.teilabfragen = @(L $q.Queries | ForEach-Object { $t = [ordered]@{ abfrage = "$($_.ModuleName): $($_.QueryName)" }
      if ("$($_.Condition)") { $t.bedingung = "$($_.Condition)" }
      $z = @(L $_.ConditionFieldMapping.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }); if ($z.Count) { $t.zuordnung = $z -join ", " }
      $t })
    $r.spalten = @(L $q.Columns | ForEach-Object { $c = $_
      $s = "$($c.Name) <- " + ((@(L $c.QueryColumns | ForEach-Object { "$($_.Query).$($_.Name)" })) -join " | ")
      if (-not $c.UseColumn) { $s += " (aus)" }; if ("$($c.Filter)") { $s += " Filter: $($c.Filter)" }; if ($c.Function) { $s += " Funktion $($c.Function)" }
      $s })
    $r.pfade = [ordered]@{ abfrage = $a.pfad; teilabfrage = "$($a.pfad)/Queries/[QueryName=<Abfrage>]/..."; spalte = "$($a.pfad)/Columns/[Name=<Spalte>]/UseColumn | Filter | QueryColumns" }
  }
  $r.hinweis = "Aendern mit blp_change baustein=dataquery objekt=$($k.ad.name) und einem Pfad von oben (zweistufig, sofort festgeschrieben, Sicherung vorher, zurueck mit blp_module_restore)."
  $r
}

Werkzeug "blp_dataquery" ("Zeigt Datenabfragen mit Inhalt: SQL-Text, Feldzuordnung, Schalter, Quelle und Anmeldeprofil (SQL/OleDb) bzw. Teilabfragen und Spalten (GroupQueries), mit Pfaden fuer blp_change baustein=dataquery. " +
  "Ohne abfrage: Uebersicht je Add-in (Quellen und Abfragenamen). Verbindungszeichenfolgen und Zugangsdaten werden nicht gezeigt. Nur Namen und Felder aller Abfragen: blp_dataqueries.") @{
  abfrage = @{ type = "string"; description = "Optional: Name wie in blp_dataqueries, z. B. 'ERP-Database.ERP_Customer' oder 'Customer' (GroupQueries); auch Namensteil" }
  addin = @{ type = "string"; description = "Optional: Add-in (SQL, GroupQueries, OleDb, 'IX Query', OData, 'SAP SOAP') oder Add-in-ID" }
  voll = @{ type = "boolean"; description = "Ganze Konfiguration des Add-ins (ausgepackt, maskiert; grosse als Datei)" } } @() {
  param($a)
  $ads = if ($a.addin) { @(AddinFinden "$($a.addin)") } else { @(Addinliste) }
  $konf = @(foreach ($ad in $ads) { try { AbfrageKonfig $ad } catch { [pscustomobject]@{ ad = $ad; fehler = (Kurz "$($_.Exception.Message)" 200) } } })
  if ($a.voll) {
    if ($konf.Count -ne 1) { throw "voll nur mit addin (z. B. addin: SQL)." }
    $k = $konf[0]; if ($k.fehler) { throw $k.fehler }
    $kopf = [ordered]@{ addin = "$($k.ad.modul)/$($k.ad.name)"; id = $k.ad.id; version = $k.o._version; geaendert = $k.o._last_modified_date; von = $k.o._last_author }
    if (-not $k.schluessel) { $kopf.hinweis = "Dieses Add-in hat im Projekt keine Konfiguration."; return $kopf }
    $text = Maskiere (ConvertTo-Json -InputObject $k.inhalt -Depth 100)
    if ($text.Length -le 50000) { $kopf.schluessel = $k.schluessel; $kopf.inhalt = $k.inhalt; return $kopf }
    New-Item -ItemType Directory -Force $MODUL_ORDNER | Out-Null
    $datei = Join-Path $MODUL_ORDNER ("dataquery-{0}-v{1}-{2}.json" -f ($k.ad.name -replace '[^\w.-]', '_'), $k.o._version, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    [IO.File]::WriteAllText($datei, $text, [Text.UTF8Encoding]::new($false))
    $kopf.datei = $datei; $kopf.zeichen = $text.Length; $kopf.gliederung = Gliederung $k.inhalt 3
    $kopf.hinweis = "Zu gross fuer die Antwort - ganze Konfiguration (maskiert, nur zum Lesen) in der Datei. Einzelne Abfragen mit abfrage, Teile mit blp_read_path baustein=dataquery."
    return $kopf
  }
  $alle = @(foreach ($k in $konf) { if (-not $k.fehler) { foreach ($x in @(AbfragenVon $k)) { $x | Add-Member -NotePropertyName k -NotePropertyValue $k -PassThru } } })
  if ($a.abfrage) {
    $w = "$($a.abfrage)"
    $t = @($alle | Where-Object { $_.voll -eq $w })
    if ($t.Count -eq 0) { $t = @($alle | Where-Object { $_.name -eq $w }) }
    if ($t.Count -eq 0) { $t = @($alle | Where-Object { $_.voll -like "*$w*" }) }
    if ($t.Count -eq 0) { throw "Datenabfrage nicht gefunden: $w" }
    if ($t.Count -gt 1) { throw "Datenabfrage mehrdeutig: " + (($t | Select-Object -First 20 | ForEach-Object { "$($_.k.ad.name): $($_.voll)" }) -join ", ") + " - vollen Namen oder addin angeben." }
    return (AbfrageDetail $t[0].k $t[0] $alle)
  }
  $liste = @(foreach ($k in $konf) {
    $o = [ordered]@{ addin = $k.ad.name; modul = $k.ad.modul; id = $k.ad.id }
    if ($k.fehler) { $o.fehler = $k.fehler; $o; continue }
    if (-not $k.schluessel) { $o.konfiguration = "keine"; $o; continue }
    $o.version = $k.o._version; $o.geaendert = $k.o._last_modified_date; $o.von = $k.o._last_author
    if ($k.o._locked) { $o.gesperrt = "$($k.o._locked_by_user) seit $($k.o._locked_on)" }
    $w = $k.inhalt
    if ($w -is [System.Management.Automation.PSCustomObject] -and $null -ne $w.Sources) {
      $o.quellen = @(L $w.Sources | ForEach-Object { $q = [ordered]@{ name = "$($_.Name)"; anmeldeprofil = [bool] $_.LoginProfile }
        if ("$($_.ConnectionString)") { $q.verbindung = "eigene Verbindungszeichenfolge" }
        $q.abfragen = @(L $_.DataQueries | ForEach-Object { "$($_.Name)$(if ($_.IsWriteCommand) { ' (schreibend)' })" })
        if (@(L $_.DataWriters).Count) { $q.schreiber = @(L $_.DataWriters).Count }
        $q })
    } elseif ($w -is [System.Management.Automation.PSCustomObject] -and $null -ne $w.Queries) {
      $o.gruppenabfragen = @(L $w.Queries | ForEach-Object { "$($_.Name) ($(@(L $_.Queries).Count) Teilabfragen)" })
    } else { $o.gliederung = Gliederung $w 3 }
    $o })
  [ordered]@{ addins = $liste; hinweis = "Einzelheiten mit abfrage (z. B. 'ERP-Database.ERP_Customer'); aendern mit blp_change baustein=dataquery." }
}
