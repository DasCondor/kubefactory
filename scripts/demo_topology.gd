extends RefCounted

const VPN_IMAGE = "qmcgaw/gluetun:v3"
const SHARED_VPN = "arr-vpn"
const SHARED_VPN_APPS = ["sonarr", "radarr", "prowlarr"]
const VPN_APPS = {
	"media": ["qbittorrent", "jackett", "prowlarr", "sonarr", "radarr", "lidarr", "bazarr"],
	"media-vpn": ["deluge", "prowlarr", "sonarr", "radarr"]
}
const SEGMENTS = {"media": 20, "media-vpn": 30, "monitoring": 40, "shop": 50}
const SHARED_FILES = {
	"downloads": {"": [["complete", "dir", 4096]], "complete": [["Sample-Episode.mkv", "file", 1048576], ["Sample-Movie.mkv", "file", 2097152]]},
	"media": {"": [["series", "dir", 4096], ["movies", "dir", 4096], ["music", "dir", 4096]],
		"series": [["Sample-Episode.mkv", "file", 1048576], ["Sample-Episode.en.srt", "file", 160]],
		"movies": [["Sample-Movie.mkv", "file", 2097152]], "music": []}
}
const COLORS = {"API": Color(0.29, 0.8, 0.96), "Metrics": Color(0.43, 0.88, 0.50),
	"Files": Color(1.0, 0.59, 0.24), "VPN": Color(0.73, 0.51, 0.98)}
const MEDIA = [
	["media/overseerr", "media/plex", "API", "Library and available titles"],
	["media/overseerr", "media/sonarr", "API", "TV requests"],
	["media/overseerr", "media/radarr", "API", "Movie requests"],
	["media/sonarr", "media/jackett", "API", "TV index searches"],
	["media/radarr", "media/jackett", "API", "Movie index searches"],
	["media/lidarr", "media/prowlarr", "API", "Music index searches"],
	["media/sonarr", "media/qbittorrent", "API", "TV download queue"],
	["media/radarr", "media/qbittorrent", "API", "Movie download queue"],
	["media/lidarr", "media/qbittorrent", "API", "Music download queue"],
	["media/bazarr", "media/sonarr", "API", "Episode list"],
	["media/bazarr", "media/radarr", "API", "Movie list"],
	["media/tautulli", "media/plex", "API", "Sessions and playback history"],
	["media-vpn/seerr", "media-vpn/jellyfin", "API", "Library and available titles"],
	["media-vpn/seerr", "media-vpn/sonarr", "API", "TV requests"],
	["media-vpn/seerr", "media-vpn/radarr", "API", "Movie requests"],
	["media-vpn/sonarr", "media-vpn/prowlarr", "API", "TV index searches"],
	["media-vpn/radarr", "media-vpn/prowlarr", "API", "Movie index searches"],
	["media-vpn/sonarr", "media-vpn/deluge", "API", "TV download queue"],
	["media-vpn/radarr", "media-vpn/deluge", "API", "Movie download queue"],
	["media/qbittorrent", "media/sonarr", "Files", "downloads → series import"],
	["media/qbittorrent", "media/radarr", "Files", "downloads → movie import"],
	["media/qbittorrent", "media/lidarr", "Files", "downloads → music import"],
	["media/sonarr", "media/plex", "Files", "series import → media library"],
	["media/radarr", "media/plex", "Files", "movie import → media library"],
	["media/lidarr", "media/plex", "Files", "music import → media library"],
	["media/bazarr", "media/plex", "Files", "subtitles → media library"],
	["media-vpn/deluge", "media-vpn/sonarr", "Files", "downloads → series import"],
	["media-vpn/deluge", "media-vpn/radarr", "Files", "downloads → movie import"],
	["media-vpn/sonarr", "media-vpn/jellyfin", "Files", "series import → media library"],
	["media-vpn/radarr", "media-vpn/jellyfin", "Files", "movie import → media library"],
	["monitoring/grafana", "monitoring/prometheus", "Metrics", "Dashboard queries"],
	["monitoring/prometheus", "media/tautulli", "Metrics", "Plex stream totals via simulated Tautulli exporter"],
	["monitoring/prometheus", "monitoring/cadvisor", "Metrics", "Container metrics"],
	["monitoring/prometheus", "monitoring/node-exporter", "Metrics", "Node metrics"]
]
const SHOP = [
	["shop/frontend", "shop/cart", "API", "Shopping cart"],
	["shop/frontend", "shop/checkout", "API", "Submit order"],
	["shop/frontend", "shop/catalog-db", "API", "Product catalogue"],
	["shop/checkout", "shop/cart", "API", "Read order items"],
	["shop/checkout", "shop/catalog-db", "API", "Store order"],
	["shop/cart", "shop/redis", "API", "Cart state"]
]

