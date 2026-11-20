extends Node
# The Krew: workers that watch the infrastructure and report what they find.
#
# Each worker is a set of rules over the state every source already reports
# (and, for Scrappy on Docker, one scan the operator asks for). A rule produces
# a finding: what is wrong, the evidence, the resources it touches, what could
# be done about it and what that would risk. Nothing here acts on its own: a
# proposed action is carried out only when the operator approves it, through
# the same guard rails as the hand tools (tiers, read-only mode, confirmation).
# No language model and no network is involved; the rules are plain code.
#
#   Bob       maintenance   failing pods and unhealthy nodes (his fix list)
#   Gauge     performance   nodes whose requests are close to capacity
#   Sentinel  security      privileged, host access, the engine's socket, root, powerful capabilities, floating tags
#   Scout     network       Services that reach nothing, and what is exposed outside
#   Scrappy   cleanup       finished pods, stopped containers, unused images (approved removal only)
#   Archie    storage       stateful software with nowhere lasting to keep its data; unnamed volumes
#   Forge     build         images in use that exist only on this machine; idle build cache (after a scan)
#   Blueprint architect     drift: fewer replicas or containers running than the definition asks for
#
# A finding keeps its first-seen time while it lasts. When the condition is
# gone it moves to the history as resolved, which is how an approved action is
# seen to have worked: by the next state, not by the action's own answer.

const K = preload("res://scripts/kutil.gd")
const Models = preload("res://scripts/models.gd")

signal changed()

const WORKERS = [
	{"id": "bob", "name": "BOB", "role": "Maintenance", "color": Color(1.0, 0.8, 0.45)},
	{"id": "gauge", "name": "GAUGE", "role": "Performance", "color": Color(0.4, 0.92, 1.0)},
	{"id": "sentinel", "name": "SENTINEL", "role": "Security", "color": Color(0.36, 0.6, 1.0)},
	{"id": "scout", "name": "SCOUT", "role": "Network", "color": Color(0.4, 0.9, 0.5)},
	{"id": "scrappy", "name": "SCRAPPY", "role": "Cleanup", "color": Color(1.0, 0.85, 0.25)},
	{"id": "archie", "name": "ARCHIE", "role": "Storage", "color": Color(0.7, 0.5, 1.0)},
	{"id": "forge", "name": "FORGE", "role": "Build", "color": Color(1.0, 0.55, 0.2)},
	{"id": "blueprint", "name": "BLUEPRINT", "role": "Architect", "color": Color(0.84, 0.8, 1.0)},
]
# software that keeps data, by the model role its image gets (models.gd ROLES)
const STATEFUL = {"database_server": ["high", "a database"], "broker_rack": ["medium", "a message broker"], "registry_rack": ["medium", "an image registry"],
	"monitoring_server": ["low", "a metrics or dashboard store"], "cache_server": ["low", "a cache"]}
const DRIFT_HOLD = 120.0           # a rollout in progress is not drift: wait this long before reporting
const BUILD_CACHE_REPORT = 1.0e9
const SEVERITY_ORDER = {"high": 0, "medium": 1, "low": 2, "info": 3}
# namespaces whose node agents legitimately need host access: the finding is still
# reported, one step lower, and says why
const SYSTEM_NS = ["kube-system", "kube-public", "kube-node-lease", "monitoring", "cattle-system", "calico-system", "tigera-operator", "metallb-system", "longhorn-system"]
const FINISHED_AFTER = 3600.0      # a finished pod is clutter once it has sat for an hour
const HISTORY_LIMIT = 200
const MIN_INTERVAL = 2.0

var findings = {}       # key -> finding
var history = []        # resolved findings, newest first
var scan = {}           # the latest cleanup scan: {ok, msg, data, at}
var source = ""
var _last = -INF
var _pending_state = null
var _held = {}          # key -> first seen, for findings that wait (hold) before they are shown

# ---- running the rules

func observe(state: Dictionary) -> void:
	_pending_state = state

func _process(_d: float) -> void:
	if _pending_state == null:
		return
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last < MIN_INTERVAL:
		return
	_last = now
	var st = _pending_state
	_pending_state = null
	update(st, Time.get_unix_time_from_system())

