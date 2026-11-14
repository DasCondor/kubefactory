"""Runs the Grafana provider against a real, disposable Grafana.

    powershell -ExecutionPolicy Bypass -File tools\\live-test.ps1 -Grafana

Grafana OSS is started on 127.0.0.1 under a reverse-proxy style sub-path
(/grafana) with a throw-away data folder and a random admin password, given a
Viewer service account, a token and one dashboard, and then the companion is
driven against it. Everything is deleted afterwards.

argv: <repo root> <kf-agent.exe> <grafana home> [<godot exe> <shots dir>]
With the last two, the game's own provider panels are run against it as well.
"""
import base64
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

root, agent, ghome = sys.argv[1], sys.argv[2], sys.argv[3]
game = sys.argv[4:6] if len(sys.argv) >= 6 else None
PORT = 3111
BASE = "http://127.0.0.1:%d/grafana" % PORT
tmp = tempfile.mkdtemp(prefix="kf-grafana-")
admin_pw = secrets.token_urlsafe(18)

env = dict(os.environ, GF_PATHS_DATA=os.path.join(tmp, "data"), GF_PATHS_LOGS=os.path.join(tmp, "logs"), GF_PATHS_PLUGINS=os.path.join(tmp, "plugins"),
           GF_SERVER_HTTP_ADDR="127.0.0.1", GF_SERVER_HTTP_PORT=str(PORT), GF_SERVER_ROOT_URL=BASE + "/", GF_SERVER_SERVE_FROM_SUB_PATH="true",
           GF_SECURITY_ADMIN_PASSWORD=admin_pw, GF_ANALYTICS_REPORTING_ENABLED="false", GF_ANALYTICS_CHECK_FOR_UPDATES="false",
           GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES="false", GF_LOG_MODE="file")
for d in ("data", "logs", "plugins"):
    os.makedirs(os.path.join(tmp, d))      # Grafana does not create its data folder itself
exe = os.path.join(ghome, "bin", "grafana.exe")
srv = subprocess.Popen([exe, "server", "--homepath", ghome], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ghome)

results = []


def step(name, ok, note=""):
    results.append(ok)
    print("%s  %s  %s" % ("PASS" if ok else "FAIL", name, note))


def api(method, path, body=None, auth=True, follow=True):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(("admin:" + admin_pw).encode()).decode())
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    with opener.open(req, timeout=15) as r:
        raw = r.read()
        try:
            return r.status, json.loads(raw or b"{}")
        except ValueError:
            return r.status, {}            # a page, not JSON


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


