<#
.SYNOPSIS
  Hinterlegt die BLP-Zugangsdaten fuer eine Umgebung verschluesselt und prueft die Anmeldung.

.DESCRIPTION
  Liest config.local.json, fragt Benutzer und Passwort ab und legt sie in der Datei ab, die bei der
  Umgebung unter credentialFile steht. Verschluesselung ueber die Windows-DPAPI: nur dieses
  Windows-Konto auf diesem Rechner kann die Datei wieder lesen. Die Datei bekommt nur fuer das
  eigene Konto Zugriff.

  Danach meldet sich das Skript am BLP an und zeigt den Benutzer und die Projekte des Projektdienstes
  mit ihren IDs - die passende ID gehoert in config.local.json unter projectId.

  Das Konto muss im BLP-Projekt Bausteine bearbeiten duerfen. Haeufig geht das nur mit dem BLP-eigenen
  admin; Windows-Konten bekommen trotz Designer-Rechten "User is not authorized" (PRJ050000).

  Ohne Windows (kein DPAPI): statt der Datei BLP_USER und BLP_PASSWORD im env-Block des MCP-Clients setzen.

.EXAMPLE
  .\Set-BlpCredential.ps1
.EXAMPLE
  .\Set-BlpCredential.ps1 -Umgebung produktiv -UserName "DOMAIN\blp-designer"
.EXAMPLE
  .\Set-BlpCredential.ps1 -NurPruefen
#>
[CmdletBinding()]
param(
  # Umgebung aus config.local.json (Schluessel unter environments); Standard: defaultEnvironment.
  [string] $Umgebung,
  # Anmeldename; ohne Angabe wird gefragt.
  [string] $UserName,
  # Pfad zur Konfiguration; Standard: $env:BLP_MCP_CONFIG, sonst config.local.json neben diesem Skript.
  [string] $Config,
  # Nichts speichern, nur die vorhandenen Zugangsdaten pruefen.
  [switch] $NurPruefen
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Bitte mit PowerShell 7 (pwsh) starten, nicht mit Windows PowerShell 5.1." }
. (Join-Path $PSScriptRoot "blp-mcp-konfig.ps1")

$K = Lade-Konfig -Pfad $Config -Umgebung $Umgebung -OhneProjekt
$TLS = $K.tls
Write-Host "Konfiguration: $($K.datei)"
Write-Host "Umgebung:      $($K.name) ($($K.label))"

if (-not $NurPruefen) {
  if (-not $IsWindows) { throw "Die verschluesselte Datei geht nur unter Windows (DPAPI). Hier BLP_USER und BLP_PASSWORD im env-Block des MCP-Clients setzen." }
  if (-not $K.credentialFile) { throw "Bei Umgebung '$($K.name)' fehlt credentialFile in der Konfiguration." }
  if (-not $UserName) { $UserName = Read-Host "BLP-Benutzer (z. B. admin)" }
  if (-not $UserName) { throw "Kein Benutzer angegeben." }
  $secret = Read-Host "Passwort fuer '$UserName'" -AsSecureString
  $cred = [System.Management.Automation.PSCredential]::new($UserName, $secret)
  New-Item -ItemType Directory -Force (Split-Path -Parent $K.credentialFile) | Out-Null
  $cred | Export-CliXml -LiteralPath $K.credentialFile

  # Nur das eigene Konto darf die Datei lesen.
  $acl = Get-Acl -LiteralPath $K.credentialFile
  $acl.SetAccessRuleProtection($true, $false)
  $acl.Access | ForEach-Object { [void] $acl.RemoveAccessRule($_) }
  $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().Name, "FullControl", "Allow"))
  Set-Acl -LiteralPath $K.credentialFile -AclObject $acl
  Write-Host "Gespeichert:   $($K.credentialFile) (verschluesselt fuer $env:USERDOMAIN\$env:USERNAME auf $env:COMPUTERNAME)"
}

# Anmeldung pruefen
Write-Host ""
$z = Zugangsdaten $K
$body = @{ user = $z.user; password = $z.password } | ConvertTo-Json -Compress
try { $login = Invoke-RestMethod -Uri "$($K.authUrl)/api/v1/auth/login" -Method Post -ContentType "application/json" -Body $body @TLS }
catch { throw "Anmeldung an $($K.authUrl) fehlgeschlagen: $($_.Exception.Message)$(if ("$($_.Exception.Message)" -match 'SSL|certificate|Zertifikat') { ' - Zertifikat nicht vertrauenswuerdig? Siehe skipCertificateCheck in der Konfiguration.' })" }
if (-not $login.token) { throw "Anmeldung lieferte kein Token." }
$h = @{ Authorization = "Bearer $($login.token)"; "X-CLIENT-SYSTEM-ID" = $K.clientSystemId; Accept = "application/json" }
$info = Invoke-RestMethod -Uri "$($K.authUrl)/api/v2/auth/info" -Headers @{ Authorization = $h.Authorization } @TLS
Write-Host "Anmeldung ok:  $($info.user_display_name)"

try { $projekte = @((Invoke-RestMethod -Uri "$($K.projectUrl)/api/v1/project" -Headers $h @TLS).projects) }
catch { throw "Projektdienst $($K.projectUrl) antwortet nicht wie erwartet: $($_.Exception.Message) - hat das Konto Designer-Rechte?" }
Write-Host ""
Write-Host "Projekte am Projektdienst:"
foreach ($p in $projekte) { Write-Host ("  {0}  {1}{2}" -f $p._id, $p.name, $(if ($p._id -eq $K.projectId) { "   <- konfiguriert" } else { "" })) }
if ($K.projectId -and $K.projectId -notlike "*HIER_*" -and -not ($projekte | Where-Object { $_._id -eq $K.projectId })) {
  Write-Warning "projectId $($K.projectId) aus der Konfiguration gibt es hier nicht."
} elseif (-not $K.projectId -or $K.projectId -like "*HIER_*") {
  Write-Host ""
  Write-Host "Naechster Schritt: die ID des Projekts in config.local.json bei '$($K.name)' unter projectId eintragen."
}
