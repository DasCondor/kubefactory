extends RefCounted
const KU = preload("res://scripts/kutil.gd")
# What Porter (the Portainer NPC) can build for you.
#  - APPS: complete setups bundled with the game (apps/<id>.k8s.yaml and
#    apps/<id>.compose.yaml): workloads + services + storage + a generated secret.
#  - Portainer app templates: the container templates from a Portainer server
#    (or Portainer's public catalogue), turned into a Deployment + Service on
#    Kubernetes or a `docker run` on a plain Docker engine.

const APPS = [
	{"id": "web", "name": "Web server", "desc": "Two nginx replicas behind a Service, with readiness probes and resource limits.",
		"parts": ["Deployment  web  (nginx x2)", "Service  web  :80"], "secret": false,
		"sim": [["Deployment", "web", "nginx:1.27-alpine", 2, "80/TCP"]]},
	{"id": "redis", "name": "Redis cache", "desc": "A Redis instance with snapshotting and an LRU memory cap, plus its Service.",
		"parts": ["Deployment  redis", "Service  redis  :6379"], "secret": false,
		"sim": [["Deployment", "redis", "redis:7.4-alpine", 1, "6379/TCP"]]},
	{"id": "postgres", "name": "PostgreSQL database", "desc": "A PostgreSQL StatefulSet with a 1Gi volume, a generated password stored as a Secret, and its Service.",
		"parts": ["Secret  app-db  (generated password)", "StatefulSet  postgres", "PersistentVolumeClaim  1Gi", "Service  postgres  :5432"], "secret": true,
		"sim": [["StatefulSet", "postgres", "postgres:16-alpine", 1, "5432/TCP"]]},
	{"id": "wordpress", "name": "WordPress + MySQL", "desc": "A full WordPress site: MySQL with persistent storage, WordPress wired to it, a shared generated password, and both Services.",
		"parts": ["Secret  app-db  (generated password)", "PersistentVolumeClaim  mysql-data  1Gi", "Deployment  mysql", "Service  mysql  :3306",
			"Deployment  wordpress", "Service  wordpress  :80 (NodePort)"], "secret": true,
		"sim": [["Deployment", "mysql", "mysql:8.4", 1, "3306/TCP"], ["Deployment", "wordpress", "wordpress:6-apache", 1, "80/TCP"]]},
	{"id": "media", "name": "Media server suite", "desc": "A home media server: Plex to watch, Overseerr to request, Sonarr / Radarr / Lidarr / Bazarr to organise TV, films, music and subtitles, Jackett as the indexer proxy they search through (Prowlarr is there as the alternative), qBittorrent as the download client and Tautulli for Plex statistics. They share one media and one downloads volume.",
		"parts": ["Plex  :32400", "Overseerr  :5055  (requests)", "Sonarr  :8989  (TV)", "Radarr  :7878  (films)", "Lidarr  :8686  (music)",
			"Bazarr  :6767  (subtitles)", "Jackett  :9117  (indexer proxy)", "Prowlarr  :9696  (indexer manager)", "qBittorrent  :8080  (downloads)", "Tautulli  :8181  (Plex stats)",
			"Volumes  media, downloads + one config volume each"], "secret": false,
		"sim": [["Deployment", "plex", "lscr.io/linuxserver/plex:latest", 1, "32400/TCP"], ["Deployment", "overseerr", "lscr.io/linuxserver/overseerr:latest", 1, "5055/TCP"],
			["Deployment", "sonarr", "lscr.io/linuxserver/sonarr:latest", 1, "8989/TCP"], ["Deployment", "radarr", "lscr.io/linuxserver/radarr:latest", 1, "7878/TCP"],
			["Deployment", "lidarr", "lscr.io/linuxserver/lidarr:latest", 1, "8686/TCP"], ["Deployment", "bazarr", "lscr.io/linuxserver/bazarr:latest", 1, "6767/TCP"],
			["Deployment", "jackett", "lscr.io/linuxserver/jackett:latest", 1, "9117/TCP"],
			["Deployment", "prowlarr", "lscr.io/linuxserver/prowlarr:latest", 1, "9696/TCP"], ["Deployment", "qbittorrent", "lscr.io/linuxserver/qbittorrent:latest", 1, "8080/TCP"],
			["Deployment", "tautulli", "lscr.io/linuxserver/tautulli:latest", 1, "8181/TCP"]]},
	{"id": "monitoring", "name": "Monitoring dashboard", "desc": "Grafana with a ready-made container dashboard, fed by Prometheus, which scrapes cAdvisor (per-container CPU, memory, network) and node-exporter (the host). Grafana's admin password is generated.",
		"parts": ["Secret  app-db  (generated Grafana admin password)", "Grafana  :3000  (dashboard: Containers)", "Prometheus  :9090", "cAdvisor  (container metrics)", "node-exporter  (host metrics)"], "secret": true,
		"sim": [["Deployment", "grafana", "grafana/grafana:11.2.0", 1, "3000/TCP"], ["Deployment", "prometheus", "prom/prometheus:v2.54.1", 1, "9090/TCP"],
			["DaemonSet", "cadvisor", "gcr.io/cadvisor/cadvisor:v0.49.1", 0, "8080/TCP"], ["DaemonSet", "node-exporter", "prom/node-exporter:v1.8.2", 0, "9100/TCP"]]},
]

