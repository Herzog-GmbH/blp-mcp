# blp-mcp-aendern.ps1 - Stufe 2 des BLP-MCP-Servers: Bausteine gezielt aendern.
# Wird von blp-mcp.ps1 per Dot-Sourcing eingebunden (nutzt Lies, Blp-Get, Finde, Prozessliste, L, Kurz, Werkzeug, Log).
#
# Aenderungen kommen als Liste von Pfad-Operationen, nicht als ganzer Baustein:
#   pfad  = Segmente mit "/" getrennt
#           Eigenschaft          nodes, parameters, Module.Elo.ActionNode.EloAs (Punkte gehoeren zum Namen)
#           Index                0, 1, ...
#           Auswahl              [id=...], [name=...], [tile_id^=f8d0]  (=  exakt, ^= beginnt mit; genau ein Treffer)
#           #                    in den eingebetteten JSON-String hinein (Parameterwerte sind JSON als Text)
#           -                    am Ende mit aktion "anhaengen": neues Listenelement
#   aktion = setzen (Standard) | anhaengen | entfernen | sortieren (Pfad zeigt auf eine Liste, wert = Feld, Standard display_text)
#
# Ablauf beim Ausfuehren: Sicherung (GET) -> checkout -> Aenderungen auf die Arbeitskopie -> Pruefen
# (keine null in Listen, Prozessparameter nur Text) -> Speichern (POST) -> commit -> Nachlesen.
# Bei Fehler nach dem checkout: undo. Veroeffentlichen macht ein Mensch im Designer, nicht der MCP.

# Freischaltung je Umgebung ("allowChanges" in der Konfiguration) oder per Schalter -AendernErlauben;
# bei mehreren Umgebungen setzt Setze-Umgebung den Wert vor jedem Aufruf neu.
$AENDERN_ERLAUBT = Erlaubt $K
$DATEN = if ($K) { $K.datenOrdner } else { Join-Path ([IO.Path]::GetTempPath()) "blp-mcp" }
$SICHERUNG = Join-Path $DATEN "sicherung"
$script:Pending = @{}
$TOKEN_SEK = 300

# Bausteine mit erprobtem checkout -> Speichern -> commit. Ein neuer Eintrag mit erprobt = $false
# bekommt in der Vorschau eine Warnung, bis der Weg einmal geprueft ist.
$BAUSTEINE = [ordered]@{
  "processengine"             = @{ erprobt = $true;  text = "Prozess" }
  "objectmanager"             = @{ erprobt = $true;  text = "Geschaeftsobjekt" }
  "client/sidebar/tab/action" = @{ erprobt = $true;  text = "Sidebar-Tab" }
  "smartsearch"               = @{ erprobt = $true;  text = "Smart-Search-Profil" }
  "role"                      = @{ erprobt = $true;  text = "Rolle" }
  # Einzelbaustein ohne ID: GET/POST client/selection, checkout/commit/undo darunter
  # (erprobt: anhaengen, include, sortieren, ganze childs-Liste zurueckschreiben).
  "client/selection"          = @{ erprobt = $true;  text = "Auswahlbaum (Client)"; einzel = $true }
}

# Adresse eines Bausteins relativ zum Projekt; Einzelbausteine (Auswahlbaum) haben keine ID.
function BausteinPfad([string] $b, [string] $id) { if ($id) { "$b/$id" } else { $b } }
function BausteinName($o, [string] $b) { if ($o.name) { $o.name } else { $BAUSTEINE[$b].text } }

function Blp-Send([string] $Method, [string] $Url, [string] $Json) {
  for ($versuch = 1; $versuch -le 2; $versuch++) {
    try {
      $h = Header; $h["Content-Type"] = "application/json; charset=utf-8"
      # Rumpf als String (ein byte[] kaeme als Zahlenfolge an)
      $r = Invoke-WebRequest -Uri $Url -Method $Method -Headers $h -Body $Json -UseBasicParsing @TLS
      return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
      $code = $null; try { $code = [int] $_.Exception.Response.StatusCode } catch {}
      if ($code -eq 401 -and $versuch -eq 1) { Log "401, melde neu an"; $script:Token = $null; continue }
      $detail = $_.ErrorDetails.Message
      throw ("$Method $Url -> " + $(if ($code) { "HTTP $code " } else { "" }) + $(if ($detail) { $detail.Substring(0, [Math]::Min(400, $detail.Length)) } else { $_.Exception.Message }))
    }
  }
}

# -NoEnumerate und Rueckgabe mit Komma: sonst wird ["x"] beim Parsen und bei der Rueckgabe zu "x" entrollt.
function JObj([string] $s) { return ,(ConvertFrom-Json -InputObject $s -Depth 100 -DateKind String -NoEnumerate) }
# Immer -InputObject: "$o | ConvertTo-Json" entrollt Listen, aus ["x"] wird "x".
function JStr($o) { ConvertTo-Json -InputObject $o -Depth 100 -Compress }
function Kopie($o) { if ($null -eq $o) { return $null }; JObj (JStr $o) }

function Protokoll($eintrag) {
  try {
    New-Item -ItemType Directory -Force $DATEN | Out-Null
    $eintrag.zeit = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"); $eintrag.umgebung = $UMGEBUNG; $eintrag.windowsBenutzer = $env:USERNAME
    $f = Join-Path $DATEN ("protokoll-" + (Get-Date).ToString("yyyy-MM") + ".jsonl")
    [IO.File]::AppendAllText($f, (Maskiere (JStr $eintrag)) + "`n", [Text.UTF8Encoding]::new($false))
  } catch { Log "Protokoll nicht geschrieben: $_" }
}

