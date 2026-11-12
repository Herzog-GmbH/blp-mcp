# blp-mcp-berichte.ps1 - Laufberichte (Berichtsdienst) und Suche im ganzen Projekt (Full Export). Nur lesend.
# Wird von blp-mcp.ps1 per Dot-Sourcing eingebunden (nutzt Blp-Get, P, L, Kurz, Baustein, Werkzeug, Log, $BERICHT, $PROJEKT, $PROJEKT_ID).
#
# Berichtsdienst (BLP 6, belegt 12.11.2026 an Test und Produktiv):
#   Liste    GET <reportUrl>/api/v3/report?query=*&page=N  -> {reports[], page, pages, has_next_page, item_count}
#            25 je Seite, aelteste zuerst. "pages" und "has_next_page" stimmen nicht verlaesslich (pages 321 bei 334 echten
#            Seiten, has_next_page ueberall false) - das Ende ist die erste leere Seite. sort/order werden ignoriert,
#            Datumsfilter in query liefern HTTP 500. start_date ist UTC. Haltedauer 28 Tage (retention_date).
#   Einzeln  GET <reportUrl>/api/v1/report/<transaction_id> -> Kopf, configuration (Feldverwaltungs-Parameter), services
#            (enthaelt Zugangsdaten der Message-Queue -> nie ungefiltert ausgeben), steps[] mit messages[] (level Debug,
#            Message, Warning, Error ...), children[] als volle Berichte, process.layout.nodes (Knoten mit module_id/processor_id).
# Full Export: GET <projectUrl>/api/v2/project/<id>/export?password= (wie Designer > Export project > full export).
#   Ohne Dateikennwort lesbares JSON mit Zugangsdaten - wird nur im Speicher gehalten, nie auf die Platte geschrieben.

$script:ExportCache = @{}
$EXPORT_SEK = 180

# ---------- Zeit ----------

