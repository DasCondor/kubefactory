extends RefCounted
# Talks to a real cluster through the kubectl on PATH, using whatever
# kubeconfig / context / credentials kubectl itself is set up with.
# Every call here blocks, so cluster.gd only calls it from worker threads.

const K = preload("res://scripts/kutil.gd")
const LogSources = preload("res://scripts/log_sources.gd")
const Apps = preload("res://scripts/apps.gd")

var label = "kubernetes"
var poll_interval = 3.0
var caps = {"scale": true, "delete_pod": true, "restart": true, "delete_workload": true,
	"create": true, "cordon": true, "drain": true, "logs": true}
var context = ""
var ctx = ""            # explicit kubeconfig context; "" = kubectl's current one
var provider = "Kubernetes"
var log_cfg = {}
var providers = []
var _pf_pid = -1
# multi-user
var user = ""               # who the cluster says you are
var groups = []
var policy = {}             # from configmap kubefactory/kubefactory-policy ({} if not installed)
var scoped_ns = ""          # set when the account can only see one namespace
var presence_ok = false     # the kubefactory namespace is there and usable
var _nodes_forbidden = false

func _run(args: Array, with_err: bool = true) -> Dictionary:
	var out = []
	if ctx != "":
		args = ["--context=" + ctx] + args
	var code = OS.execute("kubectl", PackedStringArray(args), out, with_err)
	return {"code": code, "out": (str(out[0]) if out.size() > 0 else "")}

# Every context in the kubeconfig, with a provider guess: [{context, provider, current}]
static func list_contexts() -> Array:
	var out = []
	var code = OS.execute("kubectl", PackedStringArray(["config", "view", "-o", "json"]), out, false)
	if code != 0 or out.size() == 0:
		return []
	var d = JSON.parse_string(str(out[0]))
	if typeof(d) != TYPE_DICTIONARY:
		return []
	var servers = {}
	var clusters = d.get("clusters")
	if typeof(clusters) == TYPE_ARRAY:
		for c in clusters:
			servers[str(c.get("name", ""))] = str(c.get("cluster", {}).get("server", ""))
	var res = []
	var contexts = d.get("contexts")
	if typeof(contexts) == TYPE_ARRAY:
		for c in contexts:
			var nm = str(c.get("name", ""))
			var server = str(servers.get(str(c.get("context", {}).get("cluster", "")), ""))
			res.append({"context": nm, "provider": K.provider_hint(nm, server),
				"current": nm == str(d.get("current-context", ""))})
	return res

func probe() -> Dictionary:
	var r
	if ctx == "":
		r = _run(["config", "current-context"])
		if r.code != 0:
			return {"ok": false, "msg": "kubectl has no current context"}
		context = r.out.strip_edges()
	else:
		context = ctx
	for c in list_contexts():
		if c["context"] == context:
			provider = c["provider"]
	providers = LogSources.list_for(provider, context, log_cfg)
	r = _run(["get", "--raw", "/version", "--request-timeout=5s"])
	if r.code != 0:
		return {"ok": false, "msg": "cluster '%s' not reachable" % context}
	_identify()
	return {"ok": true, "msg": context}

func _can(verb: String, resource: String, scope: Array) -> bool:
	var r = _run(["auth", "can-i", verb, resource] + scope + ["--request-timeout=8s"])
	return _last_line(r.out).strip_edges() == "yes"

