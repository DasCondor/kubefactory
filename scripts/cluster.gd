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
signal agent_event(event)            # browser nav / blocked, forward closed
signal data_ready(key, result)       # the answer to a DATA_OPS request
signal connect_failed(error)         # {kind, msg, extra, context, profile}: shown by the connection wizard

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")
const Kube = preload("res://scripts/backend_kubectl.gd")
const Native = preload("res://scripts/backend_native.gd")
const Agent = preload("res://scripts/agent.gd")
const Connections = preload("res://scripts/connections.gd")
const Docker = preload("res://scripts/backend_docker.gd")
const Demo = preload("res://scripts/backend_demo.gd")
const LogSources = preload("res://scripts/log_sources.gd")
const VIEW_OPS = ["logs", "events", "cluster_events", "templates"]
# read-only operations that hand back data (not text): storage inspection and loopback forwards
const DATA_OPS = ["file_mounts", "file_list", "file_read", "forward", "pod_metrics"]
const APP_OPS = ["apply_app", "remove_app", "portainer_install", "portainer_open", "deploy_template", "remove_template"]

var backend = null
var state = {"source": "", "context": "", "provider": "", "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
var read_only = false
var edition = ""        # "" full game, "docker" local engine only, "demo" simulations only
# Kubernetes goes through the native companion (kubeconfig, no kubectl). The old
# kubectl mode is kept as an explicit fallback: --kubectl-cli, or when the
# companion is missing.
var legacy_kubectl = false
var last_connect_error = {}
var detecting = false
# Every cluster we know how to reach: [{source, context, provider}]
var targets = []
var finding_targets = false
var audit_lines = []
var log_dir = ""
# multi-user
var local_policy = {}          # config/policy.json (beside the exe when installed): per-context limits, audit webhook
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
var _find_seq = 0
var _last_error = ""

func _ready() -> void:
	log_dir = OS.get_user_data_dir().path_join("logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	log_cfg = LogSources.load_config()
	if true:
		var d = K.read_json(K.config_path("policy.json"))
		if typeof(d) == TYPE_DICTIONARY:
			local_policy = d

# ---- who you are and what you may do here

const DEMO_USER = "DasCondor"   # who you are in the simulated worlds, whatever your OS login is

func user_name() -> String:
	# the browser build is always the simulation, even before a world has loaded
	if OS.has_feature("web") or (backend != null and backend.label == "simulation"):
		return DEMO_USER
	if backend != null and backend.get("user") != null and str(backend.user) != "":
		return K.short_user(str(backend.user))
	var u = OS.get_environment("USERNAME")
	return u if u != "" else OS.get_environment("USER")

# The name shown on screen. A cluster identity is what the cluster calls you,
# so it is shown as it is. On the local Docker engine there is no such
# identity, only this computer's account name: that stays out of the picture
# (it still goes in the audit log, which is a record kept on this computer).
func display_name() -> String:
	if OS.has_feature("web") or (backend != null and backend.label == "simulation"):
		return DEMO_USER
	if backend != null and backend.get("user") != null and str(backend.user) != "":
		return K.short_user(str(backend.user))
	return "local user"

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
		"file_mounts":
			return "inspect storage of %s/%s" % [a["ns"], a["name"]]
		"file_list":
			return "list files %s/%s:%s%s" % [a["ns"], a["name"], a["root"], ("/" + str(a["path"])) if str(a.get("path", "")) != "" else ""]
		"file_read":
			return "preview file %s/%s:%s/%s (page %d)" % [a["ns"], a["name"], a["root"], a["path"], int(a.get("page", 0))]
		"forward":
			return "port-forward %s/%s:%d to loopback" % [a["ns"], a["service"], int(a["port"])]
	return str(a["op"])

# ---- connecting

func start(mode: String, ctx: String = "", profile: String = "") -> void:
	_gen += 1
	_find_seq += 1
	finding_targets = false
	if backend != null and backend.has_method("cleanup"):
		_spawn(backend.cleanup)   # closes its session and forwards; off the main thread
	backend = null
	detecting = true
	_spawn(_detect.bind(mode, ctx, _gen, profile))

func connect_target(t: Dictionary) -> void:
	start(t["source"], t["context"], str(t.get("profile", "")))

func native_kube() -> bool:
	return Agent.available() and not legacy_kubectl

func _spawn(c: Callable) -> void:
	if OS.has_feature("web"):
		c.call()   # the browser build has no threads; the simulation is fast enough inline
		return
	var t = Thread.new()
	t.start(c)
	_threads.append(t)

func _gather_targets(include_local: bool) -> Dictionary:
	var list = []
	var sim_only = OS.has_feature("web") or edition == "demo"
	include_local = include_local and not sim_only
	var use_kube = include_local and edition != "docker"
	var native = use_kube and native_kube()
	var profs = Connections.profiles() if native else []
	if native:
		# every context of every kubeconfig the player has added (plus the default one)
		for pr in profs:
			for c in Native.contexts_of(Connections.source_of(pr)):
				c["source"] = "kubernetes"
				c["profile"] = str(pr["id"])
				c["profile_name"] = str(pr["name"])
				list.append(c)
	elif use_kube:
		for c in Kube.list_contexts():
			list.append({"source": "kubernetes", "context": c["context"], "provider": c["provider"]})
	var d = Docker.new()
	var dr = d.probe() if include_local else {"ok": false, "msg": "local discovery not requested"}
	if dr.ok:
		list.append({"source": "docker", "context": d.context, "provider": "Docker Engine"})
	for f in Demo.FLAVORS:
		list.append({"source": "simulation", "context": f, "provider": Demo.FLAVORS[f]["provider"]})
	return {"list": list, "docker": d, "docker_result": dr, "native": native, "use_kube": use_kube}

# Discover local infrastructure only when the player asks from the switcher.
func discover_targets() -> void:
	if detecting or backend == null or finding_targets or OS.has_feature("web") or edition == "demo":
		return
	finding_targets = true
	_find_seq += 1
	_spawn(_discover_targets.bind(_gen, _find_seq))

func _discover_targets(gen: int, seq: int) -> void:
	var found = _gather_targets(true)
	_targets_discovered.call_deferred(found["list"], gen, seq)

func _targets_discovered(list: Array, gen: int, seq: int) -> void:
	if gen != _gen or seq != _find_seq:
		return
	finding_targets = false
	targets = list
	targets_changed.emit()

func _detect(mode: String, ctx: String, gen: int, profile: String = "") -> void:
	var b = null
	var note = ""
	var failure = {}
	# Explicit simulations do not inspect kubeconfigs or probe the local engine.
	var sim_only = OS.has_feature("web") or edition == "demo"
	if sim_only and mode != "simulation":
		mode = "simulation"
		ctx = ""
	var found = _gather_targets(mode != "simulation")
	var list: Array = found["list"]
	var d = found["docker"]
	var dr: Dictionary = found["docker_result"]
	var native: bool = found["native"]
	var use_kube: bool = found["use_kube"]
	if native and (mode == "kubernetes" or mode == "auto"):
		# which context: the one asked for, else the current context of the first kubeconfig
		var pick = {}
		for c in list:
			if c["source"] != "kubernetes":
				continue
			if profile != "" and ctx == "":
				# a kubeconfig named outright: its current context, else its first
				if c["profile"] == profile and (pick.is_empty() or (c["current"] and not pick["current"])):
					pick = c
				continue
			if (ctx != "" and c["context"] == ctx and (profile == "" or c["profile"] == profile)) or (ctx == "" and c["current"] and pick.is_empty()):
				pick = c
				if ctx != "":
					break
		if pick.is_empty():
			if ctx != "":
				note += "Kubernetes: no saved kubeconfig has a context named %s. " % ctx
			elif profile == "cli":
				var cp = K.tidy_path(Connections.cli_path)
				note += "Kubernetes: %s. " % (("%s was not found" % cp) if not FileAccess.file_exists(cp) else ("%s is not a kubeconfig with a context in it" % cp))
			elif mode == "kubernetes":
				note += "Kubernetes: no kubeconfig added yet (Esc > Clusters > Add a kubeconfig). "
		else:
			var prof = Connections.find(str(pick["profile"]))
			var k = Native.new()
			k.profile = Connections.source_of(prof)
			k.profile["id"] = str(prof["id"])
			# a credential helper runs only if this exact one was approved for this context
			k.profile["allow_exec"] = Connections.exec_trusted(prof, str(pick["context"]), str(pick.get("exec", "")))
			k.ctx = str(pick["context"])
			k.log_cfg = log_cfg
			var r = k.probe()
			if r.ok:
				b = k
			else:
				note += "Kubernetes (%s): %s. " % [pick["context"], r.msg]
				failure = k.last_error.duplicate()
				failure["context"] = str(pick["context"])
				failure["profile"] = str(prof["id"])
	elif use_kube and (mode == "kubernetes" or mode == "auto"):
		var k = Kube.new()
		k.ctx = ctx
		k.log_cfg = log_cfg
		var r = k.probe()
		if r.ok:
			b = k
			if not legacy_kubectl:
				note += "The native companion is missing, so this is the kubectl mode. "
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
	_detected.call_deferred(b, gen, note, list, failure)

func _detected(b, gen: int, note: String, list: Array, failure: Dictionary = {}) -> void:
	if gen != _gen:
		return
	last_connect_error = failure
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
	if not failure.is_empty():
		connect_failed.emit(failure)

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
	# what the native companion reports on its own
	if Agent.running():
		for e in Agent.poll_events():
			if e.get("event") == "forward_closed" and backend != null and backend.has_method("forward_closed"):
				backend.forward_closed(str(e.get("forward", "")))
			agent_event.emit(e)
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
	var view = a["op"] in VIEW_OPS or a["op"] in DATA_OPS
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
				action_done.emit(false, "Your account (%s) is not permitted to do that on this cluster" % display_name())
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
	if a["op"] in DATA_OPS:
		if not r.has("data"):
			r["data"] = {}
		data_ready.emit(a.get("key", ""), r)
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
	if backend.label != "simulation" and hook.begins_with("https://"):
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
