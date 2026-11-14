"""Runs kf-agent against a real cluster with running containers (kind, in Docker).

    powershell -ExecutionPolicy Bypass -File tools\\dev-cluster.ps1      (creates it)
    powershell -ExecutionPolicy Bypass -File tools\\live-test.ps1 -Kind

This covers what the control-plane-only test cannot: logs of a running
container, reading real files through the storage inspection, a port-forward
that really carries HTTP, usage figures, and draining a node that has pods on
it. It only ever touches the disposable cluster "kind-kubefactory" and the
namespace it creates for itself, which it deletes afterwards.

argv: <repo root> <kf-agent.exe> [<kubeconfig>]
"""
import base64
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request

root, agent = sys.argv[1], sys.argv[2]
kubeconfig = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.expanduser("~"), ".kube", "config")
CTX = "kind-kubefactory"
NS = "kf-live-test"

ag = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put(l) for l in ag.stdout], daemon=True).start()
seq = [0]
results = []


def call(op, timeout=90, **args):
    seq[0] += 1
    ag.stdin.write(json.dumps({"id": seq[0], "op": op, "args": args}) + "\n")
    ag.stdin.flush()
    end = time.time() + timeout
    while True:
        try:
            m = json.loads(lines.get(timeout=max(end - time.time(), 0.1)))
        except queue.Empty:
            return {"ok": False, "kind": "timeout", "msg": "no answer from the companion"}
        if m.get("id") == seq[0]:
            m.update(m.pop("error", None) or {})
            return m


def step(name, ok, note=""):
    results.append(bool(ok))
    print("%s  %s  %s" % ("PASS" if ok else "FAIL", name, str(note)[:200]))


def items(s, kind, ns=None):
    d = call("kube.list", session=s).get("data") or {}
    return [i for i in d.get("items") or [] if i.get("kind") == kind and (ns is None or i["metadata"].get("namespace") == ns)]


def wait_for(fn, seconds=150):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(2)
    return None


MANIFEST = """apiVersion: v1
kind: Pod
metadata:
  name: files
  namespace: %(ns)s
  labels: {app: files}
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "mkdir -p /data/sub && echo hello-from-a-real-volume > /data/hello.txt && echo nested > /data/sub/deep.txt && ln -s /etc /data/escape && ln -s /etc/hostname /data/linkfile && i=0; while true; do i=$((i+1)); echo \\"line $i from a real container\\"; sleep 1; done"]
    volumeMounts:
    - {name: data, mountPath: /data}
  volumes:
  - {name: data, emptyDir: {}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: %(ns)s
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: %(ns)s
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 80}]
""" % {"ns": NS}

