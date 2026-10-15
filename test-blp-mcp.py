"""Testlauf fuer den BLP-MCP-Server: startet ihn, ruft Werkzeuge nacheinander auf, zeigt gekuerzte Antworten.
   python -I test-blp-mcp.py aufrufe.json   (Liste von [name, argumente], Beispiel: beispiel-aufrufe.json); ohne Datei: nur initialize + tools/list
   Umgebungsvariable MCP_TEST_LIMIT = Zeichen je Antwort (Standard 900), MCP_ARGS = Schalter fuer den Server (z. B. -Umgebung produktiv).
   Aendernde Aufrufe paarweise: erst ohne freigabe (Vorschau), dann mit "freigabe": "$TOKEN" (= Code der letzten Vorschau).
   Stuerzt der Server ab (z. B. Syntaxfehler beim Start), werden die letzten Zeilen seiner Fehlerausgabe gezeigt.
"""
import json, os, subprocess, sys, tempfile

sys.stdout.reconfigure(encoding="utf-8")  # python -I ignoriert PYTHONIOENCODING
LIMIT = int(os.environ.get("MCP_TEST_LIMIT", "900"))
here = os.path.dirname(os.path.abspath(__file__))
calls = json.load(open(sys.argv[1], encoding="utf-8")) if len(sys.argv) > 1 else []
err = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
p = subprocess.Popen(["pwsh", "-NoProfile", "-NoLogo", "-NonInteractive", "-File", os.path.join(here, "blp-mcp.ps1")] + os.environ.get("MCP_ARGS", "").split(),
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, encoding="utf-8")


def rpc(i, method, params=None):
    msg = {"jsonrpc": "2.0", "id": i, "method": method}
    if params is not None:
        msg["params"] = params
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    line = p.stdout.readline()
    if not line:
        p.wait(timeout=30); err.seek(0)
        raise SystemExit("Server hat nichts geantwortet (abgestuerzt?). Fehlerausgabe:\n" + "\n".join(err.read().splitlines()[-15:]))
    return json.loads(line)


rpc(0, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); p.stdin.flush()
print("Werkzeuge:", [t["name"] for t in rpc(1, "tools/list")["result"]["tools"]])
last = {}
for n, (name, args) in enumerate(calls, start=2):
    # "$TOKEN" = token der letzten Vorschau
    args = json.loads(json.dumps(args).replace('"$TOKEN"', json.dumps(last.get("token", ""))))
    r = rpc(n, "tools/call", {"name": name, "arguments": args})["result"]
    txt = r["content"][0]["text"]
    try:
        d = json.loads(txt)
        if isinstance(d, dict) and "freigabe" in d: last["token"] = d["freigabe"]
    except ValueError:
        pass
    print(f"\n### {name} {json.dumps(args, ensure_ascii=False)} {'FEHLER' if r.get('isError') else 'ok'}")
    print(txt[:LIMIT] + (" ..." if len(txt) > LIMIT else ""))
p.stdin.close(); p.wait(timeout=60)
