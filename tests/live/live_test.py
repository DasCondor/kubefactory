"""Runs kf-agent against a real Kubernetes API server and reports what worked.

The server is the Kubernetes project's own kube-apiserver + etcd (envtest),
started for this run and thrown away after it. It is a control plane only: no
nodes, no controllers, no kubelet. So this proves the API paths (connect,
watch, list, apply, scale, restart, delete, cordon, drain, RBAC refusal,
presence) and cannot prove anything that needs a running container (logs,
exec, file inspection, port-forward): those are reported as expected refusals.

    powershell -ExecutionPolicy Bypass -File tools\\live-test.ps1
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import queue

root, agent, apiserver = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = tempfile.mkdtemp(prefix="kf-live-")
admin, nobody = os.path.join(tmp, "admin.yaml"), os.path.join(tmp, "nobody.yaml")

srv = subprocess.Popen([apiserver, admin, nobody], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
if srv.stdout.readline().strip() != "READY":
    print("the API server did not start")
    sys.exit(2)

ag = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put(l) for l in ag.stdout], daemon=True).start()
events = []
seq = 0


def call(op, timeout=60, **args):
    global seq
    seq += 1
    ag.stdin.write(json.dumps({"id": seq, "op": op, "args": args}) + "\n")
    ag.stdin.flush()
    while True:
        try:
            m = json.loads(lines.get(timeout=timeout))
        except queue.Empty:
            return {"ok": False, "kind": "timeout", "msg": "no answer from the companion"}
        if m.get("id") == seq:
            m.update(m.pop("error", None) or {})   # {"error": {kind, msg}} -> top level
            return m
        if "event" in m:
            events.append(m)


results = []


def step(name, r, want_ok=True, want_kind=None, check=None):
    ok = bool(r.get("ok")) == want_ok
    if ok and want_kind:
        ok = r.get("kind") == want_kind
    note = ""
    if ok and check:
        try:
            got = check(r.get("data"))
            ok = got is True
            note = "" if ok else "unexpected: %s" % (got,)
        except Exception as e:  # a wrong shape is a failure, not a crash
            ok, note = False, "check raised %r" % e
    if not r.get("ok"):
        note = (note + " " if note else "") + "[%s] %s" % (r.get("kind"), str(r.get("msg"))[:110])
    results.append((ok, name, note))
    print("%s  %s  %s" % ("PASS" if ok else "FAIL", name, note))
    return r


def items(session, kind, ns=None):
    d = call("kube.list", session=session).get("data") or {}
    return [i for i in d.get("items") or [] if i.get("kind") == kind and (ns is None or i["metadata"].get("namespace") == ns)]


def named(session, kind, ns, name):
    for i in items(session, kind, ns):
        if i["metadata"]["name"] == name:
            return i
    return None


try:
    r = step("inspect kubeconfig", call("kubeconfig.inspect", path=admin), check=lambda d: len(d["contexts"]) == 1 or d)
    text = json.dumps(r)
    step("inspection carries no key or certificate data", {"ok": "BEGIN " not in text and "client-key-data" not in text})
    r = step("connect (client certificate)", call("kube.connect", path=admin, context="", allow_exec=False))
    s = (r.get("data") or {}).get("session", "")
    step("server version reported", {"ok": "1.32" in json.dumps(r.get("data"))})
    step("permission check: may create deployments", call("kube.can", session=s, verb="create", group="apps", resource="Deployment", subresource="", namespace="shop"), check=lambda d: d.get("allowed") is True or d)
    step("start watches", call("kube.watch", session=s, namespace="", nodes=True))
    step("create namespace", call("kube.ensure_namespace", session=s, namespace="shop"))
    step("server-side apply: sample workloads", call("kube.apply", session=s, namespace="shop", yaml=open(os.path.join(root, "tools", "dev", "sample-workloads.yaml"), encoding="utf-8").read(), timeout=90))
    step("server-side apply: a Node and a Pod", call("kube.apply", session=s, namespace="shop", yaml="apiVersion: v1\nkind: Node\nmetadata:\n  name: test-node\n---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: lonely\n  namespace: shop\nspec:\n  containers:\n  - name: app\n    image: nginx:1.27\n    volumeMounts:\n    - name: data\n      mountPath: /data\n  volumes:\n  - name: data\n    emptyDir: {}\n"))
    import time
    time.sleep(2.0)   # let the informers see it
    step("the watch cache shows the applied deployments", {"ok": True}, check=lambda _: len(items(s, "Deployment", "shop")) >= 4 or len(items(s, "Deployment", "shop")))
    step("scale to 5", call("kube.scale", session=s, kind="Deployment", namespace="shop", name="frontend", replicas=5))
    time.sleep(1.0)
    step("  the server now says 5", {"ok": True}, check=lambda _: named(s, "Deployment", "shop", "frontend")["spec"]["replicas"] == 5 or named(s, "Deployment", "shop", "frontend")["spec"]["replicas"])
    step("scale by -2 (relative)", call("kube.scale", session=s, kind="Deployment", namespace="shop", name="frontend", delta=-2))
    time.sleep(1.0)
    step("  the server now says 3", {"ok": True}, check=lambda _: named(s, "Deployment", "shop", "frontend")["spec"]["replicas"] == 3 or named(s, "Deployment", "shop", "frontend")["spec"]["replicas"])
    step("rolling restart", call("kube.restart", session=s, kind="Deployment", namespace="shop", name="frontend"))
    time.sleep(1.0)
    step("  restart annotation is on the pod template", {"ok": True}, check=lambda _: "kubectl.kubernetes.io/restartedAt" in json.dumps(named(s, "Deployment", "shop", "frontend")["spec"]["template"]["metadata"]) or "annotation missing")
    step("create a deployment", call("kube.create_deployment", session=s, namespace="shop", name="kf-live", image="nginx:1.27", replicas=2))
    step("create a secret", call("kube.create_secret", session=s, namespace="shop", name="app-db", key="password", value="not-a-real-password"))
    step("delete the deployment", call("kube.delete", session=s, kind="Deployment", namespace="shop", name="kf-live"))
    time.sleep(1.0)
    step("  it is gone", {"ok": named(s, "Deployment", "shop", "kf-live") is None})
    step("deleting something already gone is not an error", call("kube.delete", session=s, kind="Deployment", namespace="shop", name="never-existed"))
    step("cordon the node", call("kube.cordon", session=s, node="test-node", on=True))
    time.sleep(1.0)
    step("  the node is unschedulable", {"ok": True}, check=lambda _: named(s, "Node", None, "test-node")["spec"].get("unschedulable") is True or "not cordoned")
    step("drain the node (nothing on it)", call("kube.drain", session=s, node="test-node", timeout=120))
    step("uncordon the node", call("kube.cordon", session=s, node="test-node", on=False))
    step("events for a pod", call("kube.events", session=s, namespace="shop", name="lonely"))
    step("storage: mounts of a pod", call("files.mounts", session=s, namespace="shop", pod="lonely"), check=lambda d: any(m.get("path") == "/data" for m in d.get("mounts", [])) or d)
    step("storage: listing a pod that is not running is refused", call("files.list", session=s, namespace="shop", pod="lonely", container="app", root="/data", path=""), want_ok=False)
    step("storage: leaving the volume is refused", call("files.list", session=s, namespace="shop", pod="lonely", container="app", root="/data", path="../etc"), want_ok=False, want_kind="invalid")
    r = call("kube.logs", session=s, namespace="shop", pod="lonely", container="", tail=50)
    print("      logs answer:", json.dumps(r)[:300])
    step("logs of a pod with no node: nothing is invented", {"ok": (not r.get("ok")) or (r.get("data") or {}).get("text", "") == ""})
    step("delete the pod", call("kube.delete", session=s, kind="pod", namespace="shop", name="lonely"))
    step("multi-user manifest applies", call("kube.apply", session=s, namespace="kubefactory", yaml=open(os.path.join(root, "deploy", "kubefactory.yaml"), encoding="utf-8").read(), timeout=90))
    step("presence heartbeat", call("kube.presence", session=s, lease="kf-test-lease", user="DasCondor", holder="DasCondor", pos="0,0,0", tool="scanner"))
    step("action feed post", call("kube.post_event", session=s, lease="kf-test-lease", user="DasCondor", msg="live test", ok=True))
    step("remove sample workloads", call("kube.delete_manifest", session=s, namespace="shop", yaml=open(os.path.join(root, "tools", "dev", "sample-workloads.yaml"), encoding="utf-8").read(), timeout=90))
    step("disconnect", call("kube.disconnect", session=s))
    # a user who is signed in and allowed nothing
    r = step("connect as a user with no permissions", call("kube.connect", path=nobody, context="", allow_exec=False))
    s2 = (r.get("data") or {}).get("session", "")
    step("  permission check says no", call("kube.can", session=s2, verb="delete", group="", resource="pods", subresource="", namespace="shop"), check=lambda d: d.get("allowed") is False or d)
    step("  scaling is refused as a permission problem", call("kube.scale", session=s2, kind="Deployment", namespace="shop", name="frontend", replicas=1), want_ok=False, want_kind="rbac")
    step("  applying is refused as a permission problem", call("kube.apply", session=s2, namespace="shop", yaml="apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: nope\n"), want_ok=False, want_kind="rbac")
finally:
    try:
        ag.stdin.close()
        ag.wait(timeout=10)
    except Exception:
        ag.kill()
    # envtest cannot signal its children on Windows, so the whole tree is ended here
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(srv.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for f in (admin, nobody):
        try:
            os.remove(f)
        except OSError:
            pass
    try:
        os.rmdir(tmp)
    except OSError:
        pass

bad = [r for r in results if not r[0]]
print("\n%d of %d steps passed against a real kube-apiserver (control plane only)" % (len(results) - len(bad), len(results)))
sys.exit(1 if bad else 0)
