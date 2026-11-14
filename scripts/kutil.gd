extends RefCounted
# Shared helpers: status classification, quantity parsing, formatting.

static func health_of(status: String, ready: bool) -> String:
	if status == "Running":
		return "ok" if ready else "warn"
	if status in ["Completed", "Succeeded"]:
		return "done"
	if status in ["Pending", "ContainerCreating", "PodInitializing", "Terminating"] or status.begins_with("Init:"):
		return "warn"
	return "bad"

# Size a sign's Label3D so its text fits a w x h metre panel: `pixel` is the
# normal text scale, and the label only ever shrinks from it. Call after every
# text change, since cluster names and alert lines can be any length.
static func fit_label(l: Label3D, w: float, h: float, pixel: float = 0.01) -> void:
	var f = l.font if l.font != null else ThemeDB.fallback_font
	var sz = f.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.font_size)
	sz.y += l.line_spacing * l.text.count("\n")
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	l.pixel_size = minf(pixel, minf(w / sz.x, h / sz.y))

# Bob's patter. He greets you with one of these and mutters them as you walk up.
const BOB_ZINGERS = [
	"CrashLoopBackOff? Back in my day we called that Monday.",
	"That pod has restarted more times than my hip.",
	"It is always DNS. Except when it is the image tag. Today it is the image tag.",
	"You deploy on Fridays, don't you? I can tell by the eyes.",
	"Have you tried turning it off and on again? That will be forty years of experience, please.",
	"Somebody typed 'latest' and prayed. I can smell it from here.",
	"I have seen YAML that would make a grown operator weep. Yours is... getting there.",
	"Your indentation is doing things to me that my doctor warned about.",
	"That is not a cluster, that is a cry for help with a load balancer.",
	"I have fixed worse with a paperclip. Not much worse, mind.",
]
const BOB_RIZZ = [
	"Are you a liveness probe? You checked on me and my heart restarted.",
	"You must be a LoadBalancer, because you just got an external IP straight to my heart.",
	"If you were a pod, I would never set a memory limit on you.",
	"Are you a ConfigMap? Because you have got everything I need.",
	"You and me are like a Service and its endpoints: I would be nothing without you.",
	"I would give you five nines of uptime, and I do not say that to every operator.",
	"You have got more replicas of charm than this cluster has of frontend.",
	"Is your name kubectl? Because you have got me under control.",
	"I would never drain you, sweetheart. You are staying scheduled.",
	"They say nothing is highly available. Then you walked up to my stand.",
]
const BOB_IDLE = [
	"Nothing broken. Either you are very good, or nobody has deployed yet.",
	"All green. Enjoy it. It will not last, it never does.",
	"A quiet cluster. I have not been this relaxed since they invented rollbacks.",
	"No alarms, no smoke. Did you break the monitoring instead?",
]
# One dry remark per kind of failure, shown on its card in his fix list.
const BOB_QUIPS = {
	"CrashLoopBackOff": "Up, down, up, down. It is doing more squats than I ever did.",
	"ImagePullBackOff": "You cannot pull what is not there. Believe me, I have tried.",
	"ErrImagePull": "You cannot pull what is not there. Believe me, I have tried.",
	"OOMKilled": "Ate until it burst. I had an uncle like that.",
	"Unschedulable": "All dressed up and no node to go to.",
	"Error": "It says 'Error'. Very helpful. Thank you, pod.",
	"Evicted": "Thrown out for hogging the place. Happens to the best of us.",
	"CreateContainerConfigError": "It wants a Secret nobody told it. Relatable.",
	"NotReady": "This node has gone for a lie-down and did not say when it is back.",
	"Cordoned": "Somebody put the rope up and forgot to take it down.",
	"Restarting": "Still standing, but it flinches every few minutes.",
}

# A random line of Bob's: a zinger or some rizz when there is work, relief when there is none.
static func bob_line(has_jobs: bool) -> String:
	if not has_jobs and randf() < 0.6:
		return BOB_IDLE[randi() % BOB_IDLE.size()]
	var pool = BOB_RIZZ if randf() < 0.5 else BOB_ZINGERS
	return pool[randi() % pool.size()]