const PORTAINER_MANIFEST = "https://downloads.portainer.io/ce-lts/portainer.yaml"

static func find(id: String) -> Variant:
	for a in APPS:
		if a["id"] == id:
			return a
	return null

static func file_for(id: String, flavor: String) -> String:
	return KU.data_path("apps/%s.%s.yaml" % [id, flavor])

static func load_config() -> Dictionary:
	var cfg = {"url": "", "api_key": "", "insecure_tls": false}
	if true:
		var d = KU.read_json(KU.config_path("portainer.json"))
		if typeof(d) == TYPE_DICTIONARY:
			for k in d:
				cfg[k] = d[k]
	return cfg

static func random_password(n: int = 24) -> String:
	var chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
	var crypto = Crypto.new()
	var bytes = crypto.generate_random_bytes(n)
	var s = ""
	for b in bytes:
		s += chars[b % chars.length()]
	return s

static func slug(title: String) -> String:
	var s = ""
	for ch in title.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			s += ch
		elif s != "" and not s.ends_with("-"):
			s += "-"
	return s.trim_suffix("-").left(40)

# ---- app lists (catalogues)
# Any list in Portainer's app-template format works: Portainer's own, the one
# served by your Portainer server, or community lists. Built-in lists come from
# config/catalogs.json (beside the exe when installed); lists added in-game are kept in the user folder.


static func _user_catalogs_path() -> String:
	return OS.get_user_data_dir().path_join("catalogs.json")

static func _read_list(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) == TYPE_DICTIONARY and typeof(d.get("catalogs")) == TYPE_ARRAY:
		return d["catalogs"]
	return []

static func load_catalogs() -> Array:
	var res = []
	var cfg = load_config()
	if str(cfg.get("url", "")) != "":
		res.append({"name": "My Portainer server", "url": str(cfg["url"]).trim_suffix("/") + "/api/templates",
			"api_key": str(cfg.get("api_key", "")), "insecure_tls": bool(cfg.get("insecure_tls", false)), "builtin": true})
	for c in _read_list(KU.config_path("catalogs.json")):
		c["builtin"] = true
		res.append(c)
	for c in _read_list(_user_catalogs_path()):
		c["builtin"] = false
		res.append(c)
	return res

static func save_user_catalogs(all: Array) -> void:
	var mine = []
	for c in all:
		if not c.get("builtin", false):
			mine.append({"name": c["name"], "url": c["url"]})
	var f = FileAccess.open(_user_catalogs_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"catalogs": mine}, "  "))
		f.close()

# Fetch one list as JSON text {source, templates, skipped}. Container templates
# only: stack templates need Portainer itself to deploy.
static func fetch_templates(cat: Dictionary) -> Dictionary:
	var src = str(cat.get("url", ""))
	if not (src.begins_with("https://") or src.begins_with("http://")):
		return {"ok": false, "text": "A list needs an http(s) address."}
	var args = ["-s", "-S", "-L", "--max-time", "30", "--max-filesize", "20000000"]
	var secrets = []
	if str(cat.get("api_key", "")) != "":
		if not src.begins_with("https://"):
			return {"ok": false, "text": "Refusing to send an API key over plain http. Use an https address for your Portainer server."}
		secrets.append(["header", "X-API-Key: " + str(cat["api_key"])])
	if cat.get("insecure_tls", false):
		args.append("-k")   # opt-in only: accepts a self-signed certificate
	args.append(src)
	var cr = KU.curl(args, secrets)
	var code = cr.code
	var text = cr.out
	var d = JSON.parse_string(text)
	var list = []
	if typeof(d) == TYPE_DICTIONARY and typeof(d.get("templates")) == TYPE_ARRAY:
		list = d["templates"]
	elif typeof(d) == TYPE_ARRAY:
		list = d
	else:
		return {"ok": false, "text": "That address did not return a Portainer-format app list.\n%s" % text.left(200)}
	if code != 0:
		return {"ok": false, "text": "Could not reach %s" % src}
	var keep = []
	var skipped = 0
	for t in list:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		if int(t.get("type", 1)) == 1 and str(t.get("platform", "linux")) == "linux" and str(t.get("image", "")) != "":
			keep.append(t)
		else:
			skipped += 1
	keep.sort_custom(func(x, y): return str(x.get("title", "")).to_lower() < str(y.get("title", "")).to_lower())
	return {"ok": true, "text": JSON.stringify({"source": src, "templates": keep, "skipped": skipped})}

