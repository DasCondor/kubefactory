extends "res://scripts/backend_kubectl.gd"
# Kubernetes without kubectl: the same backend as backend_kubectl.gd, but every
# call goes through kf-agent (client-go) using a kubeconfig the player chose.
# Nothing here shells out. State comes from list+watch caches in the agent, so
# fetch() is a read of that cache rather than a round of API calls.
#
# It keeps the label "kubernetes" so the rest of the game (tools, panels, Bob,
# Porter, tiers, audit) treats it exactly like the kubectl backend.

const Agent = preload("res://scripts/agent.gd")

var native = true
var profile = {}            # {id, name, path | content, base_dir, allow_exec}
var session = ""
var server = ""
var last_error = {}         # {kind, msg, extra} of the failed connect, for the wizard
var _ns_default = ""
var _watching = false
var _forwards = {}          # "ns/service:port" -> {forward, address}

func _src() -> Dictionary:
	var a = {"context": ctx, "allow_exec": bool(profile.get("allow_exec", false))}
	for k in ["path", "content", "base_dir"]:
		if str(profile.get(k, "")) != "":
			a[k] = profile[k]
	return a

func _call(op: String, args: Dictionary = {}, timeout: float = 45.0) -> Dictionary:
	args["session"] = session
	return Agent.request(op, args, timeout)

# Every context in a kubeconfig source, with a provider guess (no connection is made).
static func contexts_of(prof: Dictionary) -> Array:
	var a = {}
	for k in ["path", "content", "base_dir"]:
		if str(prof.get(k, "")) != "":
			a[k] = prof[k]
	var r = Agent.request("kubeconfig.inspect", a, 15.0)
	var res = []
	if r["ok"]:
		for c in r["data"].get("contexts", []):
			res.append({"context": str(c["name"]), "provider": K.provider_hint(str(c["name"]), str(c.get("server", ""))),
				"current": bool(c.get("current", false)), "server": str(c.get("server", "")), "auth": str(c.get("auth", "")),
				"exec": str(c.get("exec", "")), "namespace": str(c.get("namespace", "")), "problem": str(c.get("problem", "")),
				"insecure": bool(c.get("insecure", false))})
	return res

func probe() -> Dictionary:
	var r = Agent.request("kube.connect", _src(), 30.0)
	if not r["ok"]:
		last_error = {"kind": r["kind"], "msg": r["msg"], "extra": r["extra"]}
		return {"ok": false, "msg": "%s: %s" % [Agent.kind_title(r["kind"]), r["msg"]], "kind": r["kind"]}
	var d = r["data"]
	session = str(d["session"])
	context = str(d["context"])
	ctx = context
	server = str(d.get("server", ""))
	user = str(d.get("user", ""))
	groups = d.get("groups", [])
	_ns_default = str(d.get("namespace", ""))
	provider = K.provider_hint(context, server)
	providers = LogSources.list_for(provider, context, log_cfg)
	_identify()
	var w = _call("kube.watch", {"namespace": scoped_ns, "nodes": not _nodes_forbidden}, 25.0)
	if not w["ok"]:
		last_error = {"kind": w["kind"], "msg": w["msg"], "extra": {}}
		return {"ok": false, "msg": "%s: %s" % [Agent.kind_title(w["kind"]), w["msg"]], "kind": w["kind"]}
	_watching = true
	return {"ok": true, "msg": context}

# verb + "resource[.group][/subresource]", scope ["-A"] or ["-n", ns] as the kubectl backend passes it
func _can(verb: String, resource: String, scope: Array) -> bool:
	var sub = ""
	if resource.contains("/"):
		sub = resource.get_slice("/", 1)
		resource = resource.get_slice("/", 0)
	var group = ""
	if resource.contains("."):
		group = resource.substr(resource.find(".") + 1)
		resource = resource.get_slice(".", 0)
	elif resource in ["deployments", "statefulsets", "daemonsets"]:
		group = "apps"
	var ns = str(scope[1]) if scope.size() > 1 and scope[0] == "-n" else ""
	var r = _call("kube.can", {"verb": verb, "group": group, "resource": resource, "subresource": sub, "namespace": ns}, 12.0)
	return r["ok"] and bool(r["data"].get("allowed", false))

