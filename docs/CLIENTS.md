# MCP-Clients anbinden

Der Server läuft über **stdio**: Der Client startet `pwsh` mit dem Skript und spricht über Ein- und Ausgabe mit ihm. Es gibt keinen Port und keinen Dienst. In allen Beispielen `C:\Tools\blp-mcp` durch euren Repo-Ordner ersetzen.

Gemeinsamer Aufruf:

```text
pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" [-Umgebung <name>[,<name>]] [-Config <pfad>]
```

Test und Produktiv in einem Eintrag: `-Umgebung test,produktiv`. Jedes Werkzeug hat dann den Parameter `umgebung`, ohne Angabe gilt die erste. Alternativ den Server ein zweites Mal unter anderem Namen mit `-Umgebung produktiv` eintragen.

## Claude Code

```powershell
claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" -Umgebung test,produktiv
```

Danach neue Sitzung oder `/mcp` zum Neuladen.

## Claude Desktop

Am einfachsten über das Paket `blp-mcp-<version>.mcpb` aus dem [Release](https://github.com/Herzog-GmbH/blp-mcp/releases): doppelklicken, in den Einstellungen der Erweiterung Umgebung 1 und optional Umgebung 2 eintragen, siehe [README](../README.md#c-claude-desktop-paket). Eine `config.local.json` braucht es dafür nicht.

Ohne Paket in `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "blp": {
      "command": "pwsh",
      "args": ["-NoProfile", "-NoLogo", "-NonInteractive", "-File", "C:\\Tools\\blp-mcp\\blp-mcp.ps1"]
    }
  }
}
```

Claude Desktop danach ganz beenden und neu starten.

## VS Code / GitHub Copilot (Agent-Modus)

`.vscode/mcp.json` im Arbeitsbereich oder über „MCP: Open User Configuration“:

```json
{
  "servers": {
    "blp": {
      "type": "stdio",
      "command": "pwsh",
      "args": ["-NoProfile", "-NoLogo", "-NonInteractive", "-File", "C:\\Tools\\blp-mcp\\blp-mcp.ps1"]
    }
  }
}
```

## Cursor

`%USERPROFILE%\.cursor\mcp.json`:

```json
{
  "mcpServers": {
    "blp": {
      "command": "pwsh",
      "args": ["-NoProfile", "-NoLogo", "-NonInteractive", "-File", "C:\\Tools\\blp-mcp\\blp-mcp.ps1"]
    }
  }
}
```

## Codex CLI

`%USERPROFILE%\.codex\config.toml`:

```toml
[mcp_servers.blp]
command = "pwsh"
args = ["-NoProfile", "-NoLogo", "-NonInteractive", "-File", 'C:\Tools\blp-mcp\blp-mcp.ps1']
```

## Gemini CLI

`%USERPROFILE%\.gemini\settings.json`:

```json
{
  "mcpServers": {
    "blp": {
      "command": "pwsh",
      "args": ["-NoProfile", "-NoLogo", "-NonInteractive", "-File", "C:\\Tools\\blp-mcp\\blp-mcp.ps1"]
    }
  }
}
```

## Zugangsdaten ohne DPAPI-Datei

Auf Systemen ohne Windows-DPAPI (oder wenn ihr die Datei nicht wollt) liest der Server `BLP_USER` und `BLP_PASSWORD` aus der Umgebung. Die meisten Clients haben dafür einen `env`-Block, z. B.:

```json
"blp": { "command": "pwsh", "args": ["…"], "env": { "BLP_USER": "…", "BLP_PASSWORD": "…" } }
```

Dann steht das Passwort im Klartext in der Client-Konfiguration – nur auf einem Rechner, den nur ihr benutzt, und nie in einem Repo.