# One pass of every worker's rules. Separate from _process so a test can call it.
func update(state: Dictionary, now: float) -> void:
	var src = str(state.get("source", ""))
	if src != source:
		findings.clear()
		_held.clear()
		scan = {}
		source = src
	var fresh = analyze(state, scan, now)
	for key in _held.keys():
		if not fresh.has(key):
			_held.erase(key)
	for key in fresh.keys():
		var hold = float(fresh[key].get("hold", 0.0))
		if hold > 0.0 and not findings.has(key):
			var since = float(_held.get(key, now))
			_held[key] = since
			if now - since < hold:
				fresh.erase(key)
			else:
				fresh[key]["first_seen"] = since
	for key in findings.keys():
		if not fresh.has(key):
			var f = findings[key]
			f["resolved_at"] = now
			history.push_front(f)
			findings.erase(key)
	for key in fresh:
		if findings.has(key):
			fresh[key]["first_seen"] = findings[key]["first_seen"]
		findings[key] = fresh[key]
	if history.size() > HISTORY_LIMIT:
		history.resize(HISTORY_LIMIT)
	changed.emit()

func set_scan(result: Dictionary) -> void:
	scan = result.duplicate(true)
	scan["at"] = Time.get_unix_time_from_system()
	_last = -INF

static func analyze(state: Dictionary, scan_result: Dictionary, now: float) -> Dictionary:
	var out = {}
	var sim = str(state.get("source", "")) == "simulation"
	for f in bob_rules(state) + gauge_rules(state) + sentinel_rules(state) + scout_rules(state) + scrappy_rules(state, scan_result, now) \
			+ archie_rules(state) + forge_rules(state, scan_result) + blueprint_rules(state):
		f["simulated"] = sim
		f["first_seen"] = now
		f["last_seen"] = now
		out[f["key"]] = f
	return out

static func _finding(worker: String, rule: String, subject: String, severity: String, title: String) -> Dictionary:
	return {"key": "%s:%s:%s" % [worker, rule, subject], "worker": worker, "rule": rule, "severity": severity, "title": title,
		"resource": subject, "uids": [], "evidence": [], "proposal": "", "risk": "", "action": {}, "action_label": ""}

# Pods of one workload are reported once, with every replica as evidence.
static func _owner(p: Dictionary) -> String:
	return "%s/%s" % [p["ns"], p["wname"] if str(p.get("wname", "")) != "" else p["name"]]

static func _lower(sev: String) -> String:
	return {"high": "medium", "medium": "low", "low": "info"}.get(sev, sev)

# ---- Bob: what is broken (his own diagnoses, K.issues)

static func bob_rules(state: Dictionary) -> Array:
	var out = []
	for j in K.issues(state):
		var subject = ("node/" + str(j["name"])) if j["kind"] == "node" else "%s/%s" % [j["ns"], j["name"]]
		var f = _finding("bob", str(j["status"]), subject, {"bad": "high", "warn": "medium"}.get(str(j["sev"]), "medium"), "%s is %s" % [j["name"], j["status"]])
		f["evidence"] = [str(j["why"])]
		f["proposal"] = str(j["fix"])
		if j["kind"] == "pod":
			f["uids"] = [str(j.get("uid", ""))]
		out.append(f)
	return out

# ---- Gauge: nodes whose requests leave no room

static func gauge_rules(state: Dictionary) -> Array:
	var out = []
	if not str(state.get("source", "")) in ["kubernetes", "simulation"]:
		return out
	for n in state.get("nodes", []):
		if str(n.get("roles", "")) == "node details hidden":
			continue
		for pair in [["cpu", "cpu_req", "CPU"], ["mem", "mem_req", "memory"]]:
			var cap = float(n.get(pair[0], 0.0))
			var req = float(n.get(pair[1], 0.0))
			if cap <= 0.0:
				continue
			var share = req / cap
			if share >= 0.9:
				var f = _finding("gauge", "requests-" + pair[0], "node/" + str(n["name"]), "high" if share >= 1.0 else "medium",
					"%s: %d%% of its %s is requested" % [n["name"], int(round(share * 100.0)), pair[2]])
				f["evidence"] = ["Requested %s of %s allocatable." % [_amount(pair[0], req), _amount(pair[0], cap)],
					"Requests are what pods reserve, not what they use; new pods that need more will stay Pending."]
				f["proposal"] = "Read the actual usage of the busiest workloads at Gauge's desk before lowering requests, or add capacity."
				f["risk"] = "Lowering requests below real use lets the node be overcommitted."
				out.append(f)
	return out