# ---------- Pfade ----------

function Segmente([string] $pfad) {
  $s = @($pfad.Trim().Trim('/') -split '/' | Where-Object { $_ -ne "" })
  if ($s.Count -eq 0) { throw "Leerer Pfad." }
  ,$s
}

function Waehle($arr, [string] $seg, [string] $wo) {
  if ($seg -match '^\d+$') {
    $i = [int] $seg
    if ($i -ge @(L $arr).Count) { throw "$wo/$seg : Index ausserhalb (Liste hat $(@(L $arr).Count) Eintraege)." }
    return $i
  }
  # [=wert] / [^=anfang]: Element einer Liste aus reinen Werten (z. B. tiles_order)
  if ($seg -match '^\[(\^?=)(.*)\]$') {
    $op = $Matches[1]; $wert = $Matches[2]; $treffer = @()
    for ($i = 0; $i -lt @(L $arr).Count; $i++) { $v = "$($arr[$i])"; if (($op -eq "=" -and $v -eq $wert) -or ($op -eq "^=" -and $v.StartsWith($wert))) { $treffer += $i } }
    if ($treffer.Count -ne 1) { throw "$wo/$seg : $($treffer.Count) Treffer statt genau einem." }
    return $treffer[0]
  }
  if ($seg -match '^\[([^=^\]]+)(\^?=)(.*)\]$') {
    $feld = $Matches[1]; $op = $Matches[2]; $wert = $Matches[3]; $treffer = @()
    for ($i = 0; $i -lt @(L $arr).Count; $i++) {
      $v = "$($arr[$i].$feld)"
      if (($op -eq "=" -and $v -eq $wert) -or ($op -eq "^=" -and $v.StartsWith($wert))) { $treffer += $i }
    }
    if ($treffer.Count -ne 1) { throw "$wo/$seg : $($treffer.Count) Treffer statt genau einem." }
    return $treffer[0]
  }
  throw "$wo/$seg : In einer Liste nur Index, [feld=wert] / [feld^=anfang] oder bei reinen Werten [=wert]."
}

# Liest den Wert am Pfad; $null mit gefunden=$false, wenn es ihn nicht gibt.
function Hole($wurzel, [string[]] $segs) {
  $n = $wurzel; $wo = ""
  foreach ($seg in $segs) {
    if ($seg -eq "#") {
      if ($n -isnot [string]) { return @{ gefunden = $false; grund = "$wo ist kein JSON-Text" } }
      $n = JObj $n; $wo += "/#"; continue
    }
    if ($n -is [array]) { try { $n = $n[(Waehle $n $seg $wo)] } catch { return @{ gefunden = $false; grund = "$_" } } }
    elseif ($null -ne $n -and $n.PSObject.Properties[$seg]) { $n = $n.$seg }
    else { return @{ gefunden = $false; grund = "$wo/$seg fehlt" } }
    $wo += "/$seg"
  }
  @{ gefunden = $true; wert = $n }
}

# Wendet eine Operation an und gibt den (neuen) Knoten zurueck. Listen sind in PowerShell fest -
# deshalb wird der Elternteil neu gesetzt. Rueckgabe von Listen immer mit Komma (sonst entrollt).
function Setze($n, [string[]] $segs, [int] $i, [string] $aktion, $wert, [string] $wo) {
  $seg = $segs[$i]; $letzter = ($i -eq $segs.Count - 1)
  if ($seg -eq "#") {
    if ($n -isnot [string]) { throw "$wo/# : kein eingebetteter JSON-Text." }
    if ($letzter) { if ($aktion -ne "setzen") { throw "$wo/# : am Ende nur setzen." }; return (JStr $wert) }
    $innen = JObj $n
    $neu = Setze $innen $segs ($i + 1) $aktion $wert "$wo/#"
    return (JStr $neu)
  }
  if ($n -is [array]) {
    $liste = [System.Collections.Generic.List[object]]::new(); foreach ($e in $n) { $liste.Add($e) }
    if ($letzter -and $aktion -eq "anhaengen") {
      if ($seg -ne "-") { throw "$wo/$seg : zum Anhaengen den Pfad mit /- beenden." }
      $liste.Add($wert); return ,($liste.ToArray())
    }
    $k = Waehle $n $seg $wo
    if ($letzter -and $aktion -eq "entfernen") { $liste.RemoveAt($k); return ,($liste.ToArray()) }
    if ($letzter) { $liste[$k] = $wert } else { $liste[$k] = Setze $n[$k] $segs ($i + 1) $aktion $wert "$wo/$seg" }
    return ,($liste.ToArray())
  }
  if ($null -eq $n -or $n -isnot [System.Management.Automation.PSCustomObject]) { throw "$wo/$seg : '$wo' ist kein Objekt." }
  $da = $null -ne $n.PSObject.Properties[$seg]
  if ($letzter) {
    switch ($aktion) {
      "entfernen" { if (-not $da) { throw "$wo/$seg : gibt es nicht." }; $n.PSObject.Properties.Remove($seg) }
      "anhaengen" { throw "$wo/$seg : anhaengen nur an Listen (Pfad mit /- beenden)." }
      default { if ($da) { $n.$seg = $wert } else { $n | Add-Member -NotePropertyName $seg -NotePropertyValue $wert } }
    }
    return $n
  }
  # Anhaengen an eine fehlende oder leere Liste: der Dienst laesst leere Listen weg (z. B. tiles bei einem neuen Tab).
  if (($i + 2 -eq $segs.Count) -and $segs[$i + 1] -eq "-" -and $aktion -eq "anhaengen" -and (-not $da -or $null -eq $n.$seg)) {
    if ($da) { $n.$seg = @($wert) } else { $n | Add-Member -NotePropertyName $seg -NotePropertyValue @($wert) }
    return $n
  }
  if (-not $da) { throw "$wo/$seg : gibt es nicht." }
  $kind = Setze $n.$seg $segs ($i + 1) $aktion $wert "$wo/$seg"
  $n.$seg = $kind
  return $n
}

