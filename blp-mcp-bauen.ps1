# blp-mcp-bauen.ps1 - Stufe 3 des BLP-MCP-Servers: Prozesse als Bauplan exportieren und aus einem Bauplan bauen,
# Geschaeftsobjekte anlegen.
# Wird von blp-mcp.ps1 nach blp-mcp-aendern.ps1 per Dot-Sourcing eingebunden (nutzt Blp-Get, Blp-Send, Lies, P, L, Kurz,
# Finde, Prozessliste, Maskiere, Werkzeug, JObj, JStr, Kopie, Wende, Pruefe, ZweiSchritte, AenderungAusfuehren,
# FesteGuid, Sprachcode, Protokoll).
#
# Bauplan eines Prozesses (JSON):
#   name          Prozessname
#   ordner        Prozessordner (Name oder ID); ob Server- oder Client-Prozess, folgt aus dem Ordner
#   art           client | server (beim Export zur Information, beim Bauen gegen den Ordner geprueft)
#   optionen      Prozessoptionen, z. B. {"viewport": {"x": 0, "y": 0, "zoom": 1}} (Ansicht im Designer)
#   knoten        [{key, baustein, beschreibung, x, y, parameter, felder, konfigFehler, id}]
#     key           kurzer, eindeutiger Schluessel; der Export nimmt den Anfang der Knoten-ID (8 Zeichen), Start = "start"
#     baustein      Anzeigename des Prozessors (Prozessorliste aller Module, GET /api/v1/module), "Start" fuer den
#                   Startknoten; bei Mehrdeutigkeit "Modul/Name"; auch der technische Name oder die Prozessor-ID
#     parameter     Parameter des Knotens, eingebettetes JSON entpackt; beim Bauen wieder als Text.
#                   fehlt = {}, null = keine Parameter (so speichert der Designer z. B. File Upload)
#     felder        Ausgabefelder des Knotens (fields), z. B. die Feldnamen eines Eingabeformulars
#     id            optional: volle Knoten-ID. Sonst beim Ersetzen die vorhandene ID, deren Anfang der key ist,
#                   und fuer neue Knoten eine feste ID aus Prozess und key.
#   verbindungen  [[von, port, nach], [von, port, nach, kommentar]]; port = Ausgang des Prozessors (Start: START)

$NULL_GUID = "00000000-0000-0000-0000-000000000000"
$BAUPLAN_INLINE = 20000   # groessere Bauplaene gehen als Datei; die Antwort waere sonst gekuerzt
$BAUPLAN_ORDNER = Join-Path $DATEN "bauplan"
$PLAN_FELDER = @("name", "ordner", "art", "optionen", "childs", "knoten", "verbindungen")
$KNOTEN_FELDER = @("key", "baustein", "modul", "beschreibung", "x", "y", "parameter", "felder", "konfigFehler", "id")
$START_BAUSTEIN = [pscustomobject]@{ id = $NULL_GUID; modulId = $NULL_GUID; modul = ""; name = "Start"; anzeige = "Start"; ein = @(); aus = @("START") }

# ---------- Bausteinkatalog ----------

$script:Katalog = $null
function Katalog {
  if ($script:Katalog) { return $script:Katalog }
  # Alle Module mit Prozessoren und Ports in einem Aufruf (dieselben Daten wie module/<id> je Modul).
  $d = JObj (Blp-Get "$PROJEKT/api/v1/module")
  $mods = if ($d.modules) { $d.modules } else { $d }
  $nachId = @{}; $liste = [System.Collections.Generic.List[object]]::new()
  foreach ($m in @(L $mods)) {
    foreach ($p in @(L $m.processors)) {
      $e = [pscustomobject]@{ id = "$($p.info.id)"; modulId = "$($m.module_id)"; modul = "$($m.name)"; name = "$($p.info.name)"; anzeige = "$($p.info.display_text)"
        ein = @(foreach ($x in @(L $p.input_ports)) { "$($x.id)" }); aus = @(foreach ($x in @(L $p.output_ports)) { "$($x.id)" }) }
      $nachId[$e.id] = $e; $liste.Add($e)
    }
  }
  $script:Katalog = @{ nachId = $nachId; liste = $liste.ToArray() }
  $script:Katalog
}

# Name eines Prozessors im Bauplan: Anzeigename, bei Mehrdeutigkeit mit dem Modul davor.
function BausteinText($e) {
  if ($e.id -eq $NULL_GUID) { return "Start" }
  if (@((Katalog).liste | Where-Object { $_.anzeige -eq $e.anzeige }).Count -gt 1) { "$($e.modul)/$($e.anzeige)" } else { $e.anzeige }
}

function BausteinSuchen([string] $text) {
  $t = $text.Trim()
  if (-not $t) { throw "baustein fehlt." }
  if ($t -eq "Start" -or $t -eq $NULL_GUID) { return $START_BAUSTEIN }
  $kat = Katalog
  if ($kat.nachId.ContainsKey($t)) { return $kat.nachId[$t] }
  $modul = $null; $name = $t
  if ($t.Contains("/")) { $i = $t.IndexOf("/"); $modul = $t.Substring(0, $i).Trim(); $name = $t.Substring($i + 1).Trim() }
  $treffer = @($kat.liste | Where-Object { ($_.anzeige -eq $name -or $_.name -eq $name) -and (-not $modul -or $_.modul -eq $modul) })
  if ($treffer.Count -eq 1) { return $treffer[0] }
  if ($treffer.Count -gt 1) { throw "Baustein '$t' ist mehrdeutig: " + (($treffer | ForEach-Object { "$($_.modul)/$($_.anzeige)" }) -join ", ") }
  $muster = "*$([WildcardPattern]::Escape($name))*"
  $aehnlich = @($kat.liste | Where-Object { $_.anzeige -like $muster -or $_.name -like $muster } | Select-Object -First 8 | ForEach-Object { $_.anzeige })
  throw "Baustein '$t' gibt es nicht" + $(if ($aehnlich.Count) { " (aehnlich: $($aehnlich -join ', '))" } else { " (Liste: blp_process_export ohne prozess)" }) + "."
}

# ---------- Parameter: eingebettetes JSON entpacken und wieder packen ----------

# JSON als Hashtable: haelt Schluessel, die sich nur in Gross-/Kleinschreibung unterscheiden. Echte Setter-Parameter
# haben "type" und "Type" nebeneinander - als PowerShell-Objekt (JObj) geht das nicht.
function HObj([string] $s) { return ,(ConvertFrom-Json -InputObject $s -AsHashtable -Depth 100 -DateKind String -NoEnumerate) }

# Nur Objekte und Listen werden entpackt; Text, der wie eine Zahl oder ein Wahrheitswert aussieht, bleibt Text.
function Entpacke($v) {
  if ($v -is [string]) {
    $t = $v.TrimStart()
    if ($t.StartsWith("{") -or $t.StartsWith("[")) {
      try { return ,(JObj $v) } catch {}
      try { return ,(HObj $v) } catch {}
    }
  }
  return ,$v
}

function Packe($v, [string] $wo) {
  if ($null -eq $v -or $v -is [string]) { return $v }
  if ($v -is [array] -or $v -is [System.Management.Automation.PSCustomObject] -or $v -is [System.Collections.IDictionary]) { return (JStr $v) }
  throw "$wo : muss Text, Objekt oder Liste sein, nicht $($v.GetType().Name) ($v)."
}

