# blp-mcp-bilder.ps1 - Bildpaket des BLP-Designers: Bilder auflisten, hochladen (und an Kachel/Tab haengen), entfernen.
# Wird von blp-mcp.ps1 nach blp-mcp-aendern.ps1 per Dot-Sourcing eingebunden (nutzt Blp-Get, Blp-Send, JObj, JStr, Pruefe,
# ZweiSchritte, AenderungPlan, AenderungAusfuehren, BausteinFinden, Hole, Segmente, L, Kurz, Werkzeug, Log).
#
# Bilder haengen nicht am Projekt, sondern am Projektdienst (so arbeitet auch der Designer):
#   GET    /api/v1/image/package                  {packages:[{_id, name "Default", _read_token, container:[{id, name, images:[{id, file, type, data?}]}]}]}
#   PUT    /api/v1/image/<neue GUID>?filename=x   PNG als Rumpf - legt nur die Datei im Bildspeicher ab
#   POST   /api/v1/image/package/<id>/checkout | /<id> (ganzes Paket) | /commit | /undo   - Eintrag im Container
#   GET    /api/v1/image/<id>                     die Datei
#   DELETE /api/v1/image/<id>                     Datei loeschen (so loescht auch der Designer)
# Container-IDs sind NICHT eindeutig (zwei Container koennen dieselbe ID haben) - Container immer per Name.
# Dieselbe Bild-ID kann in mehreren Containern stehen.
# Verweise: Kachel layout.images.image_small/medium/large = 24/32/64 px, Tab image (24 px), je {repository_id "", item_id}.

# Aus der Konfiguration (images): Symbolordner <iconDir>\<farbe>\<motiv>_<groesse>.png und Container je Farbe, beides optional.
$ICON_DIR = if ($K) { $K.symbolOrdner } else { $null }
$BILD_FARBE = if ($K) { $K.bildContainer } else { @{} }
$BILD_SLOT = @{ 24 = "image_small"; 32 = "image_medium"; 64 = "image_large" }
$BILD_MAX = 1MB
$BILD_PAKET = if ($K) { $K.bildPaket } else { "Default" }

# Wie Blp-Send, aber mit Bytes hin und zurueck (Upload, Datei holen, Datei loeschen).
function Blp-Bytes([string] $Method, [string] $Url, [byte[]] $Body, [string] $ContentType) {
  for ($versuch = 1; $versuch -le 2; $versuch++) {
    try {
      $h = Header; $h.Accept = "*/*"; if ($ContentType) { $h["Content-Type"] = $ContentType }
      $p = @{ Uri = $Url; Method = $Method; Headers = $h; UseBasicParsing = $true } + $TLS
      if ($null -ne $Body) { $p.Body = $Body }
      $r = Invoke-WebRequest @p
      return ,($r.RawContentStream.ToArray())   # Komma: byte[] nicht in Einzelwerte entrollen
    } catch {
      $code = $null; try { $code = [int] $_.Exception.Response.StatusCode } catch {}
      if ($code -eq 401 -and $versuch -eq 1) { Log "401, melde neu an"; $script:Token = $null; continue }
      $detail = $_.ErrorDetails.Message
      throw ("$Method $Url -> " + $(if ($code) { "HTTP $code " } else { "" }) + $(if ($detail) { $detail.Substring(0, [Math]::Min(300, $detail.Length)) } else { $_.Exception.Message }))
    }
  }
}

