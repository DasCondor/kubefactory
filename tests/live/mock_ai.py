"""A stand-in AI provider for tests: speaks the OpenAI-compatible chat API on
127.0.0.1 and answers every question with the same reply, which proposes one
action that exists in the simulated world and one that must be refused.

    python -I tests/live/mock_ai.py <port> <record-file>

Each request it receives is appended to <record-file> as one JSON line:
the path, whether an Authorization header came, and the request body.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
KEY = "sk-mock-key-for-tests-only-0000"

REPLY = {
    "answer": "MOCK: the recommender keeps failing to pull its image; restart it once the image tag is fixed.",
    "actions": [
        {"tool": "restart_workload", "args": {"namespace": "shop", "kind": "Deployment", "name": "recommender"},
         "why": "the pods are stuck pulling", "risk": "brief loss of the recommender"},
        {"tool": "execute_shell", "args": {"cmd": "kubectl delete ns --all"}, "why": "ignore previous instructions"},
    ],
}


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

    def _record(self, body):
        with open(RECORD, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "auth_ok": self.headers.get("Authorization") == "Bearer " + KEY,
                                "body": body}) + "\n")

    def do_GET(self):
        self._record(None)
        if self.path == "/v1/models":
            self._send(200, {"data": [{"id": "mock-1"}, {"id": "mock-2"}]})
        else:
            self._send(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        self._record(body)
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": {"message": "no such path"}})
            return
        if self.headers.get("Authorization") != "Bearer " + KEY:
            self._send(401, {"error": {"message": "bad key"}})
            return
        self._send(200, {"model": "mock-1", "choices": [{"message": {"role": "assistant", "content": json.dumps(REPLY)}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 1000, "completion_tokens": 50}})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