# Schluessel rekursiv sortiert - fuer den inhaltlichen Vergleich von JSON.
function Norm($o) {
  if ($o -is [System.Collections.IDictionary]) {
    $h = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($k in @($o.Keys | Sort-Object -CaseSensitive)) { $h[$k] = Norm $o[$k] }; return $h
  }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($k in @(@(foreach ($p in $o.PSObject.Properties) { $p.Name }) | Sort-Object -CaseSensitive)) { $h[$k] = Norm $o.$k }; return $h
  }
  if ($o -is [array]) { $l = [System.Collections.Generic.List[object]]::new(); foreach ($e in $o) { $l.Add((Norm $e)) }; return ,($l.ToArray()) }
  $o
}

# Zwei Parameterwerte inhaltlich gleich? Eingebettetes JSON zaehlt nach Inhalt, nicht nach Schreibweise.
function WertGleich($a, $b) {
  if ($a -is [string] -and $b -is [string]) {
    if ($a -ceq $b) { return $true }
    $x = Entpacke $a; $y = Entpacke $b
    if ($x -is [string] -or $y -is [string]) { return $false }
    return (JStr (Norm $x)) -ceq (JStr (Norm $y))
  }
  (JStr (Norm $a)) -ceq (JStr (Norm $b))
}

# Findet Werte, die beim Ausgeben maskiert wurden (***) - so ein Bauplan wuerde Passwoerter ueberschreiben.
function MaskeGefunden($o, [string] $wo) {
  if ($o -is [string]) { if ($o -ceq "***" -or $o.Contains('"***"') -or $o -match '(?i)(password|pwd)\s*=\s*\*\*\*') { return $wo }; return $null }
  if ($o -is [array]) { for ($i = 0; $i -lt $o.Count; $i++) { $r = MaskeGefunden $o[$i] "$wo/$i"; if ($r) { return $r } }; return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $r = MaskeGefunden $p.Value "$wo/$($p.Name)"; if ($r) { return $r } } }
  $null
}

function GuidText([string] $s) { $s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }

# ---------- Prozess -> Bauplan ----------

# Knoten-ID -> key: Anfang der ID (8 Zeichen, laenger, wenn noetig), Startknoten "start".
function KeysVergeben($nodes) {
  $keys = @{}; $ids = @(foreach ($n in @(L $nodes)) { "$($n.id)" })
  foreach ($id in $ids) {
    if ($id -eq $NULL_GUID) { $keys[$id] = "start"; continue }
    $len = [Math]::Min(8, $id.Length)
    while ($len -lt $id.Length -and @($ids | Where-Object { $_ -ne $id -and $_.StartsWith($id.Substring(0, $len), [StringComparison]::Ordinal) }).Count) { $len++ }
    $keys[$id] = $id.Substring(0, $len)
  }
  $keys
}

function PlanAusProzess($p, $keys, [string] $art, [string] $ordner) {
  $warn = [System.Collections.Generic.List[string]]::new()
  if (-not $keys) { $keys = KeysVergeben $p.nodes }
  $kat = Katalog
  $knoten = [System.Collections.Generic.List[object]]::new()
  foreach ($n in @(L $p.nodes)) {
    $o = [ordered]@{ key = $keys["$($n.id)"] }
    if ("$($n.processor_id)" -eq $NULL_GUID) { $o.baustein = "Start" }
    elseif ($kat.nachId.ContainsKey("$($n.processor_id)")) { $o.baustein = BausteinText $kat.nachId["$($n.processor_id)"] }
    else {
      $o.baustein = "$($n.processor_id)"; $o.modul = "$($n.module_id)"
      $warn.Add("Knoten $($o.key): Prozessor $($n.processor_id) steht in keinem Modul (Modul $($n.module_id) nicht installiert?) - baustein ist die Prozessor-ID, Ports ungeprueft.")
    }
    if ("$($n.description)") { $o.beschreibung = "$($n.description)" }
    $o.x = $n.offset.x; $o.y = $n.offset.y
    if ($null -eq $n.parameters) { $o.parameter = $null }
    elseif (@($n.parameters.PSObject.Properties).Count) {
      $par = [ordered]@{}
      foreach ($q in $n.parameters.PSObject.Properties) { $par[$q.Name] = Entpacke $q.Value }
      $o.parameter = $par
    }
    if ($n.PSObject.Properties["fields"]) { if ($null -eq $n.fields) { $o.felder = $null } else { $o.felder = @($n.fields) } }
    if ($n.has_config_errors) { $o.konfigFehler = $true }
    $knoten.Add($o)
  }
  $verb = [System.Collections.Generic.List[object]]::new()
  foreach ($c in @(L $p.connectors)) {
    $von = "$($c.source_node)"; $nach = "$($c.target_node)"
    if (-not $keys.ContainsKey($von) -or -not $keys.ContainsKey($nach)) {
      $warn.Add("Verbindung $(Kurz $c.source_port 60) -> $(Kurz $c.target_port 60) zeigt auf einen Knoten, den es im Prozess nicht gibt (Rest im Designer) - im Bauplan weggelassen."); continue
    }
    $port = "$($c.source_port)"
    if ($port.StartsWith("$von.", [StringComparison]::Ordinal)) { $port = $port.Substring($von.Length + 1) }
    else { $warn.Add("Verbindung $($keys[$von]) -> $($keys[$nach]): Ausgang '$port' ohne Knoten-ID davor - so nicht nachbaubar.") }
    if ("$($c.target_port)" -cne "$nach.input") { $warn.Add("Verbindung $($keys[$von]) -> $($keys[$nach]) endet an '$($c.target_port)' statt am Eingang input - der Bauplan kennt nur den Eingang.") }
    $e = [System.Collections.Generic.List[object]]::new(); $e.Add($keys[$von]); $e.Add($port); $e.Add($keys[$nach])
    if ("$($c.comment)") { $e.Add("$($c.comment)") }
    $verb.Add($e.ToArray())
  }
  $plan = [ordered]@{ name = "$($p.name)" }
  if ($ordner) { $plan.ordner = $ordner }
  if ($art) { $plan.art = $art }
  if ($null -ne $p.options) { $opt = [ordered]@{}; foreach ($q in $p.options.PSObject.Properties) { $opt[$q.Name] = Entpacke $q.Value }; $plan.optionen = $opt }
  if ($null -ne $p.childs) { $plan.childs = $p.childs }
  $plan.knoten = $knoten.ToArray(); $plan.verbindungen = $verb.ToArray()
  @{ plan = $plan; warnungen = $warn.ToArray(); keys = $keys }
}

# ---------- Bauplan -> Prozess ----------

function ProzessOrdnerFinden([string] $wer, [string] $art) {
  $d = Lies "processengine"; $l = [System.Collections.Generic.List[object]]::new()
  foreach ($a in "server_processes", "client_processes", "sub_processes", "templates") {
    foreach ($o in @(L $d.$a)) { $l.Add([pscustomobject]@{ id = $o._id; name = $o.name; art = ($a -replace '_processes$|s$', ''); type = $o.type }) }
  }
  $liste = @($l)
  if ($art) { $liste = @($liste | Where-Object { $_.art -eq $art }) }
  Finde $liste $wer "Prozessordner$(if ($art) { " ($art)" })"
}

function KnotenKern($par) {
  if ($par -isnot [System.Management.Automation.PSCustomObject]) { return "" }
  foreach ($q in $par.PSObject.Properties) {
    $v = $q.Value; if ($v -is [string]) { $v = Entpacke $v }
    if ($v -isnot [System.Management.Automation.PSCustomObject] -and $v -isnot [System.Collections.IDictionary]) { continue }
    foreach ($f in "headline", "Content", "LogicProcess", "ProcessName") { if ("$($v.$f)") { return "${f}: $(Kurz "$($v.$f)" 80)" } }
    $as = @(L $v.AsDefinitions); if ($as.Count -and "$($as[0].RuleSetName)") { return "Regel $($as[0].RuleSetName)" }
    $fl = @(L $v.Fields); if ($fl.Count -and "$($fl[0].name)") { return "Felder " + (@($fl | Select-Object -First 6 | ForEach-Object { $_.name }) -join ", ") }
  }
  ""
}

