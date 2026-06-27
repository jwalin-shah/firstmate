#!/usr/bin/env python3
"""
bin/fm-status-server.py — local htmx status page for firstmate.
Serves a single HTML page that auto-refreshes via htmx.
Polled every 5s, no JavaScript framework, no WebSocket.

Usage:
  bin/fm-status-server.py            # default :7777
  bin/fm-status-server.py 8888      # custom port

Open http://127.0.0.1:7777/ in a browser.

This is a small, read-only inspector. It uses bin/fm-status.sh for the
canonical status, and mm_capture_pane for the last 30 lines of each
live pane (so the captain can see what each crewmate is currently
thinking without using mm-ctl directly).
"""

import os
import subprocess
import sys
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

FM_ROOT = "/Users/jwalinshah/projects/firstmate"
STATE_DIR = f"{FM_ROOT}/state"
MINTMUX_SOCK = "/tmp/mintmux-502.sock"


def run(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def get_status():
    """Run bin/fm-status.sh, return parsed sections."""
    res = run(["bash", f"{FM_ROOT}/bin/fm-status.sh", "--full"])
    if res.returncode != 0:
        return {"raw": res.stderr or "fm-status.sh failed", "in_flight": []}

    text = res.stdout
    # Section keys in priority order; first match wins
    section_map = {
        "Services": "services",
        "In flight": "in_flight",
        "Queue": "queue",
        "Done recently": "done_recently",
        "Watcher": "watcher",
    }
    sections = {"raw": text, "services": [], "in_flight": [], "queue": [], "done_recently": [], "watcher": []}
    current = None
    for line in text.splitlines():
        if line.startswith("--- "):
            header = line.strip("- ").strip()
            for key, val in section_map.items():
                if header.startswith(key):
                    current = val
                    break
            else:
                current = None
            continue
        if current and line.strip():
            sections[current].append(line)
    return sections


def capture_pane(pane_id, max_bytes=4000):
    """Capture the last N bytes of a mintmux pane, strip TUI control codes."""
    if not pane_id:
        return ""
    res = run(["mm-ctl", "capture", "-sock=" + MINTMUX_SOCK, "-bytes", str(max_bytes), str(pane_id)], timeout=3)
    if res.returncode != 0:
        return f"(capture failed: {res.stderr.strip()})"
    raw = res.stdout

    # Strip ANSI escape codes: ESC [ ... letter
    import re
    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw)
    text = re.sub(r'\x1b\][^\x07]*\x07', '', text)  # OSC sequences
    text = re.sub(r'\x1b[()].', '', text)  # charset switches
    text = re.sub(r'[\x00-\x08\x0b-\x1f]', '', text)  # other control chars

    # Collapse runs of whitespace
    lines = []
    for line in text.splitlines():
        line = line.rstrip()
        if line.strip():
            lines.append(line)
    return "\n".join(lines[-30:])  # last 30 non-empty lines


def get_drift(quick=False):
    """Run fm-drift-check.sh --json, return parsed sections. quick=True skips slow checks."""
    cmd = ["bash", f"{FM_ROOT}/bin/fm-drift-check.sh", "--json"]
    if quick:
        cmd.append("--quick")
    res = run(cmd)
    if res.returncode != 0 and not res.stdout:
        return {"drift": False, "total_fail": -1, "sections": []}
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return {"drift": False, "total_fail": -1, "sections": [], "raw": res.stdout}


def render_drift_summary(drift):
    """Render a compact drift summary for the main status page."""
    if not drift.get("drift"):
        return '<p class="ok">Drift check not available</p>'
    total = drift.get("total_fail", 0)
    if total == 0:
        return '<p class="live">✓ No drift detected</p>'
    parts = []
    for sec in drift.get("sections", []):
        name = sec.get("section", "")
        fails = [c for c in sec.get("checks", []) if c.get("status") not in ("ok", "info")]
        if fails:
            counts = {}
            for c in fails:
                s = c.get("status", "?")
                counts[s] = counts.get(s, 0) + 1
            summary = ", ".join(f"{n} {s}" for s, n in counts.items())
            parts.append(f'<div class="stale">{name}: {summary}</div>')
    return ''.join(parts) if parts else '<p class="live">✓ Clean</p>'


