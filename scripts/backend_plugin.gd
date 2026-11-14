extends RefCounted
# A backend plugin as a data source (docs/PLUGINS.md). The plugin runs as its
# own process; this speaks JSON lines with it over its stdin and stdout:
#
#   -> {"id": 1, "op": "hello", "args": {"api": 1}}
#   <- {"id": 1, "ok": true, "data": {"name": ..., "caps": {...}}}
#   -> {"id": 2, "op": "state", "args": {}}
#   <- {"id": 2, "ok": true, "data": {"nodes": [...], "pods": [...], "workloads": [...], "services": [...]}}
#   -> {"id": 3, "op": "action", "args": {"op": "restart", ...}}     only when allowed
#   -> {"id": 4, "op": "logs", "args": {"ns": ..., "name": ...}}
#
# Whatever the plugin answers is untrusted: every field is checked, coerced
# and bounded here before the world sees it, and actions go through the same
# tiers, read-only mode and confirmation as every other source, and only if
# the operator allowed this plugin to make changes.

const K = preload("res://scripts/kutil.gd")
const Plugins = preload("res://scripts/plugins.gd")

const MAX_LINE = 8 << 20
const MAX_PODS = 5000
const KNOWN_OPS = ["restart", "delete_pod", "scale", "scale_by", "cordon", "logs"]

var label = "plugin"
var poll_interval = 5.0
var caps = {"remove_image": false, "scale": false, "delete_pod": false, "restart": false, "delete_workload": false,
	"create": false, "cordon": false, "drain": false, "logs": false, "files": false}
var context = ""
var log_cfg = {}
var providers = [{"id": "kube", "name": "Plugin", "ready": true, "note": "logs from the plugin"}]
var plugin = {}
var _pid = -1
var _pipe: FileAccess = null
var _mx = Mutex.new()
var _seq = 0

func setup(p: Dictionary) -> void:
	plugin = p
	context = str(p["name"])

func probe() -> Dictionary:
	if plugin.is_empty() or plugin.get("error", "") != "":
		return {"ok": false, "msg": plugin.get("error", "no such plugin")}
	if not plugin.get("trusted", false):
		return {"ok": false, "msg": "%s is not trusted yet (Esc > Switch cluster > Plugins)" % plugin["name"]}
	var cmd: Array = plugin["command"]
	var exe = str(cmd[0])
	if exe == "python3" and OS.get_name() == "Windows":
		exe = "python"           # Windows names it python
	# a program inside the plugin folder is named relative to it
	if FileAccess.file_exists(plugin["dir"].path_join(exe)):
		exe = plugin["dir"].path_join(exe)
	var r = OS.execute_with_pipe(exe, PackedStringArray(cmd.slice(1).map(func(a): return str(a).replace("{dir}", plugin["dir"]))))
	if r.is_empty() or r.get("stdio") == null:
		return {"ok": false, "msg": "%s could not be started (%s)" % [plugin["name"], exe.get_file()]}
	_pipe = r["stdio"]
	_pid = int(r.get("pid", -1))
	var h = _request("hello", {"api": Plugins.API}, 10.0)
	if not h["ok"]:
		cleanup()
		return {"ok": false, "msg": "%s: %s" % [plugin["name"], h["msg"]]}
	var declared = h["data"].get("caps", {})
	if typeof(declared) == TYPE_DICTIONARY:
		for op in declared:
			if caps.has(op) and bool(declared[op]):
				# reading logs is harmless; anything that changes things needs the operator's say-so
				caps[op] = op == "logs" or plugin.get("actions_allowed", false)
	return {"ok": true, "msg": context}

func cleanup() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	_pipe = null

# One request, one answer line with the same id. Blocking: the cluster calls
# backends from its worker threads.
func _request(op: String, args: Dictionary, timeout: float) -> Dictionary:
	_mx.lock()
	if _pipe == null or not OS.is_process_running(_pid):
		_mx.unlock()
		return {"ok": false, "msg": "the plugin is not running", "data": {}}
	_seq += 1
	var id = _seq
	_pipe.store_line(JSON.stringify({"id": id, "op": op, "args": args}))
	_pipe.flush()
	var deadline = Time.get_ticks_msec() + int(timeout * 1000.0)
	var res = {"ok": false, "msg": "the plugin did not answer in time", "data": {}}
	while Time.get_ticks_msec() < deadline:
		var line = _pipe.get_line()
		if line == "":
			if not OS.is_process_running(_pid):
				res["msg"] = "the plugin stopped"
				break
			OS.delay_msec(5)
			continue
		if line.length() > MAX_LINE:
			res["msg"] = "the plugin's answer is too large"
			break
		var d = JSON.parse_string(line)
		if typeof(d) != TYPE_DICTIONARY or int(d.get("id", -1)) != id:
			continue          # anything else the plugin prints is ignored
		var data = d.get("data", {})
		res = {"ok": bool(d.get("ok", false)), "msg": K.tidy_text(str(d.get("error", d.get("msg", ""))).left(400)), "data": data if typeof(data) == TYPE_DICTIONARY else {}}
		break
	_mx.unlock()
	return res

