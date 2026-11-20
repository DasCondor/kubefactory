extends RefCounted
# A small simulated cluster with a scheduler and controllers, so the game
# is playable (and every tool can be tried safely) without a real cluster.

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")
const Topology = preload("res://scripts/demo_topology.gd")
const MediaLab = preload("res://scripts/demo_media_lab.gd")
const StorageFiles = preload("res://scripts/storage_files.gd")
const GI = 1073741824.0

var label = "simulation"
var poll_interval = 1.0
var caps = {"remove_image": true, "scale": true, "delete_pod": true, "restart": true, "delete_workload": true,
	"create": true, "cordon": true, "drain": true, "logs": true, "files": true, "file_write": true, "demo_update_image": true}
const DEMO_UPDATES = {"media/heimdall": "lscr.io/linuxserver/heimdall:demo-reviewed",
	"media/library-check": "kubefactory/demo-library-check:1"}
var context = "helmsman-sim"
var _lab: MediaLab

var _mx = Mutex.new()
var _nodes = []
var _wl = []
var _pods = []
var _svcs = []
var _rng = RandomNumberGenerator.new()
var _seq = 0
var _edited_files = {}

# Simulated clusters, one per "flavor", so multi-cloud switching can be tried.
const FLAVORS = {
	"helmsman-sim": {"provider": "On-prem (kubeadm)", "version": "v1.31.2", "itype": "bare-metal",
		"zones": ["rack-a", "rack-b", "rack-c"], "nodes": ["helmsman-worker-01", "helmsman-worker-02", "helmsman-worker-03"], "cp": "helmsman-cp-01"},
	"aws-eks-prod": {"provider": "AWS EKS", "version": "v1.31.2-eks-7f9249a", "itype": "m6i.2xlarge",
		"zones": ["us-east-1a", "us-east-1b", "us-east-1c"],
		"nodes": ["ip-10-0-12-87.ec2.internal", "ip-10-0-45-203.ec2.internal", "ip-10-0-78-14.ec2.internal", "ip-10-0-91-166.ec2.internal"], "cp": ""},
	"azure-aks-staging": {"provider": "Azure AKS", "version": "v1.30.6", "itype": "Standard_D8s_v5",
		"zones": ["eastus-1", "eastus-2", "eastus-3"],
		"nodes": ["aks-nodepool1-31718369-vmss000000", "aks-nodepool1-31718369-vmss000001", "aks-nodepool1-31718369-vmss000002"], "cp": ""},
	"gke-analytics": {"provider": "Google GKE", "version": "v1.31.1-gke.1678000", "itype": "e2-standard-8",
		"zones": ["us-central1-a", "us-central1-b", "us-central1-c"],
		"nodes": ["gke-analytics-default-pool-5f2a1c3e-x7kq", "gke-analytics-default-pool-5f2a1c3e-m2wd", "gke-analytics-default-pool-9b1e77a0-c4hz"], "cp": ""},
	"rancher-edge": {"provider": "Rancher · RKE2", "version": "v1.30.5+rke2r1", "itype": "edge-box",
		"zones": ["site-berlin", "site-berlin", "site-lyon"], "nodes": ["edge-worker-1", "edge-worker-2"], "cp": "edge-cp-1"},
	# a home media server: Plex, the *arr apps and a Grafana monitoring stack, all healthy
	"homelab-media": {"provider": "Homelab (k3s)", "version": "v1.31.2+k3s1", "itype": "mini-pc",
		"zones": ["garage", "garage", "office"], "nodes": ["nas-01", "nuc-01"], "cp": "pi-cp-01"},
	# a smart home: Home Assistant and the services around it, with a Zigbee stick gone missing
	"home-assistant": {"provider": "Home Assistant (k3s)", "version": "v1.31.2+k3s1", "itype": "mini-pc",
		"zones": ["hallway", "hallway", "loft"], "nodes": ["nuc-home", "pi-zigbee"], "cp": "ha-green"},
	# a build farm: source hosting, CI runners, compile caches and dev containers per language
	"dev-containers": {"provider": "Dev containers (k3s)", "version": "v1.31.2+k3s1", "itype": "build-box",
		"zones": ["rack-1", "rack-1", "rack-2"], "nodes": ["build-01", "build-02", "build-03"], "cp": ""},
	"docker-media": {"provider": "Docker Engine", "version": "29", "itype": "Media Lab",
		"zones": ["Media LAN"], "nodes": [MediaLab.MEDIA], "cp": ""},
	"docker-media-gatherer": {"provider": "Docker Engine", "version": "29", "itype": "Media Lab",
		"zones": ["Media LAN", "Management VLAN 40"], "nodes": [MediaLab.MEDIA, MediaLab.GATHER], "cp": ""},
}

# The demo worlds offered when you start the simulation without naming one
# (`--demo=<id>`, the chooser on the welcome screen, or the pause menu).
const DEMO_TYPES = [
	{"id": "kubernetes", "flavor": "helmsman-sim", "name": "Kubernetes cluster",
		"short_desc": "A web shop with checkout, a database, and monitoring.",
		"desc": "A web shop on a four-node cluster: frontend, cart, checkout, database, monitoring. Two workloads are broken on purpose. The cloud variants (EKS, AKS, GKE, Rancher) are at the cluster gates."},
	{"id": "home-assistant", "flavor": "home-assistant", "name": "Home Assistant",
		"short_desc": "A smart home with cameras, sensors, and automations.",
		"desc": "A smart home: Home Assistant, Mosquitto, Zigbee2MQTT, Z-Wave, ESPHome, Node-RED, Frigate cameras, voice, and its database and graphs. The Zigbee stick has gone missing and one image tag is mistyped."},
	{"id": "dev-containers", "flavor": "dev-containers", "name": "Dev containers",
		"short_desc": "A build farm with a Git server, CI runners, and a registry.",
		"desc": "A build farm for compiling: Gitea, CI server and runners, BuildKit, a registry, compile caches, and a dev container per language (C++, Rust, Go, Python, Node). One heavy build keeps running out of memory."},
	{"id": "media", "flavor": "homelab-media", "name": "Media suite",
		"short_desc": "A Plex and Jellyfin lab with shared storage and VPN routes.",
		"desc": "A k3s media lab with Plex, Jellyfin, Heimdall, and Grafana. Follow requests, index searches, VPN egress, downloads, library imports and playback metrics."},
	{"id": "docker-media", "flavor": "docker-media", "name": "Docker media lab",
		"short_desc": "Plex, requests and reporting on one Docker host.",
		"desc": "Follow Seerr requests and Grafana queries. Inspect Plex's read-only library, Prometheus storage and the optional Discord route. Try loopback, LAN or media VLAN bindings."},
	{"id": "docker-media-gatherer", "flavor": "docker-media-gatherer", "name": "Docker media lab + gatherer",
		"short_desc": "Full media stack, VPN egress and file sync. Hosts come from config.",
		"desc": "Trace Jackett or Prowlarr searches and downloader traffic through Gluetun. Operate the sync lever and import into Plex. Set host_count in media-lab.json to use one or two hosts."},
]

static func demo_flavor(id: String) -> String:
	for d in DEMO_TYPES:
		if d["id"] == id or d["flavor"] == id:
			return d["flavor"]
	return ""

static func flavor_info(flavor: String) -> Dictionary:
	var info: Dictionary = FLAVORS.get(flavor, FLAVORS["helmsman-sim"]).duplicate(true)
	if flavor == "docker-media-gatherer" and MediaLab.configured_host_count() == 1:
		info["nodes"] = [MediaLab.MEDIA]
		info["zones"] = ["Media LAN"]
	return info

var provider = ""
var log_cfg = {}
var providers = []