function LeerWert($v) { $null -eq $v -or ($v -is [bool] -and -not $v) -or (($v -is [array] -or $v -is [System.Collections.IList]) -and $v.Count -eq 0) }
function SortierFeld($c) { if ($c.Contains("wert") -and "$($c.wert)") { "$($c.wert)" } else { "display_text" } }

function Wende($obj, $aenderungen) {
  foreach ($c in @(L $aenderungen)) {
    $aktion = if ($c.aktion) { "$($c.aktion)" } else { "setzen" }
    if ($aktion -notin "setzen", "anhaengen", "entfernen", "sortieren") { throw "aktion '$aktion' unbekannt (setzen, anhaengen, entfernen, sortieren)." }
    if ($aktion -eq "sortieren") {
      # Liste am Pfad lesen, sortiert zuruecksetzen - so gilt fuer sortieren dieselbe Pruefung wie fuer setzen.
      $segs = Segmente "$($c.pfad)"; $h = Hole $obj $segs
      if (-not $h.gefunden) { throw "Pfad $($c.pfad): $($h.grund)" }
      if ($h.wert -isnot [array]) { throw "Pfad $($c.pfad): sortieren geht nur bei Listen (Pfad auf die Liste selbst, z. B. .../childs)." }
      $obj = Setze $obj $segs 0 "setzen" (SortiereListe $h.wert (SortierFeld $c)) ""
      continue
    }
    $wert = $null
    if ($aktion -ne "entfernen") {
      if (-not ($c.Contains("wert"))) { throw "Pfad $($c.pfad): wert fehlt." }
      $wert = if ($null -eq $c.wert) { $null } else { JObj (JStr $c.wert) }   # Hashtables aus dem Aufruf -> gleiche Objektart wie der Baustein
    }
    $obj = Setze $obj (Segmente "$($c.pfad)") 0 $aktion $wert ""
  }
  $obj
}

function Pruefe($obj, [string] $baustein) {
  $fehler = [System.Collections.Generic.List[string]]::new()
  function Suche($n, [string] $wo) {
    if ($n -is [array]) {
      for ($i = 0; $i -lt $n.Count; $i++) {
        if ($null -eq $n[$i]) { $fehler.Add("$wo/$i ist null - der Dienst bricht dann die Verbindung ab.") } else { Suche $n[$i] "$wo/$i" }
      }
    } elseif ($n -is [System.Management.Automation.PSCustomObject]) {
      foreach ($p in $n.PSObject.Properties) { Suche $p.Value "$wo/$($p.Name)" }
    }
  }
  Suche $obj ""
  if ($baustein -eq "processengine") {
    foreach ($nd in @(L $obj.nodes)) {
      foreach ($p in @(L $nd.parameters.PSObject.Properties)) {
        if ($p.Value -isnot [string]) { $fehler.Add("nodes/[id=$($nd.id)]/parameters/$($p.Name) muss Text sein (eingebettetes JSON mit /# aendern).") }
      }
    }
  }
  $fehler
}

function BausteinFinden([string] $baustein, [string] $wer) {
  if ($BAUSTEINE.Contains($baustein) -and $BAUSTEINE[$baustein].einzel) { return "" }   # Einzelbaustein, objekt entfaellt
  if (-not $wer) { throw "objekt fehlt (ID oder Name; nur beim Auswahlbaum client/selection entbehrlich)." }
  switch ($baustein) {
    "processengine" { $e = Finde (Prozessliste) $wer "Prozess"; return $e.id }
    "objectmanager" { return (Finde ((Lies "objectmanager").objects) $wer "Objekt")._id }
    "client/sidebar/tab/action" { return (Finde ((Lies "client/sidebar/tab/action").tabs) $wer "Tab")._id }
    "smartsearch" { $d = Lies "smartsearch"; $l = if ($d.lists) { $d.lists } else { $d }; return (Finde $l $wer "Suchprofil")._id }
    "role" { return (Finde ((Lies "role").roles) $wer "Rolle")._id }
  }
  throw "Baustein '$baustein' wird nicht unterstuetzt: $($BAUSTEINE.Keys -join ', ')."
}

function SortiertJson($o) {
  if ($o -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in ($o.Keys | Sort-Object)) { $h[$k] = SortiertJson $o[$k] }; return $h }
  if ($o -is [array]) { return ,@($o | ForEach-Object { SortiertJson $_ }) }
  $o
}

