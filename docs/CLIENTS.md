# MCP-Clients anbinden

Der Server läuft über **stdio**: Der Client startet `pwsh` mit dem Skript und spricht über Ein- und Ausgabe mit ihm. Es gibt keinen Port und keinen Dienst. In allen Beispielen `C:\Tools\blp-mcp` durch euren Repo-Ordner ersetzen.

Gemeinsamer Aufruf:

```text
pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" [-Umgebung <name>] [-Config <pfad>]
```

Für eine zweite Umgebung (z. B. Produktiv, nur lesen) den Server ein zweites Mal unter anderem Namen eintragen und `-Umgebung produktiv` anhängen.

## Claude Code

```powershell
claude mcp add blp --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1"
claude mcp add blp-prod --scope user -- pwsh -NoProfile -NoLogo -NonInteractive -File "C:\Tools\blp-mcp\blp-mcp.ps1" -Umgebung produktiv
```

Danach neue Sitzung oder `/mcp` zum Neuladen.

## Claude Desktop

`%APPDATA%\Claude\claude_desktop_config.json`:

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