static func _amount(kind: String, v: float) -> String:
	return ("%.2f cores" % v) if kind == "cpu" else K.fmt_bytes(v)

# ---- Sentinel: security settings that widen what a compromise can reach

static func sentinel_rules(state: Dictionary) -> Array:
	var by_owner = {}
	for p in state.get("pods", []):
		var s = p.get("sec", {})
		if typeof(s) != TYPE_DICTIONARY or s.is_empty():
			continue
		var o = _owner(p)
		if not by_owner.has(o):
			by_owner[o] = {"pods": [], "sec": s, "ns": str(p["ns"])}
		by_owner[o]["pods"].append(p)
	var out = []
	for o in by_owner:
		var s: Dictionary = by_owner[o]["sec"]
		var pods: Array = by_owner[o]["pods"]
		var system = by_owner[o]["ns"] in SYSTEM_NS
		var add = func(rule: String, sev: String, title: String, evidence: Array, proposal: String, risk: String):
			var f = _finding("sentinel", rule, o, _lower(sev) if system else sev, title)
			f["evidence"] = evidence + (["%s is a system namespace: node agents there often need this. Confirm it is expected." % by_owner[o]["ns"]] if system else [])
			f["evidence"].append("%d pod(s): %s" % [pods.size(), ", ".join(PackedStringArray(pods.map(func(p): return str(p["name"])).slice(0, 4)))])
			f["proposal"] = proposal
			f["risk"] = risk
			f["uids"] = pods.map(func(p): return str(p["uid"]))
			var common = _common_fix(rule, o, pods, s)
			if not common.is_empty():
				f["common"] = common["fix"]
				f["example"] = common.get("example", "")
				if common.get("expected", false):
					f["severity"] = _lower(f["severity"])
					f["title"] += " (expected for %s)" % common["what"]
			out.append(f)
		if s.get("docker_socket", false):
			add.call("engine-socket", "high", "%s can control the container engine" % o, ["The engine's socket is mounted: " + ", ".join(PackedStringArray(s.get("host_paths", []).filter(func(x): return K.is_socket_path(str(x)))))],
				"Remove the socket mount; if it must build or manage containers, use a rootless builder or a restricted API proxy.",
				"Anything that can reach the socket can start a privileged container, which is root on the host.")
		if not s.get("privileged", []).is_empty():
			add.call("privileged", "high", "%s runs privileged" % o, ["Privileged containers: " + ", ".join(PackedStringArray(s["privileged"]))],
				"Drop privileged mode and grant only the specific capabilities or devices it needs.",
				"A privileged container has almost every power of the host's root user.")
		var hp: Array = s.get("host_paths", []).filter(func(x): return not K.is_socket_path(str(x)))
		if not hp.is_empty():
			add.call("host-path", "high" if "/" in hp else "medium", "%s mounts the host's files" % o, ["Host paths: " + ", ".join(PackedStringArray(hp))],
				"Mount only the narrowest path it needs, read-only where possible.",
				"A writable host mount lets the container change the node itself.")
		var host_ns = []
		for pair in [["host_network", "network"], ["host_pid", "processes"], ["host_ipc", "shared memory"]]:
			if s.get(pair[0], false):
				host_ns.append(pair[1])
		if not host_ns.is_empty():
			add.call("host-namespaces", "medium", "%s shares the host's %s" % [o, ", ".join(PackedStringArray(host_ns))], ["Shares: " + ", ".join(PackedStringArray(host_ns))],
				"Use the pod's own namespaces unless the app truly needs the host's (a node agent, a discovery protocol).",
				"It can see and reach what the host can, past network policies.")
		if not s.get("root", []).is_empty():
			add.call("root", "medium", "%s explicitly runs as root" % o, ["Set to user 0: " + ", ".join(PackedStringArray(s["root"]))],
				"Run as a non-root user (runAsNonRoot: true and a user ID above 0).",
				"A process that breaks out of the container is root.")
		if not s.get("caps", []).is_empty():
			var bad = s["caps"].any(func(c): return str(c).ends_with("ALL") or str(c).ends_with("SYS_ADMIN"))
			add.call("capabilities", "high" if bad else "medium", "%s adds powerful capabilities" % o, ["Added: " + ", ".join(PackedStringArray(s["caps"]))],
				"Drop all capabilities and add back only the ones it needs.",
				"SYS_ADMIN and ALL come close to privileged mode.")
		if not s.get("latest", []).is_empty():
			add.call("floating-tag", "low", "%s runs a floating image tag" % o, ["Images: " + ", ".join(PackedStringArray(s["latest"]))],
				"Pin a version (or a digest) so a restart cannot quietly change what runs.",
				"A restart can pull a different image than the one that was reviewed.")
	return out