# Who am I, what does the cluster policy say, and what am I actually allowed to do?
func _identify() -> void:
	var r = _run(["auth", "whoami", "-o", "json", "--request-timeout=8s"], false)
	var d = JSON.parse_string(r.out) if r.code == 0 else null
	if typeof(d) == TYPE_DICTIONARY:
		var info = d.get("status", {}).get("userInfo", {})
		user = str(info.get("username", ""))
		groups = info.get("groups", [])
	if user == "":
		r = _run(["config", "view", "--minify", "-o", "jsonpath={.contexts[0].context.user}"], false)
		user = r.out.strip_edges() if r.code == 0 else "unknown"
	r = _run(["get", "configmap", "kubefactory-policy", "-n", "kubefactory", "-o", "json", "--request-timeout=8s"], false)
	d = JSON.parse_string(r.out) if r.code == 0 else null
	if typeof(d) == TYPE_DICTIONARY:
		var p = JSON.parse_string(str(d.get("data", {}).get("policy.json", "")))
		if typeof(p) == TYPE_DICTIONARY:
			policy = p
		presence_ok = policy.get("presence", true) and _can("create", "leases.coordination.k8s.io", ["-n", "kubefactory"])
	# namespace-limited account? then work inside the context's namespace
	if not _can("list", "pods", ["-A"]):
		r = _run(["config", "view", "--minify", "-o", "jsonpath={.contexts[0].context.namespace}"], false)
		scoped_ns = r.out.strip_edges() if r.code == 0 and r.out.strip_edges() != "" else "default"
	var scope = ["-n", scoped_ns] if scoped_ns != "" else ["-A"]
	caps["scale"] = _can("update", "deployments/scale", scope)
	caps["restart"] = _can("patch", "deployments", scope)
	caps["create"] = _can("create", "deployments", scope)
	caps["delete_pod"] = _can("delete", "pods", scope)
	caps["delete_workload"] = _can("delete", "deployments", scope)
	caps["cordon"] = _can("patch", "nodes", ["-A"])
	caps["drain"] = caps["cordon"] and _can("create", "pods/eviction", scope)

func fetch() -> Dictionary:
	var args = ["get", "nodes,pods,deployments.apps,statefulsets.apps,daemonsets.apps,services",
		"-A", "-o", "json", "--request-timeout=15s"]
	if scoped_ns != "":
		args = ["get", "pods,deployments.apps,statefulsets.apps,daemonsets.apps,services",
			"-n", scoped_ns, "-o", "json", "--request-timeout=15s"]
	var r = _run(args, false)
	if r.code != 0:
		var e = _run(args, true)
		return {"source": label, "context": context, "error": _last_line(e.out), "failed": true}
	var data = JSON.parse_string(r.out)
	if typeof(data) != TYPE_DICTIONARY:
		return {"source": label, "context": context, "error": "could not parse kubectl output", "failed": true}
	if scoped_ns != "" and not _nodes_forbidden:
		# nodes are cluster-wide; a namespace account may or may not see them
		var nr = _run(["get", "nodes", "-o", "json", "--request-timeout=10s"], false)
		var nd = JSON.parse_string(nr.out) if nr.code == 0 else null
		if typeof(nd) == TYPE_DICTIONARY:
			data["items"] = nd.get("items", []) + data.get("items", [])
		else:
			_nodes_forbidden = true
	var st = normalize(data, context)
	if scoped_ns != "" and _nodes_forbidden:
		# no access to nodes: draw one platform per node name the pods mention
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
	return st

static func _last_line(s: String) -> String:
	var lines = s.strip_edges().split("\n")
	return lines[lines.size() - 1] if lines.size() > 0 else "kubectl failed"

static func _pod_status(md: Dictionary, status: Dictionary) -> String:
	if md.has("deletionTimestamp"):
		return "Terminating"
	var res = str(status.get("phase", "Unknown"))
	if status.has("reason") and str(status["reason"]) != "":
		res = str(status["reason"])
	for cs in status.get("initContainerStatuses", []):
		var s = cs.get("state", {})
		if s.has("waiting") and str(s["waiting"].get("reason", "")) not in ["", "PodInitializing"]:
			return "Init:" + str(s["waiting"]["reason"])
		if s.has("terminated") and int(s["terminated"].get("exitCode", 0)) != 0:
			return "Init:Error"
	var any_running = false
	for cs in status.get("containerStatuses", []):
		var s = cs.get("state", {})
		if s.has("waiting") and str(s["waiting"].get("reason", "")) != "":
			return str(s["waiting"]["reason"])
		if s.has("terminated"):
			res = str(s["terminated"].get("reason", "Error"))
			if res == "":
				res = "Error"
		elif s.has("running"):
			any_running = true
	if any_running and res == "Completed":
		res = "Running"
	return res