function PngInfo([string] $pfad) {
  if (-not [IO.Path]::IsPathRooted($pfad)) { throw "Pfad muss absolut sein: $pfad" }
  if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) { throw "Datei fehlt: $pfad$(if ($ICON_DIR -and $pfad -like "$ICON_DIR*") { ' (Symbolordner aus images.iconDir)' })" }
  if ([IO.Path]::GetExtension($pfad) -ne ".png") { throw "Nur PNG-Dateien: $pfad" }
  $fi = Get-Item -LiteralPath $pfad
  if ($fi.Length -gt $BILD_MAX) { throw "Datei zu gross (ueber 1 MB): $pfad" }
  $b = [IO.File]::ReadAllBytes($fi.FullName)
  $sig = 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
  if ($b.Length -lt 24) { throw "Keine PNG-Datei: $pfad" }
  for ($i = 0; $i -lt 8; $i++) { if ($b[$i] -ne $sig[$i]) { throw "Keine PNG-Datei (Signatur): $pfad" } }
  $w = ([int] $b[16] -shl 24) -bor ([int] $b[17] -shl 16) -bor ([int] $b[18] -shl 8) -bor [int] $b[19]
  $hh = ([int] $b[20] -shl 24) -bor ([int] $b[21] -shl 16) -bor ([int] $b[22] -shl 8) -bor [int] $b[23]
  [pscustomobject]@{ datei = $fi.Name; pfad = $fi.FullName; bytes = $fi.Length; breite = $w; hoehe = $hh; stand = $fi.LastWriteTimeUtc.ToString("o") }
}

function BildPaketLesen {
  $j = JObj (Blp-Get "$PROJEKT/api/v1/image/package")
  $p = @(L $j.packages | Where-Object { $_.name -eq $BILD_PAKET })
  if ($p.Count -ne 1) { throw "Bildpaket '$BILD_PAKET' nicht gefunden (vorhanden: $(@(L $j.packages | ForEach-Object { $_.name }) -join ', '))." }
  $p[0]
}

# Containername aus Angabe (Name oder Farbe aus images.containers) oder aus der Farbe; Pruefung gegen das Paket.
function BildContainerName($paket, [string] $wer, [string] $farbe) {
  if (-not $wer) {
    $f = if ($farbe) { $farbe } else { "weiss" }
    if (-not $BILD_FARBE.ContainsKey($f)) { throw "container angeben (oder images.containers.$f in der Konfiguration eintragen)." }
    $wer = $f
  }
  $name = if ($BILD_FARBE.ContainsKey($wer)) { $BILD_FARBE[$wer] } else { $wer }
  $c = @(L $paket.container | Where-Object { $_.name -eq $name })
  if ($c.Count -ne 1) { throw "Container '$name' im Bildpaket $($c.Count)-mal gefunden (vorhanden: $(@(L $paket.container | ForEach-Object { $_.name }) -join ', '))." }
  $name
}

# Wo werden diese Bild-IDs benutzt? Tab-Bilder und Kachelbilder in Tabs und Objekten, dazu Textsuche in Rollen und Objekten.
function BildVerwendung([string[]] $ids) {
  $hit = @{}; foreach ($i in $ids) { $hit[$i] = [System.Collections.Generic.List[string]]::new() }
  $merke = { param($id, $text) if ($id -and $hit.ContainsKey("$id")) { $hit["$id"].Add($text) } }
  $tabsRoh = Blp-Get (P "client/sidebar/tab/action")
  foreach ($t in @(L (JObj $tabsRoh).tabs)) {
    & $merke $t.image.item_id "Tab $($t.name) (Tab-Bild)"
    foreach ($k in @(L $t.tiles)) { foreach ($s in "image_small", "image_medium", "image_large") { & $merke $k.layout.images.$s.item_id "Tab $($t.name) / Kachel $($k.name) ($s)" } }
  }
  $objRoh = Blp-Get (P "objectmanager")
  foreach ($o in @(L (JObj $objRoh).objects)) {
    foreach ($k in @(L $o.tiles)) { foreach ($s in "image_small", "image_medium", "image_large") { & $merke $k.layout.images.$s.item_id "Objekt $($o.name) / Kachel $($k.name) ($s)" } }
  }
  $rollenRoh = Blp-Get (P "role")
  foreach ($i in $ids) {
    if ($rollenRoh.Contains($i)) { $hit[$i].Add("Rollen (Einstellungen ueberschreiben)") }
    if ($hit[$i].Count -eq 0 -and ($tabsRoh.Contains($i) -or $objRoh.Contains($i))) { $hit[$i].Add("kommt in Tabs/Objekten an anderer Stelle vor") }
  }
  $hit
}

function BildZeile($im) { "$($im.file) [$($im.id)]" + $(if ($im.width) { " $($im.width)x$($im.height)" } else { "" }) }

