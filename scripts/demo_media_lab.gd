extends RefCounted
# State and topology for the playable Docker lab. All clocks, files and
# endpoints here belong to the simulation.

const K = preload("res://scripts/kutil.gd")
const CONFIG_FILE = "media-lab.json"
const MEDIA = "media-host"
const GATHER = "gathering-node"
const GI = 1073741824
const FILE_BYTES = GI >> 1
const EXIT_IP = "203.0.113.141"
const COLORS = {"LAN": Color(0.50, 0.89, 0.30), "API": Color(0.31, 0.60, 1.0),
	"Metrics": Color(0.19, 0.86, 0.82), "Files": Color(1.0, 0.53, 0.20),
	"Mounts": Color(0.96, 0.72, 0.32), "HTTPS": Color(0.72, 0.60, 0.97),
	"VPN": Color(1.0, 0.75, 0.28), "Alerts": Color(0.96, 0.38, 0.81)}
const APPS = {
	MEDIA: [
		["plex", "plexinc/pms-docker:latest", 32400],
		["seerr", "ghcr.io/seerr-team/seerr:v3.5.2", 5055],
		["tautulli", "ghcr.io/tautulli/tautulli:latest", 8181],
		["tautulli-exporter", "quay.io/prometheuscommunity/json-exporter:v0.8.0", 7979],
		["prometheus", "prom/prometheus:v3.5.1", 9090],
		["grafana", "grafana/grafana:12.3.11", 3000],
		["blackbox", "ghcr.io/prometheus/blackbox-exporter:v0.29.1", 9115]],
	GATHER: [
		["sonarr", "lscr.io/linuxserver/sonarr:latest", 8989],
		["radarr", "lscr.io/linuxserver/radarr:latest", 7878],
		["jackett", "lscr.io/linuxserver/jackett:latest", 9117],
		["downloader", "lscr.io/linuxserver/qbittorrent:latest", 8080],
		["gluetun", "qmcgaw/gluetun:v3", 8000],
		["syncthing", "syncthing/syncthing:2.1.5", 22000],
		["gatherer-metrics", "kubefactory/demo-gatherer-metrics:1", 9100]],
}
# The gathering node's indexer: Jackett (searchers call it) or Prowlarr (searchers call
# it, and it also pushes its indexers into Sonarr and Radarr). Chosen at start.
const INDEXERS = {
	"jackett": ["lscr.io/linuxserver/jackett:latest", 9117, "Jackett"],
	"prowlarr": ["lscr.io/linuxserver/prowlarr:latest", 9696, "Prowlarr"],
}
const BINDABLE = ["plex", "seerr"]
const HOST_ONLY = ["tautulli", "prometheus", "grafana"]
const VPN_APPS = ["sonarr", "radarr", "jackett", "downloader"]
# capacity in GiB, starting used GiB, mount consumers and container paths.
const DISKS = {
	"plex-config": [8, 1, [["plex", "/config", false]]],
	"seerr-config": [4, 1, [["seerr", "/app/config", false]]],
	"tautulli-config": [8, 1, [["tautulli", "/config", false]]],
	"prometheus-data": [20, 6, [["prometheus", "/prometheus", false]]],
	"grafana-data": [8, 1, [["grafana", "/var/lib/grafana", false]]],
	"sonarr-config": [4, 1, [["sonarr", "/config", false]]],
	"radarr-config": [4, 1, [["radarr", "/config", false]]],
	"jackett-config": [4, 1, [["jackett", "/config", false]]],
	"prowlarr-config": [4, 1, [["prowlarr", "/config", false]]],
	"downloader-config": [4, 1, [["downloader", "/config", false]]],
	"gluetun-config": [4, 1, [["gluetun", "/gluetun", false]]],
	"syncthing-config": [4, 1, [["syncthing", "/var/syncthing/config", false]]],
	"media-sync-config": [4, 1, [["media-sync", "/var/syncthing/config", false]]],
	"library": [200, 180, [["plex", "/media", true]]],
	"inbox": [40, 1, [["media-sync", "/var/syncthing/incoming", false]]],
	"outbox": [40, 4, [["downloader", "/downloads", false], ["syncthing", "/var/syncthing/outbox", false]]],
}
const ROUTES = [
	["lan", "plex", "LAN", "Published TCP 32400"],
	["lan", "seerr", "LAN", "Published TCP 5055"],
	["seerr", "plex", "API", "Library availability"],
	["seerr", "sonarr", "API", "TV requests · management LAN/VLAN"],
	["seerr", "radarr", "API", "Movie requests · management LAN/VLAN"],
	["sonarr", "jackett", "API", "TV index searches"],
	["radarr", "jackett", "API", "Movie index searches"],
	["sonarr", "downloader", "API", "TV download queue"],
	["radarr", "downloader", "API", "Movie download queue"],
	["grafana", "prometheus", "Metrics", "Queries the shared data source"],
	["prometheus", "tautulli-exporter", "Metrics", "Scrapes playback metrics"],
	["tautulli-exporter", "tautulli", "Metrics", "Reads activity"],
	["tautulli", "plex", "Metrics", "Reads Plex sessions"],
	["prometheus", "blackbox", "Metrics", "Scrapes probe results"],
	["blackbox", "plex", "Metrics", "HTTP health probe"],
	["blackbox", "seerr", "Metrics", "HTTP health probe"],
	["blackbox", "tautulli", "Metrics", "HTTP health probe"],
	["blackbox", "grafana", "Metrics", "HTTP health probe"],
	["prometheus", "gatherer-metrics", "Metrics", "Scrapes over management LAN/VLAN"],
	["gatherer-metrics", "sonarr", "Metrics", "TV worker status"],
	["gatherer-metrics", "radarr", "Metrics", "Movie worker status"],
	["gatherer-metrics", "jackett", "Metrics", "Indexer reachability"],
	["gatherer-metrics", "downloader", "Metrics", "Download queue"],
	["gatherer-metrics", "gluetun", "Metrics", "Tunnel health"],
	["gatherer-metrics", "syncthing", "Metrics", "Sync state"],
	["downloader", "outbox", "Files", "Writes to the shared outbox"],
	["outbox", "syncthing", "Files", "Reads the shared outbox"],
	["syncthing", "media-sync", "Files", "File sync · management LAN/VLAN"],
	["media-sync", "inbox", "Files", "Writes the receiver inbox"],
	["inbox", "library", "Files", "Manual import"],
	["plex", "www", "HTTPS", "Plex sign-in and metadata", "443/tcp"],
	["seerr", "www", "HTTPS", "Seerr sign-in and metadata", "443/tcp"],
	["seerr", "discord", "Alerts", "Optional Discord HTTPS notification", "443/tcp"],
	["gluetun", "www", "VPN", "Public VPN exit · " + EXIT_IP, "51820/udp"],
]