# Known, common cases of the findings above, with the usual fix. Recognised from the
# pod's VPN role, container names and images; anything else keeps the general advice.
const MEDIA_SERVERS = ["plex", "jellyfin", "emby"]
const MEDIA_APPS = ["plex", "jellyfin", "emby", "sonarr", "radarr", "lidarr", "readarr", "bazarr", "prowlarr", "jackett", "deluge", "qbittorrent", "transmission", "sabnzbd", "nzbget", "tautulli", "seerr", "overseerr"]

static func _is_vpn_pod(pods: Array) -> bool:
	return pods.any(func(p): return typeof(p.get("net")) == TYPE_DICTIONARY and not p["net"].get("vpn", {}).is_empty())

static func _common_fix(rule: String, owner: String, pods: Array, s: Dictionary) -> Dictionary:
	var name = owner.get_slice("/", 1).to_lower()
	var vpn = _is_vpn_pod(pods) or K.is_vpn_image(name)
	match rule:
		"capabilities":
			var caps: Array = s.get("caps", []).map(func(c): return str(c).get_slice(": ", 1) if ": " in str(c) else str(c))
			if vpn and caps.all(func(c): return c == "NET_ADMIN"):
				var who = ", ".join(PackedStringArray(s["caps"].map(func(c): return str(c).get_slice(": ", 0))))
				return {"expected": true, "what": "a VPN gateway",
					"fix": "A VPN gateway (%s) needs NET_ADMIN to create its tunnel and firewall. Keep it on the gateway container only: the apps that share its network get no capabilities of their own." % who,
					"example": "Compose:  gluetun:  cap_add: [NET_ADMIN]   (nothing on the apps using network_mode: service:gluetun)\nKubernetes:  only the gluetun container gets  securityContext.capabilities.add: [NET_ADMIN]"}
		"host-path":
			var hp: Array = s.get("host_paths", []).filter(func(x): return not K.is_socket_path(str(x)))
			if vpn and hp.all(func(x): return str(x) == "/dev/net/tun"):
				return {"expected": true, "what": "a VPN gateway",
					"fix": "Only /dev/net/tun, the tunnel device a VPN needs. Pass it as a device rather than a mounted folder, so nothing else of the host is reachable.",
					"example": "Compose:  devices: [/dev/net/tun:/dev/net/tun]\nKubernetes:  a hostPath of type CharDevice for /dev/net/tun, or a device plugin that hands out /dev/net/tun"}
			if name.contains("node-exporter"):
				return {"expected": true, "what": "a node exporter",
					"fix": "A node exporter reads the host's /proc, /sys and root filesystem to report on the machine. Mount them read-only and with host-to-container propagation only.",
					"example": "Compose:  - /proc:/host/proc:ro  - /sys:/host/sys:ro  - /:/rootfs:ro,rslave\nKubernetes:  volumeMounts[].readOnly: true (and mountPropagation: HostToContainer for /)"}
			if not hp.is_empty() and MEDIA_APPS.any(func(m): return name.contains(m)):
				return {"fix": "Mount the one folder the app needs (its config or the media library), not a parent folder; mount media read-only for players.",
					"example": "Compose:  - /srv/media/library:/media:ro   instead of  - /srv:/srv\nKubernetes:  volumeMounts[].readOnly: true for the library"}
		"host-namespaces":
			if s.get("host_network", false) and MEDIA_SERVERS.any(func(m): return name.contains(m)):
				return {"fix": "Media servers use the host network for local discovery (DLNA, GDM). Without it, publish the server port and tell the server its own address; keep host networking only if a TV must find it by itself.",
					"example": "Compose:  ports: [\"32400:32400/tcp\"]  (Plex: set Custom server access URLs; Jellyfin: 8096 and its Published server URL)\nKubernetes:  hostNetwork: false and a Service for the server port"}
		"floating-tag":
			var imgs: Array = s.get("latest", []).map(func(i): return str(i).get_slice(": ", 1) if ": " in str(i) else str(i))
			var lsio = imgs.any(func(i): return i.contains("linuxserver/"))
			return {"fix": "Pin the version that runs now and let the image updater propose the next one, so updates are reviewed instead of arriving on a restart." + (" LinuxServer images publish version tags for every release." if lsio else ""),
				"example": "Compose:  image: %s\nKubernetes:  image: <image>:<version>  or  <image>@sha256:<digest>" % (_pinned_hint(imgs[0]) if not imgs.is_empty() else "<image>:<version>")}
	return {}