func _init(flavor: String = "helmsman-sim"):
	if not FLAVORS.has(flavor):
		flavor = "helmsman-sim"
	var f = flavor_info(flavor)
	context = flavor
	provider = f["provider"]
	providers = [{"id": "kube", "name": "Kubernetes API", "ready": true, "note": "live from the kubelet (simulated)"},
		{"id": "loki", "name": "Grafana Loki", "ready": true, "note": "http://loki.monitoring:3100 (simulated)"}]
	var cloud_log = {"AWS EKS": "AWS CloudWatch", "Azure AKS": "Azure Monitor", "Google GKE": "Google Cloud Logging"}
	if cloud_log.has(provider):
		providers.append({"id": "cloud", "name": cloud_log[provider], "ready": true, "note": "simulated"})
	else:
		providers.append({"id": "elastic", "name": "AWS CloudWatch", "ready": false, "note": "not configured: this cluster is not on AWS"})
	_rng.seed = flavor.hash()
	if f["cp"] != "":
		_nodes.append({"name": f["cp"], "roles": "control-plane", "cpu": 4.0, "mem": 8 * GI})
	for nn in f["nodes"]:
		_nodes.append({"name": nn, "roles": "worker", "cpu": 8.0, "mem": 16 * GI})
	for i in _nodes.size():
		var n = _nodes[i]
		n["ready"] = true
		n["cordoned"] = false
		n["version"] = f["version"]
		n["zone"] = f["zones"][i % f["zones"].size()]
		n["itype"] = f["itype"]
		n["created"] = _now() - 86400.0 * 41
	if flavor in ["docker-media", "docker-media-gatherer"]:
		_lab = MediaLab.new(flavor == "docker-media-gatherer", _now(), f["nodes"].size(), MediaLab.configured_indexer())
		providers = [{"id": "kube", "name": "Docker logs", "ready": true, "note": "simulated container output"}]
		caps.merge({"lab_sync": _lab.gathered, "lab_import": _lab.gathered, "lab_access": true,
			"lab_discord": true, "cordon": false, "drain": false, "create": false, "demo_update_image": false}, true)
		var apps = _lab.apps()
		for host in apps:
			for spec in apps[host]:
				_add_wl("Compose", host, spec[0], [[spec[0], spec[1]]], 1, 0.25, 0.4)
				_wl[-1]["host"] = host
				_wl[-1]["port"] = spec[2]
		_settle()
		return
	var healthy = flavor == "gke-analytics"
	_add_wl("Deployment", "kube-system", "coredns", [["coredns", "registry.k8s.io/coredns/coredns:v1.11.3"]], 2, 0.1, 0.07)
	_add_wl("DaemonSet", "kube-system", "kube-proxy", [["kube-proxy", "registry.k8s.io/kube-proxy:v1.31.2"]], 0, 0.1, 0.05)
	if flavor in ["homelab-media", "home-assistant", "dev-containers"]:
		match flavor:
			"homelab-media":
				_seed_media()
			"home-assistant":
				_seed_home()
			"dev-containers":
				_seed_dev()
		_settle()
		return
	if flavor == "rancher-edge":
		_add_wl("Deployment", "cattle-system", "cattle-cluster-agent", [["cluster-register", "rancher/rancher-agent:v2.9.3"]], 2, 0.1, 0.2)
		_add_wl("Deployment", "cattle-fleet-system", "fleet-agent", [["fleet-agent", "rancher/fleet-agent:v0.10.4"]], 1, 0.1, 0.1)
	_add_wl("Deployment", "shop", "frontend", [["web", "helmsman/shop-frontend:2.4.1"], ["envoy", "envoyproxy/envoy:v1.31"]], 5 if flavor == "aws-eks-prod" else 3, 0.5, 0.5)
	_add_wl("Deployment", "shop", "cart", [["cart", "helmsman/shop-cart:1.9.0"]], 2, 0.5, 0.4)
	_add_wl("Deployment", "shop", "checkout", [["checkout", "helmsman/shop-checkout:0.8.2-rc1"]], 2, 0.5, 0.4, "" if healthy else "crashy")
	if not healthy:
		_add_wl("Deployment", "shop", "recommender", [["model", "helmsman/recommender:latset"]], 1, 0.75, 1.0, "badimage")
	_add_wl("StatefulSet", "shop", "catalog-db", [["postgres", "postgres:16"]], 1, 1.0, 2.0)
	_add_wl("Deployment", "shop", "redis", [["redis", "redis:7.4"]], 1, 0.25, 0.5)
	_add_wl("Deployment", "monitoring", "prometheus", [["prometheus", "prom/prometheus:v2.54.1"]], 1, 1.0, 2.0)
	_add_wl("Deployment", "monitoring", "grafana", [["grafana", "grafana/grafana:11.2.0"]], 1, 0.25, 0.5)
	_add_wl("DaemonSet", "monitoring", "node-exporter", [["exporter", "prom/node-exporter:v1.8.2"]], 0, 0.1, 0.05)
	_add_wl("Job", "default", "db-migrate", [["migrate", "helmsman/migrator:2.4.1"]], 1, 0.25, 0.25)
	_add_svc("kube-system", "kube-dns", "ClusterIP", "53/UDP,53/TCP", "coredns")
	_add_svc("shop", "frontend", "LoadBalancer", "80/TCP,443/TCP", "frontend")
	_add_svc("shop", "cart", "ClusterIP", "8080/TCP", "cart")
	_add_svc("shop", "checkout", "ClusterIP", "8080/TCP", "checkout")
	_add_svc("shop", "catalog-db", "ClusterIP", "5432/TCP", "catalog-db")
	_add_svc("shop", "redis", "ClusterIP", "6379/TCP", "redis")
	# left behind when the search service was retired: it selects pods that no longer exist
	_add_svc("shop", "search", "ClusterIP", "9200/TCP", "search")
	_add_svc("monitoring", "prometheus", "ClusterIP", "9090/TCP", "prometheus")
	_add_svc("monitoring", "grafana", "NodePort", "3000/TCP", "grafana")
	_settle()

# The homelab: the same pieces Porter's "Media server suite" and "Monitoring
# dashboard" setups build (see Apps.APPS), already running.
func _seed_media() -> void:
	for app_id in ["media", "media-vpn", "monitoring"]:
		var app = Apps.find(app_id)
		for s in app["sim"]:
			var heavy = s[1] in ["plex", "prometheus", "jellyfin"]
			var conts = [[s[1], s[2]]] + (s[5] if s.size() > 5 else [])
			_add_wl(s[0], app_id, s[1], conts, s[3], 1.0 if heavy else 0.25, 2.0 if heavy else 0.4)
			if s[4] != "":
				_add_svc(app_id, s[1], "LoadBalancer" if s[1] in ["plex", "grafana", "overseerr"] else "ClusterIP", s[4], s[1])

	_add_wl("Deployment", "media-vpn", Topology.SHARED_VPN, [["gluetun", Topology.VPN_IMAGE]], 1, 0.25, 0.4)
	_add_wl("Deployment", "media", "image-updater", [["reviewer", "kubefactory/demo-image-updater:1"]], 1, 0.1, 0.1)
	_add_wl("Deployment", "media", "library-check", [["check", "kubefactory/demo-library-check:latset"]], 1, 0.1, 0.1, "badimage")
	_add_svc("media", "library-check", "ClusterIP", "9101/TCP", "library-check")

# One simple workload with its Service: [kind, name, image, replicas, port, cpu, mem Gi].
func _stack(ns: String, rows: Array) -> void:
	for r in rows:
		_add_wl(r[0], ns, r[1], [[r[1], r[2]]], r[3], r[5], r[6])
		if r[4] != "":
			_add_svc(ns, r[1], "LoadBalancer" if r.size() > 7 else "ClusterIP", r[4], r[1])