def render_drift_detail(drift):
    """Render full drift detail for the /drift endpoint."""
    html = ['<h2>Drift Check</h2>']
    if not drift.get("drift"):
        html.append('<p class="error">Drift check failed to run</p>')
        return ''.join(html)
    
    total = drift.get("total_fail", 0)
    if total == 0:
        html.append('<p class="live">✓ No drift detected — all clear</p>')
    else:
        html.append(f'<p class="error">{total} drift issues found</p>')
    
    for sec in drift.get("sections", []):
        name = sec.get("section", "?")
        html.append(f'<h3>{name}</h3>')
        html.append('<table><tr><th>Status</th><th>Message</th></tr>')
        for c in sec.get("checks", []):
            status = c.get("status", "?")
            msg = c.get("msg", "")
            cls = "error" if status in ("fail","missing","shadow","atrisk") else ("stale" if status in ("warn","unknown") else "ok")
            html.append(f'<tr class="{cls}"><td>{status}</td><td>{msg}</td></tr>')
        html.append('</table>')
    html.append(f'<p><a href="/">Back to status</a></p>')
    return ''.join(html)
    """Capture the last N bytes of a mintmux pane, strip TUI control codes."""
    if not pane_id:
        return ""
    res = run(["mm-ctl", "capture", "-sock=" + MINTMUX_SOCK, "-bytes", str(max_bytes), str(pane_id)], timeout=3)
    if res.returncode != 0:
        return f"(capture failed: {res.stderr.strip()})"
    raw = res.stdout

    # Strip ANSI escape codes: ESC [ ... letter
    import re
    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw)
    text = re.sub(r'\x1b\][^\x07]*\x07', '', text)  # OSC sequences
    text = re.sub(r'\x1b[()].', '', text)  # charset switches
    text = re.sub(r'[\x00-\x08\x0b-\x1f]', '', text)  # other control chars

    # Collapse runs of whitespace
    lines = []
    for line in text.splitlines():
        line = line.rstrip()
        if line.strip():
            lines.append(line)
    return "\n".join(lines[-30:])  # last 30 non-empty lines