static func _pinned_hint(image: String) -> String:
	var bare = image.get_slice("@", 0)
	var last = bare.get_slice("/", bare.get_slice_count("/") - 1)
	if ":" in last:
		bare = bare.substr(0, bare.length() - last.length() + last.find(":"))
	return bare + ":<version>"

# ---- Scout: Services that lead nowhere, and what is exposed

static func _selects(svc_sel: Dictionary, labels: Dictionary) -> bool:
	if svc_sel.is_empty():
		return false
	for k in svc_sel:
		if str(labels.get(k, "")) != str(svc_sel[k]):
			return false
	return true

static func scout_rules(state: Dictionary) -> Array:
	var out = []
	for svc in state.get("services", []):
		var sel = svc.get("selector", {})
		if typeof(sel) != TYPE_DICTIONARY or sel.is_empty():
			continue          # a Service without a selector has its endpoints managed by hand: nothing to judge here
		var subject = "%s/%s" % [svc["ns"], svc["name"]]
		var matched = state.get("pods", []).filter(func(p): return str(p["ns"]) == str(svc["ns"]) and _selects(sel, p.get("labels", {})))
		var sel_text = ", ".join(PackedStringArray(sel.keys().map(func(k): return "%s=%s" % [k, sel[k]])))
		if matched.is_empty():
			var f = _finding("scout", "no-pods", subject, "medium", "Service %s selects no pods" % subject)
			f["evidence"] = ["Selector: " + sel_text, "No pod in %s has those labels." % svc["ns"]]
			f["proposal"] = "Fix the selector, or delete the Service if what it served is gone."
			f["risk"] = "Anything still calling it gets connection errors."
			out.append(f)
		elif not matched.any(func(p): return bool(p.get("ready", false))):
			var f = _finding("scout", "no-ready", subject, "high", "Service %s has no ready pods" % subject)
			f["evidence"] = ["Selector: " + sel_text, "%d pod(s) match, none ready: %s" % [matched.size(), ", ".join(PackedStringArray(matched.map(func(p): return "%s (%s)" % [p["name"], p["status"]]).slice(0, 4)))]]
			f["proposal"] = "Look at why those pods are not ready (Bob's fix list has the details)."
			f["uids"] = matched.map(func(p): return str(p["uid"]))
			out.append(f)
		var t = str(svc.get("type", "ClusterIP"))
		if t in ["LoadBalancer", "NodePort"]:
			var f = _finding("scout", "exposed", subject, "info", "Service %s is reachable from outside the cluster" % subject)
			f["evidence"] = ["Type %s, ports %s" % [t, str(svc.get("ports", ""))]]
			f["proposal"] = "Expected for a front door; otherwise use ClusterIP and an ingress with authentication."
			out.append(f)
	# Docker and host ports: what listens on every address of this machine
	for p in state.get("pods", []):
		var s = p.get("sec", {})
		if typeof(s) != TYPE_DICTIONARY or s.get("host_ports", []).is_empty():
			continue
		if str(state.get("source", "")) == "docker" and not s.get("all_interfaces", false):
			continue
		var f = _finding("scout", "host-ports", _owner(p), "low", "%s listens on the host's own ports" % _owner(p))
		f["evidence"] = ["Host ports: " + ", ".join(PackedStringArray(s["host_ports"].map(func(x): return str(x)))) + (" on every network address" if s.get("all_interfaces", false) else "")]
		f["proposal"] = "Publish on 127.0.0.1 only, unless other machines need to reach it."
		f["uids"] = [str(p["uid"])]
		out.append(f)
	return out