function ZweiSchritte([string] $name, $a, [scriptblock] $pruefen, [scriptblock] $ausfuehren) {
  if (-not $AENDERN_ERLAUBT) { throw "Aendern ist in der Umgebung $UMGEBUNG gesperrt (allowChanges in der Konfiguration$(if (-not $MEHRERE) { " oder Schalter -AendernErlauben" }), beim Paket fuer Claude Desktop der Schalter in den Einstellungen; das entscheidet ein Mensch)." }
  $ohne = [ordered]@{}; foreach ($p in $a.PSObject.Properties) { if ($p.Name -ne "freigabe") { $ohne[$p.Name] = $p.Value } }
  $key = JStr (SortiertJson $ohne)
  $plan = & $pruefen
  $jetzt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if (-not $a.freigabe) {
    foreach ($t in @($script:Pending.Keys)) { if ($script:Pending[$t].ablauf -lt $jetzt) { $script:Pending.Remove($t) } }
    $tok = ([guid]::NewGuid().ToString()).Substring(0, 13)
    $script:Pending[$tok] = @{ name = $name; key = $key; fp = $plan.fp; ablauf = $jetzt + $TOKEN_SEK; umgebung = $UMGEBUNG_NAME }
    # Feld heisst "freigabe", nicht "token": Maskiere blendet alles mit "token" im Namen aus.
    return [ordered]@{ modus = "Vorschau - noch nichts geaendert"; vorschau = $plan.vorschau; warnungen = @(L $plan.warnungen); freigabe = $tok
      naechsterSchritt = "Vorschau dem Anwender zeigen. Nach Zustimmung dasselbe Werkzeug mit denselben Argumenten und freigabe=`"$tok`" aufrufen. Gueltig 5 Minuten, einmal." }
  }
  $p = $script:Pending["$($a.freigabe)"]; $script:Pending.Remove("$($a.freigabe)")
  if (-not $p) { throw "freigabe unbekannt oder schon benutzt. Bitte neue Vorschau holen (Aufruf ohne freigabe)." }
  if ($p.ablauf -lt $jetzt) { throw "freigabe abgelaufen. Bitte neue Vorschau holen." }
  if ($p.umgebung -ne $UMGEBUNG_NAME) { throw "freigabe gehoert zur Umgebung $($p.umgebung), nicht zu $UMGEBUNG_NAME. Bitte neue Vorschau in der gewuenschten Umgebung holen." }
  if ($p.name -ne $name -or $p.key -ne $key) { throw "Argumente weichen von der Vorschau ab. Bitte neue Vorschau holen." }
  if ($p.fp -ne $plan.fp) { throw "Der Baustein (oder die Bauplan-Datei) hat sich seit der Vorschau geaendert. Bitte neue Vorschau holen." }
  try { $res = & $ausfuehren $plan }
  catch { Protokoll ([ordered]@{ werkzeug = $name; argumente = $ohne; fehler = "$($_.Exception.Message)" }); throw }
  Protokoll ([ordered]@{ werkzeug = $name; argumente = $ohne; ergebnis = $res })
  [ordered]@{ modus = "ausgefuehrt"; ergebnis = $res }
}

# ---------- Werkzeuge ----------

Werkzeug "blp_read_path" ("Liest den Wert an einem Pfad eines Bausteins (gleiche Pfadsprache wie blp_change), z. B. 'nodes/[id^=23d05bc3]/parameters/Module.Elo.ActionNode.EloAs/#/AsDefinitions/0' " +
  "oder beim Auswahlbaum (client/selection, ohne objekt) 'selections/[name=Einkauf]/childs/[name=Rechnung]'. Zum Vorbereiten von Aenderungen.") @{
  baustein = @{ type = "string"; enum = @($BAUSTEINE.Keys) }
  objekt = @{ type = "string"; description = "ID oder Name des Bausteins (Prozess, Objekt, Tab, Suchprofil, Rolle); entfaellt bei client/selection" }
  pfad = @{ type = "string" } } @("baustein", "pfad") {
  param($a)
  $id = BausteinFinden $a.baustein $a.objekt
  $o = JObj (Blp-Get (P (BausteinPfad $a.baustein $id)))
  $h = Hole $o (Segmente $a.pfad)
  if (-not $h.gefunden) { throw "Pfad nicht gefunden: $($h.grund)" }
  [ordered]@{ baustein = $a.baustein; id = $id; name = (BausteinName $o $a.baustein); version = $o._version; pfad = $a.pfad; wert = $h.wert }
}

# Plan und Ausfuehrung einer Pfad-Aenderung - gemeinsam fuer blp_change und blp_add_tile.
function AenderungPlan([string] $baustein, [string] $objekt, $aenderungen, [string] $aktionText) {
  if (-not $BAUSTEINE.Contains($baustein)) { throw "Baustein '$baustein' nicht freigegeben." }
  if (@(L $aenderungen).Count -eq 0) { throw "aenderungen ist leer." }
  $id = BausteinFinden $baustein $objekt
  $roh = Blp-Get (P (BausteinPfad $baustein $id)); $ist = JObj $roh
  $neu = Wende (Kopie $ist) $aenderungen
  $fehler = @(L (Pruefe $neu $baustein))
  if ($fehler.Count) { throw ("Aenderung ergaebe einen ungueltigen Baustein:`n- " + ($fehler -join "`n- ")) }
  $zeilen = foreach ($c in @(L $aenderungen)) {
    $segs = Segmente "$($c.pfad)"; $vor = Hole $ist $segs; $nach = Hole $neu $segs
    if ("$($c.aktion)" -eq "sortieren") {
      # Reihenfolge zeigen statt der ganzen Liste
      $f = SortierFeld $c
      [ordered]@{ pfad = $c.pfad; aktion = "sortieren nach $f"; bisher = (Kurz (ListenText $vor.wert $f) 3000); neu = (Kurz (ListenText $nach.wert $f) 3000) }
      continue
    }
    [ordered]@{ pfad = $c.pfad; aktion = $(if ($c.aktion) { $c.aktion } else { "setzen" })
      bisher = $(if ($vor.gefunden) { Kurz $vor.wert 500 } else { "(nicht vorhanden)" }); neu = $(if ($nach.gefunden) { Kurz $nach.wert 500 } elseif ("$($c.aktion)" -eq "anhaengen") { Kurz $c.wert 800 } else { "(entfernt)" }) }
  }
  $warn = @()
  if (-not $BAUSTEINE[$baustein].erprobt) { $warn += "Baustein '$baustein' wurde bisher noch nie per API geaendert - Ergebnis im Designer pruefen." }
  if ((JStr $ist) -eq (JStr $neu)) { throw "Keine Aenderung - alle Werte sind schon so." }
  $warn += "Wirksam erst nach Veroeffentlichen im Designer."
  @{ vorschau = [ordered]@{ aktion = $(if ($aktionText) { $aktionText } else { "$($BAUSTEINE[$baustein].text) aendern" }); baustein = $baustein; id = $id; name = (BausteinName $ist $baustein); version = $ist._version; umgebung = $UMGEBUNG; aenderungen = @($zeilen) }
     warnungen = $warn; fp = "$id|$($ist._version)|$($ist._last_modified_date)"; id = $id; roh = $roh }
}

function AenderungAusfuehren([string] $b, $plan, $aenderungen) {
  $id = $plan.id; $adr = BausteinPfad $b $id
  New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
  $sich = Join-Path $SICHERUNG ("{0}-{1}-{2}-vorher.json" -f ($b -replace '/', '_'), $(if ($id) { $id } else { "einzel" }), (Get-Date).ToString("yyyyMMdd-HHmmss"))
  [IO.File]::WriteAllText($sich, $plan.roh, [Text.UTF8Encoding]::new($false))
  $ist = JObj $plan.roh
  $wkText = Blp-Send "POST" (P "$adr/checkout") (JStr @{ _read_token = $ist._read_token })
  $wk = JObj $wkText
  if (-not $wk._read_token) { throw "checkout lieferte keine Arbeitskopie: $(Kurz $wkText 300)" }
  $token = $wk._read_token
  try {
    $neu = Wende $wk $aenderungen
    $fehler = @(L (Pruefe $neu $b)); if ($fehler.Count) { throw ("Pruefung nach checkout: " + ($fehler -join "; ")) }
    $gespeichert = JObj (Blp-Send "POST" (P $adr) (JStr $neu))
    if ($gespeichert._read_token) { $token = $gespeichert._read_token }
    $null = Blp-Send "POST" (P "$adr/commit") (JStr @{ _read_token = $token })
  } catch {
    $fehlerText = "$($_.Exception.Message)"
    try { Blp-Send "POST" (P "$adr/undo") (JStr @{ _read_token = $token }) | Out-Null; $fehlerText += " (Arbeitskopie per undo verworfen)" }
    catch { $fehlerText += " (undo fehlgeschlagen: $($_.Exception.Message) - Baustein evtl. noch ausgecheckt, im Designer pruefen)" }
    throw $fehlerText
  }
  $nach = JObj (Blp-Get (P $adr)); $abweichung = @()   # mit -DateKind String, sonst wirken Datumstexte veraendert
  foreach ($c in @(L $aenderungen)) {
    $segs = Segmente "$($c.pfad)"
    if ("$($c.aktion)" -eq "anhaengen") { continue }
    if ("$($c.aktion)" -eq "sortieren") {
      $h = Hole $nach $segs; $f = SortierFeld $c
      if (-not $h.gefunden -or (ListenText $h.wert $f) -ne (ListenText (SortiereListe $h.wert $f) $f)) { $abweichung += "$($c.pfad) ist nach dem Speichern nicht sortiert" }
      continue
    }
    $h = Hole $nach $segs
    # Entfernen: bei Name oder Auswahl [..] darf der Pfad danach nicht mehr gefunden werden; bei einem Index rueckt das naechste Element nach.
    if ("$($c.aktion)" -eq "entfernen") { if ($h.gefunden -and ($segs[-1] -notmatch '^\d+$')) { $abweichung += "$($c.pfad) noch vorhanden" }; continue }
    # false und leere Listen laesst der Dienst beim Speichern weg (z. B. include=false am Auswahlbaum) - fehlt dann = richtig.
    if (-not $h.gefunden -and (LeerWert $c.wert) -and $segs[-1] -notmatch '^(\d+|\[.*\])$') { continue }
    if (-not $h.gefunden -or (JStr $h.wert) -ne (JStr (JObj (JStr $c.wert)))) { $abweichung += "$($c.pfad) weicht nach dem Speichern ab" }
  }
  [ordered]@{ baustein = $b; id = $id; name = (BausteinName $nach $b); versionVorher = $ist._version; versionNachher = $nach._version
    kontrolle = $(if ($abweichung.Count) { $abweichung } else { "alle Werte wie gewuenscht" }); sicherung = $sich; nachher = $nach
    danach = "Im Designer veroeffentlichen, erst dann sieht die Sidebar die Aenderung." }
}

Werkzeug "blp_change" ("Aendert einen BLP-Baustein gezielt ueber Pfade (zweistufig: Vorschau mit bisher/neu, dann mit freigabe ausfuehren). " +
  "Bausteine: processengine, objectmanager, client/sidebar/tab/action, smartsearch, role, client/selection (Auswahlbaum, ohne objekt). " +
  "Pfad: Segmente mit '/', Listen per Index oder [feld=wert]/[feld^=anfang], '#' = in eingebettetes JSON, '/-' + aktion anhaengen = neues Element, " +
  "aktion sortieren = Liste am Pfad alphabetisch (de-DE) nach Feld wert (Standard display_text), z. B. selections/[name=Einkauf]/childs. " +
  "Ablauf: Sicherung, checkout, Aenderung, Pruefung (keine null in Listen, Prozessparameter nur Text), speichern, commit, nachlesen; bei Fehler undo. " +
  "Veroeffentlichen macht ein Mensch im Designer. Nur in Umgebungen mit allowChanges.") @{
  baustein = @{ type = "string"; enum = @($BAUSTEINE.Keys) }
  objekt = @{ type = "string"; description = "ID oder Name; entfaellt bei client/selection" }
  aenderungen = @{ type = "array"; description = "Liste von {pfad, wert, aktion}"; items = @{ type = "object"; properties = @{
      pfad = @{ type = "string" }; wert = @{ description = "Neuer Wert (beliebiges JSON); entfaellt bei entfernen; bei sortieren das Feld (Standard display_text)" }
      aktion = @{ type = "string"; enum = @("setzen", "anhaengen", "entfernen", "sortieren") } }; required = @("pfad") } }
  freigabe = @{ type = "string"; description = "Leer fuer die Vorschau; zum Ausfuehren der Freigabe-Code aus der Vorschau" } } @("baustein", "aenderungen") {
  param($a)
  ZweiSchritte "blp_change" $a { AenderungPlan "$($a.baustein)" "$($a.objekt)" $a.aenderungen "" } {
    param($plan)
    $r = AenderungAusfuehren "$($a.baustein)" $plan $a.aenderungen
    $r.Remove("nachher"); $r
  }
} -Schreibt

# ---------- Neuanlage ----------

# Feste GUID aus einem Text (gleiche Eingabe -> gleiche ID), damit Vorschau und Ausfuehrung dieselbe ID zeigen.
function FesteGuid([string] $text) {
  $h = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("blp-mcp." + $text))
  $h[6] = ($h[6] -band 0x0f) -bor 0x30; $h[8] = ($h[8] -band 0x3f) -bor 0x80   # Version 3, RFC-4122
  $x = ($h | ForEach-Object { $_.ToString("x2") }) -join ""
  "{0}-{1}-{2}-{3}-{4}" -f $x.Substring(0, 8), $x.Substring(8, 4), $x.Substring(12, 4), $x.Substring(16, 4), $x.Substring(20, 12)
}

function Sprachcode([string] $prefix, [string] $name) {
  $n = $name.ToUpperInvariant() -replace 'Ä', 'AE' -replace 'Ö', 'OE' -replace 'Ü', 'UE' -replace 'ß', 'SS' -replace '[^A-Z0-9]+', '_'
  "$prefix" + $n.Trim('_')
}

function Prozessordner {
  $d = Lies "processengine"; $out = @()
  foreach ($art in "server_processes", "client_processes", "sub_processes", "templates") {
    foreach ($o in @(L $d.$art)) { $out += [pscustomobject]@{ id = $o._id; name = $o.name; art = $art } }
  }
  $out
}

function KachelFinden([string] $wer) {
  # sucht eine Kachel (tile_id oder Name) in allen Tabs und Objekten
  $treffer = @()
  foreach ($t in @(L (Lies "client/sidebar/tab/action").tabs)) { foreach ($k in @(L $t.tiles)) { if ($k.tile_id -eq $wer -or $k.tile_id -like "$wer*" -or $k.name -eq $wer) { $treffer += [pscustomobject]@{ kachel = $k; wo = "Tab $($t.name)" } } } }
  foreach ($o in @(L (Lies "objectmanager").objects)) { foreach ($k in @(L $o.tiles)) { if ($k.tile_id -eq $wer -or $k.tile_id -like "$wer*" -or $k.name -eq $wer) { $treffer += [pscustomobject]@{ kachel = $k; wo = "Objekt $($o.name)" } } } }
  if ($treffer.Count -eq 0) { throw "Vorlage-Kachel nicht gefunden: $wer" }
  # Dieselbe Kachel (gleiche tile_id) kann in mehreren Tabs stecken, z. B. in einer Tab-Kopie - dann ist es egal, welche.
  if (@($treffer | ForEach-Object { $_.kachel.tile_id } | Select-Object -Unique).Count -eq 1) { return $treffer[0] }
  if ($treffer.Count -gt 1) { throw "Vorlage-Kachel mehrdeutig: " + (($treffer | ForEach-Object { "$($_.kachel.name) [$($_.kachel.tile_id)] in $($_.wo)" }) -join "; ") + " - tile_id angeben." }
  $treffer[0]
}

Werkzeug "blp_create_process" ("Legt einen neuen BLP-Prozess als Kopie eines vorhandenen an (zweistufig): PUT processengine mit der ganzen Definition, " +
  "nicht 'duplicate' (der Klon kaeme ohne Namen/Ordner an und waere im Designer unsichtbar). Optional Pfad-Aenderungen an der Kopie (gleiche Pfadsprache wie blp_change). Nur in Umgebungen mit allowChanges.") @{
  vorlage = @{ type = "string"; description = "Prozess, der kopiert wird (ID oder Name)" }
  name = @{ type = "string"; description = "Name des neuen Prozesses, z. B. 'Rechnung pruefen (Kopie)'" }
  ordner = @{ type = "string"; description = "Ordner-ID oder -Name; Standard: Ordner der Vorlage" }
  aenderungen = @{ type = "array"; description = "Optional: Liste von {pfad, wert, aktion} fuer die Kopie"; items = @{ type = "object" } }
  freigabe = @{ type = "string" } } @("vorlage", "name") {
  param($a)
  ZweiSchritte "blp_create_process" $a {
    $q = Finde (Prozessliste) $a.vorlage "Prozess"
    $name = "$($a.name)".Trim(); if (-not $name) { throw "name ist leer." }
    if (@(L (Prozessliste) | Where-Object { $_.name -eq $name }).Count) { throw "Es gibt schon einen Prozess '$name'." }
    $ordnerListe = Prozessordner
    $ordner = if ($a.ordner) { Finde $ordnerListe "$($a.ordner)" "Ordner" } else { $ordnerListe | Where-Object { $_.name -eq $q.ordner -and $_.art -like "$($q.art)*" } | Select-Object -First 1 }
    if (-not $ordner) { throw "Ordner nicht bestimmbar - ordner angeben." }
    $roh = Blp-Get (P "processengine/$($q.id)"); $src = JObj $roh
    $def = [pscustomobject][ordered]@{ internal_id = "00000000-0000-0000-0000-000000000000"; type = $src.type; name = $name; folder = $ordner.id
      nodes = $src.nodes; connectors = $src.connectors; childs = $src.childs; options = $src.options }
    $zeilen = @()
    if (@(L $a.aenderungen).Count) {
      $vorher = Kopie $def
      $def = Wende $def $a.aenderungen
      $zeilen = foreach ($c in @(L $a.aenderungen)) { $s = Segmente "$($c.pfad)"; $v = Hole $vorher $s; $n = Hole $def $s
        [ordered]@{ pfad = $c.pfad; bisher = $(if ($v.gefunden) { Kurz $v.wert 300 } else { "(nicht vorhanden)" }); neu = $(if ($n.gefunden) { Kurz $n.wert 300 } else { "(entfernt)" }) } }
    }
    $fehler = @(L (Pruefe $def "processengine")); if ($fehler.Count) { throw ("Neuer Prozess waere ungueltig:`n- " + ($fehler -join "`n- ")) }
    @{ vorschau = [ordered]@{ aktion = "Prozess anlegen"; name = $name; vorlage = "$($q.name) [$($q.id)] v$($q.version)"; ordner = "$($ordner.name) [$($ordner.id)]"
         knoten = @(L $def.nodes).Count; verbindungen = @(L $def.connectors).Count; aenderungen = @($zeilen); umgebung = $UMGEBUNG }
       warnungen = @("Der neue Prozess wird erst nach Veroeffentlichen im Designer wirksam; eine Kachel dazu mit blp_add_tile.")
       fp = "neu|$name|$($q.id)|$($q.version)"; def = $def; name = $name }
  } {
    param($plan)
    $antwort = Blp-Send "PUT" (P "processengine") (JStr $plan.def)
    $neu = $null; try { $neu = JObj $antwort } catch {}
    $script:Prozessliste = $null
    $p = @(L (Prozessliste) | Where-Object { $_.name -eq $plan.name })
    if ($p.Count -ne 1) { throw "Anlage unklar: $($p.Count) Prozesse '$($plan.name)' gefunden. Antwort: $(Kurz $antwort 300)" }
    $chk = JObj (Blp-Get (P "processengine/$($p[0].id)"))
    [ordered]@{ id = $p[0].id; name = $chk.name; version = $chk._version; ordner = $p[0].ordner; knoten = @(L $chk.nodes).Count; verbindungen = @(L $chk.connectors).Count
      danach = "Im Designer pruefen und veroeffentlichen. Kachel mit blp_add_tile anlegen." }
  }
} -Schreibt

Werkzeug "blp_create_tab" ("Legt einen neuen, leeren Sidebar-Tab an (zweistufig; PUT client/sidebar/tab/action). Kacheln danach mit blp_add_tile. " +
  "Achtung: ein neuer Tab steht in ALLEN Rollen auf eingeschlossen, bis er dort abgewaehlt wird. Nur in Umgebungen mit allowChanges.") @{
  name = @{ type = "string" }; anzeige = @{ type = "string"; description = "Anzeigetext, Standard = name" }
  beschreibung = @{ type = "string" }
  bild = @{ type = "string"; description = "Optional: item_id eines Bildes aus dem Bildpaket" }
  freigabe = @{ type = "string" } } @("name") {
  param($a)
  ZweiSchritte "blp_create_tab" $a {
    $name = "$($a.name)".Trim(); if (-not $name) { throw "name ist leer." }
    $tabs = @(L (Lies "client/sidebar/tab/action").tabs)
    if (@($tabs | Where-Object { $_.name -eq $name }).Count) { throw "Es gibt schon einen Tab '$name'." }
    $typ = if ($tabs.Count) { $tabs[0].type } else { 0 }
    $tab = [pscustomobject][ordered]@{ name = $name; type = $typ; address = ""; smart_search_profile = ""; ai_assistant = ""
      display_text = $(if ($a.anzeige) { "$($a.anzeige)" } else { $name }); description = "$($a.beschreibung)"
      language_code = (Sprachcode "LC_TAB_" $name); language_code_description = (Sprachcode "TAB_DESC_" $name)
      image = [pscustomobject]@{ repository_id = ""; item_id = "$($a.bild)" }; tiles = @() }
    $rollen = @(L (Lies "role").roles | ForEach-Object { $_.name })
    @{ vorschau = [ordered]@{ aktion = "Sidebar-Tab anlegen"; tab = $tab; umgebung = $UMGEBUNG }
       warnungen = @("Der BLP traegt den neuen Tab beim Anlegen in alle Rollen mit Situation ein, eingeschlossen ($($rollen -join ', ')). Abwaehlen je Rolle: blp_change baustein=role, pfad situations/0/action_tabs/[tab_id=<neue ID>]/include, wert false.",
         "Wird der Tab spaeter geloescht, bleiben diese Rollen-Eintraege stehen - dann mit blp_change ... aktion entfernen aufraeumen, und zwar erst NACH dem Loeschen des Tabs.", "Wirksam erst nach Veroeffentlichen im Designer.")
       fp = "neu|$name|$($tabs.Count)"; tab = $tab; name = $name }
  } {
    param($plan)
    $antwort = Blp-Send "PUT" (P "client/sidebar/tab/action") (JStr $plan.tab)
    $t = @(L (Lies "client/sidebar/tab/action").tabs | Where-Object { $_.name -eq $plan.name })
    if ($t.Count -ne 1) { throw "Anlage unklar: $($t.Count) Tabs '$($plan.name)'. Antwort: $(Kurz $antwort 300)" }
    [ordered]@{ id = $t[0]._id; name = $t[0].name; version = $t[0]._version; danach = "Kacheln mit blp_add_tile; Sichtbarkeit in den Rollen pruefen; im Designer veroeffentlichen." }
  }
} -Schreibt

Werkzeug "blp_add_tile" ("Haengt eine neue Kachel an einen Tab oder ein Geschaeftsobjekt (zweistufig). Die Kachel ist eine Kopie einer vorhandenen Vorlage-Kachel (gleiche Aktion, Farbe, Bilder) " +
  "mit neuer fester ID, neuem Namen und optionalen Pfad-Aenderungen relativ zur Kachel, z. B. 'parameters/Module.Core.Action.ProcessStarter.Config/#/ProcessName' oder 'layout/color_id'. " +
  "Bei Objekten wird auch tiles_order ergaenzt. Nur in Umgebungen mit allowChanges.") @{
  ziel = @{ type = "string"; enum = @("tab", "objekt") }
  zielname = @{ type = "string"; description = "Tab bzw. Geschaeftsobjekt (ID oder Name)" }
  vorlage = @{ type = "string"; description = "Vorlage-Kachel: tile_id (auch Anfang) oder eindeutiger Name, aus einem beliebigen Tab oder Objekt" }
  name = @{ type = "string"; description = "Name der neuen Kachel" }
  anzeige = @{ type = "string"; description = "Anzeigetext, Standard = name" }
  beschreibung = @{ type = "string" }
  aenderungen = @{ type = "array"; description = "Optional: {pfad, wert, aktion} relativ zur neuen Kachel"; items = @{ type = "object" } }
  freigabe = @{ type = "string" } } @("ziel", "zielname", "vorlage", "name") {
  param($a)
  $b = if ($a.ziel -eq "tab") { "client/sidebar/tab/action" } else { "objectmanager" }
  $kachelPlan = {
    $v = KachelFinden "$($a.vorlage)"
    $name = "$($a.name)".Trim(); if (-not $name) { throw "name ist leer." }
    $k = Kopie $v.kachel
    $k.tile_id = FesteGuid "$b|$($a.zielname)|$name"
    $k.inherited_from = "000000000000000000000000"
    $k.name = $name; $k.display_text = $(if ($a.anzeige) { "$($a.anzeige)" } else { $name })
    if ($null -ne $a.beschreibung) { $k.description = "$($a.beschreibung)" }
    $k.language_code = Sprachcode "LC_" $name
    if (@(L $a.aenderungen).Count) { $k = Wende $k $a.aenderungen }
    $aend = @(@{ pfad = "tiles/-"; aktion = "anhaengen"; wert = $k })
    if ($b -eq "objectmanager") { $aend += @{ pfad = "tiles_order/-"; aktion = "anhaengen"; wert = $k.tile_id } }
    @{ kachel = $k; vorlage = $v; aend = $aend }
  }
  ZweiSchritte "blp_add_tile" $a {
    $kp = & $kachelPlan
    $ziel = JObj (Blp-Get (P "$b/$(BausteinFinden $b "$($a.zielname)")"))
    if (@(L $ziel.tiles | Where-Object { $_.name -eq $kp.kachel.name }).Count) { throw "Im Ziel gibt es schon eine Kachel '$($kp.kachel.name)'." }
    if (@(L $ziel.tiles | Where-Object { $_.tile_id -eq $kp.kachel.tile_id }).Count) { throw "Kachel-ID $($kp.kachel.tile_id) gibt es im Ziel schon." }
    $plan = AenderungPlan $b "$($a.zielname)" $kp.aend "Kachel anlegen"
    $plan.vorschau.Remove("aenderungen")
    $plan.vorschau.kachel = KachelKurz $kp.kachel
    $plan.vorschau.vorlage = "$($kp.vorlage.kachel.name) [$($kp.vorlage.kachel.tile_id)] aus $($kp.vorlage.wo)"
    $plan.warnungen = @("Kachelbild und Farbe kommen von der Vorlage; Sichtbarkeit je Rolle im Designer pruefen.") + @(L $plan.warnungen)
    $plan.aend = $kp.aend; $plan.tileId = $kp.kachel.tile_id
    $plan
  } {
    param($plan)
    $r = AenderungAusfuehren $b $plan $plan.aend
    $da = @(L $r.nachher.tiles | Where-Object { $_.tile_id -eq $plan.tileId }).Count -eq 1
    $r.Remove("nachher")
    $r.kachelId = $plan.tileId; $r.kontrolle = $(if ($da) { "Kachel vorhanden" } else { "Kachel nach dem Speichern NICHT gefunden" })
    $r
  }
} -Schreibt
