"""KubeFactory backend plugin example (plugin API 1, docs/PLUGINS.md).

Serves the world described in world.json. Reads one JSON request per line on
stdin and writes one JSON answer per line on stdout. Anything else it prints
must go to stderr.

    python3 -I plugin.py world.json
"""
import json
import sys

WORLD = sys.argv[1] if len(sys.argv) > 1 else "world.json"


def answer(req_id, ok=True, data=None, error=""):
    sys.stdout.write(json.dumps({"id": req_id, "ok": ok, "data": data or {}, "error": error}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    op, rid = req.get("op"), req.get("id")
    if op == "hello":
        # caps: what this plugin can do. Only "logs" is used without the operator's approval.
        answer(rid, data={"name": "Static world", "api": 1, "caps": {"logs": True}})
    elif op == "state":
        with open(WORLD, encoding="utf-8") as f:
            answer(rid, data=json.load(f))
    elif op == "logs":
        name = req.get("args", {}).get("name", "")
        answer(rid, data={"text": "This is the static-world example plugin.\nNo real logs for %s.\n" % name})
    else:
        answer(rid, ok=False, error="the static world does not change")