var gathered: bool
var host_count: int
var indexer = "jackett"
static var _configured_hosts = 0
var access = "Loopback"
var discord = true
var paused = false
var queued = 0
var inbox = 0
var imported = 0
var last_alert = 0.0
var last_import = 0.0
var last_sync = 0.0
var transfer_ends = 0.0
var last_prepared: float
var history = []
var online = {}

static func configured_host_count() -> int:
	if _configured_hosts != 0:
		return _configured_hosts
	var path = "res://" + CONFIG_FILE
	if not OS.has_feature("web") and FileAccess.file_exists(K.data_path(CONFIG_FILE)):
		path = K.data_path(CONFIG_FILE)
	var config = K.read_json(path)
	var count = config.get("host_count", 2) if config is Dictionary else null
	var hosts = 2
	if typeof(count) in [TYPE_INT, TYPE_FLOAT] and (count == 1 or count == 2):
		hosts = int(count)
	else:
		push_warning("%s must contain host_count of 1 or 2. Using 2 hosts." % CONFIG_FILE)
	_configured_hosts = hosts
	return _configured_hosts

# The indexer: the player's choice in the game (settings) wins over media-lab.json.
static var forced_indexer = ""      # tests only: overrides the setting and the config

static func configured_indexer() -> String:
	if INDEXERS.has(forced_indexer):
		return forced_indexer
	var chosen = str(K.load_settings().get("lab_indexer", ""))
	if INDEXERS.has(chosen):
		return chosen
	var path = "res://" + CONFIG_FILE
	if not OS.has_feature("web") and FileAccess.file_exists(K.data_path(CONFIG_FILE)):
		path = K.data_path(CONFIG_FILE)
	var config = K.read_json(path)
	var named = str(config.get("indexer", "jackett")).to_lower() if config is Dictionary else "jackett"
	return named if INDEXERS.has(named) else "jackett"