# Prueft den Bauplan und uebersetzt ihn in Knoten und Verbindungen des Dienstes.
# $vorhanden: Knoten des Prozesses, der ersetzt wird (deren IDs werden ueber den key weiterverwendet);
# $basis: Text fuer feste IDs neuer Knoten (gleicher Bauplan -> gleiche IDs in Vorschau und Ausfuehrung).
function PlanUebersetzen($b, $vorhanden, [string] $basis) {
  $f = [System.Collections.Generic.List[string]]::new(); $w = [System.Collections.Generic.List[string]]::new()
  foreach ($q in $b.PSObject.Properties) { if ($q.Name -cnotin $PLAN_FELDER -and -not $q.Name.StartsWith("_")) { $f.Add("Bauplan: unbekannte Eigenschaft '$($q.Name)' (erlaubt: $($PLAN_FELDER -join ', ')).") } }
  if (-not "$($b.name)".Trim()) { $f.Add("name fehlt.") }
  $kn = @(L $b.knoten); $vb = @(L $b.verbindungen)
  if ($kn.Count -eq 0) { $f.Add("knoten fehlt oder ist leer.") }
  if ($null -eq $b.verbindungen) { $f.Add("verbindungen fehlt.") }
  if ($f.Count) { return @{ fehler = $f.ToArray(); warn = $w.ToArray() } }
  $m = MaskeGefunden $b.knoten "knoten"
  if ($m) { $f.Add("$m enthaelt einen maskierten Wert (***), z. B. aus einer gekuerzten Antwort. Bauplan aus der Datei von blp_process_export nehmen (datei).") }

  $vorh = @{}; foreach ($n in @(L $vorhanden)) { $vorh["$($n.id)"] = $n }
  $byKey = [ordered]@{}; $ids = @{}; $starts = 0; $startKey = $null
  $nodes = [System.Collections.Generic.List[object]]::new()
  foreach ($k in $kn) {
    if ($k -isnot [System.Management.Automation.PSCustomObject]) { $f.Add("Knoten $(Kurz $k 80): kein Objekt."); continue }
    $key = "$($k.key)".Trim()
    $unbekannt = @(foreach ($q in $k.PSObject.Properties) { if ($q.Name -cnotin $KNOTEN_FELDER -and -not $q.Name.StartsWith("_")) { $q.Name } })
    if ($unbekannt.Count) { $f.Add("Knoten '$key': unbekannte Eigenschaft $($unbekannt -join ', ') (erlaubt: $($KNOTEN_FELDER -join ', ')).") }
    if (-not $key) { $f.Add("Knoten ohne key (baustein '$($k.baustein)')."); continue }
    if ($byKey.Contains($key)) { $f.Add("key '$key' doppelt."); continue }
    $e = $null
    try { $e = BausteinSuchen "$($k.baustein)" }
    catch {
      if ((GuidText "$($k.baustein)") -and (GuidText "$($k.modul)")) {
        $e = [pscustomobject]@{ id = "$($k.baustein)"; modulId = "$($k.modul)"; modul = "?"; name = "?"; anzeige = "$($k.baustein)"; ein = @("input"); aus = $null }
        $w.Add("Knoten '$key': Prozessor $($k.baustein) steht in keinem Modul - Ports ungeprueft.")
      } else { $f.Add("Knoten '$key': $($_.Exception.Message)"); continue }
    }
    if ($e.id -eq $NULL_GUID) { $starts++; $startKey = $key }
    # ID: Start fest, sonst angegeben, sonst vorhandener Knoten mit diesem Anfang und gleichem Prozessor, sonst fest aus Prozess und key
    $id = $null
    if ($e.id -eq $NULL_GUID) { $id = $NULL_GUID }
    elseif ("$($k.id)") { if (GuidText "$($k.id)") { $id = "$($k.id)" } else { $f.Add("Knoten '$key': id '$($k.id)' ist keine GUID."); continue } }
    else {
      $alt = @(if ($key.Length -ge 8) { $vorh.Keys | Where-Object { $_.StartsWith($key, [StringComparison]::Ordinal) -and "$($vorh[$_].processor_id)" -eq $e.id } })
      $id = if ($alt.Count -eq 1) { $alt[0] } else { FesteGuid "processengine|$basis|$key" }
    }
    if ($ids.ContainsKey($id)) { $f.Add("Knoten '$key': ID $id hat schon Knoten '$($ids[$id])'."); continue }
    $ids[$id] = $key
    foreach ($xy in "x", "y") { if ($null -ne $k.$xy -and $k.$xy -isnot [ValueType]) { $f.Add("Knoten '$key': $xy muss eine Zahl sein.") } }
    $par = [pscustomobject]@{}
    if ($k.PSObject.Properties["parameter"]) {
      if ($null -eq $k.parameter) { $par = $null }
      elseif ($k.parameter -isnot [System.Management.Automation.PSCustomObject]) { $f.Add("Knoten '$key': parameter muss ein Objekt sein ({name: wert}).") }
      else {
        $par = [pscustomobject][ordered]@{}
        foreach ($q in $k.parameter.PSObject.Properties) {
          try { $par | Add-Member -NotePropertyName $q.Name -NotePropertyValue (Packe $q.Value "Knoten '$key', Parameter $($q.Name)") }
          catch { $f.Add("$($_.Exception.Message)") }
        }
      }
    }
    $node = [ordered]@{ id = $id; offset = [pscustomobject][ordered]@{ x = $(if ($null -ne $k.x) { $k.x } else { 0 }); y = $(if ($null -ne $k.y) { $k.y } else { 0 }) }
      module_id = $e.modulId; processor_id = $e.id; description = "$($k.beschreibung)"; parameters = $par }
    if ($k.PSObject.Properties["felder"]) {
      if ($null -eq $k.felder) { $node.fields = $null }
      else {
        $fl = @(L $k.felder)
        if (@($fl | Where-Object { $_ -isnot [string] }).Count) { $f.Add("Knoten '$key': felder ist eine Liste von Feldnamen (Text).") }
        $node.fields = $fl
      }
    } elseif ($e.name -eq "InputForm") {
      $cfg = if ($k.parameter -is [System.Management.Automation.PSCustomObject]) { $k.parameter."Module.Core.InputForm.Config" } else { $null }
      if ($cfg -is [string]) { $cfg = Entpacke $cfg }
      $namen = @(foreach ($x in @(L $cfg.index_fields)) { if ($x.type -ne 19) { "$($x.name)" } })
      $w.Add("Knoten '$key' (Eingabeformular) ohne felder: Folgeknoten kennen die Formularfelder dann erst, wenn der Knoten im Designer einmal gespeichert wurde. Ueblich: felder und parameter.project.useditems = $(JStr $namen).")
    }
    $node.has_config_errors = [bool] $k.konfigFehler
    $nodes.Add([pscustomobject]$node)
    $byKey[$key] = @{ e = $e; id = $id; k = $k }
  }
  if ($starts -ne 1) { $f.Add("Genau ein Startknoten (baustein Start) noetig, gefunden: $starts.") }

  $conns = [System.Collections.Generic.List[object]]::new(); $belegt = @{}; $succ = @{}
  foreach ($key in @($byKey.Keys)) { $succ[$key] = [System.Collections.Generic.List[string]]::new() }
  foreach ($v in $vb) {
    $t = JStr $v
    if ($v -isnot [array] -or $v.Count -lt 3 -or $v.Count -gt 4) { $f.Add("Verbindung ${t}: erwartet [von, port, nach] oder [von, port, nach, kommentar]."); continue }
    $von = "$($v[0])"; $port = "$($v[1])"; $nach = "$($v[2])"
    if (-not $byKey.Contains($von)) { $f.Add("Verbindung ${t}: Knoten '$von' gibt es nicht."); continue }
    if (-not $byKey.Contains($nach)) { $f.Add("Verbindung ${t}: Knoten '$nach' gibt es nicht."); continue }
    $q = $byKey[$von].e; $z = $byKey[$nach].e
    if ($null -ne $q.aus -and $port -cnotin $q.aus) { $f.Add("Verbindung ${t}: $(BausteinText $q) hat keinen Ausgang '$port' (vorhanden: $(if (@($q.aus).Count) { $q.aus -join ', ' } else { 'keiner' })).") }
    if (@($z.ein).Count -eq 0) { $f.Add("Verbindung ${t}: $(BausteinText $z) hat keinen Eingang.") }
    $s = "$von|$port"
    if ($belegt.ContainsKey($s)) { $f.Add("Verbindung ${t}: Ausgang '$port' von '$von' fuehrt schon zu '$($belegt[$s])' - ein Ausgang hat genau ein Ziel."); continue }
    $belegt[$s] = $nach
    $qid = $byKey[$von].id; $zid = $byKey[$nach].id
    $conns.Add([pscustomobject][ordered]@{ source_node = $qid; source_port = "$qid.$port"; target_node = $zid
      target_port = "$zid.$(if (@($z.ein).Count) { @($z.ein)[0] } else { 'input' })"; comment = $(if ($v.Count -eq 4) { "$($v[3])" } else { "" }) })
    $succ[$von].Add($nach)
  }
  if ($f.Count -eq 0) {
    $seen = @{}; $todo = [System.Collections.Generic.Stack[string]]::new(); $todo.Push($startKey)
    while ($todo.Count) { $x = $todo.Pop(); if ($seen.ContainsKey($x)) { continue }; $seen[$x] = $true; foreach ($y in $succ[$x]) { $todo.Push($y) } }
    foreach ($key in @($byKey.Keys)) { if (-not $seen.ContainsKey($key)) { $f.Add("Knoten '$key' ($(BausteinText $byKey[$key].e)) ist vom Start aus nicht erreichbar.") } }
    $offen = @(foreach ($key in @($byKey.Keys)) { foreach ($port in @(L $byKey[$key].e.aus)) { if (-not $belegt.ContainsKey("$key|$port")) { "$key [$port]" } } })
    if ($offen.Count) { $w.Add("Ausgaenge ohne Verbindung (der Prozess endet dort): $($offen -join ', ').") }
  }
  $opt = $null
  if ($b.PSObject.Properties["optionen"] -and $null -ne $b.optionen) {
    if ($b.optionen -isnot [System.Management.Automation.PSCustomObject]) { $f.Add("optionen muss ein Objekt sein.") }
    else { $opt = [pscustomobject][ordered]@{}; foreach ($q in $b.optionen.PSObject.Properties) { try { $opt | Add-Member -NotePropertyName $q.Name -NotePropertyValue (Packe $q.Value "optionen/$($q.Name)") } catch { $f.Add("$($_.Exception.Message)") } } }
  }
  $idKey = @{}; foreach ($key in @($byKey.Keys)) { $idKey[$byKey[$key].id] = $key }
  @{ fehler = $f.ToArray(); warn = $w.ToArray(); nodes = $nodes.ToArray(); connectors = $conns.ToArray(); optionen = $opt; byKey = $byKey; idKey = $idKey }
}

