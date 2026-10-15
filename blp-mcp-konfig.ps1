# blp-mcp-konfig.ps1 - Konfiguration und Zugangsdaten des BLP-MCP-Servers.
# Wird von blp-mcp.ps1 und Set-BlpCredential.ps1 per Dot-Sourcing eingebunden.
#
# Reihenfolge fuer die Konfigurationsdatei: -Config, dann $env:BLP_MCP_CONFIG, dann config.local.json neben dem Skript.
# Aufbau: siehe config.example.json. Relative Pfade gelten relativ zur Konfigurationsdatei.

function KonfigPfad([string] $Pfad) {
  if ($Pfad) { return $Pfad }
  if ($env:BLP_MCP_CONFIG) { return $env:BLP_MCP_CONFIG }
  Join-Path $PSScriptRoot "config.local.json"
}

# Pfad aus der Konfiguration aufloesen: Umgebungsvariablen (%LOCALAPPDATA%), ~ und relativ zur Konfigurationsdatei.
function KonfigDatei([string] $wert, [string] $basis) {
  if (-not $wert) { return $null }
  $w = [Environment]::ExpandEnvironmentVariables($wert)
  if ($w.StartsWith("~")) { $w = Join-Path $HOME $w.Substring(1).TrimStart('\', '/') }
  if (-not [IO.Path]::IsPathRooted($w)) { $w = Join-Path $basis $w }
  [IO.Path]::GetFullPath($w)
}

# -OhneProjekt: projectId darf noch fehlen (Set-BlpCredential.ps1 zeigt die vorhandenen Projekte erst nach der Anmeldung).
function Lade-Konfig([string] $Pfad, [string] $Umgebung, [switch] $OhneProjekt) {
  $datei = KonfigPfad $Pfad
  if (-not (Test-Path -LiteralPath $datei -PathType Leaf)) {
    throw "Keine Konfiguration gefunden: $datei. Vorlage config.example.json nach config.local.json kopieren und ausfuellen (oder -Config bzw. BLP_MCP_CONFIG setzen)."
  }
  try { $c = Get-Content -LiteralPath $datei -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
  catch { throw "Konfiguration $datei ist kein gueltiges JSON: $($_.Exception.Message)" }
  $basis = Split-Path -Parent ([IO.Path]::GetFullPath($datei))

  $namen = @(if ($c.environments) { $c.environments.PSObject.Properties | Where-Object { $_.Name -notlike "_*" } | ForEach-Object { $_.Name } })
  if ($namen.Count -eq 0) { throw "Konfiguration ${datei}: Abschnitt environments fehlt oder ist leer." }
  $name = if ($Umgebung) { $Umgebung } elseif ($c.defaultEnvironment) { "$($c.defaultEnvironment)" } else { $namen[0] }
  if ($name -notin $namen) { throw "Umgebung '$name' fehlt in $datei (vorhanden: $($namen -join ', '))." }
  $u = $c.environments.$name
  foreach ($f in @("authUrl", "projectUrl", "clientUrl") + $(if ($OhneProjekt) { @() } else { @("projectId") })) {
    if (-not "$($u.$f)" -or "$($u.$f)" -like "*HIER_*") { throw "Umgebung '$name': $f fehlt oder ist noch ein Platzhalter ($datei)." }
  }

  # Nur echtes true zaehlt ("false" als Text waere als [bool] wahr).
  $skip = if ($null -ne $u.skipCertificateCheck) { $u.skipCertificateCheck -eq $true } else { $c.skipCertificateCheck -eq $true }
  $daten = if ($c.dataDir) { KonfigDatei "$($c.dataDir)" $basis } else {
    Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }) "blp-mcp" }
  $bilder = $c.images
  $container = @{}
  if ($bilder -and $bilder.containers) {
    foreach ($p in $bilder.containers.PSObject.Properties) { if ($p.Name -notlike "_*" -and "$($p.Value)") { $container[$p.Name] = "$($p.Value)" } }
  }

  [pscustomobject]@{
    datei          = $datei
    name           = $name
    label          = $(if ($u.label) { "$($u.label)" } else { $name })
    authUrl        = "$($u.authUrl)".TrimEnd('/')
    projectUrl     = "$($u.projectUrl)".TrimEnd('/')
    clientUrl      = "$($u.clientUrl)".TrimEnd('/')
    projectId      = "$($u.projectId)"
    credentialFile = KonfigDatei "$($u.credentialFile)" $basis
    aendernErlaubt = ($u.allowChanges -eq $true)
    tls            = $(if ($skip) { @{ SkipCertificateCheck = $true } } else { @{} })
    clientSystemId = $(if ($c.clientSystemId) { "$($c.clientSystemId)" } else { "IoSidebarWebClient" })
    organisation   = "$($c.organization)"
    hinweise       = "$($c.extraInstructions)"
    datenOrdner    = $daten
    bildPaket      = $(if ($bilder -and $bilder.package) { "$($bilder.package)" } else { "Default" })
    symbolOrdner   = $(if ($bilder) { KonfigDatei "$($bilder.iconDir)" $basis } else { $null })
    bildContainer  = $container
  }
}

# Benutzer und Passwort: BLP_USER/BLP_PASSWORD (z. B. im env-Block des MCP-Clients), sonst die DPAPI-Datei der Umgebung.
function Zugangsdaten($k) {
  if (-not $k) { throw "Keine Konfiguration." }
  if ($env:BLP_USER -and $env:BLP_PASSWORD) { return @{ user = $env:BLP_USER; password = $env:BLP_PASSWORD } }
  if (-not $k.credentialFile) { throw "Keine Zugangsdaten: credentialFile fehlt bei Umgebung '$($k.name)' (oder BLP_USER und BLP_PASSWORD setzen)." }
  if (-not (Test-Path -LiteralPath $k.credentialFile)) { throw "Keine Zugangsdaten ($($k.credentialFile)). Einmalig hinterlegen: .\Set-BlpCredential.ps1 -Umgebung $($k.name)" }
  $cred = Import-CliXml -LiteralPath $k.credentialFile
  @{ user = $cred.UserName; password = $cred.GetNetworkCredential().Password }
}