func _init(include_gatherer: bool, now: float, hosts: int = 2, chosen_indexer: String = "jackett") -> void:
	gathered = include_gatherer
	indexer = chosen_indexer if INDEXERS.has(chosen_indexer) else "jackett"
	host_count = hosts if gathered else 1
	queued = 2 if gathered else 0
	last_prepared = now

func apps() -> Dictionary:
	var result = APPS.duplicate(true)
	for i in result[GATHER].size():
		if result[GATHER][i][0] == "jackett":
			result[GATHER][i] = [indexer, INDEXERS[indexer][0], INDEXERS[indexer][1]]
	if gathered:
		result[MEDIA].append(["media-sync", "syncthing/syncthing:2.1.5", 22000])
		if host_count == 1:
			result[MEDIA].append_array(result[GATHER])
			result.erase(GATHER)
	else:
		result.erase(GATHER)
	return result

func tick(now: float) -> void:
	while not history.is_empty() and history[0] <= now - 3600.0:
		history.pop_front()
	if not gathered:
		return
	if online.get("downloader", false) and online.get("gluetun", false) and now - last_prepared >= 20.0:
		if used_bytes("outbox") + FILE_BYTES <= DISKS["outbox"][0] * GI:
			queued += 1
		last_prepared = now
	if paused or not online.get("syncthing", false) or not online.get("media-sync", false):
		transfer_ends = 0.0
		return
	if transfer_ends > 0.0 and now >= transfer_ends:
		queued -= 1
		inbox += 1
		last_sync = now
		history.append(now)
		transfer_ends = 0.0
	if transfer_ends == 0.0 and queued > 0 and used_bytes("inbox") + FILE_BYTES <= DISKS["inbox"][0] * GI:
		transfer_ends = now + 4.0

# The apps that reach the internet only through Gluetun, with the chosen indexer.
func vpn_apps() -> Array:
	return VPN_APPS.map(func(app): return indexer if app == "jackett" else app)

# The routes with the chosen indexer; Prowlarr also syncs its indexers into the searchers.
func routes() -> Array:
	var rows = []
	for row in ROUTES:
		var r: Array = row.duplicate()
		for i in 2:
			if r[i] == "jackett":
				r[i] = indexer
		rows.append(r)
	if indexer == "prowlarr":
		rows.append(["prowlarr", "sonarr", "API", "Indexer sync: pushes its indexers into Sonarr"])
		rows.append(["prowlarr", "radarr", "API", "Indexer sync: pushes its indexers into Radarr"])
	return rows

func used_bytes(disk: String) -> int:
	var added = 0
	match disk:
		"outbox": added = queued + inbox + imported
		"inbox": added = inbox
		"library": added = imported
	return int(DISKS[disk][1] * GI + added * FILE_BYTES)

func mounts(app: String) -> Array:
	var result = []
	for id in DISKS:
		var spec = DISKS[id]
		for mount in spec[2]:
			if mount[0] == app:
				result.append({"kind": "volume", "name": id, "container": app, "path": mount[1],
					"read_only": mount[2], "capacity": spec[0] * GI, "used": used_bytes(id)})
	return result

func files(volume: String) -> Array:
	var rows = []
	var start = 1
	var count = 0
	match volume:
		"library":
			rows.append(["Demo Reel.mkv", "file", FILE_BYTES])
			count = imported
		"inbox":
			start = imported + 1
			count = inbox
		"outbox":
			count = queued + inbox + imported
		"tautulli-config":
			rows.append(["tautulli.db", "file", 2097152])
		"grafana-data":
			rows.append(["grafana.db", "file", 1048576])
		"sonarr-config", "radarr-config":
			rows.append([volume.trim_suffix("-config") + ".db", "file", 1048576])
		"prometheus-data":
			rows.append(["wal", "dir", 4096])
		_:
			rows.append(["settings.yaml", "file", 412])
	if volume in ["tautulli-config", "grafana-data", "sonarr-config", "radarr-config", "prometheus-data"]:
		rows.append(["demo-settings.yaml", "file", 120])
	if volume in ["library", "inbox", "outbox"]:
		rows.append(["README.txt", "file", 100])
	for i in range(start, start + count):
		rows.append(["Sample %03d.mkv" % i, "file", FILE_BYTES])
	return rows