# ---------- Werkzeuge ----------

Werkzeug "blp_images" ("Bildpaket des Designers (Standard 'Default'): Container mit Bildern (Datei, ID, Groesse), ohne Bilddaten. filter = Dateinamensteil; " +
  "bild = ID oder Dateiname zeigt, in welchen Containern es steht und wo es benutzt wird (Tab-Bild, Kachel).") @{
  container = @{ type = "string"; description = "Optional: Containername oder eine Farbe aus images.containers (z. B. weiss)" }
  filter = @{ type = "string"; description = "Optional: Dateinamensteil, z. B. 'rechnung'" }
  bild = @{ type = "string"; description = "Optional: item_id oder Dateiname" } } @() {
  param($a)
  $p = BildPaketLesen
  $cs = @(L $p.container)
  if ($a.container) { $cn = BildContainerName $p "$($a.container)" ""; $cs = @($cs | Where-Object { $_.name -eq $cn }) }
  if ($a.bild) {
    $treffer = @(foreach ($c in $cs) { foreach ($im in @(L $c.images)) { if ($im.id -eq $a.bild -or $im.file -eq $a.bild) { [ordered]@{ container = $c.name; datei = $im.file; id = $im.id } } } })
    if ($treffer.Count -eq 0) { throw "Bild nicht gefunden: $($a.bild)" }
    $ids = @($treffer | ForEach-Object { $_.id } | Select-Object -Unique)
    $verw = BildVerwendung $ids; $v = [ordered]@{}
    foreach ($i in $ids) { if ($verw[$i].Count) { $v[$i] = $verw[$i].ToArray() } else { $v[$i] = "nirgends benutzt" } }
    return [ordered]@{ paket = $p.name; version = $p._version; treffer = $treffer; verwendung = $v }
  }
  [ordered]@{ paket = $p.name; id = $p._id; version = $p._version; geaendert = $p._last_modified_date; von = $p._last_author
    container = @(foreach ($c in $cs) {
      $ims = @(L $c.images | Where-Object { -not $a.filter -or $_.file -like "*$($a.filter)*" })
      [ordered]@{ name = $c.name; id = $c.id; anzahl = @(L $c.images).Count; bilder = @($ims | ForEach-Object { BildZeile $_ }) } })
    hinweis = "Container-IDs sind nicht eindeutig - Container immer per Name ansprechen." }
}