# The smart home. Zigbee2MQTT cannot find its USB stick and the Matter server's
# image tag is mistyped, so Bob has something to read.
func _seed_home() -> void:
	_stack("home", [
		["Deployment", "homeassistant", "ghcr.io/home-assistant/home-assistant:stable", 1, "8123/TCP", 0.5, 1.0, "lb"],
		["Deployment", "mosquitto", "eclipse-mosquitto:2", 1, "1883/TCP", 0.1, 0.1],
		["Deployment", "zwave-js-ui", "zwavejs/zwave-js-ui:latest", 1, "8091/TCP", 0.2, 0.3],
		["Deployment", "esphome", "ghcr.io/esphome/esphome:stable", 1, "6052/TCP", 0.25, 0.5],
		["Deployment", "node-red", "nodered/node-red:latest", 1, "1880/TCP", 0.2, 0.3],
		["Deployment", "frigate", "ghcr.io/blakeblackshear/frigate:stable", 1, "5000/TCP", 2.0, 2.0],
		["Deployment", "music-assistant", "ghcr.io/music-assistant/server:latest", 1, "8095/TCP", 0.25, 0.5],
		["StatefulSet", "mariadb", "mariadb:11", 1, "3306/TCP", 0.5, 1.0],
		["Deployment", "influxdb", "influxdb:2", 1, "8086/TCP", 0.5, 1.0],
		["Deployment", "grafana", "grafana/grafana:11.2.0", 1, "3000/TCP", 0.25, 0.5, "lb"]])
	_stack("voice", [
		["Deployment", "whisper", "rhasspy/wyoming-whisper:latest", 1, "10300/TCP", 1.0, 1.5],
		["Deployment", "piper", "rhasspy/wyoming-piper:latest", 1, "10200/TCP", 0.5, 0.5],
		["Deployment", "openwakeword", "rhasspy/wyoming-openwakeword:latest", 1, "10400/TCP", 0.25, 0.3]])
	_add_wl("Deployment", "home", "zigbee2mqtt", [["zigbee2mqtt", "koenkk/zigbee2mqtt:latest"]], 1, 0.2, 0.3, "crashy", [
		"INFO  Starting Zigbee2MQTT version 1.40.2",
		"INFO  Starting zigbee-herdsman (0.57.3)",
		"ERROR Error while starting zigbee-herdsman",
		"ERROR Failed to start zigbee",
		"ERROR Error: Error while opening serialport 'Error: No such file or directory, cannot open /dev/ttyUSB0'",
		"FATAL Zigbee adapter not found, exiting with code 1"])
	_add_svc("home", "zigbee2mqtt", "ClusterIP", "8080/TCP", "zigbee2mqtt")
	_add_wl("Deployment", "home", "matter-server", [["matter", "ghcr.io/home-assistant-libs/python-matter-server:stabel"]], 1, 0.2, 0.3, "badimage")

# The build farm. One oversized C++ build keeps getting killed for memory and a
# dev container image tag is mistyped.
func _seed_dev() -> void:
	_stack("ci", [
		["Deployment", "gitea", "gitea/gitea:1.22", 1, "3000/TCP,22/TCP", 0.5, 1.0, "lb"],
		["Deployment", "woodpecker-server", "woodpeckerci/woodpecker-server:v2", 1, "8000/TCP", 0.25, 0.5, "lb"],
		["Deployment", "woodpecker-agent", "woodpeckerci/woodpecker-agent:v2", 3, "", 1.0, 1.0],
		["Deployment", "buildkitd", "moby/buildkit:v0.16.0", 2, "1234/TCP", 1.0, 2.0],
		["Deployment", "registry", "registry:2", 1, "5000/TCP", 0.25, 0.5],
		["Deployment", "sccache-redis", "redis:7.4", 1, "6379/TCP", 0.25, 1.0],
		["StatefulSet", "minio", "minio/minio:latest", 1, "9000/TCP", 0.5, 1.0],
		["StatefulSet", "postgres", "postgres:16", 1, "5432/TCP", 0.5, 1.0]])
	_stack("dev", [
		["Deployment", "devcontainer-cpp", "mcr.microsoft.com/devcontainers/cpp:ubuntu", 2, "", 1.0, 2.0],
		["Deployment", "devcontainer-rust", "mcr.microsoft.com/devcontainers/rust:1", 1, "", 1.0, 2.0],
		["Deployment", "devcontainer-go", "mcr.microsoft.com/devcontainers/go:1.23", 1, "", 0.5, 1.0],
		["Deployment", "devcontainer-python", "mcr.microsoft.com/devcontainers/python:3.12", 1, "", 0.5, 1.0],
		["Deployment", "devcontainer-node", "mcr.microsoft.com/devcontainers/typescript-node:22", 1, "", 0.5, 1.0],
		["Deployment", "code-server", "codercom/code-server:latest", 1, "8080/TCP", 0.5, 1.0, "lb"]])
	_add_wl("Deployment", "ci", "nightly-engine-build", [["builder", "mcr.microsoft.com/devcontainers/cpp:ubuntu"]], 1, 2.0, 2.0, "crashy", [
		"INFO  cmake --build build --parallel 16",
		"INFO  [ 86%] Building CXX object src/CMakeFiles/engine.dir/renderer.cpp.o",
		"INFO  [ 87%] Building CXX object src/CMakeFiles/engine.dir/shader_cache.cpp.o",
		"ERROR virtual memory exhausted: Cannot allocate memory",
		"ERROR c++: fatal error: Killed signal terminated program cc1plus",
		"ERROR compilation terminated.",
		"ERROR make[2]: *** [src/CMakeFiles/engine.dir/build.make:412: src/CMakeFiles/engine.dir/renderer.cpp.o] Error 1",
		"ERROR make: *** [Makefile:136: all] Error 2",
		"FATAL build failed, exiting with code 137"])
	_add_wl("Deployment", "dev", "devcontainer-zig", [["zig", "mcr.microsoft.com/devcontainers/zig:lastest"]], 1, 0.5, 1.0, "badimage")
	_add_wl("Job", "ci", "build-firmware", [["make", "mcr.microsoft.com/devcontainers/cpp:ubuntu"]], 1, 0.5, 0.5)

# Start with everything already up.
func _settle() -> void:
	_tick()
	for p in _pods:
		p["since"] = _now() - 3.0 - _rng.randf() * 6.0
		p["created"] = _now() - _rng.randf_range(600.0, 86400.0 * 6)
	_tick()

func _now() -> float:
	return Time.get_unix_time_from_system()

func _rand_id(n: int) -> String:
	var chars = "bcdfghjklmnpqrstvwxz2456789"
	var s = ""
	for i in n:
		s += chars[_rng.randi() % chars.length()]
	return s

# crashlog: the last lines a "crashy" workload prints before it dies (level + message each).
# The security settings these apps really ship with (or that a homelab really
# uses), so the Krew has something true to say about the simulation.
const SIM_SECURITY = {
	"kube-proxy": {"privileged": ["kube-proxy"], "host_network": true, "host_paths": ["/run/xtables.lock", "/lib/modules"]},
	"node-exporter": {"host_network": true, "host_pid": true, "host_paths": ["/proc", "/sys", "/"]},
	"checkout": {"root": ["checkout"]},
	"zigbee2mqtt": {"privileged": ["zigbee2mqtt"], "host_paths": ["/dev/ttyUSB0", "/run/udev"]},
	"home-assistant": {"host_network": true},
	"matter-server": {"host_network": true},
	"plex": {"host_network": true},
	"nightly-engine-build": {"host_paths": ["/var/run/docker.sock"], "docker_socket": true, "caps": ["builder: SYS_ADMIN"]},
	# Gluetun, Deluge's VPN sidecar, needs what any VPN client needs
	"deluge": {"caps": ["gluetun: NET_ADMIN"], "host_paths": ["/dev/net/tun"]},
}