# Bob's diagnosis for a pod status: [what is wrong, what he would do, action].
# The action is "" (nothing to press), "restart", "delete_pod" or "uncordon".
static func diagnose(status: String) -> Array:
	match status:
		"ImagePullBackOff", "ErrImagePull", "InvalidImageName":
			return ["The image cannot be pulled: the name or tag is wrong, or the registry wants a login.",
				"Fix the image in the workload's spec (or add an imagePullSecret). Restarting will not help until then - read the events for the exact pull error.", ""]
		"CrashLoopBackOff":
			return ["The container starts, falls over, and gets restarted again and again.",
				"Read its logs for the crash reason. If it was waiting on something that is back now, a rolling restart clears it.", "restart"]
		"OOMKilled":
			return ["It ran out of memory and the kernel killed it.",
				"Raise its memory limit, or find the leak. A restart only buys time.", "restart"]
		"CreateContainerConfigError", "CreateContainerError":
			return ["It is pointing at a ConfigMap or Secret that is not there, or has a bad key.",
				"Create the missing ConfigMap / Secret, or fix the reference. The events name the missing piece.", ""]
		"Unschedulable":
			return ["No node will take it: nothing has room, or every node that fits is cordoned.",
				"Free up capacity, or uncordon a node so the scheduler can place it.", "uncordon"]
		"Evicted":
			return ["The node was short on disk or memory and threw it out.",
				"Dismantle the leftover pod; its workload has already built a replacement elsewhere.", "delete_pod"]
		"Error":
			return ["The container exited with an error.",
				"Read the logs for the last lines before it died. Rebuilding the pod gives it a clean start.", "delete_pod"]
		"Restarting":
			return ["It is running now, but it keeps getting restarted.",
				"Something is intermittently killing it. Check the logs and its memory limit before it gets worse.", ""]
	return ["It is not healthy (%s)." % status,
		"Start with its events and logs. If nothing stands out, rebuild the pod.", "delete_pod"]

# Everything in the cluster that needs fixing, worst first: unhealthy nodes,
# failing and unschedulable pods, and pods that keep restarting. Each entry
# carries Bob's diagnosis. Used by his stand's board and his fix list.
static func issues(st: Dictionary) -> Array:
	var out = []
	for n in st.get("nodes", []):
		if not n["ready"]:
			out.append({"kind": "node", "sev": "bad", "name": n["name"], "node": n["name"], "status": "NotReady",
				"why": "The node has stopped reporting in: its kubelet is down, or it lost the network.",
				"fix": "Check the machine itself. Its pods are rescheduled elsewhere after a few minutes; drain it if it is not coming back.", "action": ""})
		elif n["cordoned"]:
			out.append({"kind": "node", "sev": "warn", "name": n["name"], "node": n["name"], "status": "Cordoned",
				"why": "Scheduling is switched off here, so no new pods can land on it.",
				"fix": "If the maintenance is done, uncordon it.", "action": "uncordon"})
	for p in st.get("pods", []):
		var status = ""
		var sev = "bad"
		if p["node"] == "":
			status = "Unschedulable"
			sev = "warn" if p["health"] != "bad" else "bad"
		elif p["health"] == "bad":
			status = str(p["status"])
		elif p["health"] == "ok" and int(p["restarts"]) >= 5:
			status = "Restarting"
			sev = "warn"
		if status == "":
			continue
		var d = diagnose(status)
		out.append({"kind": "pod", "sev": sev, "name": p["name"], "uid": p["uid"], "ns": p["ns"], "node": p["node"],
			"wkind": p["wkind"], "wname": p["wname"], "restarts": int(p["restarts"]), "status": status,
			"why": d[0], "fix": d[1], "action": d[2]})
	out.sort_custom(func(a, b): return ("0" if a["sev"] == "bad" else "1") + a["name"] < ("0" if b["sev"] == "bad" else "1") + b["name"])
	return out

# `ls -la` output (POSIX long format) -> [{name, type: dir|file|link|other, size, mode, owner, group, mtime, link}]
static func parse_ls(text: String) -> Array:
	var out = []
	for ln in text.split("\n"):
		var f = ln.split(" ", false)
		if f.size() < 9 or f[0].length() < 10:
			continue
		var rest = ln
		for i in 8:
			rest = rest.lstrip(" ")
			var j = rest.find(" ")
			if j >= 0:
				rest = rest.substr(j)
		var name = rest.lstrip(" ")
		if name in [".", "..", ""]:
			continue
		var e = {"name": name, "type": "other", "size": f[4].to_int(), "mode": f[0], "owner": f[2], "group": f[3], "mtime": "%s %s %s" % [f[5], f[6], f[7]], "link": ""}
		match f[0][0]:
			"d":
				e["type"] = "dir"
			"-":
				e["type"] = "file"
			"l":
				e["type"] = "link"
				var k = name.find(" -> ")
				if k >= 0:
					e["link"] = name.substr(k + 4)
					e["name"] = name.substr(0, k)
		out.append(e)
	return out