func present(st: Dictionary, now: float) -> void:
	var by_name = {}
	var hosts = {}
	var app_ports = {}
	for specs in apps().values():
		for spec in specs:
			app_ports[spec[0]] = "%d/tcp" % spec[2]
	online.clear()
	for pod in st["pods"]:
		var app: String = pod["wname"]
		hosts[app] = pod["node"]
		if not by_name.has(app) or pod["ready"]:
			by_name[app] = pod["uid"]
			online[app] = pod["ready"]
		pod["sec"]["host_network"] = false
		pod["net"]["addrs"] = [pod["ip"] + " (container)"] if pod["ip"] != "" else []
		pod["net"]["segments"] = [{"name": "Private Docker bridge", "interface": "eth0", "vlan": 0}]
		if app in BINDABLE and access != "Loopback":
			var vlan = 30 if access == "VLAN 30" else 0
			pod["net"]["segments"].append({"name": "Media " + access, "vlan": vlan})
			if vlan == 30:
				pod["labels"]["kubefactory.io/vlan-id"] = "30"
		if host_count == 2 and (pod["node"] == GATHER or app in ["prometheus", "seerr", "media-sync"]):
			pod["net"]["segments"].append({"name": "Private management", "vlan": 40})
		var port = int(pod.get("lab_port", 0))
		pod.erase("lab_port")
		pod["docker_ports"] = []
		if port > 0:
			var binding = {"target": "%d/tcp" % port}
			if app in BINDABLE or app in HOST_ONLY:
				binding["published"] = str(port)
				binding["ip"] = {"LAN": "192.0.2.20", "VLAN 30": "198.51.100.30"}.get(access, "127.0.0.1") if app in BINDABLE else "127.0.0.1"
				if app in BINDABLE and access == "LAN":
					binding["lan"] = true
			pod["docker_ports"].append(binding)
	tick(now)
	for pod in st["pods"]:
		pod["store"]["shared_mounts"] = mounts(pod["wname"])
		pod["store"]["persistent"] = pod["store"]["shared_mounts"].map(func(m): return m["name"])
		if gathered and pod["wname"] in vpn_apps() and by_name.has("gluetun"):
			pod["net"]["via"] = by_name["gluetun"]
		if pod["wname"] == "gluetun":
			var vpn: Dictionary = pod["net"]["vpn"]
			vpn["exit_ip"] = EXIT_IP if online["gluetun"] else ""
			vpn["through"] = vpn_apps().filter(func(app): return by_name.has(app))
	var fixtures = {"lan": "LAN / VLAN IN", "www": "WWW OUT"}
	if discord:
		fixtures["discord"] = "Discord · simulated"
	if gathered:
		fixtures["sync-switch"] = "File sync"
	var rows = routes()
	var fixture_hosts = {}
	for app in vpn_apps():
		rows.append([app, "gluetun", "VPN", "VPN-only outbound route"])
	for name in DISKS:
		for mount in DISKS[name][2]:
			if not by_name.has(mount[0]):
				continue
			fixtures[name] = name
			fixture_hosts[name] = hosts[mount[0]]
			rows.append([mount[0], name, "Mounts", "%s · %s" % [mount[1], "read-only" if mount[2] else "read/write"]])
	for key in fixtures:
		by_name[key] = "lab:" + key
		online[key] = true
	var links = []
	for row in rows:
		if not by_name.has(row[0]) or not by_name.has(row[1]):
			continue
		var ready: bool = online[row[0]] and online[row[1]]
		var flow = ready
		match row[2]:
			"LAN": ready = ready and access != "Loopback"
			"Files":
				flow = ready and (now - last_import < 3.0 if row[0] == "inbox" else transfer_ends > now)
				if row[0] in ["outbox", "syncthing", "media-sync"]:
					ready = ready and not paused
			"VPN": ready = ready and online.get("gluetun", false)
			"Alerts": flow = ready and last_alert > 0.0 and now - last_alert < 5.0
			"Mounts": flow = false
		var description: String = row[3]
		if host_count == 1:
			description = description.replace("management LAN/VLAN", "private Docker bridge")
		var port: String = row[4] if row.size() > 4 else app_ports.get(row[1], "")
		if row[2] == "VPN" and row[1] != "www":
			port = "shared VPN network"
		links.append({"from": by_name[row[0]], "to": by_name[row[1]], "from_name": row[0],
			"to_name": row[1], "kind": row[2], "what": description, "port": port, "ready": ready, "flow": flow and ready})
	var gateway_ports = {"lan": [], "www": [], "discord": []}
	for row in routes():
		var inbound = row[0] == "lan"
		if not inbound and row[1] not in ["www", "discord"]:
			continue
		var app: String = row[1] if inbound else row[0]
		var station: String = "lan" if inbound else row[1]
		if not app_ports.has(app) or (station == "discord" and not discord):
			continue
		var uid: String = by_name.get(app, "")
		var ready: bool = online.get(app, false)
		var trace = []
		if uid != "":
			trace.append(["lab:lan", uid, "LAN"] if inbound else [uid, "lab:" + station, row[2]])
		gateway_ports[station].append({"uid": uid, "app": app, "target": station,
			"port": app_ports[app] if inbound else row[4], "listener_port": app_ports[app],
			"source_port": "ephemeral", "ready": ready, "reachable": ready and (not inbound or access != "Loopback"),
			"scope": access if inbound else ("WireGuard" if row[2] == "VPN" else "HTTPS"), "trace": trace, "via": ""})
	var egress = gateway_ports["www"].duplicate(true)
	egress.append_array(gateway_ports["discord"].duplicate(true))
	for gateway in gateway_ports["www"]:
		if gateway["app"] != "gluetun":
			continue
		for app in vpn_apps():
			var route: Dictionary = gateway.duplicate(true)
			route["uid"] = by_name.get(app, "")
			route["app"] = app
			route["listener_port"] = app_ports[app]
			route["via"] = "gluetun"
			route["ready"] = online.get(app, false) and gateway["ready"]
			route["reachable"] = route["ready"]
			if route["uid"] != "" and gateway["uid"] != "":
				route["trace"].push_front([route["uid"], gateway["uid"], "VPN"])
			else:
				route["trace"] = []
			egress.append(route)
	st["links"] = links
	st["lab"] = {"fixtures": fixtures, "fixture_hosts": fixture_hosts, "gathered": gathered, "host_count": host_count, "indexer": indexer, "access": access, "discord": discord,
		"gateway_ports": gateway_ports, "egress": egress,
		"sync_ready": online.get("syncthing", false) and online.get("media-sync", false),
		"paused": paused, "transfer": transfer_ends > now, "queued": queued, "inbox": inbox,
		"recent_count": history.size(), "recent_bytes": history.size() * FILE_BYTES,
		"last_sync": last_sync, "last_import": last_import, "last_alert": last_alert}

