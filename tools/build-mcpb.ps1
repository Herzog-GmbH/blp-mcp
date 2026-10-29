<#
.SYNOPSIS
  Baut das MCPB-Paket (MCP Bundle) dist\blp-mcp-<version>.mcpb fuer Claude Desktop und die MCP Registry.

.DESCRIPTION
  Ein .mcpb ist ein ZIP mit manifest.json an der Wurzel. Hinein kommen die Skripte des Servers,
  das Startskript mcpb\mcpb-start.ps1, Set-BlpCredential.ps1, die Vorlage config.example.json,
  Symbol, LICENSE und README. Nie hinein: config.local.json und Zugangsdateien.

  Prueft vorher: Version in mcpb\manifest.json = $VERSION in blp-mcp.ps1 = Eintrag in CHANGELOG.md,
  alles, was blp-mcp.ps1 und mcpb-start.ps1 einbinden, ist im Paket, manifest.json ist gueltiges JSON.

  Das Paket ist reproduzierbar: feste Reihenfolge, feste Zeitstempel (Datum aus dem CHANGELOG),
  Zeilenenden immer CRLF. Derselbe Stand ergibt also dieselbe SHA-256. Die traegt das Skript mit
  Version und Download-URL in server.json ein (Eintrag fuer die MCP Registry).

  Windows PowerShell 5.1 und PowerShell 7 komprimieren verschieden, die Pruefsumme ist also nur
  innerhalb derselben Variante gleich. Fuer Releases PowerShell 7 (pwsh) nehmen, wie fuer den Server;
  hochgeladen wird genau die Datei, deren SHA-256 in server.json steht.

.EXAMPLE
  pwsh -NoProfile -File tools\build-mcpb.ps1
