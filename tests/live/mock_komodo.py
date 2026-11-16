"""A stand-in Komodo Core for tests: POST /read only, with the request shape
and headers of komodo_client (request.rs) and the list shapes of its
entities. /write and /execute are recorded so a test can prove they were
never called.

    python -I tests/live/mock_komodo.py <port> <record-file>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
KEY, SECRET = "K-mock-key-0000", "S-mock-secret-0000"

SERVERS = [
    {"id": "s1", "name": "pve-docker-1", "tags": [], "info": {"state": "Ok", "region": "rack"}},
    {"id": "s2", "name": "pve-docker-2", "tags": [], "info": {"state": "Ok", "region": "rack"}},
    {"id": "s3", "name": "nas", "tags": [], "info": {"state": "NotOk", "region": "closet"}},
]
CONTAINERS = [
    {"server_id": "s1", "name": "immich-server", "id": "a1", "image": "ghcr.io/immich-app/immich-server:release", "state": "running", "status": "Up 3 days",
     "ports": [{"IP": "0.0.0.0", "PrivatePort": 2283, "PublicPort": 2283, "Type": "tcp"}]},
    {"server_id": "s1", "name": "immich-postgres", "id": "a2", "image": "tensorchord/pgvecto-rs:pg14-v0.2.0", "state": "exited", "status": "Exited (1) 2 hours ago"},
    {"server_id": "s2", "name": "paperless", "id": "b1", "image": "ghcr.io/paperless-ngx/paperless-ngx:2.11", "state": "running", "status": "Up 9 days (healthy)"},
    {"server_id": "s2", "name": "redis", "id": "b2", "image": "redis:7", "state": "running", "status": "Up 9 days"},
]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        with open(RECORD, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "type": body.get("type")}) + "\n")
        if self.path != "/read":
            self._send(200, {})
            return
        if self.headers.get("x-api-key") != KEY or self.headers.get("x-api-secret") != SECRET:
            self._send(401, {"error": "invalid api key"})
            return
        t = body.get("type")
        if t == "GetVersion":
            self._send(200, {"version": "1.19.5"})
        elif t == "ListServers":
            self._send(200, SERVERS)
        elif t == "ListAllContainers":
            # an older Core: 2.3's name is an unknown variant, so the game must fall back
            self._send(422, {"error": "unknown variant `ListAllContainers`"})
        elif t == "ListAllDockerContainers":
            self._send(200, CONTAINERS)
        elif t == "GetContainerLog":
            p = body.get("params", {})
            if p.get("server") == "s2":
                # Komodo wants Read plus the Logs permission on the server
                self._send(500, {"error": "User does not have required permissions on this Server. Must have at least Read permissions, as well as these specific permissions: [Logs]", "trace": []})
            elif p.get("server") == "s1" and p.get("container") == "immich-server":
                self._send(200, {"stage": "Get Container Log", "command": "docker logs immich-server --tail %d" % p.get("tail", 0),
                                 "stdout": "Immich Server is listening on :2283\n", "stderr": "warn: thumbnail queue slow\n", "success": True})
            else:
                self._send(400, {"error": "no such container"})
        else:
            self._send(400, {"error": "unknown request"})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