# ---- Scrappy: what is left over (never removes anything by itself)

static func scrappy_rules(state: Dictionary, scan_result: Dictionary, now: float) -> Array:
	var out = []
	var src = str(state.get("source", ""))
	for p in state.get("pods", []):
		var phase = str(p.get("phase", ""))
		if not phase in ["Succeeded", "Failed"]:
			continue
		var fin = float(p.get("finished", 0.0))
		if fin <= 0.0 or now - fin < FINISHED_AFTER:
			continue
		var what = "container" if src == "docker" else "pod"
		var f = _finding("scrappy", "finished", "%s/%s" % [p["ns"], p["name"]], "low", "Finished %s %s/%s is still here" % [what, p["ns"], p["name"]])
		f["evidence"] = ["%s %s ago (%s)." % ["Succeeded" if phase == "Succeeded" else "Failed", K.fmt_age(fin), p["status"]]]
		if phase == "Failed":
			f["evidence"].append("Its log goes with it: read it first if the failure still matters.")
		f["proposal"] = "Remove the finished %s." % what
		f["risk"] = "Its log and exit details are lost; nothing that is running is touched."
		f["action"] = {"op": "delete_pod", "ns": p["ns"], "name": p["name"]}
		f["action_label"] = "Remove " + what
		f["uids"] = [str(p["uid"])]
		out.append(f)
	if scan_result.get("ok", false):
		var d: Dictionary = scan_result.get("data", {})
		for img in d.get("images", []):
			if int(img.get("containers", 1)) > 0:
				continue
			var name = "%s:%s" % [img.get("repo", "<none>"), img.get("tag", "<none>")]
			var f = _finding("scrappy", "unused-image", "image/" + str(img.get("id", "")).trim_prefix("sha256:").left(12), "low", "Image %s is not used by any container" % name)
			f["evidence"] = ["Size %s, of which %s is not shared with other images." % [K.fmt_bytes(float(img.get("size", 0))), K.fmt_bytes(float(img.get("unique", 0)))],
				"Created %s." % str(img.get("created", "at an unknown time"))]
			f["proposal"] = "Remove the image. It can be pulled or built again."
			f["risk"] = "If it was built here and never pushed, it has to be rebuilt."
			f["action"] = {"op": "remove_image", "ns": "", "name": name, "id": str(img.get("id", ""))}
			f["action_label"] = "Remove image"
			f["reclaim"] = float(img.get("unique", 0))
			out.append(f)
		for v in d.get("volumes", []):
			if int(v.get("links", 1)) > 0:
				continue
			var f = _finding("scrappy", "unattached-volume", "volume/" + str(v.get("name", "")), "info", "Volume %s is not attached to any container" % v.get("name", ""))
			f["evidence"] = ["Size %s." % (K.fmt_bytes(float(v["size"])) if v.get("size") != null else "unknown")]
			f["proposal"] = "Check what it holds before deciding. Scrappy will not remove volumes: unattached is not the same as unwanted."
			out.append(f)
	return out

# ---- Archie: data that has nowhere lasting to live (reports only; never touches data)