#>
[CmdletBinding()]
param(
  # Zielordner, Standard dist\ im Repo (von Git ignoriert).
  [string] $OutDir,
  # server.json nicht anfassen.
  [switch] $OhneServerJson
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Core") { Write-Warning "Windows PowerShell $($PSVersionTable.PSVersion): andere Pruefsumme als mit PowerShell 7" }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $root "dist" }
$utf8 = New-Object System.Text.UTF8Encoding $false
function Text([string] $rel) { [System.IO.File]::ReadAllText((Join-Path $root $rel), $utf8) }

# ---------- Version ----------
$manifest = Text "mcpb\manifest.json" | ConvertFrom-Json
$version = [string] $manifest.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Version in mcpb\manifest.json ungueltig: '$version'" }

$m = [regex]::Match((Text "blp-mcp.ps1"), '\$VERSION\s*=\s*"([^"]+)"')
if (-not $m.Success -or $m.Groups[1].Value -ne $version) {
  throw "`$VERSION in blp-mcp.ps1 ($($m.Groups[1].Value)) passt nicht zu manifest.json ($version)"
}
$m = [regex]::Match((Text "CHANGELOG.md"), '(?m)^## ' + [regex]::Escape($version) + '\s+\S+\s+(\d{4})-(\d{2})-(\d{2})')
if (-not $m.Success) { throw "CHANGELOG.md hat keinen Eintrag '## $version - JJJJ-MM-TT'" }
# Fester Zeitstempel fuer alle Eintraege, damit derselbe Stand dieselbe Pruefsumme ergibt.
$zeit = New-Object DateTimeOffset ([int] $m.Groups[1].Value), ([int] $m.Groups[2].Value), ([int] $m.Groups[3].Value), 12, 0, 0, ([TimeSpan]::Zero)

# ---------- Inhalt ----------
# Pfad im Paket = Quelle im Repo. Reihenfolge fest. Alles flach, so wie blp-mcp.ps1 seine Teile per $PSScriptRoot findet.
$inhalt = [ordered]@{
  "manifest.json"         = "mcpb\manifest.json"
  "icon.png"              = "mcpb\icon.png"
  "mcpb-start.ps1"        = "mcpb\mcpb-start.ps1"
  "blp-mcp.ps1"           = "blp-mcp.ps1"
  "blp-mcp-konfig.ps1"    = "blp-mcp-konfig.ps1"
  "blp-mcp-aendern.ps1"   = "blp-mcp-aendern.ps1"
  "blp-mcp-bilder.ps1"    = "blp-mcp-bilder.ps1"
  "blp-mcp-bauen.ps1"     = "blp-mcp-bauen.ps1"
  "Set-BlpCredential.ps1" = "Set-BlpCredential.ps1"
  "config.example.json"   = "config.example.json"
  "LICENSE"               = "LICENSE"
  "README.md"             = "README.md"
}

# Was die Skripte per Dot-Sourcing oder Aufruf einbinden, muss drin sein.
foreach ($q in "blp-mcp.ps1", "mcpb\mcpb-start.ps1", "Set-BlpCredential.ps1") {
  foreach ($s in [regex]::Matches((Text $q), '"((?:blp-mcp[a-z-]*|Set-BlpCredential)\.ps1)"')) {
    if (-not $inhalt.Contains($s.Groups[1].Value)) { throw "$q bindet $($s.Groups[1].Value) ein, das fehlt im Paket" }
  }
}
foreach ($ziel in $inhalt.Keys) {
  if (-not (Test-Path (Join-Path $root $inhalt[$ziel]))) { throw "Fehlt: $($inhalt[$ziel])" }
}
if ($manifest.server.entry_point -and -not $inhalt.Contains([string] $manifest.server.entry_point)) {
  throw "entry_point '$($manifest.server.entry_point)' ist nicht im Paket"
}
if ($manifest.icon -and -not $inhalt.Contains([string] $manifest.icon)) { throw "icon '$($manifest.icon)' ist nicht im Paket" }
# Jede Einstellung, die das Startskript liest, braucht ein Feld im Manifest und umgekehrt.
$envNamen = @($manifest.server.mcp_config.env.PSObject.Properties.Name)
foreach ($s in [regex]::Matches((Text "mcpb\mcpb-start.ps1"), '"(BLP_MCPB_[A-Z_]+?)(?:\$n)?"')) {
  $n = $s.Groups[1].Value
  if ($n -notin $envNamen) { throw "mcpb-start.ps1 liest $n, das steht nicht in manifest.json (server.mcp_config.env)" }
}
foreach ($p in $manifest.server.mcp_config.env.PSObject.Properties) {
  $feld = [regex]::Match([string] $p.Value, '^\$\{user_config\.([a-z0-9_]+)\}$').Groups[1].Value
  if (-not $feld -or -not $manifest.user_config.$feld) { throw "env $($p.Name) zeigt auf kein Feld in user_config" }
}

# ---------- Paket ----------
Add-Type -AssemblyName System.IO.Compression
$name = "blp-mcp-$version.mcpb"
$ziel = Join-Path $OutDir $name
[void](New-Item -ItemType Directory -Force $OutDir)
if (Test-Path $ziel) { Remove-Item $ziel -Force }

$fs = [System.IO.File]::Open($ziel, [System.IO.FileMode]::CreateNew)
try {
  $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($eintrag in $inhalt.Keys) {
      $daten = [System.IO.File]::ReadAllBytes((Join-Path $root $inhalt[$eintrag]))
      if ($eintrag -notmatch '\.png$') {
        # Zeilenenden je nach Checkout (autocrlf) verschieden; im Paket immer CRLF, sonst wechselt die Pruefsumme.
        $t = $utf8.GetString($daten).Replace("`r`n", "`n").Replace("`n", "`r`n")
        $daten = $utf8.GetBytes($t)
      }
      $e = $zip.CreateEntry($eintrag, [System.IO.Compression.CompressionLevel]::Optimal)
      $e.LastWriteTime = $zeit
      $w = $e.Open()
      try { $w.Write($daten, 0, $daten.Length) } finally { $w.Dispose() }
    }
  } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$sha = (Get-FileHash -Algorithm SHA256 $ziel).Hash.ToLowerInvariant()
$groesse = (Get-Item $ziel).Length
$url = "https://github.com/Herzog-GmbH/blp-mcp/releases/download/v$version/$name"

Write-Host "Paket:   $ziel ($([Math]::Round($groesse / 1KB)) KB, $($inhalt.Count) Dateien)"
Write-Host "SHA-256: $sha"
Write-Host "URL:     $url"

# ---------- server.json ----------
$sj = Join-Path $root "server.json"
if (-not $OhneServerJson -and (Test-Path $sj)) {
  $t = [System.IO.File]::ReadAllText($sj, $utf8)
  $neu = ([regex] '"version":\s*"[^"]*"').Replace($t, '"version": "' + $version + '"', 1)
  $neu = ([regex] '"identifier":\s*"[^"]*"').Replace($neu, '"identifier": "' + $url + '"', 1)
  $neu = ([regex] '"fileSha256":\s*"[^"]*"').Replace($neu, '"fileSha256": "' + $sha + '"', 1)
  if ($neu -ne $t) { [System.IO.File]::WriteAllText($sj, $neu, $utf8); Write-Host "server.json nachgetragen (Version, URL, SHA-256)" }
  else { Write-Host "server.json passt schon" }
}