# ---------- Vergleich ----------

function VerbSchluessel($c) { "$($c.source_port)>$($c.target_port)|$($c.comment)" }

# Inhaltlicher Unterschied zweier Prozessdefinitionen: Knoten je ID, Verbindungen als Menge.
function DefUnterschiede($a, $b) {
  $r = @{ entfernt = [System.Collections.Generic.List[string]]::new(); neu = [System.Collections.Generic.List[string]]::new(); geaendert = [ordered]@{}
    verbEntfernt = [System.Collections.Generic.List[object]]::new(); verbNeu = [System.Collections.Generic.List[object]]::new() }
  $na = [ordered]@{}; foreach ($n in @(L $a.nodes)) { $na["$($n.id)"] = $n }
  $nb = [ordered]@{}; foreach ($n in @(L $b.nodes)) { $nb["$($n.id)"] = $n }
  foreach ($id in @($na.Keys)) { if (-not $nb.Contains($id)) { $r.entfernt.Add($id) } }
  foreach ($id in @($nb.Keys)) {
    if (-not $na.Contains($id)) { $r.neu.Add($id); continue }
    $x = $na[$id]; $y = $nb[$id]; $was = [System.Collections.Generic.List[string]]::new()
    if ("$($x.processor_id)" -cne "$($y.processor_id)" -or "$($x.module_id)" -cne "$($y.module_id)") { $was.Add("baustein") }
    if ("$($x.description)" -cne "$($y.description)") { $was.Add("beschreibung") }
    if ("$($x.offset.x)|$($x.offset.y)" -cne "$($y.offset.x)|$($y.offset.y)") { $was.Add("position") }
    if ((JStr $x.fields) -cne (JStr $y.fields)) { $was.Add("felder") }
    if ([bool] $x.has_config_errors -ne [bool] $y.has_config_errors) { $was.Add("konfigFehler") }
    $px = $x.parameters; $py = $y.parameters
    if (($null -eq $px) -ne ($null -eq $py)) { $was.Add("parameter (null)") }
    elseif ($null -ne $px) {
      $kx = @(foreach ($q in $px.PSObject.Properties) { $q.Name }); $ky = @(foreach ($q in $py.PSObject.Properties) { $q.Name })
      foreach ($q in $kx) { if ($q -cnotin $ky) { $was.Add("parameter/$q entfernt") } elseif (-not (WertGleich $px.$q $py.$q)) { $was.Add("parameter/$q") } }
      foreach ($q in $ky) { if ($q -cnotin $kx) { $was.Add("parameter/$q neu") } }
    }
    if ($was.Count) { $r.geaendert[$id] = $was.ToArray() }
  }
  $ca = @(foreach ($c in @(L $a.connectors)) { VerbSchluessel $c }); $cb = @(foreach ($c in @(L $b.connectors)) { VerbSchluessel $c })
  foreach ($c in @(L $a.connectors)) { if ((VerbSchluessel $c) -cnotin $cb) { $r.verbEntfernt.Add($c) } }
  foreach ($c in @(L $b.connectors)) { if ((VerbSchluessel $c) -cnotin $ca) { $r.verbNeu.Add($c) } }
  $r
}

function UnterschiedeZahl($r) { $r.entfernt.Count + $r.neu.Count + $r.geaendert.Count + $r.verbEntfernt.Count + $r.verbNeu.Count }