static func fmt_bytes(n: float) -> String:
	if n < 1024.0:
		return "%d B" % int(n)
	if n < 1048576.0:
		return "%.1f KiB" % (n / 1024.0)
	if n < 1073741824.0:
		return "%.1f MiB" % (n / 1048576.0)
	return "%.2f GiB" % (n / 1073741824.0)

# A path as it is shown on screen: the user's own folder is written as "~", so
# a screenshot or a shared screen never gives away the account name.
static func tidy_path(p: String, home: String = "") -> String:
	if home == "":
		home = OS.get_environment("USERPROFILE")
		if home == "":
			home = OS.get_environment("HOME")
	var a = p.replace("\\", "/")
	var h = home.replace("\\", "/").rstrip("/")
	if h != "" and (a.to_lower() == h.to_lower() or a.to_lower().begins_with(h.to_lower() + "/")):
		return "~" + a.substr(h.length())
	return p

# Tables: keep the rows that contain `filter` in any column, then order them by
# one column. getters: {column id: Callable(row) -> value}. Numbers sort as
# numbers, everything else as text without regard to case; rows that compare
# equal keep the order they came in. A table of TABLE_LIMIT rows or more is
# handed back untouched: it is too long to sort and filter on every keystroke.
const TABLE_LIMIT = 10000

# Intersect the crosshair ray with the display, not the machine's oversized collision box.
static func ray_hits_screen(origin: Vector3, direction: Vector3, rect: Dictionary, reach: float) -> bool:
	var normal: Vector3 = rect["normal"]
	var facing = direction.dot(normal)
	if facing >= -0.001:
		return false
	var distance = (rect["pos"] - origin).dot(normal) / facing
	if distance < 0.0 or distance > reach:
		return false
	var offset: Vector3 = origin + direction * distance - rect["pos"]
	return absf(offset.dot(rect["right"])) <= rect["size"].x * 0.5 and absf(offset.dot(rect["up"])) <= rect["size"].y * 0.5

static func table_rows(rows: Array, col: String, desc: bool, filter: String, getters: Dictionary) -> Array:
	if rows.size() >= TABLE_LIMIT:
		return rows
	var want = filter.strip_edges().to_lower()
	var kept = []
	for i in rows.size():
		var r = rows[i]
		if want != "":
			var hit = false
			for id in getters:
				if str(getters[id].call(r)).to_lower().contains(want):
					hit = true
					break
			if not hit:
				continue
		kept.append([r, i])
	if col != "" and getters.has(col):
		var g: Callable = getters[col]
		kept.sort_custom(func(a, b):
			var x = g.call(a[0])
			var y = g.call(b[0])
			var numbers = typeof(x) in [TYPE_INT, TYPE_FLOAT] and typeof(y) in [TYPE_INT, TYPE_FLOAT]
			if not numbers:
				x = str(x).to_lower()
				y = str(y).to_lower()
			if x == y:
				return a[1] < b[1]
			return (x > y) if desc else (x < y))
	var out = []
	for k in kept:
		out.append(k[0])
	return out

# A path inside a mounted volume, cleaned: "" if it would leave the mount.
static func path_inside(root: String, rel: String) -> String:
	var parts = []
	for seg in rel.replace("\\", "/").split("/", false):
		if seg == ".":
			continue
		if seg == "..":
			return ""
		parts.append(seg)
	var base = root.rstrip("/")
	return (base if base != "" else "/") if parts.is_empty() else base + "/" + "/".join(PackedStringArray(parts))

static func health_color(h: String) -> Color:
	match h:
		"ok":
			return Color(0.25, 1.0, 0.45)
		"warn":
			return Color(1.0, 0.78, 0.15)
		"done":
			return Color(0.35, 0.7, 1.0)
	return Color(1.0, 0.22, 0.18)