func _identify() -> void:
	var r = _call("kube.configmap", {"namespace": "kubefactory", "name": "kubefactory-policy"}, 12.0)
	if r["ok"]:
		var p = JSON.parse_string(str(r["data"].get("data", {}).get("policy.json", "")))
		if typeof(p) == TYPE_DICTIONARY:
			policy = p
		presence_ok = policy.get("presence", true) and _can("create", "leases.coordination.k8s.io", ["-n", "kubefactory"])
	if not _can("list", "pods", ["-A"]):
		scoped_ns = _ns_default if _ns_default != "" else "default"
	_nodes_forbidden = not _can("list", "nodes", ["-A"])
	var scope = ["-n", scoped_ns] if scoped_ns != "" else ["-A"]
	caps["scale"] = _can("update", "deployments/scale", scope)
	caps["restart"] = _can("patch", "deployments", scope)
	caps["create"] = _can("create", "deployments", scope)
	caps["delete_pod"] = _can("delete", "pods", scope)
	caps["delete_workload"] = _can("delete", "deployments", scope)
	caps["cordon"] = _can("patch", "nodes", ["-A"])
	caps["drain"] = caps["cordon"] and _can("create", "pods/eviction", scope)
	caps["files"] = _can("create", "pods/exec", scope)
	caps["file_write"] = caps["files"]
	caps["forward"] = _can("create", "pods/portforward", scope)

func fetch() -> Dictionary:
	var r = _call("kube.list", {}, 20.0)
	if not r["ok"]:
		return {"source": label, "context": context, "error": "%s: %s" % [Agent.kind_title(r["kind"]), r["msg"]], "failed": true}
	var st = normalize(r["data"], context)
	if _nodes_forbidden:
		var seen = {}
		for p in st["pods"]:
			if p["node"] != "" and not seen.has(p["node"]):
				seen[p["node"]] = true
				st["nodes"].append({"name": p["node"], "ready": true, "cordoned": false, "roles": "node details hidden",
					"version": "", "zone": "", "itype": "", "cpu": 0.0, "mem": 0.0, "cpu_req": 0.0, "mem_req": 0.0, "created": 0.0})
	if st["provider"] == "":
		st["provider"] = provider
	st["user"] = user
	st["groups"] = groups
	st["policy"] = policy
	st["scoped_ns"] = scoped_ns
	st["multiuser"] = presence_ok
	st["native"] = true
	return st

static func _res(r: Dictionary, ok_msg: String = "") -> Dictionary:
	if r["ok"]:
		return {"ok": true, "msg": str(r["data"].get("msg", ok_msg))}
	return {"ok": false, "msg": "%s: %s" % [Agent.kind_title(r["kind"]), r["msg"]]}

func run_action(a: Dictionary) -> Dictionary:
	var special = _app_action(a)
	if not special.is_empty():
		return special
	if a["op"] in ["cleanup_scan", "remove_image"]:
		return {"ok": false, "kind": "unsupported", "data": {}, "msg": "Images live in each node's container runtime; the Kubernetes API does not list which ones are unused."}
	if a["op"] == "logs" and a.get("provider", "kube") != "kube":
		var lr = LogSources.fetch(a["provider"], a, log_cfg, context)
		return {"ok": lr.ok, "msg": "", "text": lr.text}
	match a["op"]:
		"export_config":
			return _call("kube.list", {}, 20.0)
		"scale":
			return _res(_call("kube.scale", {"kind": a["kind"], "namespace": a["ns"], "name": a["name"], "replicas": int(a["replicas"])}))
		"delete_pod":
			return _res(_call("kube.delete", {"kind": "pod", "namespace": a["ns"], "name": a["name"]}))
		"restart":
			return _res(_call("kube.restart", {"kind": a["kind"], "namespace": a["ns"], "name": a["name"]}))
		"delete_workload":
			return _res(_call("kube.delete", {"kind": a["kind"], "namespace": a["ns"], "name": a["name"]}))
		"create":
			return _res(_call("kube.create_deployment", {"namespace": a["ns"], "name": a["name"], "image": a["image"], "replicas": int(a["replicas"])}))
		"cordon":
			return _res(_call("kube.cordon", {"node": a["node"], "on": bool(a["on"])}))
		"drain":
			return _res(_call("kube.drain", {"node": a["node"]}, 120.0))
		"logs":
			var r = _call("kube.logs", {"namespace": a["ns"], "pod": a["name"], "container": str(a.get("container", "")),
				"tail": int(a.get("tail", 150)), "previous": bool(a.get("previous", false))})
			var text = str(r["data"].get("text", "")) if r["ok"] else "%s: %s" % [Agent.kind_title(r["kind"]), r["msg"]]
			return {"ok": r["ok"], "msg": "", "text": text if text.strip_edges() != "" else "(no log output)"}
		"events":
			var r = _call("kube.events", {"namespace": a["ns"], "name": a["name"]})
			return {"ok": r["ok"], "msg": "", "text": str(r["data"].get("text", "")) if r["ok"] else r["msg"]}
		"cluster_events":
			var r = _call("kube.events", {"namespace": str(a.get("ns", "")), "warnings": bool(a.get("warnings", false)), "wide": true})
			return {"ok": r["ok"], "msg": "", "text": str(r["data"].get("text", "")) if r["ok"] else r["msg"]}
	return {"ok": false, "msg": "unsupported action"}