static func normalize(list: Dictionary, ctx: String) -> Dictionary:
	var st = {"source": "kubernetes", "context": ctx, "provider": "", "error": "", "nodes": [], "pods": [],
		"workloads": [], "services": []}
	var cloud = ""
	var distro = ""
	var rancher = false
	var req_cpu = {}
	var req_mem = {}
	for it in list.get("items", []):
		var kind = str(it.get("kind", ""))
		var md = it.get("metadata", {})
		var spec = it.get("spec", {})
		var status = it.get("status", {})
		var ns = str(md.get("namespace", ""))
		var nm = str(md.get("name", ""))
		var created = 0.0
		if md.has("creationTimestamp"):
			created = Time.get_unix_time_from_datetime_string(str(md["creationTimestamp"]))
		match kind:
			"Node":
				var ready = false
				for c in status.get("conditions", []):
					if c.get("type", "") == "Ready":
						ready = str(c.get("status", "")) == "True"
				var roles = []
				for l in md.get("labels", {}):
					if str(l).begins_with("node-role.kubernetes.io/"):
						roles.append(str(l).trim_prefix("node-role.kubernetes.io/"))
				var alloc = status.get("allocatable", {})
				var nl = md.get("labels", {})
				var pid = str(spec.get("providerID", ""))
				var ver = str(status.get("nodeInfo", {}).get("kubeletVersion", ""))
				if pid.begins_with("aws"):
					cloud = "AWS EKS" if ver.contains("eks") else "AWS"
				elif pid.begins_with("azure"):
					cloud = "Azure AKS" if nl.has("kubernetes.azure.com/cluster") else "Azure"
				elif pid.begins_with("gce"):
					cloud = "Google GKE" if ver.contains("gke") else "Google Cloud"
				elif pid.begins_with("kind"):
					cloud = "kind"
				if ver.contains("+rke2"):
					distro = "RKE2"
				elif ver.contains("+k3s"):
					distro = "K3s"
				st.nodes.append({"name": nm, "zone": str(nl.get("topology.kubernetes.io/zone", "")),
					"itype": str(nl.get("node.kubernetes.io/instance-type", "")), "ready": ready, "cordoned": bool(spec.get("unschedulable", false)),
					"roles": ",".join(PackedStringArray(roles)) if roles.size() > 0 else "worker",
					"version": str(status.get("nodeInfo", {}).get("kubeletVersion", "")),
					"cpu": K.parse_cpu(alloc.get("cpu", "0")), "mem": K.parse_mem(alloc.get("memory", "0")),
					"cpu_req": 0.0, "mem_req": 0.0, "created": created})
			"Pod":
				if ns == "cattle-system":
					rancher = true
				var pstatus = _pod_status(md, status)
				var conts = []
				var restarts = 0
				var all_ready = true
				var cstat = {}
				for cs in status.get("containerStatuses", []):
					cstat[str(cs.get("name", ""))] = cs
				for c in spec.get("containers", []):
					var cn = str(c.get("name", ""))
					var cs = cstat.get(cn, {})
					var state = "waiting"
					var reason = ""
					var s = cs.get("state", {})
					if s.has("running"):
						state = "running"
					elif s.has("terminated"):
						state = "terminated"
						reason = str(s["terminated"].get("reason", ""))
					elif s.has("waiting"):
						reason = str(s["waiting"].get("reason", ""))
					var cready = bool(cs.get("ready", false))
					if not cready:
						all_ready = false
					restarts += int(cs.get("restartCount", 0))
					conts.append({"name": cn, "image": str(c.get("image", "")), "state": state,
						"reason": reason, "ready": cready, "restarts": int(cs.get("restartCount", 0))})
				var wkind = "Pod"
				var wname = ""
				var owners = md.get("ownerReferences", [])
				var labels = md.get("labels", {})
				if owners.size() > 0:
					wkind = str(owners[0].get("kind", "Pod"))
					wname = str(owners[0].get("name", ""))
					if wkind == "ReplicaSet":
						wkind = "Deployment"
						var h = str(labels.get("pod-template-hash", ""))
						if h != "" and wname.ends_with("-" + h):
							wname = wname.trim_suffix("-" + h)
						elif wname.rfind("-") > 0:
							wname = wname.substr(0, wname.rfind("-"))
				var node = str(spec.get("nodeName", ""))
				var phase = str(status.get("phase", ""))
				if node != "" and phase != "Succeeded" and phase != "Failed":
					for c in spec.get("containers", []):
						var rq = c.get("resources", {}).get("requests", {})
						req_cpu[node] = req_cpu.get(node, 0.0) + K.parse_cpu(rq.get("cpu", "0"))
						req_mem[node] = req_mem.get(node, 0.0) + K.parse_mem(rq.get("memory", "0"))
				var finished = 0.0
				for cs in status.get("containerStatuses", []):
					var term = cs.get("state", {}).get("terminated", {})
					if typeof(term) == TYPE_DICTIONARY and term.has("finishedAt"):
						finished = maxf(finished, Time.get_unix_time_from_datetime_string(str(term["finishedAt"])))
				st.pods.append({"uid": str(md.get("uid", ns + "/" + nm)), "name": nm, "ns": ns, "node": node,
					"status": pstatus, "ready": all_ready and conts.size() > 0,
					"health": K.health_of(pstatus, all_ready and conts.size() > 0),
					"restarts": restarts, "wkind": wkind, "wname": wname,
					"ip": str(status.get("podIP", "")), "created": created,
					"labels": labels, "containers": conts, "phase": phase, "finished": finished,
					"sec": K.pod_security(spec), "store": K.pod_storage(spec), "net": K.pod_net(spec, status, md.get("annotations", {}))})
			"Deployment", "StatefulSet":
				st.workloads.append({"kind": kind, "name": nm, "ns": ns,
					"replicas": int(spec.get("replicas", 1)), "ready": int(status.get("readyReplicas", 0)),
					"image": _first_image(spec)})
			"DaemonSet":
				st.workloads.append({"kind": kind, "name": nm, "ns": ns,
					"replicas": int(status.get("desiredNumberScheduled", 0)), "ready": int(status.get("numberReady", 0)),
					"image": _first_image(spec)})
			"Service":
				var ports = []
				var node_ports = {}
				for p in spec.get("ports", []):
					var port = "%d/%s" % [int(p.get("port", 0)), str(p.get("protocol", "TCP"))]
					ports.append(port)
					if int(p.get("nodePort", 0)) > 0:
						node_ports[port] = "%d/%s" % [int(p["nodePort"]), str(p.get("protocol", "TCP"))]
				var sel = spec.get("selector", {})
				st.services.append({"name": nm, "ns": ns, "type": str(spec.get("type", "ClusterIP")),
					"cluster_ip": str(spec.get("clusterIP", "")), "ports": ",".join(PackedStringArray(ports)), "node_ports": node_ports,
					"selector": sel if typeof(sel) == TYPE_DICTIONARY else {}})
	for n in st.nodes:
		n["cpu_req"] = req_cpu.get(n["name"], 0.0)
		n["mem_req"] = req_mem.get(n["name"], 0.0)
	var parts = []
	if rancher:
		parts.append("Rancher")
	if cloud != "":
		parts.append(cloud)
	if distro != "":
		parts.append(distro)
	st["provider"] = " · ".join(PackedStringArray(parts))
	return st