# Home Assistant: the hub calls each integration; device bridges publish to MQTT.
const HOME = [
	["home/homeassistant", "home/mosquitto", "API", "MQTT devices and events"],
	["home/zigbee2mqtt", "home/mosquitto", "API", "Zigbee devices over MQTT"],
	["home/frigate", "home/mosquitto", "API", "Camera detections over MQTT"],
	["home/homeassistant", "home/zwave-js-ui", "API", "Z-Wave devices (WebSocket)"],
	["home/homeassistant", "home/matter-server", "API", "Matter devices (WebSocket)"],
	["home/homeassistant", "home/frigate", "API", "Camera events and clips"],
	["home/homeassistant", "home/music-assistant", "API", "Media players"],
	["home/node-red", "home/homeassistant", "API", "Automations (WebSocket API)"],
	["home/homeassistant", "voice/whisper", "API", "Speech to text (Wyoming)"],
	["home/homeassistant", "voice/piper", "API", "Text to speech (Wyoming)"],
	["home/homeassistant", "voice/openwakeword", "API", "Wake word detection (Wyoming)"],
	["home/homeassistant", "home/mariadb", "API", "Recorder history"],
	["home/homeassistant", "home/influxdb", "Metrics", "Long-term sensor history"],
	["home/grafana", "home/influxdb", "Metrics", "Dashboard queries"]
]
# The build farm: Git and CI, image builds, caches and artifacts.
const DEV = [
	["ci/gitea", "ci/woodpecker-server", "API", "Push webhooks"],
	["ci/woodpecker-server", "ci/gitea", "API", "Clones and commit status"],
	["ci/woodpecker-agent", "ci/woodpecker-server", "API", "Pipeline jobs (gRPC)"],
	["ci/woodpecker-server", "ci/postgres", "API", "Pipeline state"],
	["ci/gitea", "ci/postgres", "API", "Repositories and users"],
	["ci/woodpecker-agent", "ci/buildkitd", "API", "Image builds"],
	["ci/buildkitd", "ci/registry", "Files", "Pushes built images"],
	["ci/woodpecker-agent", "ci/minio", "Files", "Build artifacts and logs"],
	["ci/gitea", "ci/minio", "Files", "LFS objects and attachments"],
	["ci/nightly-engine-build", "ci/sccache-redis", "API", "Compiler cache"],
	["ci/build-firmware", "ci/minio", "Files", "Firmware images"],
	["dev/devcontainer-cpp", "ci/sccache-redis", "API", "Compiler cache"],
	["dev/devcontainer-rust", "ci/sccache-redis", "API", "Compiler cache"],
	["dev/code-server", "ci/gitea", "API", "Git push and pull"],
	["dev/devcontainer-cpp", "ci/gitea", "API", "Git push and pull"],
	["dev/devcontainer-rust", "ci/gitea", "API", "Git push and pull"],
	["dev/devcontainer-go", "ci/gitea", "API", "Git push and pull"],
	["dev/devcontainer-python", "ci/gitea", "API", "Git push and pull"],
	["dev/devcontainer-node", "ci/gitea", "API", "Git push and pull"]
]

static func key(p: Dictionary) -> String:
	return "%s/%s" % [p.get("ns", ""), p.get("wname", p.get("name", ""))]

static func protects(ns: String, name: String) -> bool:
	return name in VPN_APPS.get(ns, [])

static func uses_shared_vpn(ns: String, name: String) -> bool:
	return ns == "media-vpn" and name in SHARED_VPN_APPS

static func volumes(ns: String, name: String) -> Dictionary:
	if ns not in ["media", "media-vpn"]:
		return {}
	if name in ["qbittorrent", "deluge"]:
		return {"downloads": false}
	if name in ["sonarr", "radarr", "lidarr"]:
		return {"downloads": true, "media": false}
	if name == "bazarr":
		return {"media": false}
	if name in ["plex", "jellyfin"]:
		return {"media": true}
	return {}

static func disk(claim: String) -> Dictionary:
	var entries: Dictionary = SHARED_FILES[claim]
	var used = 0
	for dir in entries.values():
		for file in dir:
			if file[1] == "file":
				used += int(file[2])
	return {"entries": entries, "capacity": (10 if claim == "downloads" else 20) * 1073741824, "used": used}

static func preset(media: bool) -> Array:
	var rows = MEDIA.duplicate(true) if media else SHOP.duplicate(true)
	if media:
		for ns in VPN_APPS:
			for name in VPN_APPS[ns]:
				var gateway = ns + "/" + SHARED_VPN if uses_shared_vpn(ns, name) else ns + "/" + name + " · Gluetun"
				rows.append([ns + "/" + name, gateway, "VPN", "Internet egress"])
	return rows

static func links(state: Dictionary) -> Array:
	if state.get("source") != "simulation":
		return []
	var pods = {}
	for p in state.get("pods", []):
		if p.get("node", "") != "":
			var id = key(p)
			if not pods.has(id):
				pods[id] = []
			pods[id].append(p)
	var out = []
	for row in MEDIA + SHOP + HOME + DEV:
		if not pods.has(row[0]) or not pods.has(row[1]):
			continue
		for a in pods[row[0]]:
			for b in pods[row[1]]:
				out.append({"from": a["uid"], "to": b["uid"], "from_name": row[0], "to_name": row[1],
					"kind": row[2], "what": row[3], "ready": a["ready"] and b["ready"]})
	return out