static func fmt_age(created) -> String:
	if created <= 0:
		return "-"
	var s = int(Time.get_unix_time_from_system() - created)
	if s < 0:
		s = 0
	if s < 120:
		return "%ds" % s
	if s < 7200:
		return "%dm" % int(s / 60.0)
	if s < 172800:
		return "%dh" % int(s / 3600.0)
	return "%dd" % int(s / 86400.0)

static func parse_cpu(q) -> float:
	var s = str(q)
	if s == "":
		return 0.0
	if s.ends_with("m"):
		return s.trim_suffix("m").to_float() / 1000.0
	if s.ends_with("u"):
		return s.trim_suffix("u").to_float() / 1.0e6
	if s.ends_with("n"):
		return s.trim_suffix("n").to_float() / 1.0e9
	return s.to_float()

static func parse_mem(q) -> float:
	var s = str(q)
	if s == "":
		return 0.0
	var units = [["Ki", 1024.0], ["Mi", 1048576.0], ["Gi", 1073741824.0], ["Ti", 1099511627776.0],
		["k", 1.0e3], ["K", 1.0e3], ["M", 1.0e6], ["G", 1.0e9], ["T", 1.0e12], ["m", 0.001]]
	for u in units:
		if s.ends_with(u[0]):
			return s.trim_suffix(u[0]).to_float() * u[1]
	return s.to_float()

static func fmt_mem(b: float) -> String:
	if b >= 1073741824.0:
		return "%.1f Gi" % (b / 1073741824.0)
	return "%d Mi" % int(b / 1048576.0)

# Best guess at who runs a cluster, from its kubeconfig context name + API URL.
static func provider_hint(ctx: String, server: String) -> String:
	var s = server.to_lower()
	var c = ctx.to_lower()
	if s.contains("/k8s/clusters/"):
		return "Rancher"
	if s.contains(".eks.amazonaws.com") or c.contains(":eks:") or c.contains("eks"):
		return "AWS EKS"
	if s.contains(".azmk8s.io") or c.contains("aks"):
		return "Azure AKS"
	if c.begins_with("gke_") or c.contains("gke") or s.contains("googleapis.com"):
		return "Google GKE"
	if s.contains("ondigitalocean.com"):
		return "DigitalOcean"
	if s.contains("openshift") or c.contains("openshift"):
		return "OpenShift"
	if c.begins_with("kind-"):
		return "kind"
	if c.begins_with("k3d-"):
		return "k3d"
	if c == "minikube":
		return "minikube"
	if c == "docker-desktop":
		return "Docker Desktop"
	if c.contains("rancher"):
		return "Rancher"
	return "Kubernetes"

static func provider_color(p: String) -> Color:
	var s = p.to_lower()
	if s.contains("aws"):
		return Color(1.0, 0.6, 0.0)
	if s.contains("azure"):
		return Color(0.0, 0.47, 0.83)
	if s.contains("google"):
		return Color(0.2, 0.66, 0.33)
	if s.contains("rancher") or s.contains("rke") or s.contains("k3"):
		return Color(0.0, 0.72, 0.78)
	if s.contains("docker"):
		return Color(0.11, 0.39, 0.93)
	if s.contains("openshift"):
		return Color(0.93, 0.0, 0.0)
	return Color(0.72, 0.72, 0.76)

# Action tiers. Every tool and every button is tagged with one: the higher the
# Mk, the more it can break, and the hotter its colour.
const TIERS = ["", "SAFE", "CONSTRUCTIVE", "DISRUPTIVE", "DESTRUCTIVE", "CRITICAL"]

static func tier_color(mk: int) -> Color:
	match mk:
		1:
			return Color(0.82, 0.86, 0.9)
		2:
			return Color(0.3, 0.86, 0.45)
		3:
			return Color(1.0, 0.82, 0.2)
		4:
			return Color(1.0, 0.5, 0.14)
	return Color(1.0, 0.2, 0.2)