s = ""
try:
    r = call("kube.connect", path=kubeconfig, context=CTX, allow_exec=False)
    s = (r.get("data") or {}).get("session", "")
    step("connect to the kind cluster (no kubectl)", r.get("ok"), r.get("msg", ""))
    if not s:
        raise SystemExit(1)
    call("kube.watch", session=s, namespace="", nodes=True)
    nodes = wait_for(lambda: [n for n in items(s, "Node")] or None, 30) or []
    step("nodes are listed and ready", len(nodes) >= 2, "%d nodes" % len(nodes))
    call("kube.ensure_namespace", session=s, namespace=NS)
    step("apply a pod with a volume, a 3-replica deployment and a service", call("kube.apply", session=s, namespace=NS, yaml=MANIFEST).get("ok"))

    def running():
        ps = items(s, "Pod", NS)
        ok = [p for p in ps if p.get("status", {}).get("phase") == "Running" and all(c.get("ready") for c in p["status"].get("containerStatuses", []))]
        return ok if len(ok) >= 4 else None
    pods = wait_for(running, 240)
    step("pods reach Running (images pulled, containers started)", pods is not None, "%d running" % len(pods or []))

    # ---- logs of a running container
    time.sleep(3)
    r = call("kube.logs", session=s, namespace=NS, pod="files", container="app", tail=20)
    text = (r.get("data") or {}).get("text", "")
    step("logs: real lines from a running container", r.get("ok") and "from a real container" in text, text.strip().splitlines()[-1] if text else r.get("msg"))

    # ---- storage inspection on a real volume
    r = call("files.mounts", session=s, namespace=NS, pod="files")
    mounts = (r.get("data") or {}).get("mounts", [])
    data = [m for m in mounts if m.get("path") == "/data"]
    token = [m for m in mounts if "serviceaccount" in m.get("path", "")]
    step("storage: the volume and the token volume are both listed", bool(data) and bool(token), [m["path"] for m in mounts])
    step("storage: the token volume is marked as never readable", bool(token) and token[0].get("readable") is False)
    r = call("files.list", session=s, namespace=NS, pod="files", container="app", root="/data", path="")
    names = sorted(e["name"] for e in (r.get("data") or {}).get("entries", []))
    step("storage: a real folder listing (links shown as links)", r.get("ok") and names == ["escape", "hello.txt", "linkfile", "sub"], names or r.get("msg"))
    r = call("files.read", session=s, namespace=NS, pod="files", container="app", root="/data", path="hello.txt", page=0)
    def content(rr):
        try:
            return base64.b64decode((rr.get("data") or {}).get("data", "")).decode("utf-8", "replace")
        except Exception:
            return ""
    step("storage: a real file's contents", r.get("ok") and content(r).strip() == "hello-from-a-real-volume", content(r).strip() if r.get("ok") else r.get("msg"))
    r = call("files.read", session=s, namespace=NS, pod="files", container="app", root="/data", path="sub/deep.txt", page=0)
    step("storage: a file in a sub-folder", r.get("ok") and content(r).strip() == "nested", content(r).strip())
    r = call("files.list", session=s, namespace=NS, pod="files", container="app", root="/data", path="../etc")
    step("storage: leaving the volume with .. is refused", r.get("ok") is False and r.get("kind") == "invalid", r.get("msg"))
    r = call("files.list", session=s, namespace=NS, pod="files", container="app", root="/data", path="escape")
    step("storage: a symlinked folder that leaves the volume is not followed", r.get("ok") is False, "%s: %s" % (r.get("kind"), r.get("msg")))
    r = call("files.read", session=s, namespace=NS, pod="files", container="app", root="/data", path="linkfile", page=0)
    step("storage: a symlinked file that points outside the volume is not read", r.get("ok") is False and r.get("kind") == "invalid", "%s: %s" % (r.get("kind"), r.get("msg")))
    r = call("files.read", session=s, namespace=NS, pod="files", container="app", root="/data", path="nothing-here.txt", page=0)
    step("storage: a file that is not there is reported as missing", r.get("ok") is False and r.get("kind") == "notfound", "%s: %s" % (r.get("kind"), r.get("msg")))
    r = call("files.read", session=s, namespace=NS, pod="files", container="app", root="/data", path="escape/passwd", page=0)
    step("storage: a file reached through that symlink is refused", r.get("ok") is False, "%s: %s" % (r.get("kind"), r.get("msg")))
    if token:
        r = call("files.list", session=s, namespace=NS, pod="files", container="app", root=token[0]["path"], path="")
        r2 = call("files.read", session=s, namespace=NS, pod="files", container="app", root=token[0]["path"], path="token", page=0)
        step("storage: the service-account token is never read", r2.get("ok") is False and "eyJ" not in json.dumps([r, r2]), "%s: %s" % (r2.get("kind"), r2.get("msg")))
    r = call("files.list", session=s, namespace=NS, pod="files", container="app", root="/etc", path="")
    step("storage: a path that is not a mounted volume is refused", r.get("ok") is False and r.get("kind") == "invalid", r.get("msg"))

    # ---- port-forward that really carries HTTP
    r = call("kube.forward", session=s, namespace=NS, service="web", port=80)
    fw = r.get("data") or {}
    url = ("http://%s/" % fw["address"]) if fw.get("address") else ""
    page = ""
    if url:
        try:
            page = urllib.request.urlopen(url, timeout=10).read().decode("utf-8", "replace")
        except Exception as e:
            page = "ERR %r" % e
    step("port-forward: nginx answers through a loopback port", r.get("ok") and "nginx" in page.lower() and "127.0.0.1" in url, url or r.get("msg"))
    if fw.get("forward") or fw.get("id"):
        call("kube.forward_stop", session=s, forward=fw.get("forward") or fw.get("id"))

    # ---- usage figures
    r = call("kube.pod_metrics", session=s, namespace=NS, pod="files")
    if r.get("ok"):
        d = r["data"]
        step("usage: CPU and memory of a running pod from the metrics API", d.get("mem_bytes", 0) > 0, "cpu %.4f cores, mem %.1f MiB" % (d.get("cpu_cores", 0), d.get("mem_bytes", 0) / 1048576.0))
    else:
        step("usage: no metrics API here, and that is said plainly (nothing invented)", r.get("kind") == "unsupported", r.get("msg"))

    # ---- scale and restart, with real pods following
    step("scale the deployment to 4", call("kube.scale", session=s, kind="Deployment", namespace=NS, name="web", replicas=4).get("ok"))
    grown = wait_for(lambda: len([p for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-") and p.get("status", {}).get("phase") == "Running"]) >= 4 or None, 120)
    step("  a fourth pod really starts", grown)
    before = sorted(p["metadata"]["name"] for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-"))
    step("rolling restart", call("kube.restart", session=s, kind="Deployment", namespace=NS, name="web").get("ok"))

    def replaced():
        now = [p for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-") and p.get("status", {}).get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")]
        return len(now) >= 4 and not (set(p["metadata"]["name"] for p in now) & set(before))
    step("  every pod is replaced by a new one", wait_for(replaced, 240))

    # ---- drain a node that has pods on it
    by_node = {}
    for p in items(s, "Pod", NS):
        if p["metadata"]["name"].startswith("web-"):
            by_node.setdefault(p["spec"].get("nodeName", ""), []).append(p["metadata"]["name"])
    workers = [n["metadata"]["name"] for n in items(s, "Node") if "control-plane" not in n["metadata"]["name"]]
    victim = next((n for n in workers if by_node.get(n)), workers[0] if workers else "")
    r = call("kube.drain", session=s, node=victim, timeout=240)
    step("drain a worker that is running pods", r.get("ok"), "%s had %d of the pods; %s" % (victim, len(by_node.get(victim, [])), r.get("msg", "") or (r.get("data") or {}).get("msg", "")))

    def moved():
        ps = [p for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-") and not p["metadata"].get("deletionTimestamp")]
        return len(ps) >= 4 and all(p["spec"].get("nodeName") != victim and p.get("status", {}).get("phase") == "Running" for p in ps)
    step("  its pods are evicted and running elsewhere", wait_for(moved, 240))
    node = next((n for n in items(s, "Node") if n["metadata"]["name"] == victim), {})
    step("  the node is left cordoned", node.get("spec", {}).get("unschedulable") is True)
    step("uncordon it", call("kube.cordon", session=s, node=victim, on=False).get("ok"))

    # ---- delete a pod and watch its replacement
    one = next(p["metadata"]["name"] for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-"))
    step("delete one pod", call("kube.delete", session=s, kind="pod", namespace=NS, name=one).get("ok"))
    step("  the deployment brings up a replacement", wait_for(lambda: (lambda ps: len(ps) >= 4 and one not in [p["metadata"]["name"] for p in ps])(
        [p for p in items(s, "Pod", NS) if p["metadata"]["name"].startswith("web-") and p.get("status", {}).get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")]), 180))
finally:
    if s:
        r = call("kube.delete_manifest", session=s, namespace=NS, yaml=MANIFEST + "---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n" % NS, timeout=120)
        print("cleanup: test namespace removed:", r.get("ok"), r.get("msg", "")[:120])
        call("kube.disconnect", session=s)
    try:
        ag.stdin.close()
        ag.wait(timeout=15)
    except Exception:
        ag.kill()

print("\n%d of %d steps passed against a real cluster with running containers (kind)" % (sum(results), len(results)))
sys.exit(0 if results and all(results) else 1)
