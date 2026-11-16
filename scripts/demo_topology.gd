extends RefCounted

const VPN_IMAGE = "qmcgaw/gluetun:v3"
const VPN_APPS = {
	"media": ["qbittorrent", "jackett", "prowlarr", "sonarr", "radarr", "lidarr", "bazarr"],
	"media-vpn": ["deluge", "prowlarr", "sonarr", "radarr"]
}
const SEGMENTS = {"media": 20, "media-vpn": 30, "monitoring": 40, "shop": 50}
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

static func key(p: Dictionary) -> String:
	return "%s/%s" % [p.get("ns", ""), p.get("wname", p.get("name", ""))]

static func protects(ns: String, name: String) -> bool:
	return name in VPN_APPS.get(ns, [])

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

static func preset(media: bool) -> Array:
	var rows = MEDIA.duplicate(true) if media else SHOP.duplicate(true)
	if media:
		for ns in VPN_APPS:
			for name in VPN_APPS[ns]:
				rows.append([ns + "/" + name, ns + "/" + name + " · Gluetun", "VPN", "Internet egress"])
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
	for row in MEDIA + SHOP:
		if not pods.has(row[0]) or not pods.has(row[1]):
			continue
		for a in pods[row[0]]:
			for b in pods[row[1]]:
				out.append({"from": a["uid"], "to": b["uid"], "from_name": row[0], "to_name": row[1],
					"kind": row[2], "what": row[3], "ready": a["ready"] and b["ready"]})
	return out