static func archie_rules(state: Dictionary) -> Array:
	var by_owner = {}
	var docker = str(state.get("source", "")) == "docker"
	for p in state.get("pods", []):
		if str(p.get("phase", "")) in ["Succeeded", "Failed"]:
			continue
		var st = p.get("store", {})
		if typeof(st) != TYPE_DICTIONARY or not st.get("known", false):
			continue          # the source said nothing about storage: no guessing
		var o = _owner(p)
		if not by_owner.has(o):
			by_owner[o] = {"pods": [], "store": st, "role": Models.machine_for(p), "image": str(p["containers"][0].get("image", "")) if not p.get("containers", []).is_empty() else ""}
		by_owner[o]["pods"].append(p)
	var out = []
	for o in by_owner:
		var g = by_owner[o]
		var st: Dictionary = g["store"]
		var uids = g["pods"].map(func(x): return str(x["uid"]))
		if STATEFUL.has(g["role"]) and st["persistent"].is_empty() and st["binds"].is_empty():
			var kind: Array = STATEFUL[g["role"]]
			var f = _finding("archie", "no-persistent-storage", o, kind[0], "%s keeps its data nowhere lasting" % o)
			f["evidence"] = ["Runs %s, %s." % [g["image"], kind[1]]]
			if not st["anonymous"].is_empty():
				f["evidence"].append("Its only volumes have no name: " + ", ".join(PackedStringArray(st["anonymous"])) + ".")
			elif not st["scratch"].is_empty():
				f["evidence"].append("Its volumes are scratch space (%s): deleted with the %s." % [", ".join(PackedStringArray(st["scratch"])), "container" if docker else "pod"])
			else:
				f["evidence"].append("No volume is mounted: data is written inside the %s itself." % ("container's writable layer" if docker else "pod's container"))
			f["proposal"] = ("Mount a named volume at its data directory" if docker else "Mount a PersistentVolumeClaim at its data directory") + ", then set up a backup and test a restore."
			f["risk"] = "Only cached data is lost, which is often fine; confirm nothing relies on it surviving." if g["role"] == "cache_server" else \
				"Recreating, rescheduling or upgrading it loses the data. A copy of the files is not a backup until a restore has been tried."
			f["uids"] = uids
			out.append(f)
		elif not st["anonymous"].is_empty():
			var f = _finding("archie", "anonymous-volume", o, "low", "%s keeps data in a volume without a name" % o)
			f["evidence"] = ["Unnamed volumes: " + ", ".join(PackedStringArray(st["anonymous"])) + "."]
			f["proposal"] = "Give the volume a name (a named volume in Compose, or -v name:/path), so it is clear what holds this data."
			f["risk"] = "Recreating the container starts with a new empty volume; removing it with -v deletes the old one."
			f["uids"] = uids
			out.append(f)
	return out

# ---- Forge: what was built here (after a scan)

static func forge_rules(state: Dictionary, scan_result: Dictionary) -> Array:
	var out = []
	if not scan_result.get("ok", false):
		return out
	var d: Dictionary = scan_result.get("data", {})
	for img in d.get("images", []):
		if int(img.get("containers", 0)) <= 0 or not img.has("digests") or int(img["digests"]) > 0:
			continue
		var name = "%s:%s" % [img.get("repo", "<none>"), img.get("tag", "<none>")]
		var f = _finding("forge", "local-build", "image/" + str(img.get("id", "")).trim_prefix("sha256:").left(12), "low", "Image %s runs here but exists only on this machine" % name)
		f["evidence"] = ["It has no registry digest: it was built here and never pushed or pulled.", "Used by %d container(s)." % int(img["containers"])]
		f["proposal"] = "Push it to your registry and run it by version, so it can be pulled again on another machine."
		f["risk"] = "If this machine's disk is lost or the image is removed, its containers cannot be recreated without rebuilding it from source."
		f["uids"] = state.get("pods", []).filter(func(p): return p.get("containers", []).any(func(c): return str(c.get("image", "")) == name or str(c.get("image", "")) == str(img.get("repo", "")))).map(func(p): return str(p["uid"]))
		out.append(f)
	var bc: Dictionary = d.get("build_cache", {})
	if float(bc.get("reclaimable", 0.0)) >= BUILD_CACHE_REPORT:
		var f = _finding("forge", "build-cache", "build-cache", "info", "Build cache holds %s no build is using" % K.fmt_bytes(float(bc["reclaimable"])))
		f["evidence"] = ["%d cache entries, %d in use." % [int(bc.get("entries", 0)), int(bc.get("in_use", 0))]]
		f["proposal"] = "Prune it when no build is running (docker builder prune). The next build of each image starts from scratch."
		out.append(f)
	return out

# ---- Blueprint: the definition says one thing, the running state another