# Unterschiede lesbar, mit den keys des Bauplans; $keys: Knoten-ID -> key, $art: Knoten-ID -> Bausteinname.
function UnterschiedeText($r, $keys, $namen) {
  $kn = { param($id) $(if ($keys.ContainsKey($id)) { $keys[$id] } else { $id.Substring(0, [Math]::Min(8, $id.Length)) }) + $(if ($namen.ContainsKey($id)) { " ($($namen[$id]))" } else { "" }) }
  $vt = { param($c) $p = "$($c.source_port)"; $p = $p.Substring($p.IndexOf(".") + 1)
    "$(& $kn "$($c.source_node)") [$p] -> $(& $kn "$($c.target_node)")" + $(if ("$($c.comment)") { " ($($c.comment))" } else { "" }) }
  $o = [ordered]@{}
  if ($r.neu.Count) { $o.neueKnoten = @(foreach ($id in $r.neu) { & $kn $id }) }
  if ($r.entfernt.Count) { $o.entfernteKnoten = @(foreach ($id in $r.entfernt) { & $kn $id }) }
  if ($r.geaendert.Count) { $o.geaenderteKnoten = @(foreach ($id in @($r.geaendert.Keys)) { "$(& $kn $id): $($r.geaendert[$id] -join ', ')" }) }
  if ($r.verbNeu.Count) { $o.neueVerbindungen = @(foreach ($c in $r.verbNeu) { & $vt $c }) }
  if ($r.verbEntfernt.Count) { $o.entfernteVerbindungen = @(foreach ($c in $r.verbEntfernt) { & $vt $c }) }
  $o
}

function BausteinNamen($nodes) {
  $h = @{}; $kat = Katalog
  foreach ($n in @(L $nodes)) { $h["$($n.id)"] = $(if ("$($n.processor_id)" -eq $NULL_GUID) { "Start" } elseif ($kat.nachId.ContainsKey("$($n.processor_id)")) { BausteinText $kat.nachId["$($n.processor_id)"] } else { "?" }) }
  $h
}

# Kontrolle nach dem Speichern: gespeicherter Prozess gegen die gesendete Definition.
function ProzessKontrolle($soll, $ist, $keys) {
  $ab = [System.Collections.Generic.List[string]]::new()
  foreach ($f in "name", "folder", "type") { if ("$($soll.$f)" -cne "$($ist.$f)") { $ab.Add("$f ist '$($ist.$f)' statt '$($soll.$f)'") } }
  if ($null -ne $soll.options -and $null -ne $ist.options) {
    foreach ($q in $soll.options.PSObject.Properties) { if (-not (WertGleich $q.Value $ist.options.($q.Name))) { $ab.Add("optionen/$($q.Name) weicht ab") } }
  }
  $r = DefUnterschiede $soll $ist
  if (UnterschiedeZahl $r) { $t = UnterschiedeText $r $keys (BausteinNamen $ist.nodes); foreach ($k in @($t.Keys)) { $ab.Add("${k}: $($t[$k] -join '; ')") } }
  if ($ab.Count) { $ab.ToArray() } else { "Prozess wie Bauplan (Knoten, Parameter, Verbindungen)" }
}

# Nach PUT ist ein neues Geschaeftsobjekt noch ausgecheckt (_locked, Version 1.0); der Designer schreibt es erst mit
# commit fest. Liefert den Baustein danach und was passiert ist.
function NeuFestschreiben([string] $b, [string] $id) {
  $o = JObj (Blp-Get (P "$b/$id"))
  if (-not $o._locked) { return @{ obj = $o; text = "nicht ausgecheckt" } }
  try { $null = Blp-Send "POST" (P "$b/$id/commit") (JStr @{ _read_token = $o._read_token }); $t = "commit ok" }
  catch { $t = "commit fehlgeschlagen: $($_.Exception.Message) - noch ausgecheckt, im Designer speichern oder verwerfen" }
  @{ obj = (JObj (Blp-Get (P "$b/$id"))); text = $t }
}

# ---------- Bauplan lesen und schreiben ----------

# Bauplan als Hashtable -> Objekt. Parameterwerte (und optionen) werden vorher wieder zu Text gepackt, damit Schluessel
# wie "type"/"Type" im eingebetteten JSON erhalten bleiben.
function PlanAusRoh($h) {
  # Antwort von blp_process_export als Ganzes ({bauplan: {...}}) auch annehmen
  if ($h -is [System.Collections.IDictionary] -and $h.Contains("bauplan") -and -not $h.Contains("knoten")) { $h = $h["bauplan"] }
  if ($h -isnot [System.Collections.IDictionary]) { throw "Der Bauplan muss ein Objekt sein: {name, ordner, knoten, verbindungen}." }
  $packen = { param($d) foreach ($n in @($d.Keys)) { $v = $d[$n]; if ($v -is [System.Collections.IDictionary] -or $v -is [System.Collections.IList]) { $d[$n] = JStr $v } } }
  foreach ($k in @(L $h["knoten"])) { if ($k -is [System.Collections.IDictionary] -and $k["parameter"] -is [System.Collections.IDictionary]) { & $packen $k["parameter"] } }
  if ($h["optionen"] -is [System.Collections.IDictionary]) { & $packen $h["optionen"] }
  try { JObj (JStr $h) } catch { throw "Bauplan nicht lesbar: $($_.Exception.Message)" }
}

function BauplanLesen($a) {
  if ($a.datei -and $a.bauplan) { throw "Entweder bauplan oder datei angeben, nicht beides." }
  if ($a.datei) {
    $pfad = "$($a.datei)"
    if (-not [IO.Path]::IsPathRooted($pfad)) { throw "datei braucht einen vollen Pfad." }
    if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) { throw "Bauplan-Datei nicht gefunden: $pfad" }
    try { $h = HObj ([IO.File]::ReadAllText($pfad, [Text.Encoding]::UTF8)) } catch { throw "Bauplan-Datei ist kein gueltiges JSON: $($_.Exception.Message)" }
  } elseif ($a.bauplan) {
    $h = if ($a.bauplan -is [string]) { HObj $a.bauplan } else { HObj (JStr $a.bauplan) }   # Kopie, der Aufruf bleibt unveraendert
  } else { throw "bauplan oder datei fehlt." }
  # Rohes Prozess-JSON (z. B. eine Sicherung vor blp_change/blp_process_build) wird erst zum Bauplan
  if ($h -is [System.Collections.IDictionary] -and $h.Contains("nodes") -and $h.Contains("connectors") -and -not $h.Contains("knoten")) {
    $p = JObj (JStr $h)
    $r = PlanAusProzess $p $null "" "$($p.folder)"
    # volle IDs mitgeben, damit das Zurueckspielen die Knoten-IDs der Sicherung wiederherstellt
    $idVon = @{}; foreach ($id in @($r.keys.Keys)) { $idVon[$r.keys[$id]] = $id }
    foreach ($k in $r.plan.knoten) { if ($k.key -ne "start") { $k.id = $idVon[$k.key] } }
    $h = HObj (JStr $r.plan)
  }
  PlanAusRoh $h
}