def render_html(sections, pane_peek=None):
    pane_peek = pane_peek or {}
    html_parts = ["""<!DOCTYPE html>
<html>
<head>
<title>firstmate status</title>
<script src="https://unpkg.com/htmx.org@1.9.10"></script>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, monospace;
         background: #0a0a0a; color: #e0e0e0; margin: 1em; }
  h1, h2, h3 { color: #88ddff; }
  .live { color: #66ff66; font-weight: bold; }
  .no-pane { color: #888; }
  .phantom { color: #ff6666; }
  pre { background: #1a1a1a; padding: 0.5em; overflow-x: auto;
        border-left: 3px solid #88ddff; white-space: pre-wrap; }
  .in-flight-row { margin: 0.5em 0; padding: 0.5em;
                  background: #1a1a1a; border-radius: 4px; }
  .pane-peek { background: #0a1a1a; padding: 0.5em; margin-top: 0.5em;
               max-height: 12em; overflow-y: auto;
               font-size: 0.85em; }
  button { background: #333; color: #e0e0e0; border: 1px solid #555;
           padding: 0.3em 0.6em; cursor: pointer; margin-left: 0.5em; }
  button:hover { background: #555; }
  details summary { cursor: pointer; color: #ffaa66; }
  .error { color: #ff6666; }
  .stale { color: #ffaa66; }
  #last-updated { color: #888; font-size: 0.85em; }
</style>
</head>
<body>
<h1>firstmate status</h1>
<div hx-get="/" hx-trigger="every 5s" hx-swap="innerHTML" hx-target="this">
"""]

    html_parts.append(f'<p id="last-updated">last update: {subprocess.run(["date", "+%Y-%m-%d %H:%M:%S"], capture_output=True, text=True).stdout.strip()}</p>')

    # Drift summary (collapsed by default)
    html_parts.append("<h2>Drift <span style='font-size:0.6em;color:#888;'>(auto-refresh 30s)</span></h2>")
    html_parts.append('<div hx-get="/drift-summary" hx-trigger="every 30s" hx-swap="innerHTML">')
    html_parts.append(render_drift_summary(get_drift(quick=True)))
    html_parts.append('</div>')

    # Services
    html_parts.append("<h2>Services</h2><pre>")
    for s in sections.get("services", []):
        html_parts.append(s + "\n")
    html_parts.append("</pre>")

    # In flight
    html_parts.append("<h2>In flight</h2>")
    for line in sections.get("in_flight", []):
        if line.strip() == "(none)":
            html_parts.append("<p>(none)</p>")
            continue
        # Parse: id kind harness mode live | last_status
        parts = line.strip().split(" | ", 1)
        meta = parts[0]
        last = parts[1] if len(parts) > 1 else ""
        tokens = meta.split()
        task_id = tokens[0] if tokens else "?"
        # Determine liveness class
        liveness = "no-pane"
        if "live" in meta:
            liveness = "live"
        elif "phantom" in meta:
            liveness = "phantom"
        # Extract pane id from meta line (look for "pane <n>")
        pane_id = None
        for tok in tokens:
            if tok.startswith("pane=") or tok.isdigit() and len(tok) < 4:
                pane_id = tok.split("=")[-1] if "=" in tok else tok
        html_parts.append(f'<div class="in-flight-row">')
        html_parts.append(f'<div><span class="{liveness}">[{liveness}]</span> <strong>{task_id}</strong> &nbsp; {meta[len(task_id):].strip()}</div>')
        html_parts.append(f'<div>last: <code>{last}</code></div>')
        # Pane peek (only for live)
        if liveness == "live" and pane_id and pane_id in pane_peek:
            html_parts.append(f'<div class="pane-peek"><pre>{pane_peek[pane_id]}</pre></div>')
        elif liveness == "live":
            html_parts.append(f'<div class="pane-peek stale">(pane content not yet captured)</div>')
        html_parts.append('</div>')

    # Queue
    html_parts.append("<h2>Queue (fm-tasks)</h2><pre>")
    for s in sections.get("queue", [])[:20]:
        html_parts.append(s + "\n")
    if len(sections.get("queue", [])) > 20:
        html_parts.append(f"... and {len(sections.get('queue', [])) - 20} more\n")
    html_parts.append("</pre>")

    # Done recently
    html_parts.append("<h2>Done recently</h2><pre>")
    for s in sections.get("done_recently", []):
        html_parts.append(s + "\n")
    html_parts.append("</pre>")

    # Watcher
    html_parts.append("<h2>Watcher</h2><pre>")
    for s in sections.get("watcher", []):
        html_parts.append(s + "\n")
    html_parts.append("</pre>")

    html_parts.append("</div></body></html>")
    return "".join(html_parts)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass  # silence

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/" or url.path == "":
            sections = get_status()
            # Find live panes and capture content
            pane_peek = {}
            for line in sections.get("in_flight", []):
                tokens = line.strip().split()
                if not tokens:
                    continue
                if "live" in line:
                    # Parse pane id from meta: tokens like "kind=ship harness=ctoken mode=direct-PR live"
                    # Need to grep the original meta line for pane=N
                    import re
                    m = re.search(r'pane=(\d+)', line)
                    if not m:
                        # Try the meta file directly
                        task_id = tokens[0]
                        meta_file = f"{STATE_DIR}/{task_id}.meta"
                        if os.path.exists(meta_file):
                            with open(meta_file) as f:
                                for ml in f:
                                    if ml.startswith("pane="):
                                        m = re.match(r'pane=(\d+)', ml)
                                        break
                    if m:
                        pane_id = m.group(1)
                        pane_peek[pane_id] = capture_pane(pane_id, max_bytes=2000)
            body = render_html(sections, pane_peek)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())
        elif url.path == "/raw":
            sections = get_status()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(sections["raw"].encode())
        elif url.path == "/drift":
            drift = get_drift(quick=False)
            body = render_drift_detail(drift)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())
        elif url.path == "/drift-summary":
            drift = get_drift(quick=True)
            body = render_drift_summary(drift)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(404)
            self.end_headers()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
    print(f"firstmate status server: http://127.0.0.1:{port}/", file=sys.stderr)
    print(f"raw:                    http://127.0.0.1:{port}/raw", file=sys.stderr)
    print(f"polling interval:       5s (via htmx every)", file=sys.stderr)
    httpd = HTTPServer(("127.0.0.1", port), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