# Where simulated software keeps its data. The shop's Redis runs on scratch
# space (an emptyDir), so Archie has something true to say about it; the
# storage door shows the same thing (_sim_mounts).
const DATA_DIRS = {"postgres": "/var/lib/postgresql/data", "mysql": "/var/lib/mysql", "mariadb": "/var/lib/mysql", "redis": "/data", "prometheus": "/prometheus",
	"grafana": "/var/lib/grafana", "influxdb": "/var/lib/influxdb2", "minio": "/data", "registry": "/var/lib/registry", "gitea": "/data", "plex": "/config", "homeassistant": "/config"}
const SIM_EPHEMERAL = ["redis"]

# A simulated VPN gateway (a Gluetun sidecar): its settings as a real one would
# state them, and an outside address from the documentation range 203.0.113.0/24,
# which belongs to nobody, so it cannot be mistaken for a real one.
const SIM_VPN = {"VPN_SERVICE_PROVIDER": "mullvad", "VPN_TYPE": "wireguard", "SERVER_COUNTRIES": "Netherlands"}

static func sim_net(w: Dictionary, p: Dictionary, running: bool) -> Dictionary:
	var n = K.empty_net()
	var vlan = int(Topology.SEGMENTS.get(w["ns"], 0))
	if vlan > 0:
		n["segments"] = [{"name": w["ns"], "vlan": vlan, "interface": "eth0"}]
	if str(p.get("ip", "")) != "" and str(p.get("node", "")) != "":
		n["addrs"].append("%s (pod)" % p["ip"])
	var others = []
	var gw = false
	var side = ""
	for c in w["containers"]:
		if K.is_vpn_image(str(c[1])):
			gw = true
			side = str(c[0])
		else:
			others.append(str(c[0]))
	if gw:
		var env = []
		for k in SIM_VPN:
			env.append("%s=%s" % [k, SIM_VPN[k]])
		var v = K.vpn_settings(env, K.vpn_entry("qmcgaw/gluetun"))
		v["through"] = others
		v["sidecar"] = side if not others.is_empty() else ""
		v["can_check"] = running
		v["exit_ip"] = "203.0.113.%d" % (40 + abs(str(p["uid"]).hash()) % 200) if running else ""
		v["exit_note"] = "SIMULATED" if running else "the VPN container is not running"
		n["vpn"] = v
	return n

static func _data_dir(wname: String, image: String) -> String:
	var img = image.to_lower()
	for key in DATA_DIRS:
		if img.contains(key) or wname.contains(key):
			return DATA_DIRS[key]
	return ""

static func sim_storage(wname: String, containers: Array) -> Dictionary:
	var s = K.empty_storage()
	s["known"] = true
	if _data_dir(wname, str(containers[0][1])) != "":
		if wname in SIM_EPHEMERAL:
			s["scratch"] = ["data"]
		else:
			s["persistent"] = ["%s-data" % wname]
	return s

static func sim_security(wname: String, containers: Array) -> Dictionary:
	var s = K.empty_security()
	for k in SIM_SECURITY.get(wname, {}):
		s[k] = SIM_SECURITY[wname][k]
	for c in containers:
		if K.floating_tag(str(c[1])):
			s["latest"] = s["latest"] + ["%s: %s" % [c[0], c[1]]]
	return s

func _add_wl(kind, ns, wname, containers, replicas, cpu, mem_gi, quirk = "", crashlog = []):
	if context == "homelab-media" and Topology.protects(ns, wname) and not Topology.uses_shared_vpn(ns, wname) and not containers.any(func(c): return K.is_vpn_image(str(c[1]))):
		containers = containers + [["gluetun", Topology.VPN_IMAGE]]
	if context == "homelab-media" and ns == "media" and wname == "tautulli":
		containers = containers + [["metrics-exporter", "kubefactory/demo-tautulli-exporter:1"]]
	_wl.append({"kind": kind, "ns": ns, "name": wname, "containers": containers, "replicas": replicas,
		"cpu": cpu, "mem": mem_gi * GI, "quirk": quirk, "crashlog": crashlog, "hash": _rand_id(9), "ordinal": 0, "spawned": false})

func _add_svc(ns, sname, type, ports, app):
	_svcs.append({"name": sname, "ns": ns, "type": type, "ports": ports,
		"cluster_ip": "10.96.%d.%d" % [_rng.randi_range(0, 250), _rng.randi_range(2, 250)],
		"selector": {"app": app}})

func _node_load(node_name: String) -> Array:
	var cpu = 0.0
	var mem = 0.0
	for p in _pods:
		if p["node"] == node_name and p["st"] != "Completed":
			cpu += p["cpu"]
			mem += p["mem"]
	return [cpu, mem]

func _schedule(p: Dictionary) -> String:
	var best = ""
	var best_free = -1.0
	for n in _nodes:
		if n["cordoned"] or not n["ready"] or n["roles"] == "control-plane":
			continue
		var load = _node_load(n["name"])
		if load[0] + p["cpu"] > n["cpu"] or load[1] + p["mem"] > n["mem"]:
			continue
		var free = n["cpu"] - load[0]
		if free > best_free:
			best_free = free
			best = n["name"]
	return best

func _spawn(w: Dictionary, fixed_node: String = "") -> void:
	_seq += 1
	var pname = ""
	match w["kind"]:
		"Compose":
			pname = w["name"]
			for other in _pods:
				if other["name"] == pname:
					pname = "%s-%d" % [w["name"], _seq]
					break
		"Deployment":
			pname = "%s-%s-%s" % [w["name"], w["hash"], _rand_id(5)]
		"StatefulSet":
			var used = {}
			for q in _pods:
				if q["wl"] == w:
					used[q["name"]] = true
			var i = 0
			while used.has("%s-%d" % [w["name"], i]):
				i += 1
			pname = "%s-%d" % [w["name"], i]
		_:
			pname = "%s-%s" % [w["name"], _rand_id(5)]
	var p = {"uid": "sim-%d" % _seq, "name": pname, "wl": w, "node": fixed_node, "st": "Pending",
		"since": _now(), "created": _now(), "restarts": 0, "cpu": w["cpu"], "mem": w["mem"],
		"ip": "10.244.%d.%d" % [_rng.randi_range(0, 3), _rng.randi_range(2, 250)],
		"jitter": _rng.randf() * 6.0}
	if fixed_node != "":
		p["st"] = "ContainerCreating"
	_pods.append(p)

func _tick() -> void:
	var now = _now()
	# Pod lifecycles
	var keep = []
	for p in _pods:
		var age = now - p["since"]
		var w = p["wl"]
		match p["st"]:
			"Pending":
				var n = _schedule(p)
				if n != "":
					p["node"] = n
					p["st"] = "ContainerCreating"
					p["since"] = now
			"ContainerCreating":
				if age > 2.2:
					p["st"] = "ImagePullBackOff" if w["quirk"] == "badimage" else "Running"
					p["since"] = now
			"Running":
				if w["kind"] == "Job" and age > 8.0:
					p["st"] = "Completed"
					p["since"] = now
				elif w["quirk"] == "crashy" and age > 10.0 + p["jitter"]:
					p["st"] = "Error"
					p["since"] = now
			"Error":
				if age > 2.0:
					p["st"] = "CrashLoopBackOff"
					p["restarts"] += 1
					p["since"] = now
			"CrashLoopBackOff":
				if age > 7.0:
					p["st"] = "Running"
					p["since"] = now
			"Terminating":
				if age > 1.6:
					continue
		keep.append(p)
	_pods = keep
	# Controllers
	for w in _wl:
		var live = []
		for p in _pods:
			if p["wl"] == w and p["st"] != "Terminating":
				live.append(p)
		match w["kind"]:
			"Deployment", "StatefulSet", "Compose":
				for i in range(live.size(), w["replicas"]):
					_spawn(w, str(w.get("host", "")))
				for i in range(w["replicas"], live.size()):
					var victim = live[live.size() - 1 - (i - w["replicas"])]
					victim["st"] = "Terminating"
					victim["since"] = now
			"DaemonSet":
				for n in _nodes:
					var found = false
					for p in live:
						if p["node"] == n["name"]:
							found = true
					if not found:
						_spawn(w, n["name"])
			"Job":
				if not w["spawned"]:
					w["spawned"] = true
					_spawn(w)