static func _first_image(spec: Dictionary) -> String:
	var cs = spec.get("template", {}).get("spec", {}).get("containers", [])
	return str(cs[0].get("image", "")) if cs.size() > 0 else ""

func run_action(a: Dictionary) -> Dictionary:
	var special = _app_action(a)
	if special.is_empty() and a["op"] in ["cleanup_scan", "remove_image"]:
		return {"ok": false, "kind": "unsupported", "data": {}, "msg": "Images live in each node's container runtime; the Kubernetes API does not list which ones are unused."}
	if special.is_empty() and a["op"] == "pod_metrics":
		return {"ok": false, "kind": "unsupported", "msg": "Usage figures need the built-in Kubernetes connection, not the kubectl mode.", "data": {}}
	if not special.is_empty():
		return special
	if a["op"] == "logs" and a.get("provider", "kube") != "kube":
		var lr = LogSources.fetch(a["provider"], a, log_cfg, context)
		return {"ok": lr.ok, "msg": "", "text": lr.text}
	var args = []
	match a["op"]:
		"scale":
			args = ["scale", a["kind"].to_lower(), a["name"], "-n", a["ns"], "--replicas=%d" % a["replicas"]]
		"delete_pod":
			args = ["delete", "pod", a["name"], "-n", a["ns"], "--wait=false"]
		"restart":
			args = ["rollout", "restart", a["kind"].to_lower() + "/" + a["name"], "-n", a["ns"]]
		"delete_workload":
			args = ["delete", a["kind"].to_lower(), a["name"], "-n", a["ns"], "--wait=false"]
		"create":
			args = ["create", "deployment", a["name"], "--image=" + a["image"],
				"--replicas=%d" % a["replicas"], "-n", a["ns"]]
		"cordon":
			args = ["cordon" if a["on"] else "uncordon", a["node"]]
		"drain":
			args = ["drain", a["node"], "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=90s"]
		"logs":
			args = ["logs", a["name"], "-n", a["ns"], "--tail=%d" % int(a.get("tail", 150))]
			if a.get("container", "") != "":
				args.append_array(["-c", a["container"]])
			if a.get("previous", false):
				args.append("--previous")
		"cluster_events":
			args = ["get", "events", "--sort-by=.lastTimestamp", "-o",
				"custom-columns=LAST:.lastTimestamp,NAMESPACE:.metadata.namespace,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message"]
			if a.get("ns", "") != "":
				args.append_array(["-n", a["ns"]])
			else:
				args.append("-A")
			if a.get("warnings", false):
				args.append_array(["--field-selector", "type=Warning"])
		"events":
			args = ["get", "events", "-n", a["ns"], "--field-selector", "involvedObject.name=" + a["name"],
				"--sort-by=.lastTimestamp", "-o", "custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message"]
		_:
			return {"ok": false, "msg": "unsupported action"}
	args.append("--request-timeout=20s")
	var r = _run(args)
	if a["op"] == "cluster_events" and r.code == 0:
		var lines = r.out.strip_edges().split("\n")
		if lines.size() > 301:
			r.out = lines[0] + "\n" + "\n".join(lines.slice(lines.size() - 300))
	if a["op"] in ["logs", "events", "cluster_events"]:
		return {"ok": r.code == 0, "msg": "", "text": r.out if r.out.strip_edges() != "" else "(no log output)"}
	return {"ok": r.code == 0, "msg": _last_line(r.out)}