func cleanup() -> void:
	if session == "":
		return
	if presence_ok:
		_call("kube.delete", {"kind": "lease", "namespace": "kubefactory", "name": _lease_name()}, 6.0)
	_call("kube.disconnect", {}, 6.0)   # also closes this session's port-forwards
	session = ""
	_forwards.clear()

func presence(info: Dictionary) -> Dictionary:
	var res = {"peers": [], "events": [], "ok": false}
	if not presence_ok:
		return res
	var r = _call("kube.presence", {"lease": _lease_name(), "user": user, "holder": K.short_user(user),
		"pos": str(info.get("pos", "")), "tool": str(info.get("tool", 0)), "doing": str(info.get("doing", ""))}, 12.0)
	if not r["ok"]:
		return res
	res["ok"] = true
	for p in r["data"].get("peers", []):
		res["peers"].append({"id": str(p["id"]), "user": K.short_user(str(p.get("user", "?"))), "pos": str(p.get("pos", "")),
			"tool": int(str(p.get("tool", "0"))), "doing": str(p.get("doing", ""))})
	for e in r["data"].get("events", []):
		res["events"].append({"id": str(e["id"]), "user": K.short_user(str(e.get("user", ""))), "msg": str(e.get("msg", "")),
			"ok": bool(e.get("ok", true)), "time": float(e.get("time", 0))})
	return res

func post_event(msg: String, ok: bool) -> void:
	if presence_ok:
		_call("kube.post_event", {"lease": _lease_name(), "user": user, "msg": msg.left(900), "ok": ok}, 10.0)

func _apply_file(ns: String, path: String, delete: bool = false) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "data": {}, "kind": "notfound", "msg": "the setup file %s is missing" % path.get_file(), "extra": {}}
	return _call("kube.delete_manifest" if delete else "kube.apply", {"namespace": ns, "yaml": FileAccess.get_file_as_string(path)}, 90.0)