func action(a: Dictionary, now: float) -> Dictionary:
	match a["op"]:
		"lab_sync":
			if not gathered or not online.get("media-sync", false) or not online.get("syncthing", false) or typeof(a.get("paused")) != TYPE_BOOL:
				return {"ok": false, "msg": "The simulated sync folder is unavailable."}
			paused = a["paused"]
			if paused:
				transfer_ends = 0.0
			return {"ok": true, "msg": "File sync %s (simulated)." % ("paused" if paused else "resumed")}
		"lab_import":
			if inbox <= 0 or used_bytes("library") + FILE_BYTES > DISKS["library"][0] * GI:
				return {"ok": false, "msg": "Import needs a file in the inbox and free library space."}
			inbox -= 1
			imported += 1
			last_import = now
			return {"ok": true, "msg": "Imported one sample file into the Plex library."}
		"lab_access":
			if a.get("access") in ["Loopback", "LAN", "VLAN 30"]:
				access = a["access"]
				return {"ok": true, "msg": "Media bindings set to %s (simulated)." % access}
		"lab_discord":
			if typeof(a.get("enabled")) == TYPE_BOOL:
				discord = a["enabled"]
				return {"ok": true, "msg": "Simulated Discord route %s." % ("enabled" if discord else "disabled")}
			if discord and online.get("seerr", false):
				last_alert = now
				return {"ok": true, "msg": "Discord alert delivered in the simulation."}
	return {"ok": false, "msg": "That media lab action is unavailable."}