# ---- Porter / Portainer: full app setups, template deploys, Portainer itself

func cleanup() -> void:
	if _pf_pid > 0:
		OS.kill(_pf_pid)
		_pf_pid = -1
	if presence_ok:
		_run(["delete", "lease", _lease_name(), "-n", "kubefactory", "--ignore-not-found", "--wait=false", "--request-timeout=5s"])

# ---- multi-user: presence (who else is in this factory) and the shared action feed.
# Both live in the kubefactory namespace: one Lease per player, one Event per action.

func _lease_name() -> String:
	return "kf-" + Apps.slug(K.short_user(user))

func _tmp(kind: String) -> String:
	return OS.get_user_data_dir().path_join("%s-%d.yaml" % [kind, OS.get_process_id()])

static func _yq(v) -> String:
	return "\"" + str(v).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ") + "\""

# info: {pos: "x,y,z,yaw", tool: int, doing: String}. Returns {peers: [...], events: [...]}.
func presence(info: Dictionary) -> Dictionary:
	var res = {"peers": [], "events": [], "ok": false}
	if not presence_ok:
		return res
	var now = Time.get_datetime_string_from_system(true)
	var path = _tmp("presence")
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return res
	f.store_string("apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: %s\n  namespace: kubefactory\n  labels: {app: kubefactory}\n  annotations:\n    kubefactory/user: %s\n    kubefactory/pos: %s\n    kubefactory/tool: %s\n    kubefactory/doing: %s\nspec:\n  holderIdentity: %s\n  renewTime: \"%s.000000Z\"\n  leaseDurationSeconds: 15\n" % [
		_lease_name(), _yq(user), _yq(info.get("pos", "")), _yq(info.get("tool", 0)), _yq(info.get("doing", "")), _yq(K.short_user(user)), now])
	f.close()
	var r = _run(["apply", "-f", path, "--request-timeout=8s"])
	if r.code != 0:
		return res
	res["ok"] = true
	var t_now = Time.get_unix_time_from_system()
	r = _run(["get", "leases", "-n", "kubefactory", "-l", "app=kubefactory", "-o", "json", "--request-timeout=8s"], false)
	var d = JSON.parse_string(r.out) if r.code == 0 else null
	if typeof(d) == TYPE_DICTIONARY:
		for it in d.get("items", []):
			var md = it.get("metadata", {})
			if str(md.get("name", "")) == _lease_name():
				continue
			var renew = str(it.get("spec", {}).get("renewTime", "")).get_slice(".", 0)
			if renew == "" or t_now - Time.get_unix_time_from_datetime_string(renew) > 30.0:
				continue
			var an = md.get("annotations", {})
			res["peers"].append({"id": str(md.get("name", "")), "user": K.short_user(str(an.get("kubefactory/user", "?"))),
				"pos": str(an.get("kubefactory/pos", "")), "tool": int(str(an.get("kubefactory/tool", "0"))),
				"doing": str(an.get("kubefactory/doing", ""))})
	r = _run(["get", "events", "-n", "kubefactory", "--field-selector", "reason=KubeFactory", "-o", "json", "--request-timeout=8s"], false)
	d = JSON.parse_string(r.out) if r.code == 0 else null
	if typeof(d) == TYPE_DICTIONARY:
		for it in d.get("items", []):
			var an = it.get("metadata", {}).get("annotations", {})
			res["events"].append({"id": str(it.get("metadata", {}).get("name", "")), "user": K.short_user(str(an.get("kubefactory/user", ""))),
				"msg": str(it.get("message", "")), "ok": str(it.get("type", "Normal")) == "Normal",
				"time": Time.get_unix_time_from_datetime_string(str(it.get("lastTimestamp", "")).get_slice(".", 0)) if it.get("lastTimestamp") != null else 0.0})
	return res