func _app_action(a: Dictionary) -> Dictionary:
	match a["op"]:
		"scale_by":
			return _res(_call("kube.scale", {"kind": a["kind"], "namespace": a["ns"], "name": a["name"], "delta": int(a["delta"])}))
		"apply_app":
			var app = Apps.find(a["id"])
			if app == null:
				return {"ok": false, "msg": "unknown app"}
			_call("kube.ensure_namespace", {"namespace": a["ns"]})
			var note = ""
			if app["secret"]:
				# the password goes down the pipe to the agent: never a command line, never a file
				var s = _call("kube.create_secret", {"namespace": a["ns"], "name": "app-db", "key": "password", "value": Apps.random_password()})
				note = "  Password generated into secret app-db." if s["ok"] and s["data"].get("created", false) else "  Reusing existing secret app-db."
			var r = _apply_file(a["ns"], Apps.file_for(a["id"], "k8s"))
			return _res(r, "%s deployed to namespace %s.%s" % [app["name"], a["ns"], note])
		"remove_app":
			var r = _apply_file(a["ns"], Apps.file_for(a["id"], "k8s"), true)
			return _res(r, "%s removed from namespace %s (secret and volumes kept)" % [a["id"], a["ns"]])
		"portainer_install":
			return {"ok": false, "msg": "Installing Portainer fetches its manifest from the internet, which the native backend does not do on its own. Apply it yourself, or use the kubectl mode."}
		"portainer_open":
			var f = forward("portainer", "portainer", 9443)
			if not f["ok"]:
				return {"ok": false, "msg": f["msg"]}
			return {"ok": true, "msg": "Port-forward running: Portainer at https://%s" % f["address"], "open": "https://%s" % f["address"]}
		"deploy_template":
			var t = a["template"]
			var envinfo = Apps.template_env(t)
			_call("kube.ensure_namespace", {"namespace": a["ns"]})
			var r = _call("kube.apply", {"namespace": a["ns"], "yaml": Apps.template_manifest(t, a["name"], envinfo[0])}, 60.0)
			var note = ""
			if envinfo[1].size() > 0:
				note = "  Generated: %s (see the deployment's env)." % ", ".join(PackedStringArray(envinfo[1]))
			return _res(r, "%s deployed to namespace %s.%s" % [t.get("title", a["name"]), a["ns"], note])
		"remove_template":
			var r1 = _call("kube.delete", {"kind": "deployment", "namespace": a["ns"], "name": a["name"]})
			_call("kube.delete", {"kind": "service", "namespace": a["ns"], "name": a["name"]})
			return _res(r1, "%s removed from namespace %s" % [a["name"], a["ns"]])
		"templates":
			var r = Apps.fetch_templates(a.get("catalog", {}))
			return {"ok": r.ok, "msg": "", "text": r.text}
		# ---- new with the native backend
		"forward":
			return forward(a["ns"], a["service"], int(a["port"]))
		"pod_metrics":
			var mr = _call("kube.pod_metrics", {"namespace": a["ns"], "pod": a["name"]}, 15.0)
			return {"ok": mr["ok"], "msg": mr["msg"], "kind": mr["kind"], "data": mr["data"]}
		"file_mounts":
			var r = _call("files.mounts", {"namespace": a["ns"], "pod": a["name"]})
			return {"ok": r["ok"], "msg": r["msg"], "kind": r["kind"], "data": r["data"]}
		"file_list":
			var r = _call("files.list", {"namespace": a["ns"], "pod": a["name"], "container": a["container"], "root": a["root"], "path": a["path"]})
			return {"ok": r["ok"], "msg": r["msg"], "kind": r["kind"], "data": r["data"]}
		"file_read":
			var r = _call("files.read", {"namespace": a["ns"], "pod": a["name"], "container": a["container"], "root": a["root"], "path": a["path"], "page": int(a.get("page", 0))})
			return {"ok": r["ok"], "msg": r["msg"], "kind": r["kind"], "data": r["data"]}
		"file_write":
			var r = _call("files.write", {"namespace": a["ns"], "pod": a["name"], "container": a["container"], "root": a["root"], "path": a["path"], "text": a["text"], "expected": a["expected"]}, 30.0)
			return {"ok": r["ok"], "msg": "Saved. Previous file: " + str(r["data"].get("backup", "")) if r["ok"] else r["msg"], "kind": r["kind"], "data": r["data"]}
	return {}

# A loopback port-forward to a Service, reused while it lives.
func forward(ns: String, service: String, port: int) -> Dictionary:
	var key = "%s/%s:%d" % [ns, service, port]
	if _forwards.has(key):
		return {"ok": true, "msg": "", "kind": "", "data": {}, "address": _forwards[key]["address"], "forward": _forwards[key]["forward"]}
	var r = _call("kube.forward", {"namespace": ns, "service": service, "port": port}, 30.0)
	if not r["ok"]:
		return {"ok": false, "msg": r["msg"], "kind": r["kind"], "data": {}}
	_forwards[key] = {"forward": str(r["data"]["forward"]), "address": str(r["data"]["address"])}
	return {"ok": true, "msg": "", "kind": "", "data": {}, "address": _forwards[key]["address"], "forward": _forwards[key]["forward"]}

func forward_closed(id: String) -> void:
	for key in _forwards.keys():
		if _forwards[key]["forward"] == id:
			_forwards.erase(key)