function ZeitUtc([string] $s, [string] $was) {
  # "05:40" = heute (Ortszeit), "2026-11-12 05:40", ISO mit Z/Offset, oder relativ "30m", "4h", "2d"
  $s = "$s".Trim()
  if ($s -match '^(\d+)\s*(m|min|h|d)$') {
    $n = [int] $Matches[1]
    $sp = switch ($Matches[2]) { "d" { [TimeSpan]::FromDays($n) } "h" { [TimeSpan]::FromHours($n) } default { [TimeSpan]::FromMinutes($n) } }
    return [DateTimeOffset]::UtcNow - $sp
  }
  if ($s -match '^\d{1,2}:\d{2}$') { return [DateTimeOffset]::new([DateTime]::Parse((Get-Date).ToString("yyyy-MM-dd") + " " + $s)).ToUniversalTime() }
  $d = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::GetCultureInfo("de-DE"), [Globalization.DateTimeStyles]::AssumeLocal, [ref] $d)) { return $d.ToUniversalTime() }
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref] $d)) { return $d.ToUniversalTime() }
  throw "$was '$s' nicht lesbar. Moeglich: 05:40 (heute), 2026-11-12 05:40, 4h, 30m, 2d."
}
function Ort($iso) { if (-not $iso) { return "" }; ([DateTimeOffset]::Parse("$iso")).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") }
function Utc($iso) { ([DateTimeOffset]::Parse("$iso")).ToUniversalTime() }

# ---------- Berichtsdienst ----------

function BerichtBasis {
  if (-not $BERICHT) { throw "Adresse des Berichtsdienstes unbekannt: reportUrl in der Konfiguration setzen (bei BLP 6 meist der Port zehn ueber dem Identity-Dienst, z. B. ...:30011)." }
  $BERICHT
}
function BerichtSeite([int] $n) {
  $t = $null
  try { $t = Blp-Get "$(BerichtBasis)/api/v3/report?query=*&page=$n" }
  catch { throw "Berichtsdienst $(BerichtBasis) antwortet nicht wie erwartet ($($_.Exception.Message))$(if ($K.reportUrlAbgeleitet) { ". Die Adresse ist aus dem Identity-Dienst abgeleitet - stimmt sie nicht, reportUrl in der Konfiguration setzen." })" }
  $j = ConvertFrom-Json -InputObject $t -Depth 100 -DateKind String
  [pscustomobject]@{ seite = $n; pages = [int] $j.pages; berichte = @(L $j.reports) }
}
function SeiteVon($s) { if ($s.berichte.Count -eq 0) { return $null }; @($s.berichte | ForEach-Object { Utc $_.start_date } | Sort-Object)[0] }
function SeiteBis($s) { if ($s.berichte.Count -eq 0) { return $null }; @($s.berichte | ForEach-Object { Utc $_.start_date } | Sort-Object)[-1] }

# Letzte nicht leere Seite: ab "pages" vorwaerts in wachsenden Schritten bis zur ersten leeren, dann halbieren.
function LetzteSeite {
  $erste = BerichtSeite 1
  if ($erste.berichte.Count -eq 0) { return @{ nr = 0; seiten = @{} } }
  $cache = @{ 1 = $erste }
  $lo = 1; $hi = [Math]::Max(2, $erste.pages); $schritt = 4
  while ($true) {
    $s = BerichtSeite $hi; $cache[$hi] = $s
    if ($s.berichte.Count -eq 0) { break }
    $lo = $hi; $hi += $schritt; $schritt *= 2
    if ($hi -gt 100000) { throw "Berichtsdienst liefert endlos Seiten." }
  }
  while ($hi - $lo -gt 1) {
    $m = [int][Math]::Floor(($lo + $hi) / 2); $s = BerichtSeite $m; $cache[$m] = $s
    if ($s.berichte.Count -gt 0) { $lo = $m } else { $hi = $m }
  }
  @{ nr = $lo; seiten = $cache }
}

# Kinder rekursiv (Listenansicht: children mit state; Einzelbericht: children als volle Berichte)
function Kinder($r) { foreach ($c in @(L $r.children)) { $c; Kinder $c } }
function Zaehle($werte) { (@(L $werte) | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join " " }

function Meldungstext($m) {
  $t = "$($m.text)"
  $args3 = @(L $m.args)
  for ($i = 0; $i -lt $args3.Count; $i++) { $t = $t.Replace("{$i}", "$($args3[$i])") }
  $t
}

Werkzeug "blp_reports" ("Laufberichte des BLP (Berichtsdienst): ohne bericht eine Uebersicht der Prozesslaeufe in einem Zeitraum (seit/bis), je Prozess Anzahl und Status, " +
  "Kind-Laeufe, die nicht Done sind, und die auffaelligen Laeufe einzeln mit transaction_id. Mit bericht = transaction_id ein Einzelbericht: Kopf, Benutzer, " +
  "mitgegebene Feldverwaltungs-Parameter (configuration), Schritte mit Baustein, Status und Ausgang, Warn- und Fehlermeldungen, Kind-Laeufe; mit suche zusaetzlich " +
  "alle Meldungen, die den Text enthalten (z. B. einen Servernamen). Zeiten in Ortszeit. Berichte bleiben 28 Tage. Typisch: nach einer Umstellung pruefen, ob die Laeufe seitdem sauber sind.") @{
  seit = @{ type = "string"; description = "Beginn: 05:40 (heute), 2026-11-12 05:40, 4h, 30m, 2d. Standard 24h" }
  bis = @{ type = "string"; description = "Optional: Ende, gleiche Schreibweisen" }
  prozess = @{ type = "string"; description = "Optional: nur Laeufe, deren Prozessname (oder der eines Kind-Laufs) dies enthaelt" }
  kinderWarnungen = @{ type = "boolean"; description = "Kind-Laeufe mit Warning als auffaellig zaehlen (Standard false: nur gezaehlt, weil manche Container-Prozesse immer Warnungen haben)" }
  alle = @{ type = "boolean"; description = "Zusaetzlich jeden Lauf einzeln (Zeit, Prozess, Status, transaction_id), hoechstens max" }
  bericht = @{ type = "string"; description = "transaction_id fuer den Einzelbericht" }
  suche = @{ type = "string"; description = "Nur mit bericht: Meldungen (alle Stufen) mit diesem Text, z. B. srv-alt oder :32108" }
  max = @{ type = "integer"; description = "Hoechstens so viele auffaellige Laeufe bzw. Suchtreffer zeigen (Standard 50)" } } @() {
  param($a)
  $max = if ($a.max) { [int] $a.max } else { 50 }
  if ($a.bericht) { return (Einzelbericht "$($a.bericht)" "$($a.suche)" $max) }
  if ($a.suche) { throw "suche gilt nur mit bericht (transaction_id). Ueber viele Laeufe: erst die Uebersicht, dann einzelne Berichte." }

  $von = if ($a.seit) { ZeitUtc $a.seit "seit" } else { [DateTimeOffset]::UtcNow.AddHours(-24) }
  $bis = if ($a.bis) { ZeitUtc $a.bis "bis" } else { [DateTimeOffset]::MaxValue }
  $letzte = LetzteSeite
  if ($letzte.nr -eq 0) { return [ordered]@{ berichtsdienst = $BERICHT; anzahl = 0; hinweis = "Der Berichtsdienst hat keine Berichte." } }
  $cache = $letzte.seiten
  function Hol([int] $n) { if (-not $cache.ContainsKey($n)) { $cache[$n] = BerichtSeite $n }; $cache[$n] }

  # erste Seite, deren juengster Lauf nicht vor "seit" liegt (Seiten sind aelteste zuerst)
  $lo = 1; $hi = $letzte.nr
  while ($lo -lt $hi) { $m = [int][Math]::Floor(($lo + $hi) / 2); if ((SeiteBis (Hol $m)) -lt $von) { $lo = $m + 1 } else { $hi = $m } }
  $start = $lo; $MAXSEITEN = 60; $gekuerzt = $false
  $laeufe = [System.Collections.Generic.List[object]]::new()
  for ($n = $start; $n -le $letzte.nr; $n++) {
    if ($n - $start -ge $MAXSEITEN) { $gekuerzt = $true; break }
    $s = Hol $n
    if ((SeiteVon $s) -gt $bis) { break }
    foreach ($r in $s.berichte) { $t = Utc $r.start_date; if ($t -ge $von -and $t -le $bis) { $laeufe.Add($r) } }
  }
  if ($a.prozess) {
    $f = "$($a.prozess)"
    $laeufe = @($laeufe | Where-Object { "$($_.process.name)" -like "*$f*" -or @(Kinder $_ | Where-Object { "$($_.process.name)" -like "*$f*" }).Count })
  }
  $laeufe = @($laeufe | Sort-Object { Utc $_.start_date })

  $je = @($laeufe | Group-Object { "$($_.process.name)" } | Sort-Object Count -Descending | ForEach-Object {
    $kinderSchlecht = @($_.Group | ForEach-Object { Kinder $_ } | Where-Object { $_.state -ne "Done" } | ForEach-Object { "$($_.process.name)=$($_.state)" })
    $o = [ordered]@{ prozess = $_.Name; anzahl = $_.Count; status = (Zaehle ($_.Group | ForEach-Object { $_.state })) }
    if ($kinderSchlecht.Count) { $o.kinderNichtDone = Zaehle $kinderSchlecht }
    $o })
  $auff = @(foreach ($r in $laeufe) {
    $k = @(Kinder $r | Where-Object { $_.state -ne "Done" -and ($a.kinderWarnungen -or $_.state -ne "Warning") })
    if ($r.state -eq "Done" -and $k.Count -eq 0) { continue }
    $o = [ordered]@{ zeit = Ort $r.start_date; prozess = $r.process.name; status = $r.state; ms = $r.execution_time; bericht = $r.transaction_id }
    if ($k.Count) { $o.kinder = (@($k | ForEach-Object { "$($_.process.name)=$($_.state)" }) -join ", ") }
    $o })
  $o = [ordered]@{
    berichtsdienst = $BERICHT; zeitraum = "$(Ort $von.ToString('o')) bis $(if ($bis -eq [DateTimeOffset]::MaxValue) { 'jetzt' } else { Ort $bis.ToString('o') }) (Ortszeit)"
    anzahl = $laeufe.Count; ersterLauf = $(if ($laeufe.Count) { Ort $laeufe[0].start_date }); letzterLauf = $(if ($laeufe.Count) { Ort $laeufe[-1].start_date })
    status = (Zaehle ($laeufe | ForEach-Object { $_.state })); jeProzess = $je
    auffaellig = @($auff | Select-Object -First $max); auffaelligAnzahl = $auff.Count
    hinweis = ("Einzelbericht mit bericht = <transaction_id>, dort mit suche nach Text in allen Meldungen. Kind-Laeufe mit Warning sind nur gezaehlt (kinderWarnungen = true zeigt sie einzeln)." +
      $(if ($gekuerzt) { " GEKUERZT: mehr als $MAXSEITEN Seiten - Zeitraum enger waehlen." } else { "" }))
  }
  if ($a.alle) { $o.laeufe = @($laeufe | Select-Object -Last $max | ForEach-Object { "{0}  {1}  {2}  {3}" -f (Ort $_.start_date), $_.process.name, $_.state, $_.transaction_id }) }
  $o
}

function Einzelbericht([string] $id, [string] $suche, [int] $max) {
  if ($id -notmatch '^[0-9a-fA-F-]{36}$') { throw "bericht muss eine transaction_id sein (GUID), z. B. aus der Uebersicht." }
  $j = ConvertFrom-Json -InputObject (Blp-Get "$(BerichtBasis)/api/v1/report/$id") -Depth 100 -DateKind String
  function Lauf($r, [int] $tiefe) {
    # jeder Lauf (auch ein Kind-Lauf) bringt seinen eigenen Prozess mit Knoten mit
    $nodes = @{}
    foreach ($n in @(L $r.process.layout.nodes)) { $nodes["$($n.id)"] = $n }
    $schritte = @(L $r.steps)
    $warn = [System.Collections.Generic.List[object]]::new()
    $zeilen = @(for ($i = 0; $i -lt $schritte.Count; $i++) {
      $st = $schritte[$i]; $nd = $nodes["$($st.diagram_node_id)"]
      $name = if ($nd) { Baustein "$($nd.module_id)" "$($nd.processor_id)" } else { "Knoten" }
      $kn = "$($st.diagram_node_id)"; if ($kn.Length -gt 8) { $kn = $kn.Substring(0, 8) }
      foreach ($m in @(L $st.messages)) {
        if ("$($m.level)" -notin "Debug", "Message", "Info", "Information") { $warn.Add([ordered]@{ schritt = $i + 1; knoten = $kn; stufe = $m.level; text = Kurz (Meldungstext $m) 600 }) }
      }
      $z = "{0,2}. {1} [{2}] {3} -> {4}{5}" -f ($i + 1), $name, $kn, $st.state, $(if ("$($st.exit_port)") { $st.exit_port } else { "(kein Ausgang)" }), $(if ($st.processor_execution_time) { ", $($st.processor_execution_time) ms" } else { "" })
      $z })
    $o = [ordered]@{ prozess = $r.process.name; bericht = $r.transaction_id; status = $r.state; start = Ort $r.start_date; ende = Ort $r.end_date; ms = $r.execution_time
      meldungen = (Zaehle (@(L $schritte) | ForEach-Object { @(L $_.messages) } | ForEach-Object { $_.level })); schritte = $zeilen }
    if ($warn.Count) { $o.warnungenUndFehler = @($warn | Select-Object -First $max) }
    if ($r.state -ne "Done" -and $warn.Count -eq 0) {
      $ohne = @($schritte | Where-Object { -not "$($_.exit_port)" })
      $o.hinweis = "Status $($r.state) ohne Warn- oder Fehlermeldung im Protokoll." + $(if ($ohne.Count) { " $($ohne.Count) Schritt(e) endeten ohne Ausgang (kein Nachfolger verbunden oder Abbruch) - das setzt den Lauf auf $($r.state)." } else { "" })
    }
    $o
  }
  $kopf = Lauf $j 0
  $o = [ordered]@{ prozess = $j.process.name; bericht = $j.transaction_id; status = $j.state; start = Ort $j.start_date; ende = Ort $j.end_date; ms = $j.execution_time
    benutzer = $j.owner.user; rechner = $j.owner.machine_name; modus = $j.execution_mode; ausgefuehrteBausteine = $j.executed_processors
    parameter = $j.configuration; meldungen = $kopf.meldungen; schritte = $kopf.schritte }
  if ($kopf.warnungenUndFehler) { $o.warnungenUndFehler = $kopf.warnungenUndFehler }
  if ($kopf.hinweis) { $o.hinweis = $kopf.hinweis }
  $kinder = @(Kinder $j)
  if ($kinder.Count) { $o.kinder = @($kinder | ForEach-Object { Lauf $_ 1 }) }
  if ($suche) {
    $treffer = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(@($j) + $kinder)) {
      $schritte = @(L $r.steps)
      for ($i = 0; $i -lt $schritte.Count; $i++) {
        foreach ($m in @(L $schritte[$i].messages)) {
          $t = Meldungstext $m
          if ($t.IndexOf($suche, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $treffer.Add([ordered]@{ prozess = $r.process.name; schritt = $i + 1; zeit = Ort $m.time; stufe = $m.level; text = Kurz $t 400 }) }
        }
      }
    }
    $o.suche = [ordered]@{ text = $suche; treffer = $treffer.Count; meldungen = @($treffer | Select-Object -First $max)
      inParametern = @(L $j.configuration.PSObject.Properties | Where-Object { "$($_.Value)".IndexOf($suche, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.Name }) }
  }
  $o
}

# ---------- Suche im ganzen Projekt ----------

# Bereich des Exports -> Baustein fuer blp_read_path/blp_change (Pfade im Export entsprechen dem Baustein)
$EXPORT_BAUSTEIN = @{ Processes = "processengine"; BusinessObjects = "objectmanager"; FieldManager = "fieldmanager"; RolesAndSituations = "role"; SmartSearchProfiles = "smartsearch"; ModuleConfigs = "module" }
$GEHEIM = '(?i)pass|pwd|secret|token|credential|apikey|api_key|connectionstring'

function ExportLaden([switch] $Neu) {
  $c = $script:ExportCache[$UMGEBUNG_NAME]
  if (-not $Neu -and $c -and ((Get-Date) - $c.zeit).TotalSeconds -lt $EXPORT_SEK) { return $c }
  $t = Blp-Get "$PROJEKT/api/v2/project/$PROJEKT_ID/export?password="
  $o = ConvertFrom-Json -InputObject $t -Depth 100 -DateKind String
  $c = @{ zeit = Get-Date; obj = $o; zeichen = $t.Length; version = $o.Information._version }
  $script:ExportCache[$UMGEBUNG_NAME] = $c
  $c
}

# Listenelement fuer den Pfad benennen (gleiche Auswahl-Schreibweise wie blp_change)
function Glied($e, [int] $i) {
  if ($e -is [System.Management.Automation.PSCustomObject]) {
    foreach ($f in "name", "Name", "tile_id", "tab_id", "id", "Id", "_id") {
      $p = $e.PSObject.Properties[$f]
      if ($p -and "$($p.Value)" -and "$($p.Value)" -notmatch '[/\[\]]') {
        $v = "$($p.Value)"
        if ($f -in "id", "Id", "_id", "tile_id", "tab_id" -and $v.Length -gt 8) { return "[$f^=$($v.Substring(0, 8))]" }
        return "[$f=$v]"
      }
    }
  }
  "$i"
}

function Durchsuche($n, [string] $pfad, [string] $schluessel, [string] $text, $treffer, [int] $max) {
  if ($treffer.Count -ge $max) { return }
  if ($n -is [string]) {
    $pos = $n.IndexOf($text, [StringComparison]::OrdinalIgnoreCase)
    if ($pos -lt 0) { return }
    $s = $n.TrimStart()
    if ($s.Length -gt 1 -and ($s[0] -eq '{' -or $s[0] -eq '[')) {
      $innen = $null; try { $innen = ConvertFrom-Json -InputObject $n -Depth 100 -DateKind String -NoEnumerate } catch {}
      if ($null -ne $innen -and $innen -isnot [string]) { $vor = $treffer.Count; Durchsuche $innen "$pfad/#" $schluessel $text $treffer $max; if ($treffer.Count -gt $vor) { return } }
    }
    $wert = if ($schluessel -match $GEHEIM) { "***" } else {
      $a = [Math]::Max(0, $pos - 80); $e = [Math]::Min($n.Length, $pos + $text.Length + 80)
      $(if ($a -gt 0) { "..." } else { "" }) + $n.Substring($a, $e - $a) + $(if ($e -lt $n.Length) { "..." } else { "" }) }
    $treffer.Add(@{ pfad = $pfad; wert = $wert })
    return
  }
  if ($n -is [array]) { for ($i = 0; $i -lt $n.Count; $i++) { Durchsuche $n[$i] "$pfad/$(Glied $n[$i] $i)" $schluessel $text $treffer $max }; return }
  if ($n -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $n.PSObject.Properties) {
      if ($p.Name -eq "_read_token" -or $p.Name -eq "links") { continue }
      if ($p.Name.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $treffer.Count -lt $max) { $treffer.Add(@{ pfad = "$pfad/$($p.Name)"; wert = "(Schluessel) " + $(if ($p.Name -match $GEHEIM) { "***" } else { Kurz $p.Value 160 }) }) }
      Durchsuche $p.Value "$pfad/$($p.Name)" $p.Name $text $treffer $max
    }
    return
  }
  if ($null -ne $n -and "$n".IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $treffer.Count -lt $max) { $treffer.Add(@{ pfad = $pfad; wert = $(if ($schluessel -match $GEHEIM) { "***" } else { "$n" }) }) }
}

Werkzeug "blp_search" ("Sucht einen Text im ganzen BLP-Projekt (Full Export wie im Designer: Prozesse, Geschaeftsobjekte, Feldverwaltung, Rollen, Modulkonfigurationen, Datenabfragen, " +
  "Zugangsdaten-Eintraege, Bereitstellungsprofile, Richtlinien mit Service-Pools, Themes ...), auch in eingebettetem JSON. Liefert je Treffer Bereich, Objekt, Pfad (bei Prozessen, Objekten, " +
  "Feldverwaltung, Rollen, Suchprofilen und Modulen direkt fuer blp_read_path/blp_change) und einen Ausschnitt. Typisch: Wo steht noch ein alter Servername, wo wird ein Parameter, " +
  "eine Abfrage oder eine Prozess-ID benutzt? Gross/klein egal. Werte von Schluesseln mit pass/secret/token/credential/connectionstring erscheinen als ***. " +
  "Der Export bleibt nur im Speicher (3 Minuten fuer weitere Suchen), Bildpaket nur mit bereich.") @{
  text = @{ type = "string"; description = "Suchtext, z. B. srv-alt, ECMServer, ein Abfragename, eine Prozess-ID" }
  bereich = @{ type = "string"; description = "Optional: nur diese Bereiche des Exports, mit Komma, z. B. Processes,FieldManager,Policies,ServicePools,CredentialStore,DataConnect,ModuleConfigs,DeploymentProfiles" }
  max = @{ type = "integer"; description = "Hoechstens so viele Treffer (Standard 100)" }
  neu = @{ type = "boolean"; description = "Export neu laden statt der Kopie der letzten 3 Minuten" } } @("text") {
  param($a)
  $text = "$($a.text)"
  if ($text.Length -lt 3) { throw "Suchtext zu kurz (mindestens 3 Zeichen)." }
  $max = if ($a.max) { [int] $a.max } else { 100 }
  $e = ExportLaden -Neu:([bool] $a.neu)
  $bereiche = @($e.obj.PSObject.Properties.Name)
  $nur = @(if ($a.bereich) { "$($a.bereich)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
  foreach ($b in $nur) { if ($b -notin $bereiche) { throw "Bereich '$b' gibt es im Export nicht. Vorhanden: $($bereiche -join ', ')" } }
  $treffer = [System.Collections.Generic.List[object]]::new()
  $ergebnis = [System.Collections.Generic.List[object]]::new()
  foreach ($b in $bereiche) {
    if ($nur.Count -and $b -notin $nur) { continue }
    if (-not $nur.Count -and $b -eq "ImageRepositryPackages") { continue }   # Bilddaten base64, Mehrere MB
    if ($treffer.Count -ge $max) { break }
    $wert = $e.obj.$b
    $elemente = if ($wert -is [array]) { $wert } else { @($wert) }
    for ($i = 0; $i -lt @($elemente).Count; $i++) {
      $el = @($elemente)[$i]
      $vor = $treffer.Count
      Durchsuche $el "" "" $text $treffer $max
      if ($treffer.Count -eq $vor) { continue }
      $objekt = if ($b -eq "ModuleConfigs" -and $el.module_id) {
        # blp_change module nimmt Modulname oder Modul-ID (nicht die _id der Konfiguration)
        $m = @(L (Modulliste) | Where-Object { $_.module_id -eq $el.module_id }); $(if ($m.Count -and $m[0].name) { "$($m[0].name)" } else { "$($el.module_id)" })
      } elseif ($wert -is [array]) { $(if ($el.name) { "$($el.name)" } elseif ($el.Name) { "$($el.Name)" } elseif ($el._id) { "$($el._id)" } else { "#$i" }) } else { "" }
      for ($k = $vor; $k -lt $treffer.Count; $k++) {
        $t = $treffer[$k]
        $o = [ordered]@{ bereich = $b }
        if ($objekt) { $o.objekt = $objekt }
        $o.pfad = "$($t.pfad)".TrimStart('/'); $o.wert = $t.wert
        if ($EXPORT_BAUSTEIN.ContainsKey($b)) { $o.baustein = $EXPORT_BAUSTEIN[$b] }
        $ergebnis.Add($o)
      }
    }
  }
  [ordered]@{ text = $text; umgebung = $UMGEBUNG; projektVersion = $e.version; exportVon = $e.zeit.ToString("HH:mm:ss"); treffer = $ergebnis.Count
    gekuerzt = ($ergebnis.Count -ge $max); ergebnisse = @($ergebnis)
    hinweis = "pfad mit baustein: direkt fuer blp_read_path/blp_change (objekt = objekt). Andere Bereiche (Policies, ServicePools, CredentialStore, DeploymentProfiles, DataConnect) aendert dieser Server nicht - dafuer den Designer nehmen." }
}