# Community lists put app data under /portainer/...; treat those as plain data
# volumes. Any other host bind (docker.sock, /proc ...) is a real host mount.
static func is_data_bind(v: Dictionary) -> bool:
	return str(v.get("bind", "")).begins_with("/portainer/")

# ---- what Porter has installed, per cluster (kept in the user folder)

static func _installed_path() -> String:
	return OS.get_user_data_dir().path_join("installed.json")

static func load_installed() -> Array:
	if not FileAccess.file_exists(_installed_path()):
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(_installed_path()))
	return d if typeof(d) == TYPE_ARRAY else []

static func save_installed(list: Array) -> void:
	var f = FileAccess.open(_installed_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(list, "  "))
		f.close()

# Resolve a template's env vars to concrete values; passwords with no default
# get a generated one. Returns [[name, value], ...] and the generated names.
static func template_env(t: Dictionary) -> Array:
	var env = []
	var generated = []
	for e in t.get("env", []):
		var nm = str(e.get("name", ""))
		if nm == "":
			continue
		var val = ""
		if e.has("set"):
			val = str(e["set"])
		elif e.has("default"):
			val = str(e["default"])
		elif typeof(e.get("select")) == TYPE_ARRAY and e["select"].size() > 0:
			val = str(e["select"][0].get("value", ""))
			for o in e["select"]:
				if o.get("default", false):
					val = str(o.get("value", ""))
		else:
			var up = nm.to_upper()
			if up.contains("PASS") or up.contains("SECRET") or up.contains("KEY") or up.contains("TOKEN"):
				val = random_password()
				generated.append(nm)
		env.append([nm, val])
	return [env, generated]

# "8080:80/tcp" or "80/tcp" -> [host or 0, container, "TCP"]
static func parse_port(p) -> Array:
	var s = str(p)
	var proto = "TCP"
	if s.contains("/"):
		proto = s.get_slice("/", 1).to_upper()
		if not proto in ["TCP", "UDP", "SCTP"]:
			proto = "TCP"
		s = s.get_slice("/", 0)
	if s.contains(":"):
		return [s.get_slice(":", 0).to_int(), s.get_slice(":", 1).to_int(), proto]
	return [0, s.to_int(), proto]

static func _q(v: String) -> String:
	return "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ").replace("\r", " ").replace("\t", " ") + "\""

# ---- templates come from lists on the internet, so nothing in one is trusted.
# Everything that ends up in a `docker run` argument or a manifest is checked
# here first; a template that fails is refused outright.

static func _matches(pattern: String, s: String) -> bool:
	var re = RegEx.new()
	re.compile(pattern)
	return re.search(s) != null

static func valid_image(s: String) -> bool:
	# registry/path:tag@digest - must not look like a command-line option
	return _matches("^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$", s)

static func valid_path(s: String) -> bool:
	return _matches("^/[A-Za-z0-9._/@ -]{0,254}$", s) and not s.contains("..")

# "" if the template is safe to build, otherwise the reason it is refused.
static func template_problem(t: Dictionary) -> String:
	if typeof(t.get("image")) != TYPE_STRING or not valid_image(t["image"]):
		return "its image name is not a valid image reference"
	for v in t.get("volumes", []):
		if typeof(v) != TYPE_DICTIONARY:
			return "its storage list is malformed"
		if str(v.get("container", "")) != "" and not valid_path(str(v["container"])):
			return "it has an invalid container path"
		if v.has("bind") and not valid_path(str(v["bind"])):
			return "it has an invalid host path"
	for e in t.get("env", []):
		if typeof(e) != TYPE_DICTIONARY:
			return "its settings list is malformed"
		if str(e.get("name", "")) != "" and not _matches("^[A-Za-z_][A-Za-z0-9_.-]{0,127}$", str(e["name"])):
			return "it has an invalid setting name"
	var rp = str(t.get("restart_policy", ""))
	if rp != "" and not _matches("^(no|always|unless-stopped|on-failure(:[0-9]{1,3})?)$", rp):
		return "it has an invalid restart policy"
	if str(t.get("command", "")).length() > 2000:
		return "its command is unreasonably long"
	return ""