static func valid_name(s: String) -> bool:
	var re = RegEx.new()
	re.compile("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
	return re.search(s) != null

static func hue_color(key: String, sat: float, val: float) -> Color:
	return Color.from_hsv(float(key.hash() % 360) / 360.0, sat, val)

static func find_workload(state: Dictionary, ns: String, kind: String, wname: String) -> Variant:
	for w in state.get("workloads", []):
		if w["ns"] == ns and w["kind"] == kind and w["name"] == wname:
			return w
	return null

static func find_pod(state: Dictionary, uid: String) -> Variant:
	for p in state.get("pods", []):
		if p["uid"] == uid:
			return p
	return null

static func selects(selector: Dictionary, labels: Dictionary) -> bool:
	if selector.is_empty():
		return false
	for k in selector:
		if str(labels.get(k, "\u0000")) != str(selector[k]):
			return false
	return true

# ---- multi-user: action tiers and policy

# How dangerous an action is (1 safe .. 5 critical). Matches the tool tiers.
static func tier_of(a: Dictionary, state: Dictionary) -> int:
	match a["op"]:
		"logs", "events", "cluster_events", "templates", "portainer_open", "file_mounts", "file_list", "file_read", "forward":
			return 1
		"create", "apply_app", "deploy_template", "portainer_install":
			return 2
		"scale_by":
			return 2 if int(a.get("delta", 1)) > 0 else 3
		"scale":
			var w = find_workload(state, a["ns"], a["kind"], a["name"])
			return 2 if w == null or int(a["replicas"]) >= int(w["replicas"]) else 3
		"cordon":
			return 3 if a.get("on", true) else 2
		"restart":
			return 3
		"delete_pod":
			return 4
	return 5

static func short_user(u: String) -> String:
	if u.begins_with("system:serviceaccount:"):
		return u.get_slice(":", 3)
	if u.contains("@"):
		return u.get_slice("@", 0)
	return u

# Highest tool tier the policy grants this user: a per-user entry wins, then
# the best matching group, then the default.
static func policy_max_tier(policy: Dictionary, user: String, groups: Array) -> int:
	var users = policy.get("users", {})
	if typeof(users) == TYPE_DICTIONARY:
		for key in [user, short_user(user)]:
			if users.has(key):
				return clampi(int(users[key]), 1, 5)
	var best = -1
	var gmap = policy.get("groups", {})
	if typeof(gmap) == TYPE_DICTIONARY:
		for g in groups:
			if gmap.has(g):
				best = maxi(best, int(gmap[g]))
	if best > 0:
		return clampi(best, 1, 5)
	return clampi(int(policy.get("max_tier", 5)), 1, 5)

# ---- where the editable files live (configs, bundled app setups)
# Installed build: the folder holding KubeFactory.exe. From source: the project folder.
static func data_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://").trim_suffix("/")

static func data_path(rel: String) -> String:
	return data_dir().path_join(rel)

# The editable config files (policy, app lists, log providers, Portainer link, Bob's
# settings). Installed build: beside KubeFactory.exe. From source: the config folder.
static func config_path(file_name: String) -> String:
	if OS.has_feature("template"):
		return data_path(file_name)
	return data_path("config/" + file_name)

static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

# ---- per-user settings (kept in the user folder, survive upgrades)
static func load_settings() -> Dictionary:
	var s = {"fullscreen": false, "muted": false, "sensitivity": 1.0, "welcomed": false, "belts": true, "graphics": "auto"}
	var d = read_json(OS.get_user_data_dir().path_join("settings.json"))
	if typeof(d) == TYPE_DICTIONARY:
		for k in d:
			s[k] = d[k]
	return s

static func save_settings(s: Dictionary) -> void:
	var f = FileAccess.open(OS.get_user_data_dir().path_join("settings.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(s, "  "))
		f.close()

# ---- running curl without putting secrets on the command line
# Anything sensitive (API keys, basic-auth users, webhook URLs) goes into a
# short-lived curl config file instead of the argument list, where any other
# process on the machine could read it. Only http(s) is ever allowed.
# secret_opts: [[option, value], ...]  e.g. [["header", "X-API-Key: abc"], ["url", "https://..."]]
static func curl(args: Array, secret_opts: Array = []) -> Dictionary:
	var full = ["--proto", "=http,https", "--proto-redir", "=http,https"] + args
	var path = ""
	if secret_opts.size() > 0:
		path = OS.get_user_data_dir().path_join("curl-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"code": -1, "out": "could not write a temporary file"}
		for o in secret_opts:
			f.store_line("%s = \"%s\"" % [o[0], str(o[1]).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ").replace("\r", " ")])
		f.close()
		full = ["-K", path] + full
	var out = []
	var code = OS.execute("curl", PackedStringArray(full), out, true)
	if path != "":
		DirAccess.remove_absolute(path)
	return {"code": code, "out": str(out[0]) if out.size() > 0 else ""}
