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
		"logs", "events", "cluster_events", "templates", "portainer_open":
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

static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

# ---- per-user settings (kept in the user folder, survive upgrades)
static func load_settings() -> Dictionary:
	var s = {"fullscreen": false, "muted": false, "sensitivity": 1.0, "welcomed": false, "belts": true}
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
