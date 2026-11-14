"""Stand-ins for Grafana and Tautulli, for testing the provider panels without either.

    python tests/live/mock_providers.py 8771

Grafana is served under /grafana (a reverse-proxy prefix), Tautulli under
/tautulli. The token and key below are test values that exist only here.
These are fixtures: what they return says nothing about any real server.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

GRAFANA_TOKEN = "glsa_MOCK_test_token_only"
TAUTULLI_KEY = "mock-tautulli-key-only"

DASH = {"dashboard": {"title": "Containers", "templating": {"list": [{"name": "namespace", "type": "query"}]},
                      "panels": [{"id": 1, "title": "CPU by container", "type": "timeseries"},
                                 {"id": 2, "title": "Memory", "type": "row", "panels": [{"id": 3, "title": "Working set", "type": "gauge"}]},
                                 {"id": 4, "title": "Network I/O", "type": "timeseries"}]}}
PAGE = """<!doctype html><meta charset=utf-8><title>mock</title>
<body style="margin:0;background:#111820;color:#e8eef5;font:28px system-ui;padding:40px">
<div style="color:#f4a53a;font-size:20px">MOCK GRAFANA PAGE (test fixture, not real data)</div>
<h1>%s</h1><div id=t></div><script>setInterval(()=>t.textContent=new Date().toISOString(),500)</script>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query, keep_blank_values=True)
        p = u.path
        if p == "/grafana/api/health":
            return self.send(200, {"database": "ok", "version": "11.2.0-mock"})
        if p.startswith("/grafana/api/"):
            if self.headers.get("Authorization") != "Bearer " + GRAFANA_TOKEN:
                return self.send(401, {"message": "invalid API key"})
            if p == "/grafana/api/search":
                all_d = [{"uid": "containers", "title": "Containers", "folderTitle": "Infrastructure"},
                         {"uid": "node-overview", "title": "Node overview", "folderTitle": "Infrastructure"},
                         {"uid": "media", "title": "Media server", "folderTitle": "Home"}]
                want = q.get("query", [""])[0].lower()
                return self.send(200, [d for d in all_d if want in d["title"].lower()])
            if p.startswith("/grafana/api/dashboards/uid/"):
                return self.send(200, DASH)
            return self.send(404, {"message": "not found"})
        if p.startswith("/grafana/d-solo/") or p.startswith("/grafana/d/") or p == "/grafana/":
            return self.send(200, PAGE % ("panel %s" % q.get("panelId", ["(whole dashboard)"])[0]), "text/html")
        if p == "/tautulli/api/v2":
            if self.headers.get("X-Api-Key") != TAUTULLI_KEY:
                return self.send(200, {"response": {"result": "error", "message": "Invalid apikey", "data": {}}})
            if q.get("cmd", [""])[0] != "get_activity":
                return self.send(200, {"response": {"result": "error", "message": "unknown command", "data": {}}})
            # wan_bandwidth is left out on purpose: the game must show it as unavailable, not 0
            return self.send(200, {"response": {"result": "success", "data": {
                "stream_count": "3", "stream_count_direct_play": 1, "stream_count_direct_stream": "0", "stream_count_transcode": 2,
                "total_bandwidth": 18250, "lan_bandwidth": "6200",
                "sessions": [{"user": "someone", "ip_address": "203.0.113.9", "full_title": "A Film"}]}}})
        if p == "/tautulli/":
            return self.send(200, PAGE.replace("GRAFANA", "TAUTULLI") % "home", "text/html")
        self.send(404, {"message": "not found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8771), H).serve_forever()