func fetch() -> Dictionary:
	var r = _request("state", {}, 20.0)
	if not r["ok"]:
		return {"source": label, "context": context, "error": r["msg"], "failed": true}
	return normalize(r["data"], context)

# The plugin's state -> the shape every backend reports, checked field by field.
static func normalize(d: Dictionary, ctx: String) -> Dictionary:
	var st = {"source": "plugin", "context": ctx, "provider": "Plugin: " + ctx, "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	var s = func(x, n = 120): return str(x if x != null else "").left(n)
	for n in _list(d.get("nodes")).slice(0, 500):
		st.nodes.append({"name": s.call(n.get("name")), "ready": bool(n.get("ready", true)), "cordoned": bool(n.get("cordoned", false)),
			"roles": s.call(n.get("roles", "plugin node")), "zone": s.call(n.get("zone", "")), "itype": s.call(n.get("itype", "")), "version": s.call(n.get("version", "")),
			"cpu": _num(n.get("cpu")), "mem": _num(n.get("mem")), "cpu_req": _num(n.get("cpu_req")), "mem_req": _num(n.get("mem_req")), "created": 0.0})
	var names = st.nodes.map(func(n): return n["name"])
	for p in _list(d.get("pods")).slice(0, MAX_PODS):
		var status = s.call(p.get("status", "Running"), 40)
		var ready = bool(p.get("ready", status == "Running"))
		var node = s.call(p.get("node", ""))
		var conts = []
		for c in _list(p.get("containers")).slice(0, 20):
			conts.append({"name": s.call(c.get("name")), "image": s.call(c.get("image"), 200), "state": "running" if ready else "terminated", "reason": s.call(c.get("reason", ""), 200), "ready": ready, "restarts": int(_num(c.get("restarts")))})
		if conts.is_empty():
			conts.append({"name": s.call(p.get("name")), "image": s.call(p.get("image", ""), 200), "state": "running" if ready else "terminated", "reason": "", "ready": ready, "restarts": 0})
		st.pods.append({"uid": ctx + "/" + s.call(p.get("uid", "%s/%s" % [p.get("ns", ""), p.get("name", "")]), 200), "name": s.call(p.get("name")), "ns": s.call(p.get("ns", "default")),
			"node": node if node in names else (names[0] if not names.is_empty() else ""), "status": status, "ready": ready,
			"health": K.health_of(status, ready), "restarts": int(_num(p.get("restarts"))), "wkind": s.call(p.get("wkind", "Pod"), 40), "wname": s.call(p.get("wname", "")),
			"ip": s.call(p.get("ip", ""), 60), "created": 0.0, "labels": _labels(p.get("labels")), "containers": conts,
			"phase": "Running" if status == "Running" else ("Succeeded" if status == "Completed" else "Failed" if status in ["Error", "CrashLoopBackOff"] else "Pending"),
			"finished": 0.0, "sec": K.empty_security(), "store": K.empty_storage()})
	for w in _list(d.get("workloads")).slice(0, 2000):
		st.workloads.append({"kind": s.call(w.get("kind", "Deployment"), 40), "name": s.call(w.get("name")), "ns": s.call(w.get("ns", "default")),
			"replicas": int(_num(w.get("replicas"))), "ready": int(_num(w.get("ready"))), "image": s.call(w.get("image", ""), 200)})
	for v in _list(d.get("services")).slice(0, 2000):
		st.services.append({"name": s.call(v.get("name")), "ns": s.call(v.get("ns", "default")), "type": s.call(v.get("type", "ClusterIP"), 40),
			"ports": s.call(v.get("ports", ""), 200), "selector": _labels(v.get("selector"))})
	return st

static func _list(x) -> Array:
	return (x as Array).filter(func(e): return typeof(e) == TYPE_DICTIONARY) if typeof(x) == TYPE_ARRAY else []

static func _num(x) -> float:
	return float(x) if typeof(x) in [TYPE_INT, TYPE_FLOAT] else 0.0

static func _labels(x) -> Dictionary:
	var out = {}
	if typeof(x) == TYPE_DICTIONARY:
		for k in x.keys().slice(0, 50):
			out[str(k).left(100)] = str(x[k]).left(200)
	return out

func run_action(a: Dictionary) -> Dictionary:
	var op = str(a.get("op", ""))
	if op == "logs":
		if not caps["logs"]:
			return {"ok": false, "msg": "this plugin does not provide logs"}
		var r = _request("logs", {"ns": a.get("ns", ""), "name": a.get("name", "")}, 20.0)
		return {"ok": r["ok"], "msg": r["msg"], "text": str(r["data"].get("text", "")).left(200000) if r["ok"] else ""}
	if not op in KNOWN_OPS or not caps.get(op, false):
		return {"ok": false, "kind": "unsupported", "msg": "This plugin is not allowed to %s (Esc > Switch cluster > Plugins)." % op}
	var r2 = _request("action", a.duplicate(), 60.0)
	return {"ok": r2["ok"], "msg": r2["msg"] if r2["msg"] != "" else ("%s: done" % op)}