ag = None
try:
    version = ""
    for _ in range(120):
        try:
            version = api("GET", "/api/health", auth=False)[1].get("version", "")
            break
        except Exception:
            if srv.poll() is not None:
                break                      # it exited: no point waiting
            time.sleep(1)
    step("real Grafana is up under a sub-path", version != "", "version " + version)
    if not version:
        raise SystemExit(1)
    sa = api("POST", "/api/serviceaccounts", {"name": "kubefactory-test", "role": "Viewer"})[1]
    token = api("POST", "/api/serviceaccounts/%d/tokens" % sa["id"], {"name": "kf"})[1]["key"]
    api("POST", "/api/dashboards/db", {"overwrite": True, "dashboard": {
        "uid": "containers", "title": "Containers", "schemaVersion": 39,
        "templating": {"list": [{"name": "namespace", "type": "textbox", "query": "shop"}]},
        "panels": [
            {"id": 1, "title": "CPU by container", "type": "timeseries", "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}},
            {"id": 2, "title": "Memory", "type": "row", "collapsed": True, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 8},
             "panels": [{"id": 3, "title": "Working set", "type": "gauge", "gridPos": {"h": 8, "w": 12, "x": 0, "y": 9}}]},
            {"id": 4, "title": "Network I/O", "type": "timeseries", "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}}]}})
    step("service account (Viewer), token and a dashboard created", token.startswith("glsa_"))

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

    r = call("provider.save", type="grafana", name="Real Grafana", base_url=BASE + "/", token=token)
    pid = r.get("data", {}).get("id", "")
    step("provider saved, token accepted for storage", r.get("ok") and r["data"]["has_token"] is True)
    r = call("provider.test", id=pid)
    step("test: recognised as Grafana %s, token accepted" % version, r.get("ok") and r["data"]["version"] == version and r["data"]["token"] == "accepted", str(r.get("msg", "")))
    r = call("grafana.dashboards", id=pid, query="")
    ds = r.get("data", {}).get("dashboards", [])
    step("dashboard search finds the dashboard", any(d["uid"] == "containers" for d in ds), str(r.get("msg", "")))
    r = call("grafana.dashboards", id=pid, query="no-such-dashboard")
    step("a search with no match is empty, not an error", r.get("ok") and r["data"]["dashboards"] == [])
    r = call("grafana.panels", id=pid, uid="containers")
    ps = r.get("data", {}).get("panels", [])
    step("panels listed, the collapsed row's panel included, the row itself not", [p["id"] for p in ps] == [1, 3, 4] and ps[1]["row"] == "Memory", str(ps)[:160])
    step("the dashboard's variable is offered", r.get("data", {}).get("variables") == ["namespace"])
    r = call("grafana.link", id=pid, uid="containers", panel=3, **{"from": "now-6h", "to": "now", "vars": {"namespace": "shop"}})
    link = r.get("data", {}).get("url", "")
    step("panel link is under the sub-path and carries no credential", link.startswith(BASE + "/d-solo/containers/") and token not in link and "auth" not in link.lower(), link)
    # what that link does for someone who has not signed in: Grafana's own sign-in, not data
    try:
        code = api("GET", link[len(BASE):], auth=False, follow=False)[0]
    except urllib.error.HTTPError as e:
        code = e.code
    step("the link without a sign-in gets Grafana's sign-in redirect, not the panel", code in (302, 401), "HTTP %d" % code)
    try:
        code = api("GET", link[len(BASE):], auth=True)[0]
    except urllib.error.HTTPError as e:
        code = e.code
    step("the same link for a signed-in user is served", code == 200, "HTTP %d" % code)

    r = call("provider.save", type="grafana", name="Wrong token", base_url=BASE, token="glsa_this_is_not_a_real_token")
    r2 = call("grafana.dashboards", id=r["data"]["id"])
    step("a wrong token is an authentication failure", r2.get("kind") == "auth", "%s: %s" % (r2.get("kind"), r2.get("msg")))
    r = call("provider.save", type="grafana", name="No token", base_url=BASE)
    r2 = call("grafana.dashboards", id=r["data"]["id"])
    step("no token is an authentication failure", r2.get("kind") == "auth", "%s: %s" % (r2.get("kind"), r2.get("msg")))
    r = call("provider.save", type="grafana", name="No sub-path", base_url="http://127.0.0.1:%d" % PORT, token=token)
    nid = r["data"]["id"]
    r2 = call("provider.test", id=nid)
    if r2.get("ok"):
        # Grafana served from a sub-path also answers its API at the root. Then the
        # address has to work all the way: dashboards listed, and links that Grafana serves.
        r3 = call("grafana.dashboards", id=nid)
        r4 = call("grafana.link", id=nid, uid="containers", panel=3)
        nolink = r4.get("data", {}).get("url", "")
        try:
            code = api("GET", nolink[len("http://127.0.0.1:%d" % PORT):].replace("/grafana", "", 0), auth=True)[0] if nolink else 0
            code = urllib.request.build_opener().open(urllib.request.Request(nolink, headers={"Authorization": "Basic " + base64.b64encode(("admin:" + admin_pw).encode()).decode()}), timeout=15).status
        except urllib.error.HTTPError as e:
            code = e.code
        step("the address without its sub-path: Grafana answers there too, and it works end to end",
             r3.get("ok") and any(d["uid"] == "containers" for d in r3["data"]["dashboards"]) and code == 200,
             "dashboards %s, panel link HTTP %s" % (r3.get("ok"), code))
    else:
        step("the address without its sub-path is refused with a reason", r2.get("kind") is not None, "%s: %s" % (r2.get("kind"), r2.get("msg")))
    disk = open(os.path.join(cfg, "providers.json"), encoding="utf-8").read()
    step("the token is not on disk in the clear", token not in disk and "sealed" in disk)
    step("the token never appeared in anything the companion sent back", not any(token in l for l in everything))

    if game:
        shots = game[1]
        log = open(shots + ".log", "w")
        g = subprocess.Popen([game[0], "--path", root, "--", "--demo=media", "--gfx=enhanced", "--providershots=%s,http://127.0.0.1:%d" % (shots, PORT)],
                             env=dict(os.environ, KF_CONFIG_DIR=os.path.join(tmp, "cfg-game"), KF_TEST_GRAFANA_TOKEN=token, KF_TEST_TAUTULLI_KEY="none-there-is-no-tautulli"),
                             stdout=log, stderr=subprocess.STDOUT)
        try:
            g.wait(timeout=240)
        except subprocess.TimeoutExpired:
            g.kill()
        log.close()
        out = open(shots + ".log", encoding="utf-8", errors="replace").read()
        step("the game's panels ran against it without a script error", "SCRIPT ERROR" not in out and "prov: grafana test" in out)
        step("the token is not in the game's output", token not in out)
finally:
    if ag:
        try:
            ag.stdin.close()
            ag.wait(timeout=10)
        except Exception:
            ag.kill()
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(srv.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d of %d steps passed against a real Grafana %s" % (sum(results), len(results), version))
sys.exit(0 if all(results) else 1)