# Tell everyone on this cluster what was just done.
func post_event(msg: String, ok: bool) -> void:
	if not presence_ok:
		return
	var now = Time.get_datetime_string_from_system(true) + "Z"
	var path = _tmp("event")
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("apiVersion: v1\nkind: Event\nmetadata:\n  generateName: kf-\n  namespace: kubefactory\n  annotations:\n    kubefactory/user: %s\ninvolvedObject:\n  apiVersion: coordination.k8s.io/v1\n  kind: Lease\n  name: %s\n  namespace: kubefactory\nreason: KubeFactory\nmessage: %s\ntype: %s\nfirstTimestamp: \"%s\"\nlastTimestamp: \"%s\"\nsource:\n  component: kubefactory\n" % [
		_yq(user), _lease_name(), _yq(msg.left(900)), "Normal" if ok else "Warning", now, now])
	f.close()
	_run(["create", "-f", path, "--request-timeout=8s"])

func _app_action(a: Dictionary) -> Dictionary:
	match a["op"]:
		"scale_by":
			# relative scaling that is safe when two people do it at once: read the
			# current count, then scale only if it is still that count; retry if not
			var res = a["kind"].to_lower() + "/" + a["name"]
			for attempt in 4:
				var cur = _run(["get", res, "-n", a["ns"], "-o", "jsonpath={.spec.replicas}", "--request-timeout=10s"], false)
				if cur.code != 0:
					return {"ok": false, "msg": "%s not found" % res}
				var n = maxi(0, cur.out.strip_edges().to_int() + int(a["delta"]))
				var r = _run(["scale", res, "-n", a["ns"], "--current-replicas=%d" % cur.out.strip_edges().to_int(), "--replicas=%d" % n, "--request-timeout=15s"])
				if r.code == 0:
					return {"ok": true, "msg": "%s scaled to %d" % [res, n]}
				if not r.out.contains("Expected replicas"):
					return {"ok": false, "msg": _last_line(r.out)}
			return {"ok": false, "msg": "%s kept changing under us; try again" % res}
		"apply_app":
			var app = Apps.find(a["id"])
			if app == null:
				return {"ok": false, "msg": "unknown app"}
			_run(["create", "namespace", a["ns"]])
			var note = ""
			if app["secret"]:
				# the password goes through a short-lived file, never the command line
				var pw_path = OS.get_user_data_dir().path_join("pw-%d-%d.tmp" % [OS.get_process_id(), Time.get_ticks_usec()])
				var pf = FileAccess.open(pw_path, FileAccess.WRITE)
				pf.store_string(Apps.random_password())
				pf.close()
				var s = _run(["-n", a["ns"], "create", "secret", "generic", "app-db", "--from-file=password=" + pw_path])
				DirAccess.remove_absolute(pw_path)
				note = "  Password generated into secret app-db." if s.code == 0 else "  Reusing existing secret app-db."
			var r = _run(["apply", "-n", a["ns"], "-f", Apps.file_for(a["id"], "k8s"), "--request-timeout=30s"])
			return {"ok": r.code == 0, "msg": ("%s deployed to namespace %s.%s" % [app["name"], a["ns"], note]) if r.code == 0 else _last_line(r.out)}
		"remove_app":
			var r = _run(["delete", "-n", a["ns"], "-f", Apps.file_for(a["id"], "k8s"), "--ignore-not-found", "--wait=false", "--request-timeout=30s"])
			return {"ok": r.code == 0, "msg": ("%s removed from namespace %s (secret and volumes kept)" % [a["id"], a["ns"]]) if r.code == 0 else _last_line(r.out)}
		"portainer_install":
			var r = _run(["apply", "-n", "portainer", "-f", Apps.PORTAINER_MANIFEST, "--request-timeout=60s"])
			return {"ok": r.code == 0, "msg": "Portainer installed in namespace portainer" if r.code == 0 else _last_line(r.out)}
		"portainer_open":
			cleanup()
			var args = ["port-forward", "-n", "portainer", "svc/portainer", "9443:9443"]
			if ctx != "":
				args = ["--context=" + ctx] + args
			_pf_pid = OS.create_process("kubectl", PackedStringArray(args))
			OS.delay_msec(1500)
			return {"ok": _pf_pid > 0, "msg": "Port-forward running: Portainer at https://localhost:9443", "open": "https://localhost:9443"}
		"deploy_template":
			var t = a["template"]
			var envinfo = Apps.template_env(t)
			var path = OS.get_user_data_dir().path_join("tpl-%s.yaml" % a["name"])
			var f = FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				return {"ok": false, "msg": "could not write manifest"}
			f.store_string(Apps.template_manifest(t, a["name"], envinfo[0]))
			f.close()
			_run(["create", "namespace", a["ns"]])
			var r = _run(["apply", "-n", a["ns"], "-f", path, "--request-timeout=30s"])
			DirAccess.remove_absolute(path)
			var note = ""
			if envinfo[1].size() > 0:
				note = "  Generated: %s (see the deployment's env)." % ", ".join(PackedStringArray(envinfo[1]))
			return {"ok": r.code == 0, "msg": ("%s deployed to namespace %s.%s" % [t.get("title", a["name"]), a["ns"], note]) if r.code == 0 else _last_line(r.out)}
		"remove_template":
			var r = _run(["delete", "deployment,service", a["name"], "-n", a["ns"], "--ignore-not-found", "--wait=false", "--request-timeout=30s"])
			return {"ok": r.code == 0, "msg": ("%s removed from namespace %s" % [a["name"], a["ns"]]) if r.code == 0 else _last_line(r.out)}
		"templates":
			var r = Apps.fetch_templates(a.get("catalog", {}))
			return {"ok": r.ok, "msg": "", "text": r.text}
	return {}
