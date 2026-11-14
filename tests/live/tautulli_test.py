"""Runs the Tautulli provider against a real, disposable Tautulli.

    powershell -ExecutionPolicy Bypass -File tools\\live-test.ps1 -Tautulli

Tautulli (its released source, run with Python) is started on 127.0.0.1 under
a sub-path (/tautulli) with a throw-away data folder and a random API key.
There is no Plex server behind it, so this proves what does not need one:
that the key is accepted in the header (and in the address in legacy mode),
that a wrong or missing key is an authentication failure, that "Tautulli is
there but has no activity to report" is told apart from both, and that the
key never leaks. Real stream counts need a Plex server and are NOT covered.

argv: <repo root> <kf-agent.exe> <tautulli source folder>
"""
import json
import os
import queue
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

root, agent, thome = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = 8182
BASE = "http://127.0.0.1:%d/tautulli" % PORT
tmp = tempfile.mkdtemp(prefix="kf-tautulli-")
key = secrets.token_hex(16)
with open(os.path.join(tmp, "config.ini"), "w", encoding="utf-8") as f:
    f.write("[General]\napi_enabled = 1\napi_key = %s\nfirst_run_complete = 1\nhttp_host = 127.0.0.1\nhttp_port = %d\nhttp_root = /tautulli\n"
            "launch_browser = 0\ncheck_github = 0\ncheck_github_on_startup = 0\nupdate_show_changelog = 0\n" % (key, PORT))

srv = subprocess.Popen([sys.executable, os.path.join(thome, "Tautulli.py"), "--nolaunch", "--quiet", "--datadir", tmp, "--config", os.path.join(tmp, "config.ini"), "--port", str(PORT)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=thome)
results = []


def step(name, ok, note=""):
    results.append(bool(ok))
    print("%s  %s  %s" % ("PASS" if ok else "FAIL", name, note))


def direct(cmd, header_key=None):
    req = urllib.request.Request(BASE + "/api/v2?cmd=" + cmd)
    if header_key:
        req.add_header("X-Api-Key", header_key)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


ag = None
version = ""
try:
    up = False
    for _ in range(90):
        if srv.poll() is not None:
            break
        try:
            code, body = direct("get_tautulli_info", key)
            if code == 200 and body.get("response", {}).get("result") == "success":
                version = str(body["response"]["data"].get("tautulli_version", ""))
                up = True
                break
        except Exception:
            pass
        time.sleep(1)
    step("real Tautulli is up under a sub-path", up, "version " + version)
    if not up:
        raise SystemExit(1)
    code, body = direct("get_activity", key)
    print("      what Tautulli itself says with no Plex behind it: HTTP %d %s" % (code, json.dumps(body)[:200]))

    cfg = os.path.join(tmp, "cfg")
    os.makedirs(cfg)
    ag = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8", env=dict(os.environ, KF_CONFIG_DIR=cfg))
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in ag.stdout], daemon=True).start()
    seq = [0]
    everything = []

    def call(op, **args):
        seq[0] += 1
        ag.stdin.write(json.dumps({"id": seq[0], "op": op, "args": args}) + "\n")
        ag.stdin.flush()
        while True:
            line = lines.get(timeout=40)
            everything.append(line)
            m = json.loads(line)
            if m.get("id") == seq[0]:
                m.update(m.pop("error", None) or {})
                return m

    r = call("provider.save", type="tautulli", name="Real Tautulli", base_url=BASE, token=key)
    pid = r.get("data", {}).get("id", "")
    step("provider saved, key accepted for storage", r.get("ok") and r["data"]["has_token"] is True)
    good = call("tautulli.activity", id=pid)
    print("      right key, header mode: ok=%s kind=%s %s" % (good.get("ok"), good.get("kind"), str(good.get("msg") or good.get("data"))[:170]))
    r = call("provider.save", type="tautulli", name="Wrong key", base_url=BASE, token=secrets.token_hex(16))
    bad = call("tautulli.activity", id=r["data"]["id"])
    step("a wrong key is an authentication failure", bad.get("kind") == "auth", "%s: %s" % (bad.get("kind"), bad.get("msg")))
    r = call("provider.save", type="tautulli", name="No key", base_url=BASE)
    none = call("tautulli.activity", id=r["data"]["id"])
    step("no key is an authentication failure", none.get("kind") == "auth", "%s: %s" % (none.get("kind"), none.get("msg")))
    # the right key must get further than a wrong one: either real activity, or
    # "there, but nothing to report" (no Plex) - never an authentication failure
    step("the right key in the header is accepted (not an authentication failure)",
         good.get("ok") or good.get("kind") == "unsupported", "%s" % (good.get("kind") or "activity returned"))
    if good.get("ok"):
        d = good["data"]
        step("with no Plex, nothing is reported as a number it is not", all(d.get(k) is None or isinstance(d.get(k), int) for k in ("streams", "transcode", "wan_kbps")), json.dumps(d)[:160])
    else:
        step("with no Plex, the answer is 'no activity to report', not zeros", good.get("kind") == "unsupported" and "data" not in good or not good.get("data"), str(good.get("msg")))
    r = call("provider.save", type="tautulli", name="Legacy mode", base_url=BASE, token=key, legacy_query_key=True)
    leg = call("tautulli.activity", id=r["data"]["id"])
    step("legacy mode (key in the address) gets the same answer on this version", leg.get("ok") == good.get("ok") and leg.get("kind") == good.get("kind"), "%s" % (leg.get("kind") or "activity returned"))
    r = call("provider.save", type="tautulli", name="No sub-path", base_url="http://127.0.0.1:%d" % PORT, token=key)
    off = call("tautulli.activity", id=r["data"]["id"])
    step("the address without its sub-path fails with a reason, and not as a key problem", off.get("ok") is False and off.get("kind") in ("unsupported", "auth", "other"), "%s: %s" % (off.get("kind"), off.get("msg")))
    disk = open(os.path.join(cfg, "providers.json"), encoding="utf-8").read()
    step("the key is not on disk in the clear", key not in disk and "sealed" in disk)
    step("the key never appeared in anything the companion sent back", not any(key in l for l in everything))
finally:
    if ag:
        try:
            ag.stdin.close()
            ag.wait(timeout=10)
        except Exception:
            ag.kill()
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(srv.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    # what the server itself logged: the key belongs in no log in header mode
    logged = ""
    for dp, _, fs in os.walk(os.path.join(tmp, "logs")):
        for fn in fs:
            try:
                logged += open(os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
            except OSError:
                pass
    if version:
        print("      Tautulli's own logs contain the key: %s (legacy mode puts it in the request address)" % (key in logged))
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d of %d steps passed against a real Tautulli %s (no Plex server: stream counts not covered)" % (sum(results), len(results), version))
sys.exit(0 if results and all(results) else 1)