Werkzeug "blp_image_upload" ("Laedt PNG-Bilder ins Bildpaket (zweistufig) und haengt sie optional gleich an eine Kachel eines Tabs/Objekts " +
  "(layout.images image_small/medium/large = 24/32/64 px) und/oder als Tab-Bild (24 px). Quelle: motiv aus dem Symbolordner (images.iconDir: <farbe>\<motiv>_<groesse>.png) " +
  "oder dateien (absolute PNG-Pfade). Liegt eine Datei gleichen Namens schon im Container, wird sie wiederverwendet. " +
  "Ablauf: checkout Paket, PUT /api/v1/image/<GUID>, Eintrag im Container, speichern, commit (bei Fehler undo und Dateien wieder loeschen), " +
  "dann Zuweisung wie blp_change. Veroeffentlichen macht ein Mensch im Designer. Nur in Umgebungen mit allowChanges.") @{
  motiv = @{ type = "string"; description = "Symbolname ohne _<groesse>.png, z. B. 'rechnung'; braucht images.iconDir" }
  farbe = @{ type = "string"; description = "Standard weiss: Unterordner im Symbolordner und Schluessel in images.containers (z. B. weiss, dunkel)" }
  groessen = @{ type = "array"; items = @{ type = "integer"; enum = @(24, 32, 64) }; description = "Standard [24, 32, 64]" }
  dateien = @{ type = "array"; items = @{ type = "string" }; description = "Statt motiv: absolute Pfade zu PNG-Dateien (je max. 1 MB); der Dateiname wird der Name im Paket" }
  container = @{ type = "string"; description = "Optional: Containername; Standard nach farbe (images.containers)" }
  ziel = @{ type = "string"; enum = @("tab", "objekt"); description = "Optional: Bilder gleich zuweisen" }
  zielname = @{ type = "string"; description = "Tab bzw. Geschaeftsobjekt (ID oder Name)" }
  kachel = @{ type = "string"; description = "Kachel im Ziel (tile_id, deren Anfang oder Name)" }
  tabbild = @{ type = "boolean"; description = "Bei ziel=tab: das 24-px-Bild als Tab-Bild setzen" }
  freigabe = @{ type = "string" } } @() {
  param($a)
  ZweiSchritte "blp_image_upload" $a {
    if ($a.motiv -and @(L $a.dateien).Count) { throw "Entweder motiv oder dateien angeben, nicht beides." }
    $farbe = if ($a.farbe) { "$($a.farbe)" } else { "weiss" }
    $dateien = @()
    if ($a.motiv) {
      if (-not $ICON_DIR) { throw "motiv braucht einen Symbolordner (images.iconDir in der Konfiguration) - sonst dateien mit absoluten Pfaden angeben." }
      if ("$farbe" -notmatch '^[A-Za-z0-9_-]+$') { throw "farbe nur aus Buchstaben, Ziffern, Binde- und Unterstrich." }
      if ("$($a.motiv)" -notmatch '^[A-Za-z0-9._-]+$') { throw "motiv nur aus Buchstaben, Ziffern, Punkt, Binde- und Unterstrich (Dateiname ohne _<groesse>.png)." }
      $gr = if (@(L $a.groessen).Count) { @($a.groessen) } else { @(24, 32, 64) }
      foreach ($g in $gr) { $dateien += PngInfo (Join-Path (Join-Path $ICON_DIR $farbe) "$($a.motiv)_$g.png") }
    } elseif (@(L $a.dateien).Count) {
      foreach ($d in $a.dateien) { $dateien += PngInfo "$d" }
    } else { throw "motiv oder dateien angeben." }
    $doppelt = @($dateien | Group-Object datei | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($doppelt.Count) { throw "Dateiname mehrfach: $($doppelt -join ', ')" }

    $paket = BildPaketLesen
    $cname = BildContainerName $paket "$($a.container)" $farbe
    $cont = @(L $paket.container | Where-Object { $_.name -eq $cname })[0]
    $vorhanden = @{}; foreach ($im in @(L $cont.images)) { if ($im.file -and -not $vorhanden.ContainsKey($im.file)) { $vorhanden[$im.file] = $im.id } }
    $neuZahl = @($dateien | Where-Object { -not $vorhanden.ContainsKey($_.datei) }).Count

    # Zuweisung vorbereiten: Pfade im Ziel und bisherige item_id
    $zuw = $null; $zuwZeilen = @(); $zuwAenderungen = 0
    if ($a.ziel -or $a.kachel -or $a.tabbild) {
      if (-not $a.ziel -or -not $a.zielname) { throw "Fuer die Zuweisung ziel (tab/objekt) und zielname angeben." }
      if (-not $a.kachel -and -not $a.tabbild) { throw "kachel und/oder tabbild angeben." }
      if ($a.tabbild -and $a.ziel -ne "tab") { throw "tabbild geht nur bei ziel=tab." }
      $b = if ($a.ziel -eq "tab") { "client/sidebar/tab/action" } else { "objectmanager" }
      $zid = BausteinFinden $b "$($a.zielname)"
      $z = JObj (Blp-Get (P "$b/$zid"))
      $pfade = @()
      if ($a.kachel) {
        $k = @(L $z.tiles | Where-Object { $_.tile_id -eq $a.kachel -or $_.tile_id -like "$($a.kachel)*" -or $_.name -eq $a.kachel })
        if ($k.Count -ne 1) { throw "Kachel '$($a.kachel)' in '$($z.name)' $($k.Count)-mal gefunden (genau einmal noetig; tile_id angeben)." }
        foreach ($d in $dateien) {
          if ($d.breite -ne $d.hoehe -or -not $BILD_SLOT.ContainsKey([int] $d.breite)) { throw "$($d.datei) ist $($d.breite)x$($d.hoehe) - Kachelbilder nur 24, 32 oder 64 px quadratisch." }
          $pfade += @{ pfad = "tiles/[tile_id=$($k[0].tile_id)]/layout/images/$($BILD_SLOT[[int] $d.breite])"; datei = $d.datei; wo = "Kachel $($k[0].name) $($BILD_SLOT[[int] $d.breite])" }
        }
      }
      if ($a.tabbild) {
        $d24 = @($dateien | Where-Object { $_.breite -eq 24 -and $_.hoehe -eq 24 })
        if ($d24.Count -ne 1) { throw "Fuer tabbild genau eine 24x24-Datei angeben." }
        $pfade += @{ pfad = "image"; datei = $d24[0].datei; wo = "Tab-Bild" }
      }
      foreach ($pf in $pfade) {
        $h = Hole $z (Segmente "$($pf.pfad)/item_id")
        $bisher = if ($h.gefunden) { "$($h.wert)" } else { "" }
        $neuId = if ($vorhanden.ContainsKey($pf.datei)) { $vorhanden[$pf.datei] } else { "" }
        if ($bisher -ne $neuId) { $zuwAenderungen++ }
        $zuwZeilen += [ordered]@{ wo = $pf.wo; bisher = $(if ($bisher) { $bisher } else { "(leer)" }); neu = $(if ($neuId) { "$neuId ($($pf.datei))" } else { "(neue ID nach Upload: $($pf.datei))" }) }
      }
      $zuw = @{ b = $b; zid = $zid; name = $z.name; pfade = $pfade; fp = "$zid|$($z._version)|$($z._last_modified_date)" }
    }
    if ($neuZahl -eq 0 -and $zuwAenderungen -eq 0) { throw "Nichts zu tun: alle Dateien liegen schon im Container '$cname'$(if ($zuw) { ' und sind schon zugewiesen' })." }

    $warn = @()
    $wieder = @($dateien | Where-Object { $vorhanden.ContainsKey($_.datei) } | ForEach-Object { $_.datei })
    if ($wieder.Count) { $warn += "Schon im Container, wird wiederverwendet (nicht ersetzt): $($wieder -join ', '). Neues Motiv unter neuem Dateinamen hochladen." }
    $warn += "Wirksam erst nach Veroeffentlichen im Designer."
    @{ vorschau = [ordered]@{ aktion = "Bilder hochladen" + $(if ($zuw) { " und zuweisen" } else { "" }); paket = "$($paket.name) v$($paket._version)"; container = $cname; umgebung = $UMGEBUNG
         dateien = @($dateien | ForEach-Object { [ordered]@{ datei = $_.datei; groesse = "$($_.breite)x$($_.hoehe)"; bytes = $_.bytes; status = $(if ($vorhanden.ContainsKey($_.datei)) { "vorhanden [$($vorhanden[$_.datei])]" } else { "neu" }) } })
         zuweisung = $(if ($zuw) { [ordered]@{ ziel = "$($a.ziel) $($zuw.name) [$($zuw.zid)]"; aenderungen = @($zuwZeilen) } } else { "(keine)" }) }
       warnungen = $warn
       fp = "$($paket._id)|$($paket._version)|$($paket._last_modified_date)|$cname|" + (@($dateien | ForEach-Object { "$($_.datei):$($_.bytes):$($_.stand)" }) -join ",") + "|$(if ($zuw) { $zuw.fp })"
       dateien = $dateien; cname = $cname; vorhanden = $vorhanden; zuw = $zuw }
  } {
    param($plan)
    $ids = @{}; foreach ($k in $plan.vorhanden.Keys) { $ids[$k] = $plan.vorhanden[$k] }
    $neu = @($plan.dateien | Where-Object { -not $plan.vorhanden.ContainsKey($_.datei) })
    $erg = [ordered]@{}
    if ($neu.Count) {
      $paket = BildPaketLesen
      New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
      $sich = Join-Path $SICHERUNG ("image_package-{0}-{1}-vorher.json" -f $paket._id, (Get-Date).ToString("yyyyMMdd-HHmmss"))
      [IO.File]::WriteAllText($sich, (JStr $paket), [Text.UTF8Encoding]::new($false))
      $basis = "$PROJEKT/api/v1/image/package/$($paket._id)"
      $wk = JObj (Blp-Send "POST" "$basis/checkout" (JStr @{ _read_token = $paket._read_token }))
      if (-not $wk._read_token) { throw "checkout des Bildpakets lieferte keine Arbeitskopie." }
      $token = $wk._read_token; $hoch = @()
      try {
        $c = @(L $wk.container | Where-Object { $_.name -eq $plan.cname })
        if ($c.Count -ne 1) { throw "Container '$($plan.cname)' fehlt in der Arbeitskopie." }
        $liste = [System.Collections.Generic.List[object]]::new(); foreach ($im in @(L $c[0].images)) { if ($null -ne $im) { $liste.Add($im) } }
        foreach ($d in $neu) {
          $gid = [guid]::NewGuid().ToString()
          $null = Blp-Bytes "PUT" "$PROJEKT/api/v1/image/${gid}?filename=$([uri]::EscapeDataString($d.datei))" ([IO.File]::ReadAllBytes($d.pfad)) "image/png"
          $hoch += $gid; $ids[$d.datei] = $gid
          $liste.Add([pscustomobject][ordered]@{ id = $gid; file = $d.datei; type = "Image" })
        }
        $c[0].images = $liste.ToArray()
        $fehler = @(L (Pruefe $wk "image/package")); if ($fehler.Count) { throw ("Pruefung: " + ($fehler -join "; ")) }
        $gesp = JObj (Blp-Send "POST" $basis (JStr $wk))
        if ($gesp._read_token) { $token = $gesp._read_token }
        $null = Blp-Send "POST" "$basis/commit" (JStr @{ _read_token = $token })
      } catch {
        $t = "$($_.Exception.Message)"
        try { $null = Blp-Send "POST" "$basis/undo" (JStr @{ _read_token = $token }); $t += " (Paket per undo verworfen)" } catch { $t += " (undo fehlgeschlagen: $($_.Exception.Message) - Paket evtl. noch ausgecheckt)" }
        $weg = 0; foreach ($gid in $hoch) { try { $null = Blp-Bytes "DELETE" "$PROJEKT/api/v1/image/$gid" $null ""; $weg++ } catch {} }
        if ($hoch.Count) { $t += " ($weg von $($hoch.Count) hochgeladenen Dateien wieder geloescht)" }
        throw $t
      }
      # Kontrolle: Eintraege im Container, Datei byte-gleich zurueck
      $nachP = BildPaketLesen; $abw = @()
      $cn = @(L $nachP.container | Where-Object { $_.name -eq $plan.cname })[0]
      foreach ($d in $neu) {
        if (@(L $cn.images | Where-Object { $_.id -eq $ids[$d.datei] }).Count -ne 1) { $abw += "$($d.datei) fehlt im Container" }
        $zurueck = Blp-Bytes "GET" "$PROJEKT/api/v1/image/$($ids[$d.datei])" $null ""
        if ([Convert]::ToBase64String($zurueck) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($d.pfad))) { $abw += "$($d.datei): Datei kommt anders zurueck ($($zurueck.Length) Bytes)" }
      }
      $erg.paket = [ordered]@{ id = $nachP._id; container = $plan.cname; versionVorher = $paket._version; versionNachher = $nachP._version
        hochgeladen = @(foreach ($d in $neu) { "$($d.datei) -> $($ids[$d.datei])" }); kontrolle = $(if ($abw.Count) { $abw } else { "Eintraege da, Dateien byte-gleich" }); sicherung = $sich }
    } else { $erg.paket = "nichts hochzuladen (alle Dateien schon im Container)" }
    if ($plan.zuw) {
      $z = JObj (Blp-Get (P "$($plan.zuw.b)/$($plan.zuw.zid)"))
      $aend = @(foreach ($pf in $plan.zuw.pfade) {
        $h = Hole $z (Segmente $pf.pfad)
        if ($h.gefunden -and $h.wert -is [System.Management.Automation.PSCustomObject]) {
          @{ pfad = "$($pf.pfad)/item_id"; wert = $ids[$pf.datei] }; @{ pfad = "$($pf.pfad)/repository_id"; wert = "" }
        } else { @{ pfad = $pf.pfad; wert = [ordered]@{ repository_id = ""; item_id = $ids[$pf.datei] } } }
      })
      try {
        $zp = AenderungPlan $plan.zuw.b $plan.zuw.zid $aend "Bilder zuweisen"
        $r = AenderungAusfuehren $plan.zuw.b $zp $aend; $r.Remove("nachher"); $r.Remove("danach")
        $erg.zuweisung = $r
      } catch {
        if ("$($_.Exception.Message)" -like "Keine Aenderung*") { $erg.zuweisung = "schon zugewiesen" }
        else { throw "Bilder sind im Paket ($((@($ids.Keys | ForEach-Object { "$_ -> $($ids[$_])" })) -join ', ')), aber die Zuweisung schlug fehl: $($_.Exception.Message) - mit blp_change nachholen." }
      }
    }
    $erg.danach = "Im Designer veroeffentlichen, erst dann sieht die Sidebar die Bilder."
    $erg
  }
} -Schreibt