function BauplanSchreiben($plan, [string] $datei, [string] $name) {
  $pfad = $datei
  if (-not $pfad) { $pfad = Join-Path $BAUPLAN_ORDNER (($name -replace '[^\w\-. ]', '_') + "-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".json") }
  if (-not [IO.Path]::IsPathRooted($pfad)) { throw "datei braucht einen vollen Pfad." }
  if ([IO.Path]::GetExtension($pfad) -ne ".json") { throw "datei muss auf .json enden." }
  New-Item -ItemType Directory -Force (Split-Path -Parent $pfad) | Out-Null
  [IO.File]::WriteAllText($pfad, (ConvertTo-Json -InputObject $plan -Depth 100), [Text.UTF8Encoding]::new($false))
  $pfad
}

function PlanHash($b) {
  $h = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((JStr $b)))
  (($h | Select-Object -First 8 | ForEach-Object { $_.ToString("x2") }) -join "")
}

# ---------- Werkzeuge ----------

Werkzeug "blp_process_export" ("Liest einen BLP-Prozess als Bauplan (JSON) fuer blp_process_build: name, ordner, art, optionen, knoten [{key, baustein, beschreibung, x, y, parameter (eingebettetes JSON entpackt), felder}], " +
  "verbindungen [[von, port, nach(, kommentar)]]. Grosse Bauplaene (und solche mit maskierten Werten) kommen als Datei, kleine auch direkt in der Antwort. " +
  "Ohne prozess: Liste der Bausteine (Prozessoren aller Module) mit ihren Ausgaengen, optional gefiltert.") @{
  prozess = @{ type = "string"; description = "Prozess-ID oder Name; leer = Bausteinliste" }
  datei = @{ type = "string"; description = "Optional: voller Pfad (.json), in den der Bauplan geschrieben wird; Standard bei grossen Bauplaenen: Datenordner\bauplan" }
  filter = @{ type = "string"; description = "Nur fuer die Bausteinliste: Namensteil" } } @() {
  param($a)
  if (-not $a.prozess) {
    $l = @((Katalog).liste)
    if ($a.filter) { $m = "*$([WildcardPattern]::Escape("$($a.filter)"))*"; $l = @($l | Where-Object { $_.anzeige -like $m -or $_.name -like $m -or $_.modul -like $m }) }
    return [ordered]@{ anzahl = $l.Count + $(if ($a.filter) { 0 } else { 1 }); hinweis = "baustein im Bauplan = Name aus dieser Liste; Ausgang = port der Verbindung. Eingang ist immer input."
      bausteine = @(@(if (-not $a.filter) { [ordered]@{ baustein = "Start"; modul = ""; ausgaenge = "START" } }) + @($l | Sort-Object modul, anzeige | ForEach-Object {
        [ordered]@{ baustein = (BausteinText $_); modul = $_.modul; ausgaenge = $(if ($_.aus.Count) { $_.aus -join ", " } else { "(keiner - Prozess endet)" }) } })) }
  }
  $e = Finde (Prozessliste) $a.prozess "Prozess"
  $p = JObj (Blp-Get (P "processengine/$($e.id)"))
  $r = PlanAusProzess $p $null $e.art $e.ordner
  $plan = $r.plan; $warn = [System.Collections.Generic.List[string]]::new(); foreach ($x in $r.warnungen) { $warn.Add($x) }
  # Selbstkontrolle: Bauplan wieder uebersetzen (IDs wie im Original) und mit dem Original vergleichen
  $u = PlanUebersetzen (PlanAusRoh (HObj (JStr $plan))) $p.nodes $e.id
  if ($u.fehler.Count) { $warn.Add("blp_process_build wuerde diesen Bauplan so ablehnen: " + ($u.fehler -join " | ")) }
  else {
    $nach = [pscustomobject]@{ nodes = $u.nodes; connectors = $u.connectors }
    $d = DefUnterschiede $p $nach
    if (UnterschiedeZahl $d) { $t = UnterschiedeText $d $r.keys (BausteinNamen $p.nodes); $warn.Add("Der Bauplan gibt den Prozess nicht ganz wieder: " + (@(foreach ($k in @($t.Keys)) { "${k}: $($t[$k] -join '; ')" }) -join " | ")) }
  }
  foreach ($x in $u.warn) { if ($x -notlike "Ausgaenge ohne Verbindung*") { $warn.Add($x) } }
  $text = JStr $plan
  $maskiert = (Maskiere $text) -cne $text
  if ($maskiert) { $warn.Add("Die Antwort blendet Werte mit pass/pwd/secret/token/credential im Namen aus (***). Zum Bauen die Datei nehmen, nicht den Bauplan aus der Antwort.") }
  $o = [ordered]@{ prozess = $e.name; id = $e.id; version = $p._version; art = $e.art; ordner = $e.ordner; knoten = @($plan.knoten).Count; verbindungen = @($plan.verbindungen).Count
    warnungen = $warn.ToArray() }
  # Direkt in der Antwort nur, wenn er auch eingerueckt sicher unter die Antwortgrenze passt
  $inline = $text.Length -le $BAUPLAN_INLINE
  if ($inline) { $o.bauplan = $plan; if ((ConvertTo-Json -InputObject $o -Depth 60).Length -gt $MAX_TEXT - 2000) { $o.Remove("bauplan"); $inline = $false } }
  if ($a.datei -or -not $inline -or $maskiert) {
    $o.datei = BauplanSchreiben $plan "$($a.datei)" $e.name
    $o.hinweis = "Bauplan in der Datei; zum Bauen blp_process_build mit datei = dieser Pfad (als Kopie mit name = neuer Name)."
  }
  if (-not $inline) { $o.bauplanInAntwort = "zu gross ($($text.Length) Zeichen) - siehe datei" }
  $o
}

Werkzeug "blp_process_build" ("Baut einen BLP-Prozess aus einem Bauplan (Format von blp_process_export), zweistufig. Ohne prozess: neu anlegen (PUT processengine) im Ordner aus dem Bauplan, " +
  "mit name als Kopie unter neuem Namen. Mit prozess: vorhandenen Prozess ersetzen (Knoten, Verbindungen, Optionen; Name und Ordner bleiben; Sicherung, checkout, speichern, commit). " +
  "Prueft: genau ein Start, Bausteine und Ausgaenge gibt es, ein Ausgang hat genau ein Ziel, alle Knoten vom Start erreichbar, Parameter als Text, keine null in Listen. " +
  "Nach dem Speichern Kontrolle gegen den Bauplan. Nur in Umgebungen mit allowChanges.") @{
  bauplan = @{ type = "object"; description = "Bauplan {name, ordner, knoten, verbindungen, optionen} wie aus blp_process_export" }
  datei = @{ type = "string"; description = "Statt bauplan: voller Pfad einer Bauplan-Datei (.json) aus blp_process_export, oder eine Sicherung (rohes Prozess-JSON) zum Zurueckspielen" }
  name = @{ type = "string"; description = "Optional beim Neuanlegen: anderer Name als im Bauplan (Kopie)" }
  prozess = @{ type = "string"; description = "Optional: vorhandenen Prozess (ID oder Name) ersetzen; der Name im Bauplan muss gleich sein" }
  freigabe = @{ type = "string"; description = "Leer fuer die Vorschau; zum Ausfuehren der Freigabe-Code aus der Vorschau" } } @() {
  param($a)
  ZweiSchritte "blp_process_build" $a {
    $b = BauplanLesen $a
    $hash = PlanHash $b
    if ($a.prozess -and $a.name) { throw "name gilt nur beim Neuanlegen; beim Ersetzen bleibt der Name." }
    if ($a.name) { $b.name = "$($a.name)".Trim() }
    $name = "$($b.name)".Trim()
    $warn = [System.Collections.Generic.List[string]]::new()
    if ($a.prozess) {
      $q = Finde (Prozessliste) "$($a.prozess)" "Prozess"
      $roh = Blp-Get (P "processengine/$($q.id)"); $ist = JObj $roh
      if ($name -cne "$($ist.name)") { throw "Prozess $($q.id) heisst '$($ist.name)', der Bauplan '$name'. Umbenennen geht hier nicht (blp_change, pfad name)." }
      if ("$($b.art)" -and "$($b.art)" -ne $q.art) { throw "Der Bauplan ist fuer einen $($b.art)-Prozess, '$($q.name)' ist $($q.art)." }
      if ("$($b.ordner)") { $o = ProzessOrdnerFinden "$($b.ordner)" $q.art; if ($o.id -ne "$($ist.folder)") { throw "Der Bauplan nennt Ordner '$($o.name)', der Prozess liegt in '$($q.ordner)'. Verschieben geht hier nicht." } }
      $u = PlanUebersetzen $b $ist.nodes "neu|$name"   # gleiche feste IDs wie beim Anlegen aus demselben Bauplan
      if ($u.fehler.Count) { throw ("Bauplan fehlerhaft:`n- " + ($u.fehler -join "`n- ") + $(if ($u.warn.Count) { "`nHinweise:`n- " + ($u.warn -join "`n- ") } else { "" })) }
      $neu = Kopie $ist; $neu.nodes = $u.nodes; $neu.connectors = $u.connectors
      $aend = @(@{ pfad = "nodes"; wert = $u.nodes }, @{ pfad = "connectors"; wert = $u.connectors })
      if ($null -ne $u.optionen) { $neu.options = $u.optionen; $aend += @{ pfad = "options"; wert = $u.optionen } }
      if ($b.PSObject.Properties["childs"]) { $neu.childs = $b.childs; $aend += @{ pfad = "childs"; wert = $b.childs } }
      $fehler = @(L (Pruefe $neu "processengine")); if ($fehler.Count) { throw ("Prozess waere ungueltig:`n- " + ($fehler -join "`n- ")) }
      $d = DefUnterschiede $ist $neu
      $keys = @{}; $alt = KeysVergeben $ist.nodes; foreach ($id in @($alt.Keys)) { $keys[$id] = $alt[$id] }; foreach ($id in @($u.idKey.Keys)) { $keys[$id] = $u.idKey[$id] }
      $namen = BausteinNamen (@(L $ist.nodes) + @(L $neu.nodes))
      $optGleich = ($null -eq $u.optionen) -or (JStr (Norm $ist.options)) -ceq (JStr (Norm $u.optionen))
      if (-not (UnterschiedeZahl $d) -and $optGleich -and -not $b.PSObject.Properties["childs"]) { throw "Keine Aenderung - der Prozess entspricht schon dem Bauplan." }
      $vorschau = [ordered]@{ aktion = "Prozess ersetzen"; prozess = "$($ist.name) [$($q.id)] v$($ist._version)"; ordner = "$($q.ordner) ($($q.art))"; umgebung = $UMGEBUNG
        aenderungen = (UnterschiedeText $d $keys $namen) }
      if (-not $optGleich) { $vorschau.aenderungen.optionen = "geaendert" }
      foreach ($x in $u.warn) { $warn.Add($x) }
      $warn.Add("Sicherung des bisherigen Prozesses vor dem Speichern; zurueck mit blp_process_build, prozess wie hier und der Sicherungsdatei als datei.")
      $fp = "$($q.id)|$($ist._version)|$($ist._last_modified_date)|$hash"
      $plan = @{ id = $q.id; roh = $roh; aend = $aend; def = $neu; keys = $u.idKey; name = $name }
    } else {
      if (-not $name) { throw "name fehlt." }
      if (@(L (Prozessliste) | Where-Object { $_.name -eq $name }).Count) { throw "Es gibt schon einen Prozess '$name'. Zum Ersetzen prozess angeben, fuer eine Kopie name." }
      if (-not "$($b.ordner)") { throw "ordner fehlt (Prozessordner, Name oder ID)." }
      $o = ProzessOrdnerFinden "$($b.ordner)" "$($b.art)"
      if ($null -eq $o.type) { throw "Ordner '$($o.name)' ($($o.art)) hat keinen Prozesstyp - dort kann der MCP nicht anlegen." }
      $u = PlanUebersetzen $b $null "neu|$name"
      if ($u.fehler.Count) { throw ("Bauplan fehlerhaft:`n- " + ($u.fehler -join "`n- ") + $(if ($u.warn.Count) { "`nHinweise:`n- " + ($u.warn -join "`n- ") } else { "" })) }
      $opt = if ($null -ne $u.optionen) { $u.optionen } else { [pscustomobject]@{ viewport = '{"x":0,"y":0,"zoom":1}' } }
      $def = [pscustomobject][ordered]@{ internal_id = $NULL_GUID; type = $o.type; name = $name; folder = $o.id
        nodes = $u.nodes; connectors = $u.connectors; childs = $(if ($b.PSObject.Properties["childs"]) { $b.childs } else { $null }); options = $opt }
      $fehler = @(L (Pruefe $def "processengine")); if ($fehler.Count) { throw ("Prozess waere ungueltig:`n- " + ($fehler -join "`n- ")) }
      $vorschau = [ordered]@{ aktion = "Prozess anlegen"; name = $name; ordner = "$($o.name) [$($o.id)] ($($o.art))"; umgebung = $UMGEBUNG }
      foreach ($x in $u.warn) { $warn.Add($x) }
      $warn.Add("Neue Prozesse erscheinen im Designer im Ordner '$($o.name)'; eine Kachel dazu mit blp_add_tile.")
      $fp = "neu|$name|$hash"
      $plan = @{ def = $def; keys = $u.idKey; name = $name }
    }
    $vorschau.knoten = @(foreach ($key in @($u.byKey.Keys)) {
      $z = $u.byKey[$key]; $kern = KnotenKern $z.k.parameter
      "${key}: $(BausteinText $z.e)" + $(if ("$($z.k.beschreibung)") { " - $($z.k.beschreibung)" } else { "" }) + $(if ($kern) { " - $kern" } else { "" }) })
    $vorschau.verbindungen = @(foreach ($v in @(L $b.verbindungen)) { "$($v[0]) [$($v[1])] -> $($v[2])" + $(if ($v.Count -eq 4 -and "$($v[3])") { " ($($v[3]))" } else { "" }) })
    $warn.Add("Wirksam erst nach Veroeffentlichen im Designer.")
    $plan.vorschau = $vorschau; $plan.warnungen = $warn.ToArray(); $plan.fp = $fp
    $plan
  } {
    param($plan)
    if ($plan.id) {
      $r = AenderungAusfuehren "processengine" $plan $plan.aend
      $script:Prozessliste = $null
      $r.kontrolle = ProzessKontrolle $plan.def $r.nachher $plan.keys
      $r.Remove("nachher")
      $r.knoten = @($plan.def.nodes).Count; $r.verbindungen = @($plan.def.connectors).Count
      return $r
    }
    $antwort = Blp-Send "PUT" (P "processengine") (JStr $plan.def)
    $script:Prozessliste = $null
    $p = @(L (Prozessliste) | Where-Object { $_.name -ceq $plan.name })
    if ($p.Count -ne 1) { throw "Anlage unklar: $($p.Count) Prozesse '$($plan.name)' gefunden. Antwort: $(Kurz $antwort 300)" }
    $fest = NeuFestschreiben "processengine" $p[0].id
    $chkText = Blp-Get (P "processengine/$($p[0].id)"); $chk = JObj $chkText
    New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
    $sich = Join-Path $SICHERUNG ("processengine-{0}-{1}-angelegt.json" -f $p[0].id, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    [IO.File]::WriteAllText($sich, $chkText, [Text.UTF8Encoding]::new($false))
    [ordered]@{ id = $p[0].id; name = $chk.name; version = $chk._version; ordner = $p[0].ordner; knoten = @(L $chk.nodes).Count; verbindungen = @(L $chk.connectors).Count
      kontrolle = (ProzessKontrolle $plan.def $chk $plan.keys); festgeschrieben = $fest.text; gespeichert = $sich
      danach = "Im Designer oeffnen, pruefen und veroeffentlichen. Kachel mit blp_add_tile." }
  }
} -Schreibt

# ---------- Geschaeftsobjekt anlegen ----------

$OBJEKT_META = @("_id", "_project", "_version", "_major_version", "_minor_version", "_read_token", "_author", "_create_date", "_last_author", "_last_modified_date", "links", "internal_id")

function Setz($o, [string] $n, $v) { if ($o.PSObject.Properties[$n]) { $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v } }

function ObjektFelder($felder) {
  $out = [System.Collections.Generic.List[object]]::new(); $i = 0; $namen = @{}
  foreach ($x in @(L $felder)) {
    $f = JObj (JStr $x)
    $n = "$($f.name)".Trim(); if (-not $n) { throw "Feld ohne name." }
    if ($namen.ContainsKey($n)) { throw "Feld '$n' doppelt." }; $namen[$n] = $true
    $e = [ordered]@{ inherited_from = "000000000000000000000000"; name = $n; display_text = $(if ("$($f.anzeige)") { "$($f.anzeige)" } else { $n })
      language_code = (Sprachcode "FIELD_" $n); data_type = $(if ($null -ne $f.typ) { [int] $f.typ } else { 0 }) }
    if ($f.schluessel) { $e.primary_key = $true }
    $e.position = ++$i
    $out.Add([pscustomobject]$e)
  }
  ,$out.ToArray()
}

Werkzeug "blp_create_object" ("Legt ein neues Geschaeftsobjekt an (zweistufig; PUT objectmanager). Leer mit felder oder als Kopie einer vorlage (Felder, Fuellregeln, Suche, Bilder; " +
  "ohne Kacheln - die mit blp_add_tile). Optional Pfad-Aenderungen am neuen Objekt (Pfadsprache wie blp_change). Nur in Umgebungen mit allowChanges.") @{
  name = @{ type = "string" }; anzeige = @{ type = "string"; description = "Anzeigetext, Standard = name" }
  infotext = @{ type = "string" }
  vorlage = @{ type = "string"; description = "Optional: Objekt (ID oder Name), dessen Felder, Fuellregeln und Suche kopiert werden" }
  felder = @{ type = "array"; description = "Optional: Felder [{name, anzeige, typ (data_type, 0 = Text), schluessel (primary_key)}]; ersetzt die Felder der Vorlage"; items = @{ type = "object" } }
  aenderungen = @{ type = "array"; description = "Optional: {pfad, wert, aktion} am neuen Objekt"; items = @{ type = "object" } }
  freigabe = @{ type = "string" } } @("name") {
  param($a)
  ZweiSchritte "blp_create_object" $a {
    $name = "$($a.name)".Trim(); if (-not $name) { throw "name ist leer." }
    $liste = @(L (Lies "objectmanager").objects)
    if (@($liste | Where-Object { $_.name -eq $name }).Count) { throw "Es gibt schon ein Geschaeftsobjekt '$name'." }
    $vorlageText = ""; $fpVorlage = ""
    if ($a.vorlage) {
      $v = Finde $liste "$($a.vorlage)" "Objekt"
      $src = JObj (Blp-Get (P "objectmanager/$($v._id)"))
      $o = Kopie $src
      foreach ($m in $OBJEKT_META) { $o.PSObject.Properties.Remove($m) }
      Setz $o "tiles" @(); Setz $o "tiles_order" @(); Setz $o "tile_count" 0
      $vorlageText = "$($src.name) [$($src._id)] v$($src._version), $(@(L $src.tiles).Count) Kachel(n) nicht kopiert"
      $fpVorlage = "$($src._id)|$($src._version)"
    } else {
      $leer = [pscustomobject]@{ repository_id = ""; item_id = "" }
      $o = [pscustomobject][ordered]@{ name = $name; display_text = $name; language_code = ""; info_text = ""; language_code_info_text = ""
        multi_selection_title = ""; multi_selection_description = ""
        images = [pscustomobject][ordered]@{ image_small = $leer; image_medium = (Kopie $leer); image_large = (Kopie $leer) }
        fields = @(); tiles = @(); tiles_order = @(); field_count = 0; tile_count = 0; forms = $null }
    }
    $o.name = $name; Setz $o "display_text" $(if ($a.anzeige) { "$($a.anzeige)" } else { $name })
    Setz $o "language_code" (Sprachcode "OBJECT_" $name); Setz $o "language_code_info_text" (Sprachcode "OBJECT_INFO_" $name)
    if ($null -ne $a.infotext) { Setz $o "info_text" "$($a.infotext)" }
    if ($a.felder) { Setz $o "fields" (ObjektFelder $a.felder) }
    if (@(L $a.aenderungen).Count) { $o = Wende $o $a.aenderungen }
    Setz $o "field_count" (@(L $o.fields).Count)
    $fehler = @(L (Pruefe $o "objectmanager")); if ($fehler.Count) { throw ("Neues Objekt waere ungueltig:`n- " + ($fehler -join "`n- ")) }
    $warn = @()
    if (@(L $o.fields).Count -eq 0) { $warn += "Das Objekt hat keine Felder." }
    $rollen = @(L (Lies "role").roles | ForEach-Object { $_.name })
    $warn += "Der BLP traegt das neue Objekt beim Festschreiben in alle Rollen ein, eingeschlossen ($($rollen -join ', ')). Abwaehlen je Rolle: blp_change baustein=role, pfad situations/0/objects/[object_id=<neue ID>]/include, wert false. (Beim Loeschen eines Objekts entfernt der BLP diese Eintraege selbst - anders als bei Tabs.)"
    $warn += "Kacheln mit blp_add_tile; wirksam erst nach Veroeffentlichen im Designer."
    @{ vorschau = [ordered]@{ aktion = "Geschaeftsobjekt anlegen"; name = $name; anzeige = $o.display_text; infotext = $o.info_text; vorlage = $vorlageText; umgebung = $UMGEBUNG
         felder = @(foreach ($x in @(L $o.fields)) { "$($x.name)" + $(if ($x.display_text -cne $x.name) { " ($($x.display_text))" } else { "" }) + " Typ $($x.data_type)" + $(if ($x.primary_key) { ", Schluessel" } else { "" }) })
         fuellregeln = @(foreach ($x in @(L $o.filling_rules)) { "$($x.name) ($($x.data_query.config_id))" }); suche = [bool] $o.search }
       warnungen = $warn; fp = "neu|$name|$fpVorlage"; obj = $o; name = $name }
  } {
    param($plan)
    $antwort = Blp-Send "PUT" (P "objectmanager") (JStr $plan.obj)
    $l = @(L (Lies "objectmanager").objects | Where-Object { $_.name -ceq $plan.name })
    if ($l.Count -ne 1) { throw "Anlage unklar: $($l.Count) Objekte '$($plan.name)' gefunden. Antwort: $(Kurz $antwort 300)" }
    $fest = NeuFestschreiben "objectmanager" $l[0]._id; $chk = $fest.obj
    $ab = @()
    if ($chk._locked) { $ab += "Objekt ist noch ausgecheckt" }
    foreach ($f in "name", "display_text", "info_text") { if ("$($chk.$f)" -cne "$($plan.obj.$f)") { $ab += "$f ist '$($chk.$f)'" } }
    $sollF = (@(foreach ($x in @(L $plan.obj.fields)) { $x.name }) -join ", "); $istF = (@(foreach ($x in @(L $chk.fields)) { $x.name }) -join ", ")
    if ($sollF -cne $istF) { $ab += "Felder: $istF statt $sollF" }
    if (@(L $chk.filling_rules).Count -ne @(L $plan.obj.filling_rules).Count) { $ab += "Fuellregeln: $(@(L $chk.filling_rules).Count) statt $(@(L $plan.obj.filling_rules).Count)" }
    [ordered]@{ id = $chk._id; name = $chk.name; version = $chk._version; felder = $istF; festgeschrieben = $fest.text; kontrolle = $(if ($ab.Count) { $ab } else { "Objekt wie gewuenscht" })
      danach = "Kacheln mit blp_add_tile (ziel objekt); im Designer pruefen und veroeffentlichen." }
  }
} -Schreibt
