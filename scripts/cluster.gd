extends Node
# Owns the active data source (kubectl / docker / simulation), polls it on
# worker threads and hands results back to the main thread as signals.
# Also keeps the list of clusters you can switch to, and the audit log.

signal state_updated(state)
signal action_done(ok, msg)
signal action_finished(action, result)
signal peers_updated(peers)
signal feed_event(user, msg, ok)
signal logs_ready(key, text)
signal source_changed(label, note)
signal targets_changed()

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")
const Kube = preload("res://scripts/backend_kubectl.gd")
const Docker = preload("res://scripts/backend_docker.gd")
const Demo = preload("res://scripts/backend_demo.gd")
const LogSources = preload("res://scripts/log_sources.gd")
const VIEW_OPS = ["logs", "events", "cluster_events", "templates"]
const APP_OPS = ["apply_app", "remove_app", "portainer_install", "portainer_open", "deploy_template", "remove_template"]

var backend = null
var state = {"source": "", "context": "", "provider": "", "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
var read_only = false
var detecting = false
# Every cluster we know how to reach: [{source, context, provider}]
var targets = []
var audit_lines = []
var log_dir = ""
# multi-user
var local_policy = {}          # policy.json next to play.bat: per-context limits, audit webhook
var peers = []                 # other players on this cluster right now
var presence_info = Callable() # set by main: returns {pos, tool, doing}
var _ptimer = 0.0
var _pbusy = false
var _seen_events = {}
var _joined_at = 0.0
var log_cfg = {}
# result of the most recent log read: {provider, ok, ms}
var last_link = {}

var _threads = []
var _fetching = false
var _timer = 0.0
var _gen = 0
var _last_error = ""

func _ready() -> void:
	log_dir = OS.get_user_data_dir().path_join("logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	log_cfg = LogSources.load_config()
	if true:
		var d = K.read_json(K.data_path("policy.json"))
		if typeof(d) == TYPE_DICTIONARY:
			local_policy = d

# ---- who you are and what you may do here

func user_name() -> String:
	if backend != null and backend.get("user") != null and str(backend.user) != "":
		return K.short_user(str(backend.user))
	var u = OS.get_environment("USERNAME")
	return u if u != "" else OS.get_environment("USER")

# Highest tool tier allowed on this cluster: the cluster's own policy (if the
# admin installed one) and any local per-context rule, whichever is stricter.
func max_tier(ns: String = "") -> int:
	var limit = 5
	var pol = state.get("policy", {})
	if typeof(pol) == TYPE_DICTIONARY and not pol.is_empty():
		limit = K.policy_max_tier(pol, str(state.get("user", "")), state.get("groups", []))
		if ns != "" and ns in pol.get("protected_namespaces", []):
			limit = mini(limit, int(pol.get("protected_max_tier", 1)))
	for rule in local_policy.get("contexts", []):
		if str(state.get("context", "")).to_lower().contains(str(rule.get("match", "\n")).to_lower()):
			limit = mini(limit, int(rule.get("max_tier", 5)))
	return limit

func confirm_tier() -> int:
	var t = 5
	var pol = state.get("policy", {})
	if typeof(pol) == TYPE_DICTIONARY and pol.has("confirm_tier"):
		t = int(pol["confirm_tier"])
	for rule in local_policy.get("contexts", []):
		if str(state.get("context", "")).to_lower().contains(str(rule.get("match", "\n")).to_lower()) and rule.has("confirm_tier"):
			t = mini(t, int(rule["confirm_tier"]))
	return t

# ---- audit log: every action taken through the game, on screen and on disk

func audit(msg: String) -> void:
	var line = "%s  [%s/%s]  %s  %s" % [Time.get_datetime_string_from_system(false, true),
		state.get("source", "-") if backend != null else "-", state.get("context", "-") if backend != null else "-", user_name(), msg]
	audit_lines.append(line)
	if audit_lines.size() > 1000:
		audit_lines = audit_lines.slice(audit_lines.size() - 1000)
	var path = log_dir.path_join("audit-%s.log" % Time.get_date_string_from_system())
	var f = FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(line)
		f.close()

static func describe(a: Dictionary) -> String:
	match a["op"]:
		"scale":
			return "scale %s %s/%s to %d replicas" % [a["kind"], a["ns"], a["name"], a["replicas"]]
		"delete_pod":
			return "delete pod %s/%s" % [a["ns"], a["name"]]
		"restart":
			return "restart %s %s/%s" % [a["kind"], a["ns"], a.get("pod", a["name"])]
		"delete_workload":
			return "delete %s %s/%s" % [a["kind"], a["ns"], a["name"]]
		"create":
			return "create deployment %s/%s image=%s replicas=%d" % [a["ns"], a["name"], a["image"], a["replicas"]]
		"cordon":
			return "%s node %s" % ["cordon" if a["on"] else "uncordon", a["node"]]
		"drain":
			return "drain node %s" % a["node"]
		"logs":
			return "view logs %s/%s %s%s" % [a["ns"], a["name"], a.get("container", ""), " (previous)" if a.get("previous", false) else ""]
		"events":
			return "view events %s/%s" % [a["ns"], a["name"]]
		"apply_app":
			return "deploy app setup %s into %s" % [a["id"], a["ns"]]
		"remove_app":
			return "remove app setup %s from %s" % [a["id"], a["ns"]]
		"portainer_install":
			return "install Portainer"
		"portainer_open":
			return "open Portainer UI"
		"deploy_template":
			return "deploy Portainer template '%s' (%s) as %s/%s" % [a["template"].get("title", ""), a["template"].get("image", ""), a["ns"], a["name"]]
		"remove_template":
			return "remove installed app %s/%s" % [a["ns"], a["name"]]
		"templates":
			return "browse app list %s" % a.get("catalog", {}).get("url", "")
		"scale_by":
			return "scale %s %s/%s by %+d" % [a["kind"], a["ns"], a["name"], int(a["delta"])]
		"cluster_events":
			return "view cluster events %s" % (a.get("ns", "") if a.get("ns", "") != "" else "(all namespaces)")
	return str(a["op"])

# ---- connecting

func start(mode: String, ctx: String = "") -> void:
	_gen += 1
	if backend != null and backend.has_method("cleanup"):
		backend.cleanup()
	backend = null
	detecting = true
	_spawn(_detect.bind(mode, ctx, _gen))

func connect_target(t: Dictionary) -> void:
	start(t["source"], t["context"])

func _spawn(c: Callable) -> void:
	if OS.has_feature("web"):
		c.call()   # the browser build has no threads; the simulation is fast enough inline
		return
	var t = Thread.new()
	t.start(c)
	_threads.append(t)

func _detect(mode: String, ctx: String, gen: int) -> void:
	var b = null
	var note = ""
	var list = []
	var web = OS.has_feature("web")   # no kubectl or docker in a browser
	for c in ([] if web else Kube.list_contexts()):
		list.append({"source": "kubernetes", "context": c["context"], "provider": c["provider"]})
	var d = Docker.new()
	var dr = {"ok": false, "msg": "not available in the browser"} if web else d.probe()
	if dr.ok:
		list.append({"source": "docker", "context": d.context, "provider": "Docker Engine"})
	for f in Demo.FLAVORS:
		list.append({"source": "simulation", "context": f, "provider": Demo.FLAVORS[f]["provider"]})
	if mode == "kubernetes" or mode == "auto":
		var k = Kube.new()
		k.ctx = ctx
		k.log_cfg = log_cfg
		var r = k.probe()
		if r.ok:
			b = k
		else:
			note += "Kubernetes: %s. " % r.msg
	if b == null and (mode == "docker" or mode == "auto"):
		if dr.ok:
			b = d
		else:
			note += "Docker: %s. " % dr.msg
	if b == null:
		b = Demo.new(ctx if mode == "simulation" else "helmsman-sim")
		if mode != "simulation":
			note += "Running the built-in simulation."
	_detected.call_deferred(b, gen, note, list)

func _detected(b, gen: int, note: String, list: Array) -> void:
	if gen != _gen:
		return
	backend = b
	detecting = false
	targets = list
	_timer = 999.0
	_last_error = ""
	peers = []
	_seen_events = {}
	if b.get("policy") != null:
		state["policy"] = b.policy
		state["user"] = b.user
		state["groups"] = b.groups
		state["scoped_ns"] = b.scoped_ns
		state["multiuser"] = b.presence_ok
	_joined_at = Time.get_unix_time_from_system()
	_ptimer = 2.0
	peers_updated.emit(peers)
	state = {"source": b.label, "context": b.context, "provider": "", "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	audit("connected to %s %s. %s" % [b.label, b.context, note])
	source_changed.emit(b.label, note)
	targets_changed.emit()

func cap(op: String) -> bool:
	if op == "scale_by":
		op = "scale"
	if op in APP_OPS:
		return backend != null
	return backend != null and backend.caps.get(op, false)

func _process(delta: float) -> void:
	for i in range(_threads.size() - 1, -1, -1):
		if not _threads[i].is_alive():
			_threads[i].wait_to_finish()
			_threads.remove_at(i)
	if backend == null:
		return
	_timer += delta
	if _timer >= backend.poll_interval and not _fetching:
		_timer = 0.0
		_fetching = true
		_spawn(_fetch.bind(backend, _gen))
	# presence heartbeat: announce where we are, learn who else is here
	_ptimer += delta
	if _ptimer >= 4.0 and not _pbusy and backend.has_method("presence") and backend.presence_ok:
		_ptimer = 0.0
		_pbusy = true
		var info = presence_info.call() if presence_info.is_valid() else {}
		_spawn(_presence.bind(backend, info, _gen))

func _presence(b, info: Dictionary, gen: int) -> void:
	var r = b.presence(info)
	_presence_done.call_deferred(r, gen)

func _presence_done(r: Dictionary, gen: int) -> void:
	_pbusy = false
	if gen != _gen or not r.get("ok", false):
		return
	var before = {}
	for p in peers:
		before[p["id"]] = true
	peers = r["peers"]
	for p in peers:
		if not before.has(p["id"]):
			feed_event.emit(p["user"], "%s joined this factory" % p["user"], true)
	peers_updated.emit(peers)
	for e in r["events"]:
		if _seen_events.has(e["id"]):
			continue
		_seen_events[e["id"]] = true
		# only show what other people did since we arrived
		if e["time"] >= _joined_at - 5.0 and e["user"] != user_name():
			feed_event.emit(e["user"], e["msg"], e["ok"])

func _post_event(b, msg: String, ok: bool) -> void:
	b.post_event(msg, ok)

func _webhook(url: String, body: String) -> void:
	# webhook URLs usually embed a token, so the URL is passed out of sight too
	K.curl(["-s", "-m", "8", "-X", "POST", "-H", "Content-Type: application/json", "-d", body], [["url", url]])

func _fetch(b, gen: int) -> void:
	var st = b.fetch()
	_fetched.call_deferred(st, gen)

func _fetched(st: Dictionary, gen: int) -> void:
	_fetching = false
	if gen != _gen:
		return
	if st.get("failed", false):
		# keep showing the last good picture, just surface the error
		state["error"] = st.get("error", "fetch failed")
	else:
		state = st
	if state["error"] != _last_error:
		_last_error = state["error"]
		if _last_error != "":
			audit("ERROR polling cluster: " + _last_error)
	state_updated.emit(state)

func act(a: Dictionary) -> void:
	if backend == null:
		action_done.emit(false, "No data source connected yet")
		return
	var view = a["op"] in VIEW_OPS
	if not view:
		if read_only:
			audit("BLOCKED (read-only): " + describe(a))
			action_done.emit(false, "Read-only mode is on (Esc menu to change)")
			return
		if a["op"] == "deploy_template":
			var problem = Apps.template_problem(a["template"]) if typeof(a.get("template")) == TYPE_DICTIONARY else "it is malformed"
			if problem != "":
				audit("BLOCKED (unsafe template): " + problem)
				action_done.emit(false, "Refused: that template is not safe to build because " + problem)
				return
		# guard rail 1: the tool-tier policy (cluster policy + local per-context rules)
		var tier = K.tier_of(a, state)
		var limit = max_tier(str(a.get("ns", "")))
		if tier > limit:
			audit("BLOCKED (policy, MK.%d > MK.%d): %s" % [tier, limit, describe(a)])
			var why = "this namespace is protected" if limit < max_tier() else "your limit on this cluster is MK.%d" % limit
			action_done.emit(false, "Policy: that is an MK.%d action and %s" % [tier, why])
			return
		# guard rail 2: what your account is actually permitted to do
		if not cap(a["op"]):
			if backend.label == "kubernetes":
				audit("BLOCKED (no cluster permission): " + describe(a))
				action_done.emit(false, "Your account (%s) is not permitted to do that on this cluster" % user_name())
			else:
				action_done.emit(false, "Not supported by the %s source" % backend.label)
			return
	if not a.get("quiet", false):
		audit(describe(a))
	_spawn(_run_action.bind(backend, a, _gen))

func _run_action(b, a: Dictionary, gen: int) -> void:
	var t0 = Time.get_ticks_msec()
	var r = b.run_action(a)
	r["ms"] = Time.get_ticks_msec() - t0
	_action_finished.call_deferred(a, r, gen)

func _action_finished(a: Dictionary, r: Dictionary, gen: int) -> void:
	if gen != _gen:
		return
	if a["op"] in VIEW_OPS:
		last_link = {"provider": a.get("provider", "kube"), "ok": r.ok, "ms": r["ms"]}
		logs_ready.emit(a.get("key", ""), r.get("text", r.get("msg", "")))
		return
	audit("  -> %s: %s" % ["ok" if r.ok else "FAILED", r.msg])
	# share it: the cluster's action feed (other players see it) and the optional webhook
	var summary = "%s: %s -> %s" % [user_name(), describe(a), "ok" if r.ok else "FAILED: " + str(r.msg)]
	if backend.has_method("post_event") and backend.presence_ok:
		_spawn(_post_event.bind(backend, summary, r.ok))
	var hook = str(local_policy.get("audit_webhook", ""))
	if hook.begins_with("https://"):
		_spawn(_webhook.bind(hook, JSON.stringify({"text": summary, "user": user_name(), "source": state["source"],
			"context": state["context"], "action": describe(a), "ok": r.ok, "result": str(r.msg), "tier": K.tier_of(a, state),
			"time": Time.get_datetime_string_from_system(true) + "Z"})))
	if r.ok and r.has("open"):
		OS.shell_open(r["open"])
	action_finished.emit(a, r)
	action_done.emit(r.ok, r.msg)
	_timer = backend.poll_interval - 0.25

func _exit_tree() -> void:
	if backend != null and backend.has_method("cleanup"):
		backend.cleanup()
	for t in _threads:
		t.wait_to_finish()