Werkzeug "blp_image_remove" ("Nimmt Bilder aus einem Container des Bildpakets (zweistufig). Verweigert, solange ein Tab oder eine Kachel das Bild noch benutzt. " +
  "endgueltig = true loescht zusaetzlich die Datei im Bildspeicher (DELETE /api/v1/image/<id>, wie der Designer), sofern die ID in keinem anderen Container mehr steht. Nur in Umgebungen mit allowChanges.") @{
  bilder = @{ type = "array"; items = @{ type = "string" }; description = "item_id oder Dateiname je Bild" }
  container = @{ type = "string"; description = "Containername oder Farbe aus images.containers; noetig, wenn ein Bild in mehreren Containern steht" }
  endgueltig = @{ type = "boolean"; description = "Auch die Datei im Bildspeicher loeschen (nicht umkehrbar)" }
  freigabe = @{ type = "string" } } @("bilder") {
  param($a)
  ZweiSchritte "blp_image_remove" $a {
    if (@(L $a.bilder).Count -eq 0) { throw "bilder ist leer." }
    $paket = BildPaketLesen
    $cname = if ($a.container) { BildContainerName $paket "$($a.container)" "" } else { "" }
    $treffer = @(foreach ($x in $a.bilder) {
      $t = @(foreach ($c in @(L $paket.container)) { if (-not $cname -or $c.name -eq $cname) { foreach ($im in @(L $c.images)) { if ($im.id -eq "$x" -or $im.file -eq "$x") { [pscustomobject]@{ container = $c.name; id = $im.id; datei = $im.file } } } } })
      if ($t.Count -eq 0) { throw "Bild nicht gefunden$(if ($cname) { " in '$cname'" }): $x" }
      if ($t.Count -gt 1) { throw "Bild '$x' mehrdeutig: $(($t | ForEach-Object { "$($_.datei) [$($_.id)] in $($_.container)" }) -join '; ') - container angeben." }
      $t[0] })
    $ids = @($treffer | ForEach-Object { $_.id } | Select-Object -Unique)
    $verw = BildVerwendung $ids
    $benutzt = @(foreach ($i in $ids) { if ($verw[$i].Count) { "${i}: $($verw[$i] -join '; ')" } })
    if ($benutzt.Count) { throw "Wird noch benutzt - erst die Verweise aendern (blp_change):`n- $($benutzt -join "`n- ")" }
    $zeilen = @(foreach ($t in $treffer) {
      $sonst = @(foreach ($c in @(L $paket.container)) { foreach ($im in @(L $c.images)) { if ($im.id -eq $t.id -and -not ($c.name -eq $t.container)) { $c.name } } })
      $t | Add-Member -NotePropertyName dateiLoeschen -NotePropertyValue ([bool] $a.endgueltig -and $sonst.Count -eq 0) -Force
      [ordered]@{ container = $t.container; datei = $t.datei; id = $t.id
        datei_im_bildspeicher = $(if (-not $a.endgueltig) { "bleibt" } elseif ($sonst.Count) { "bleibt (steht noch in $($sonst -join ', '))" } else { "wird geloescht" }) } })
    @{ vorschau = [ordered]@{ aktion = "Bilder aus dem Paket nehmen"; paket = "$($paket.name) v$($paket._version)"; umgebung = $UMGEBUNG; bilder = $zeilen; verwendung = "keine (Tabs, Kacheln, Rollen geprueft)" }
       warnungen = @($(if ($a.endgueltig) { "Datei-Loeschen ist nicht umkehrbar (Sicherung des Pakets enthaelt die Bilddaten als base64)." }), "Wirksam im Client erst nach Veroeffentlichen im Designer.") | Where-Object { $_ }
       fp = "$($paket._id)|$($paket._version)|$($paket._last_modified_date)"; treffer = $treffer }
  } {
    param($plan)
    $paket = BildPaketLesen
    New-Item -ItemType Directory -Force $SICHERUNG | Out-Null
    $sich = Join-Path $SICHERUNG ("image_package-{0}-{1}-vorher.json" -f $paket._id, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    [IO.File]::WriteAllText($sich, (JStr $paket), [Text.UTF8Encoding]::new($false))
    $basis = "$PROJEKT/api/v1/image/package/$($paket._id)"
    $wk = JObj (Blp-Send "POST" "$basis/checkout" (JStr @{ _read_token = $paket._read_token }))
    if (-not $wk._read_token) { throw "checkout des Bildpakets lieferte keine Arbeitskopie." }
    $token = $wk._read_token
    try {
      foreach ($t in $plan.treffer) {
        $c = @(L $wk.container | Where-Object { $_.name -eq $t.container })
        if ($c.Count -ne 1) { throw "Container '$($t.container)' fehlt in der Arbeitskopie." }
        $vorher = @(L $c[0].images).Count
        $c[0].images = @(L $c[0].images | Where-Object { $null -ne $_ -and $_.id -ne $t.id })
        if (@(L $c[0].images).Count -ne $vorher - 1) { throw "$($t.datei) [$($t.id)] in '$($t.container)' nicht genau einmal gefunden." }
      }
      $fehler = @(L (Pruefe $wk "image/package")); if ($fehler.Count) { throw ("Pruefung: " + ($fehler -join "; ")) }
      $gesp = JObj (Blp-Send "POST" $basis (JStr $wk))
      if ($gesp._read_token) { $token = $gesp._read_token }
      $null = Blp-Send "POST" "$basis/commit" (JStr @{ _read_token = $token })
    } catch {
      $m = "$($_.Exception.Message)"
      try { $null = Blp-Send "POST" "$basis/undo" (JStr @{ _read_token = $token }); $m += " (Paket per undo verworfen)" } catch { $m += " (undo fehlgeschlagen: $($_.Exception.Message))" }
      throw $m
    }
    $geloescht = @(); $abw = @()
    foreach ($t in @($plan.treffer | Where-Object { $_.dateiLoeschen })) {
      try { $null = Blp-Bytes "DELETE" "$PROJEKT/api/v1/image/$($t.id)" $null ""; $geloescht += "$($t.datei) [$($t.id)]" } catch { $abw += "Datei $($t.datei) nicht geloescht: $($_.Exception.Message)" }
    }
    $nachP = BildPaketLesen
    foreach ($t in $plan.treffer) {
      $c = @(L $nachP.container | Where-Object { $_.name -eq $t.container })[0]
      if (@(L $c.images | Where-Object { $_.id -eq $t.id }).Count) { $abw += "$($t.datei) steht noch in '$($t.container)'" }
    }
    [ordered]@{ paket = $nachP._id; versionVorher = $paket._version; versionNachher = $nachP._version
      entfernt = @($plan.treffer | ForEach-Object { "$($_.datei) [$($_.id)] aus $($_.container)" }); dateienGeloescht = $geloescht
      kontrolle = $(if ($abw.Count) { $abw } else { "alles wie gewuenscht" }); sicherung = $sich; danach = "Im Designer veroeffentlichen." }
  }
} -Schreibt
