<#
.SYNOPSIS
  Startet blp-mcp.ps1 aus dem MCPB-Paket (Claude Desktop) mit den Einstellungen der Erweiterung.

.DESCRIPTION
  Claude Desktop reicht die Einstellungen der Erweiterung (user_config in manifest.json) als
  Umgebungsvariablen BLP_MCPB_* herein. Ein leeres oder nie gesetztes Feld kommt je nach Client
  als "" oder als unersetzter Platzhalter "${user_config....}" an; beides gilt als nicht gesetzt.
  Schalter kommen als "true" bzw. "false".

  Daraus schreibt das Skript bei jedem Start %LOCALAPPDATA%\blp-mcp\mcpb-config.json (Aufbau wie
  config.example.json, ohne Geheimnisse) und startet den Server mit allen Umgebungen daraus.
  Set-BlpCredential.ps1 findet dieselbe Datei, wenn neben ihm keine config.local.json liegt.

  Fehlt etwas (Adresse, Projekt-ID), startet der Server trotzdem und jeder Werkzeugaufruf nennt
  den Fehler. Das ist im Chat sichtbarer als ein Abbruch, der nur im Log von Claude Desktop steht.

  Zugangsdaten stehen nie in den Einstellungen. Die legt der Anwender einmal je Umgebung mit
  Set-BlpCredential.ps1 an (DPAPI), oder er waehlt eine vorhandene Zugangsdatei.
#>
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "blp-mcp-konfig.ps1")

function Wert([string] $name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($v) { $v = $v.Trim() }
  if (-not $v -or $v.StartsWith('${') -or $v -eq "undefined" -or $v -eq "null") { return $null }
  return $v
}
function Schalter([string] $name) {
  $v = Wert $name
  return [bool] ($v -and $v -match '^(true|1|ja|yes)$')
}

# Schluessel unter environments aus dem Namen: "Produktiv" -> "produktiv", "Test 2" -> "test-2".
function Schluessel([string] $name) {
  $s = $name.ToLowerInvariant().Replace([string][char]0xE4, "ae").Replace([string][char]0xF6, "oe").Replace([string][char]0xFC, "ue").Replace([string][char]0xDF, "ss")
  $s = ($s -replace '[^a-z0-9]+', '-').Trim('-')
  if ($s) { $s } else { "umgebung" }
}

# Projektdienst und Client-Dienst liegen bei vielen Installationen auf demselben Server, einen bzw.
# acht Ports ueber dem Identity-Dienst (...01, ...02, ...09). Ohne Port in der Adresse kein Vorschlag.
function Nachbar([string] $auth, [int] $plus) {
  $u = $null
  if (-not [Uri]::TryCreate($auth, [UriKind]::Absolute, [ref] $u) -or $u.IsDefaultPort) { return "" }
  "{0}://{1}:{2}" -f $u.Scheme, $u.Host, ($u.Port + $plus)
}

function Umgebung([string] $n, [string] $standardName) {
  $name = Wert "BLP_MCPB_NAME$n"; if (-not $name) { $name = $standardName }
  $auth = "$(Wert "BLP_MCPB_AUTH_URL$n")".TrimEnd('/')
  $proj = Wert "BLP_MCPB_PROJECT_URL$n"; if (-not $proj) { $proj = Nachbar $auth 1 }
  $cli = Wert "BLP_MCPB_CLIENT_URL$n"; if (-not $cli) { $cli = Nachbar $auth 8 }
  $key = Schluessel $name
  $cred = Wert "BLP_MCPB_CREDENTIAL_FILE$n"; if (-not $cred) { $cred = "%LOCALAPPDATA%\blp-mcp\blp-credential-$key.xml" }
  [pscustomobject]@{ key = $key; wert = [ordered]@{ label = $name; authUrl = $auth; projectUrl = "$proj"; clientUrl = "$cli"
    projectId = "$(Wert "BLP_MCPB_PROJECT_ID$n")"; credentialFile = $cred; allowChanges = (Schalter "BLP_MCPB_AENDERN$n") } }
}

# Umgebung 1 immer (ohne Adresse meldet der Server "authUrl fehlt"), Umgebung 2 nur mit Adresse.
$umgebungen = [ordered]@{}
$u1 = Umgebung "" "Test"
$umgebungen[$u1.key] = $u1.wert
if (Wert "BLP_MCPB_AUTH_URL2") {
  $u2 = Umgebung "2" "Produktiv"
  if ($umgebungen.Contains($u2.key)) { $u2.key = "$($u2.key)-2" }
  $umgebungen[$u2.key] = $u2.wert
}

# "weiss=Symbole hell; dunkel=Symbole dunkel" -> images.containers
$container = [ordered]@{}
foreach ($teil in "$(Wert "BLP_MCPB_BILDCONTAINER")" -split ';') {
  $kv = $teil -split '=', 2
  if ($kv.Count -eq 2 -and $kv[0].Trim() -and $kv[1].Trim()) { $container[$kv[0].Trim()] = $kv[1].Trim() }
}

$konfig = [ordered]@{
  _hinweis = "Vom Paket fuer Claude Desktop bei jedem Start aus den Einstellungen der Erweiterung geschrieben. Aenderungen hier gehen verloren; aendern in Claude Desktop unter Einstellungen > Erweiterungen."
  organization = "$(Wert "BLP_MCPB_ORGANISATION")"
  extraInstructions = "$(Wert "BLP_MCPB_HINWEISE")"
  defaultEnvironment = $u1.key
  skipCertificateCheck = (Schalter "BLP_MCPB_ZERTIFIKAT_IGNORIEREN")
  environments = $umgebungen
  images = [ordered]@{ package = "Default"; iconDir = "$(Wert "BLP_MCPB_SYMBOLORDNER")"; containers = $container }
}

# Mehrere Sitzungen starten das Paket gleichzeitig: nur schreiben, wenn sich etwas geaendert hat, und
# ueber eine Zwischendatei, damit kein Server eine halb geschriebene Datei liest.
$datei = MCPBKonfigPfad
$text = ConvertTo-Json -InputObject $konfig -Depth 10
$utf8 = [System.Text.UTF8Encoding]::new($false)
$alt = if (Test-Path -LiteralPath $datei) { [IO.File]::ReadAllText($datei, $utf8) } else { $null }
if ($alt -ne $text) {
  try {
    [void] (New-Item -ItemType Directory -Force (Split-Path -Parent $datei))
    $tmp = "$datei.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $text, $utf8)
    [IO.File]::Move($tmp, $datei, $true)
  } catch {
    [Console]::Error.WriteLine("[blp-mcp] Einstellungen nicht nach $datei geschrieben: $($_.Exception.Message)")
    if (-not (Test-Path -LiteralPath $datei)) { exit 1 }
  }
}

# Nicht an den Server weiterreichen; der liest nur die Datei.
Get-ChildItem env: | Where-Object { $_.Name -like "BLP_MCPB_*" } | ForEach-Object { Remove-Item "env:$($_.Name)" }

& (Join-Path $PSScriptRoot "blp-mcp.ps1") -Config $datei -Umgebung (@($umgebungen.Keys) -join ",")
exit $LASTEXITCODE