func fetch() -> Dictionary:
	_mx.lock()
	_tick()
	var st = {"source": label, "context": context, "provider": provider, "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	for n in _nodes:
		var load = _node_load(n["name"])
		st.nodes.append({"name": n["name"], "ready": n["ready"], "cordoned": n["cordoned"], "roles": n["roles"],
			"zone": n["zone"], "itype": n["itype"],
			"version": n["version"], "cpu": n["cpu"], "mem": n["mem"], "cpu_req": load[0], "mem_req": load[1],
			"created": n["created"]})
	for p in _pods:
		var w = p["wl"]
		var running = p["st"] == "Running"
		var conts = []
		for c in w["containers"]:
			var cstate = "waiting"
			if running:
				cstate = "running"
			elif p["st"] in ["Completed", "Error"]:
				cstate = "terminated"
			conts.append({"name": c[0], "image": c[1], "state": cstate,
				"reason": "" if running else p["st"], "ready": running, "restarts": p["restarts"]})
		var store = sim_storage(w["name"], w["containers"])
		var mounts = Topology.volumes(w["ns"], w["name"])
		for claim in mounts:
			var disk = Topology.disk(claim)
			store["persistent"].append(claim)
			store["shared_mounts"].append({"kind": "pvc", "name": claim, "container": conts[0]["name"],
				"path": "/" + claim, "read_only": mounts[claim], "capacity": disk["capacity"], "used": disk["used"]})
		st.pods.append({"uid": p["uid"], "name": p["name"], "ns": w["ns"], "node": p["node"], "status": p["st"],
			"ready": running, "health": K.health_of(p["st"], running), "restarts": p["restarts"],
			"wkind": w["kind"], "wname": w["name"], "ip": p["ip"] if p["node"] != "" else "",
			"created": p["created"], "labels": {"app": w["name"]}, "containers": conts,
			"phase": {"Running": "Running", "Completed": "Succeeded", "Error": "Failed"}.get(p["st"], "Pending"),
			# a finished Job in the demo has sat there for a while, as they do
			"finished": float(p.get("since", 0.0)) - 5400.0 if p["st"] in ["Completed", "Error"] else 0.0,
			"sec": sim_security(w["name"], w["containers"]), "store": store,
			"net": sim_net(w, p, running)})
		if _lab != null:
			st.pods[-1]["lab_port"] = w.get("port", 0)
	if context == "homelab-media":
		_link_shared_vpn(st.pods)
	for w in _wl:
		if w["kind"] == "Job":
			continue
		var total = 0
		var ready = 0
		for p in _pods:
			if p["wl"] == w and p["st"] != "Terminating":
				total += 1
				if p["st"] == "Running":
					ready += 1
		st.workloads.append({"kind": w["kind"], "name": w["name"], "ns": w["ns"],
			"replicas": total if w["kind"] == "DaemonSet" else w["replicas"], "ready": ready,
			"image": w["containers"][0][1]})
		if context == "homelab-media":
			var next = str(DEMO_UPDATES.get(Topology.key({"ns": w["ns"], "wname": w["name"]}), ""))
			if next != "" and next != w["containers"][0][1]:
				if not st.has("image_updates"):
					st["image_updates"] = []
				st["image_updates"].append({"ns": w["ns"], "name": w["name"], "kind": w["kind"], "current": w["containers"][0][1], "next": next})
	for s in _svcs:
		st.services.append(s.duplicate(true))
	if _lab == null:
		st["links"] = Topology.links(st)
	else:
		_lab.present(st, _now())
	_mx.unlock()
	return st

func _link_shared_vpn(pods: Array) -> void:
	var gateway = null
	for p in pods:
		if p["ns"] == "media-vpn" and p["wname"] == Topology.SHARED_VPN and not p["net"]["vpn"].is_empty():
			gateway = p
			if p["ready"]:
				break
	if gateway == null:
		return
	for p in pods:
		if Topology.uses_shared_vpn(p["ns"], p["wname"]) and p["net"]["vpn"].is_empty():
			p["net"]["via"] = gateway["uid"]
			gateway["net"]["vpn"]["through"].append(p["name"])

func _find_wl(ns: String, kind: String, wname: String) -> Variant:
	for w in _wl:
		if w["ns"] == ns and w["kind"] == kind and w["name"] == wname:
			return w
	return null

# ---- simulated storage: what the storage doors show in the demo worlds.
# Everything here is invented and says so; it stands in for the real listing a
# live cluster gives, so the door, the browser and its limits can be tried safely.

func _sim_mounts(p: Dictionary) -> Array:
	var w = p["wl"]
	var c = str(w["containers"][0][0])
	var res = []
	if _lab != null:
		for disk in _lab.mounts(w["name"]):
			res.append({"container": c, "path": disk["path"], "read_only": disk["read_only"],
				"volume": disk["name"], "type": "volume", "usage": K.shared_disk_usage(disk),
				"readable": true, "running": p["st"] == "Running"})
		return res
	var shared = Topology.volumes(w["ns"], w["name"])
	for claim in shared:
		var disk = Topology.disk(claim)
		res.append({"container": c, "path": "/" + claim, "read_only": shared[claim], "volume": claim, "type": "pvc", "claim": claim,
			"pv": "pvc-%s-%s" % [w["ns"], claim], "storage_class": "demo", "capacity": "%dGi" % (disk["capacity"] / GI),
			"usage": K.shared_disk_usage(disk),
			"phase": "Bound", "readable": true, "running": p["st"] == "Running"})
	var dd = _data_dir(str(w["name"]), str(w["containers"][0][1]))
	if dd != "" and str(w["name"]) in SIM_EPHEMERAL:
		res.append({"container": c, "path": dd, "read_only": false, "volume": "data", "type": "emptydir", "claim": "", "readable": true, "running": p["st"] == "Running"})
	elif dd != "":
		res.append({"container": c, "path": dd, "read_only": false, "volume": "data", "type": "pvc", "claim": "%s-data" % w["name"],
			"pv": "pvc-%s" % str(p["uid"]).md5_text().left(8), "storage_class": "standard", "capacity": "10Gi", "phase": "Bound", "readable": true, "running": p["st"] == "Running"})
	res.append({"container": c, "path": "/etc/%s" % w["name"], "read_only": true, "volume": "config", "type": "configmap", "claim": "", "readable": true, "running": p["st"] == "Running"})
	res.append({"container": c, "path": "/var/run/secrets/kubernetes.io/serviceaccount", "read_only": true, "volume": "kube-api-access", "type": "projected", "claim": "", "readable": false, "running": p["st"] == "Running"})
	return res

func _sim_files(a: Dictionary) -> Dictionary:
	var pod = null
	for p in _pods:
		if p["name"] == a["name"] and p["wl"]["ns"] == a["ns"]:
			pod = p
	if pod == null:
		return {"ok": false, "kind": "notfound", "msg": "pod not found", "data": {}}
	var mounts = _sim_mounts(pod)
	if a["op"] == "file_mounts":
		return {"ok": true, "msg": "", "kind": "", "data": {"mounts": mounts, "simulated": true}}
	var m = null
	for x in mounts:
		if x["path"] == a["root"] and x["container"] == a.get("container", x["container"]):
			m = x
	if m == null:
		return {"ok": false, "kind": "invalid", "msg": "%s is not a mounted volume of this container" % a["root"], "data": {}}
	if not m["running"]:
		return {"ok": false, "kind": "unsupported", "msg": "The container is not running, so its files cannot be read.", "data": {}}
	var full = K.path_inside(a["root"], str(a.get("path", "")))
	if full == "":
		return {"ok": false, "kind": "invalid", "msg": "That path is outside the mounted volume.", "data": {}}
	var rel = full.trim_prefix(str(a["root"]).rstrip("/")).trim_prefix("/")
	# a small invented tree per kind of volume
	var tree = {}
	match m["type"]:
		"pvc":
			tree = {"": [["base", "dir", 4096], ["pg_wal", "dir", 4096], ["PG_VERSION", "file", 3], ["postgresql.conf", "file", 29525], ["postmaster.pid", "file", 94], ["current", "link", 9]],
				"base": [["1", "dir", 4096], ["16384", "dir", 4096]], "base/1": [["1259", "file", 122880], ["2619", "file", 81920]], "base/16384": [["16385", "file", 8192]],
				"pg_wal": [["000000010000000000000001", "file", 16777216]]}
		"configmap":
			tree = {"": [["config.yaml", "file", 412], ["logging.yaml", "file", 180]]}
		_:
			tree = {"": [["ca.crt", "file", 1107], ["namespace", "file", 4], ["token", "file", 1024]]}
	if Topology.SHARED_FILES.has(m["volume"]):
		tree = Topology.SHARED_FILES[m["volume"]]
	if _lab != null:
		tree = {"": _lab.files(m["volume"])}
		if m["volume"] == "prometheus-data":
			tree["wal"] = [["00000001", "file", 16777216]]
	var disk_id = JSON.stringify([pod.get("node", "") if m["type"] == "volume" else pod["wl"]["ns"], m.get("claim", m["volume"])])
	var changes: Dictionary = _edited_files.get(disk_id, {})
	for changed in changes:
		var folder = str(changed).get_base_dir()
		if not tree.has(folder):
			tree[folder] = []
		if not tree[folder].any(func(row): return row[0] == str(changed).get_file()):
			tree[folder].append([str(changed).get_file(), "file", str(changes[changed]).to_utf8_buffer().size()])
	if a["op"] == "file_list":
		if not tree.has(rel):
			return {"ok": false, "kind": "notfound", "msg": "%s is not a directory" % full, "data": {}}
		var es = []
		for row in tree[rel]:
			var key = str(row[0]) if rel == "" else rel + "/" + str(row[0])
			es.append({"name": row[0], "type": row[1], "size": str(changes[key]).to_utf8_buffer().size() if changes.has(key) else row[2], "mode": {"dir": "drwxr-xr-x", "file": "-rw-r--r--", "link": "lrwxrwxrwx"}[row[1]], "owner": "999", "group": "999",
				"mtime": "Nov 13 21:19", "link": "/etc/passwd" if row[1] == "link" else ""})
		return {"ok": true, "msg": "", "kind": "", "data": {"path": full, "entries": es, "truncated": false, "readable": m["readable"], "simulated": true}}
	if not m["readable"]:
		return {"ok": false, "kind": "unsupported", "msg": "This is a %s volume: its contents are never shown." % m["type"], "data": {}}
	var dir = rel.get_base_dir()
	var fname = rel.get_file()
	var found = null
	for row in tree.get(dir, []):
		if row[0] == fname:
			found = row
	if found == null or found[1] != "file":
		return {"ok": false, "kind": "invalid", "msg": "Only regular files can be previewed (links and devices are not followed).", "data": {}}
	var page = clampi(int(a.get("page", 0)), 0, 255)
	var bytes = PackedByteArray()
	var text_file = changes.has(rel) or fname.get_extension() in ["yaml", "conf", "xml", "ini", "txt"] or fname == "PG_VERSION" or fname.ends_with(".pid")
	if text_file:
		var text = str(changes[rel]) if changes.has(rel) else ("# SIMULATED FILE - edits last until the demo is closed\n# %s\n\ndemo: true\nlog_level: info\n" % m["volume"] if fname.ends_with(".yaml") else "# SIMULATED FILE - invented by the demo\n# %s\n\nlog_level = info\n" % m["volume"])
		bytes = text.to_utf8_buffer() if page == 0 else PackedByteArray()
	else:
		var r = RandomNumberGenerator.new()
		r.seed = (full + str(page)).hash()
		bytes.resize(mini(int(found[2]) - page * 65536, 65536) if int(found[2]) > page * 65536 else 0)
		for i in bytes.size():
			bytes[i] = r.randi() % 256
	if a["op"] == "file_write":
		var problem = StorageFiles.write_problem(a)
		if m.get("read_only", true):
			problem = "This mount is read-only."
		elif not text_file:
			problem = "Binary files and databases cannot be edited."
		elif str(a.get("expected", "")) != bytes.get_string_from_utf8().sha256_text():
			problem = "File changed since it was opened. Reopen it before saving."
		if problem != "":
			return {"ok": false, "kind": "invalid", "msg": problem, "data": {}}
		var backup = rel + ".kf-backup-" + str(Time.get_ticks_usec())
		changes[backup] = bytes.get_string_from_utf8()
		changes[rel] = str(a["text"])
		_edited_files[disk_id] = changes
		return {"ok": true, "msg": "Saved in this simulation. Previous file: " + backup, "kind": "", "data": {"backup": backup, "simulated": true}}
	var size = bytes.size() if text_file and page == 0 else int(found[2])
	return {"ok": true, "msg": "", "kind": "", "data": {"path": full, "size": size, "page": page, "pages": mini(int(ceil(size / 65536.0)), 256),
		"data": Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else "", "simulated": true}}

# Simulated usage for one pod: it wanders around a share of what the pod asks
# for, and its counters only ever go up, as real ones do.
func _sim_metrics(a: Dictionary) -> Dictionary:
	for p in _pods:
		if p["name"] == a["name"] and p["wl"]["ns"] == a["ns"]:
			if p["st"] != "Running":
				return {"ok": false, "kind": "unsupported", "msg": "This pod is not running, so it is using nothing.", "data": {}}
			var t = Time.get_ticks_msec() / 1000.0
			var seed = float(hash(p["name"]) % 1000) / 37.0
			var busy = 0.42 + 0.22 * sin(t / 9.0 + seed) + 0.1 * sin(t / 2.3 + seed * 2.0)
			# a running container has totals from all of its uptime, so the counters start
			# where a few days of steady traffic would have left them, not at zero
			var up = 86400.0 * (1.0 + float(hash(p["name"] + "up") % 400) / 100.0)
			var c = p.get("_ctr", {"rx": up * 90000.0, "tx": up * 35000.0, "rd": up * 6000.0, "wr": up * 15000.0, "t": t})
			var dt = maxf(t - float(c["t"]), 0.0)
			c["rx"] += dt * (60000.0 + 240000.0 * busy)
			c["tx"] += dt * (25000.0 + 90000.0 * busy)
			c["rd"] += dt * 12000.0 * busy
			c["wr"] += dt * (8000.0 + 30000.0 * busy)
			c["t"] = t
			p["_ctr"] = c
			return {"ok": true, "msg": "", "kind": "", "data": {"cpu_cores": float(p["cpu"]) * busy, "mem_bytes": float(p["mem"]) * (0.55 + 0.12 * sin(t / 31.0 + seed)),
				"net_rx_bytes": c["rx"], "net_tx_bytes": c["tx"], "disk_read_bytes": c["rd"], "disk_write_bytes": c["wr"],
				"at": Time.get_datetime_string_from_system(true) + "Z", "source": "simulation", "simulated": true}}
	return {"ok": false, "kind": "notfound", "msg": "pod not found", "data": {}}

var _sim_unused = [
	{"id": "sha256:5e1a7c0d2b9f", "repo": "helmsman/shop-frontend", "tag": "2.3.9", "size": 188.0e6, "unique": 41.0e6, "containers": 0, "created": "5 weeks ago"},
	{"id": "sha256:91c4d0e7a3b2", "repo": "postgres", "tag": "15", "size": 412.0e6, "unique": 398.0e6, "containers": 0, "created": "3 months ago"},
	{"id": "sha256:0f3b8a61d4c7", "repo": "<none>", "tag": "<none>", "size": 96.0e6, "unique": 96.0e6, "containers": 0, "created": "2 weeks ago"},
]

func _sim_scan() -> Dictionary:
	var images = []
	var seen = {}
	for p in _pods:
		for c in p["wl"]["containers"]:
			if not seen.has(c[1]):
				seen[c[1]] = true
				# the release candidate was built on a node and never pushed: Forge notices
				images.append({"id": "sha256:%012x" % (hash(c[1]) & 0xffffffffffff), "repo": str(c[1]).get_slice(":", 0), "tag": str(c[1]).get_slice(":", 1),
					"size": 120.0e6, "unique": 40.0e6, "containers": 1, "created": "1 week ago", "digests": 0 if str(c[1]).ends_with("-rc1") else 1})
	return {"ok": true, "msg": "", "kind": "", "data": {"images": images + _sim_unused, "simulated": true, "source": "simulation",
		"volumes": [{"name": "old-catalog-backup", "links": 0, "size": 2.4e9}],
		"build_cache": {"entries": 46, "reclaimable": 3.1e9, "in_use": 2}}}

func run_action(a: Dictionary) -> Dictionary:
	if a["op"] == "vpn_check":      # nothing is asked of the internet in a demo
		var ip = MediaLab.EXIT_IP if _lab != null else "203.0.113.%d" % (40 + abs(str(a.get("pod", "")).hash()) % 200)
		return {"ok": true, "msg": "The internet sees %s from inside that container (SIMULATED)." % ip,
			"data": {"ip": ip, "simulated": true}}
	if a["op"] == "cleanup_scan":
		_mx.lock()
		var sres = _sim_scan()
		_mx.unlock()
		return sres
	if a["op"] == "remove_image":
		for i in _sim_unused.size():
			if str(_sim_unused[i]["id"]) == str(a.get("id", "")):
				_sim_unused.remove_at(i)
				return {"ok": true, "msg": "Removed image %s (simulated)" % a["name"]}
		return {"ok": false, "msg": "That image is in use or already gone (simulated)."}
	if a["op"] == "pod_metrics":
		_mx.lock()
		var mres = _sim_metrics(a)
		_mx.unlock()
		return mres
	if a["op"] in ["file_mounts", "file_list", "file_read", "file_write"]:
		_mx.lock()
		var fr = _sim_files(a)
		_mx.unlock()
		return fr
	if a["op"] == "forward":
		return {"ok": false, "kind": "unsupported", "msg": "This is a simulated cluster: there is no real application behind this service to show.", "data": {}}
	if a["op"] == "templates":
		return {"ok": false, "msg": "", "text": "Online app lists are unavailable in the simulation. Bundled app setups are still available."}
	if a["op"] == "logs":
		# each provider has its own (pretend) network distance
		if not OS.has_feature("web"):
			OS.delay_msec({"kube": 40, "loki": 180, "cloud": 420}.get(a.get("provider", "kube"), 60))
		if a.get("provider", "kube") == "elastic":
			return {"ok": false, "msg": "", "text": "No signal: this provider is not configured for the cluster."}
	_mx.lock()
	var r = _action(a)
	_mx.unlock()
	return r

func _action(a: Dictionary) -> Dictionary:
	var now = _now()
	if _lab != null and str(a.get("op", "")).begins_with("lab_"):
		return _lab.action(a, now)
	var special = _app_action(a)
	if not special.is_empty():
		return special
	match a["op"]:
		"demo_update_image":
			var w = _find_wl(a["ns"], a["kind"], a["name"])
			var candidate = str(DEMO_UPDATES.get(a["ns"] + "/" + a["name"], ""))
			if context != "homelab-media" or w == null or candidate == "" or w["containers"][0][1] != a.get("current"):
				return {"ok": false, "msg": "The simulated image recommendation is no longer available."}
			w["containers"][0][1] = candidate
			if w["quirk"] == "badimage":
				w["quirk"] = ""
			return _action({"op": "restart", "ns": a["ns"], "kind": a["kind"], "name": a["name"]})
		"scale":
			var w = _find_wl(a["ns"], a["kind"], a["name"])
			if w == null:
				return {"ok": false, "msg": "workload not found"}
			if w["kind"] == "DaemonSet":
				return {"ok": false, "msg": "DaemonSets run one pod per node and cannot be scaled"}
			w["replicas"] = clampi(a["replicas"], 0, 60)
			return {"ok": true, "msg": "%s/%s scaled to %d" % [w["kind"].to_lower(), w["name"], w["replicas"]]}
		"delete_pod":
			for p in _pods:
				if p["name"] == a["name"] and p["wl"]["ns"] == a["ns"]:
					p["st"] = "Terminating"
					p["since"] = now
					return {"ok": true, "msg": "pod \"%s\" deleted" % a["name"]}
			return {"ok": false, "msg": "pod not found"}
		"restart":
			var w = _find_wl(a["ns"], a["kind"], a["name"])
			if w == null:
				return {"ok": false, "msg": "workload not found"}
			w["hash"] = _rand_id(9)
			for p in _pods:
				if p["wl"] == w:
					p["st"] = "Terminating"
					p["since"] = now
			return {"ok": true, "msg": "%s/%s restarted" % [w["kind"].to_lower(), w["name"]]}
		"delete_workload":
			var w = _find_wl(a["ns"], a["kind"], a["name"])
			if w == null:
				return {"ok": false, "msg": "workload not found"}
			_wl.erase(w)
			for p in _pods:
				if p["wl"] == w:
					p["st"] = "Terminating"
					p["since"] = now
			return {"ok": true, "msg": "%s \"%s\" deleted" % [w["kind"].to_lower(), w["name"]]}
		"create":
			if _find_wl(a["ns"], "Deployment", a["name"]) != null:
				return {"ok": false, "msg": "deployment \"%s\" already exists" % a["name"]}
			_add_wl("Deployment", a["ns"], a["name"], [[a["name"], a["image"]]], clampi(a["replicas"], 0, 60), 0.25, 0.25)
			return {"ok": true, "msg": "deployment.apps/%s created" % a["name"]}
		"cordon":
			for n in _nodes:
				if n["name"] == a["node"]:
					n["cordoned"] = a["on"]
					return {"ok": true, "msg": "node/%s %s" % [n["name"], "cordoned" if a["on"] else "uncordoned"]}
			return {"ok": false, "msg": "node not found"}
		"drain":
			for n in _nodes:
				if n["name"] == a["node"]:
					n["cordoned"] = true
					var count = 0
					for p in _pods:
						if p["node"] == n["name"] and p["wl"]["kind"] != "DaemonSet" and p["st"] != "Terminating":
							p["st"] = "Terminating"
							p["since"] = now
							count += 1
					return {"ok": true, "msg": "node/%s drained (%d pods evicted)" % [n["name"], count]}
			return {"ok": false, "msg": "node not found"}
		"logs":
			for p in _pods:
				if p["name"] == a["name"] and p["wl"]["ns"] == a["ns"]:
					return {"ok": true, "msg": "", "text": _fake_logs(p, a.get("container", ""), int(a.get("tail", 0)), a.get("previous", false))}
			return {"ok": false, "msg": "", "text": "pod not found"}
		"events":
			for p in _pods:
				if p["name"] == a["name"] and p["wl"]["ns"] == a["ns"]:
					return {"ok": true, "msg": "", "text": _fake_events(p)}
			return {"ok": false, "msg": "", "text": "pod not found"}
		"cluster_events":
			var rows = []
			for p in _pods:
				if a.get("ns", "") != "" and p["wl"]["ns"] != a["ns"]:
					continue
				var lines = _fake_events(p).split("\n")
				for i in range(1, lines.size()):
					if a.get("warnings", false) and not lines[i].begins_with("Warning"):
						continue
					var t = p["created"] + i * 2.0 if not lines[i].begins_with("Warning") else p["since"]
					rows.append([t, "%sZ   %-14s %-24s %s" % [Time.get_datetime_string_from_unix_time(int(t)), p["wl"]["ns"], p["name"].left(24), lines[i]]])
			rows.sort_custom(func(x, y): return x[0] < y[0])
			var out = ["LAST                   NAMESPACE      OBJECT                   TYPE      REASON      MESSAGE"]
			for r in rows.slice(maxi(0, rows.size() - 300)):
				out.append(r[1])
			return {"ok": true, "msg": "", "text": "\n".join(PackedStringArray(out))}
	return {"ok": false, "msg": "unsupported action"}

func _fake_events(p: Dictionary) -> String:
	var w = p["wl"]
	var img = w["containers"][0][1]
	var cn = w["containers"][0][0]
	var l = ["TYPE      REASON      MESSAGE"]
	if p["node"] == "":
		l.append("Warning   FailedScheduling   0/4 nodes are available: insufficient cpu or node(s) were unschedulable.")
		return "\n".join(PackedStringArray(l))
	l.append("Normal    Scheduled   Successfully assigned %s/%s to %s" % [w["ns"], p["name"], p["node"]])
	l.append("Normal    Pulling     Pulling image \"%s\"" % img)
	if w["quirk"] == "badimage":
		l.append("Warning   Failed      Failed to pull image \"%s\": manifest for %s not found: manifest unknown" % [img, img])
		l.append("Warning   Failed      Error: ErrImagePull")
		l.append("Normal    BackOff     Back-off pulling image \"%s\"" % img)
		l.append("Warning   Failed      Error: ImagePullBackOff")
		return "\n".join(PackedStringArray(l))
	l.append("Normal    Pulled      Successfully pulled image \"%s\"" % img)
	l.append("Normal    Created     Created container %s" % cn)
	l.append("Normal    Started     Started container %s" % cn)
	if p["restarts"] > 0:
		l.append("Warning   BackOff     Back-off restarting failed container %s in pod %s (x%d)" % [cn, p["name"], p["restarts"]])
	return "\n".join(PackedStringArray(l))

func _fake_logs(p: Dictionary, container: String, a_tail: int = 0, previous: bool = false) -> String:
	if previous and p["restarts"] == 0:
		return "Error from server (BadRequest): previous terminated container \"%s\" in pod \"%s\" not found" % [container, p["name"]]
	var w = p["wl"]
	var lines = []
	var t = _now() - 120.0
	var stamp = func(x): return Time.get_datetime_string_from_unix_time(int(x)) + "Z"
	if p["st"] in ["Pending", "ContainerCreating", "ImagePullBackOff"]:
		if w["quirk"] == "badimage":
			return "Error from server (BadRequest): container \"%s\" in pod \"%s\" is waiting to start: trying and failing to pull image\n\nEvents:\n  Failed to pull image \"%s\": manifest unknown" % [w["containers"][0][0], p["name"], w["containers"][0][1]]
		return "container is waiting to start: %s" % p["st"]
	lines.append("%s INFO  starting %s (%s)" % [stamp.call(t), w["name"], container if container != "" else w["containers"][0][0]])
	lines.append("%s INFO  config loaded from /etc/%s/config.yaml" % [stamp.call(t + 1), w["name"]])
	lines.append("%s INFO  listening on 0.0.0.0:8080" % stamp.call(t + 2))
	var paths = ["/healthz", "/api/v1/items", "/api/v1/cart", "/metrics", "/api/v1/orders", "/readyz"]
	var r = RandomNumberGenerator.new()
	r.seed = p["uid"].hash()
	for i in mini(int(a_tail), 400) if a_tail > 0 else 22:
		t += r.randf_range(1.0, 6.0)
		lines.append("%s INFO  GET %s 200 %dms" % [stamp.call(t), paths[r.randi() % paths.size()], r.randi_range(1, 48)])
	if w["quirk"] == "crashy" and not w["crashlog"].is_empty():
		for i in w["crashlog"].size():
			lines.append("%s %s" % [stamp.call(t + 1 + i), w["crashlog"][i]])
	elif w["quirk"] == "crashy":
		lines.append("%s ERROR payment gateway handshake failed: connection refused (10.96.44.7:8443)" % stamp.call(t + 1))
		lines.append("%s FATAL unrecoverable error, exiting with code 1" % stamp.call(t + 2))
	if w["kind"] == "Job" and p["st"] == "Completed":
		lines.append("%s INFO  14 migrations applied, exiting" % stamp.call(t + 1))
	return "\n".join(PackedStringArray(lines))

# ---- Porter / Portainer (simulated)

func _sim_add(kind: String, ns: String, wname: String, image: String, replicas: int, ports: String) -> void:
	if _find_wl(ns, kind, wname) == null:
		_add_wl(kind, ns, wname, [[wname, image]], replicas, 0.25, 0.25)
	for s in _svcs:
		if s["ns"] == ns and s["name"] == wname:
			return
	if ports != "":
		_add_svc(ns, wname, "ClusterIP", ports, wname)

func _sim_remove(kind: String, ns: String, wname: String) -> void:
	var w = _find_wl(ns, kind, wname)
	if w != null:
		_wl.erase(w)
		for p in _pods:
			if p["wl"] == w:
				p["st"] = "Terminating"
				p["since"] = _now()
	for s in _svcs.duplicate():
		if s["ns"] == ns and s["name"] == wname:
			_svcs.erase(s)

func _app_action(a: Dictionary) -> Dictionary:
	match a["op"]:
		"scale_by":
			var w = _find_wl(a["ns"], a["kind"], a["name"])
			if w == null:
				return {"ok": false, "msg": "workload not found"}
			if w["kind"] == "DaemonSet":
				return {"ok": false, "msg": "DaemonSets run one pod per node and cannot be scaled"}
			w["replicas"] = clampi(w["replicas"] + int(a["delta"]), 0, 60)
			return {"ok": true, "msg": "%s/%s scaled to %d" % [w["kind"].to_lower(), w["name"], w["replicas"]]}
		"apply_app":
			var app = Apps.find(a["id"])
			if app == null:
				return {"ok": false, "msg": "unknown app"}
			for s in app["sim"]:
				_sim_add(s[0], a["ns"], s[1], s[2], s[3], s[4])
			return {"ok": true, "msg": "%s deployed to namespace %s.%s" % [app["name"], a["ns"], "  Password generated into secret app-db." if app["secret"] else ""]}
		"remove_app":
			var app = Apps.find(a["id"])
			if app == null:
				return {"ok": false, "msg": "unknown app"}
			for s in app["sim"]:
				_sim_remove(s[0], a["ns"], s[1])
			return {"ok": true, "msg": "%s removed from namespace %s" % [a["id"], a["ns"]]}
		"remove_template":
			_sim_remove("Deployment", a["ns"], a["name"])
			return {"ok": true, "msg": "%s removed from namespace %s" % [a["name"], a["ns"]]}
		"portainer_install":
			_sim_add("Deployment", "portainer", "portainer", "portainer/portainer-ce:lts", 1, "9443/TCP")
			return {"ok": true, "msg": "Portainer installed in namespace portainer (simulated)"}
		"portainer_open":
			return {"ok": true, "msg": "This is a simulated cluster, so there is no Portainer UI to open"}
		"deploy_template":
			var t = a["template"]
			var ports = []
			for p in t.get("ports", []):
				var pp = Apps.parse_port(p)
				ports.append("%d/%s" % [pp[1], pp[2]])
			_sim_add("Deployment", a["ns"], a["name"], str(t.get("image", "")), 1, ",".join(PackedStringArray(ports)))
			return {"ok": true, "msg": "%s deployed to namespace %s" % [t.get("title", a["name"]), a["ns"]]}
	return {}