# Host paths this template wants mounted (not counting plain app-data folders).
static func host_binds(t: Dictionary) -> Array:
	var res = []
	for v in t.get("volumes", []):
		if typeof(v) == TYPE_DICTIONARY and v.has("bind") and not is_data_bind(v):
			res.append(str(v["bind"]))
	return res

# A Portainer container template as a Kubernetes Deployment + Service.
static func template_manifest(t: Dictionary, app: String, env: Array) -> String:
	var y = []
	y.append("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n  labels: {app: %s, kubefactory/app: %s}" % [app, app, app])
	y.append("spec:\n  replicas: 1\n  selector:\n    matchLabels: {app: %s}\n  template:\n    metadata:\n      labels: {app: %s}\n    spec:\n      containers:\n        - name: %s\n          image: %s" % [app, app, app, _q(str(t["image"]))])
	if str(t.get("command", "")) != "":
		var parts = []
		for c in str(t["command"]).split(" ", false):
			parts.append(_q(c))
		y.append("          args: [%s]" % ", ".join(PackedStringArray(parts)))
	if env.size() > 0:
		y.append("          env:")
		for e in env:
			y.append("            - {name: %s, value: %s}" % [_q(e[0]), _q(e[1])])
	var ports = []
	for p in t.get("ports", []):
		var pp = parse_port(p)
		if pp[1] > 0:
			ports.append(pp)
	if ports.size() > 0:
		y.append("          ports:")
		for pp in ports:
			y.append("            - {containerPort: %d, protocol: %s}" % [pp[1], pp[2]])
	var vols = []
	for v in t.get("volumes", []):
		# real host binds (docker.sock and friends) make no sense in a pod; skip them
		if str(v.get("container", "")) != "" and (not v.has("bind") or is_data_bind(v)):
			vols.append(str(v["container"]))
	if vols.size() > 0:
		y.append("          volumeMounts:")
		for i in vols.size():
			y.append("            - {name: vol%d, mountPath: %s}" % [i, _q(vols[i])])
		y.append("      volumes:")
		for i in vols.size():
			y.append("        - {name: vol%d, emptyDir: {}}" % i)
	if ports.size() > 0:
		y.append("---\napiVersion: v1\nkind: Service\nmetadata:\n  name: %s\n  labels: {kubefactory/app: %s}\nspec:\n  selector: {app: %s}\n  ports:" % [app, app, app])
		for pp in ports:
			y.append("    - {name: p%d-%s, port: %d, targetPort: %d, protocol: %s}" % [pp[1], pp[2].to_lower(), pp[1], pp[1], pp[2]])
	return "\n".join(PackedStringArray(y)) + "\n"

# The same template as `docker run` arguments.
static func template_docker_args(t: Dictionary, app: String, env: Array, allow_host_binds: bool = false) -> Array:
	var args = ["run", "-d", "--name", app, "--label", "kubefactory.app=" + app]
	if str(t.get("restart_policy", "")) != "":
		args.append_array(["--restart", str(t["restart_policy"])])
	for p in t.get("ports", []):
		var pp = parse_port(p)
		if pp[1] > 0:
			var spec = ("%d:%d" % [pp[0], pp[1]]) if pp[0] > 0 else str(pp[1])
			args.append_array(["-p", spec + "/" + pp[2].to_lower()])
	for e in env:
		args.append_array(["-e", "%s=%s" % [e[0], e[1]]])
	var i = 0
	for v in t.get("volumes", []):
		var c = str(v.get("container", ""))
		if c == "":
			continue
		if v.has("bind") and not is_data_bind(v):
			# a real host mount (docker.sock, /proc ...): only if the player ticked the box
			if allow_host_binds:
				args.append_array(["-v", "%s:%s%s" % [str(v["bind"]), c, ":ro" if v.get("readonly", false) else ""]])
		else:
			args.append_array(["-v", "%s-vol%d:%s" % [app, i, c]])
			i += 1
	args.append(str(t["image"]))
	if str(t.get("command", "")) != "":
		args.append_array(Array(str(t["command"]).split(" ", false)))
	return args