static func blueprint_rules(state: Dictionary) -> Array:
	var out = []
	for w in state.get("workloads", []):
		var kind = str(w.get("kind", ""))
		if not kind in ["Deployment", "StatefulSet", "DaemonSet", "Compose"]:
			continue
		var want = int(w.get("replicas", 0))
		var ready = int(w.get("ready", 0))
		if want <= 0 or ready >= want:
			continue
		var subject = "%s/%s" % [w["ns"], w["name"]]
		var pods = state.get("pods", []).filter(func(p): return str(p["ns"]) == str(w["ns"]) and str(p.get("wname", "")) == str(w["name"]))
		var f
		if kind == "Compose":
			f = _finding("blueprint", "drift", subject, "medium" if ready == 0 else "low", "Compose service %s: %d of %d containers running" % [subject, ready, want])
			f["proposal"] = "Start the stopped containers, or bring the project back to its definition (docker compose up -d)."
		else:
			f = _finding("blueprint", "drift", subject, "medium" if ready == 0 else "low", "%s %s: %d of %d replicas ready" % [kind, subject, ready, want])
			f["proposal"] = "Find out why the missing replicas do not come up (Bob's fix list). If fewer are wanted, change the count in its definition, not by hand."
		f["evidence"] = ["Desired %d, ready %d, for at least %d minutes." % [want, ready, int(DRIFT_HOLD / 60.0)]]
		var notready = pods.filter(func(p): return not bool(p.get("ready", false)))
		if not notready.is_empty():
			f["evidence"].append("Not ready: " + ", ".join(PackedStringArray(notready.slice(0, 4).map(func(p): return "%s (%s)" % [p["name"], p["status"]]))))
		f["uids"] = pods.map(func(p): return str(p["uid"]))
		f["hold"] = DRIFT_HOLD
		out.append(f)
	return out

# ---- reading the results

func worker(id: String) -> Dictionary:
	for w in WORKERS:
		if w["id"] == id:
			return w
	return {}

func of_worker(id: String) -> Array:
	return sorted(findings.values().filter(func(f): return id == "" or f["worker"] == id))

static func sorted(list: Array) -> Array:
	var l = list.duplicate()
	l.sort_custom(func(a, b):
		var sa = SEVERITY_ORDER.get(a["severity"], 9)
		var sb = SEVERITY_ORDER.get(b["severity"], 9)
		return sa < sb if sa != sb else str(a["key"]) < str(b["key"]))
	return l

# What a worker's tag and panel say about it.
func status_of(id: String) -> String:
	var mine = of_worker(id)
	if id in ["scrappy", "forge"] and source == "docker" and scan.is_empty():
		return "images not scanned yet"
	if id == "forge" and mine.is_empty() and str(scan.get("data", {}).get("provenance", "")) == "unrecorded":
		return "this engine does not record where images came from"
	if mine.is_empty():
		return "all clear"
	var top = mine[0]["severity"]
	var with_action = mine.filter(func(f): return not f["action"].is_empty()).size()
	return "%d finding%s, worst %s%s" % [mine.size(), "" if mine.size() == 1 else "s", top, (", %d awaiting approval" % with_action) if with_action > 0 else ""]

func worst_of(id: String) -> String:
	var mine = of_worker(id)
	return "" if mine.is_empty() else str(mine[0]["severity"])

# ---- reports

func report_markdown() -> String:
	var md = PackedStringArray(["# KubeFactory Krew report", "", "Source: %s%s. Written %s UTC." % [source, " (SIMULATED)" if source == "simulation" else "", Time.get_datetime_string_from_system(true)], ""])
	for w in WORKERS:
		var mine = of_worker(w["id"])
		md.append("## %s (%s): %s" % [w["name"], w["role"], status_of(w["id"])])
		md.append("")
		for f in mine:
			md.append("- **%s** %s  (`%s`)" % [f["severity"].to_upper(), f["title"], f["resource"]])
			for e in f["evidence"]:
				md.append("  - %s" % e)
			if f["proposal"] != "":
				md.append("  - Proposed: %s" % f["proposal"])
			if str(f.get("common", "")) != "":
				md.append("  - Common fix: %s" % f["common"])
			if f["risk"] != "":
				md.append("  - Risk: %s" % f["risk"])
		md.append("")
	md.append("## Resolved (%d)" % history.size())
	for f in history.slice(0, 50):
		md.append("- %s  (`%s`), resolved %s ago" % [f["title"], f["resource"], K.fmt_age(float(f["resolved_at"]))])
	return "\n".join(md) + "\n"

func report_json() -> String:
	return JSON.stringify({"source": source, "simulated": source == "simulation", "written": Time.get_datetime_string_from_system(true) + "Z",
		"open": sorted(findings.values()), "resolved": history}, "  ")
