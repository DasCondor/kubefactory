extends RefCounted
# Application icons, drawn in code (the project ships no art for them and uses
# nobody's logo): a coloured tile with a plain white symbol for what kind of
# software a machine runs. The kind comes from the image the pod's main
# container runs, the same rule that picks the machine model.

const Models = preload("res://scripts/models.gd")

const SIZE = 64
# kind -> [tile colour, what it stands for]
const KINDS = {
	"database": [Color(0.42, 0.36, 0.86), "database"],
	"cache": [Color(0.86, 0.3, 0.27), "cache"],
	"queue": [Color(0.93, 0.55, 0.18), "message broker"],
	"monitor": [Color(0.95, 0.5, 0.15), "monitoring"],
	"logs": [Color(0.3, 0.62, 0.72), "log collector"],
	"registry": [Color(0.2, 0.55, 0.9), "image registry"],
	"proxy": [Color(0.15, 0.66, 0.6), "proxy / load balancer"],
	"network": [Color(0.32, 0.5, 0.85), "network service"],
	"build": [Color(0.55, 0.58, 0.63), "build tool"],
	"media": [Color(0.9, 0.62, 0.1), "media server"],
	"download": [Color(0.25, 0.68, 0.42), "media management"],
	"home": [Color(0.16, 0.66, 0.86), "home automation"],
	"web": [Color(0.24, 0.7, 0.45), "web server"],
	"app": [Color(0.45, 0.5, 0.57), "application"],
}
const BY_IMAGE = [
	[["postgres", "postgresql", "mysql", "mariadb", "mongo", "mongodb", "cockroach", "influxdb", "clickhouse", "mssql", "timescaledb"], "database"],
	[["redis", "memcached", "valkey", "dragonfly", "sccache"], "cache"],
	[["kafka", "rabbitmq", "nats", "mosquitto", "pulsar", "activemq"], "queue"],
	[["prometheus", "grafana", "alertmanager", "tautulli", "uptime-kuma", "cadvisor", "node-exporter"], "monitor"],
	[["loki", "fluentd", "fluent-bit", "promtail", "logstash", "vector", "filebeat"], "logs"],
	[["registry", "harbor-core", "harbor-registry", "nexus", "nexus3", "artifactory"], "registry"],
	[["traefik", "haproxy", "envoy", "nginx-ingress", "nginx-ingress-controller"], "proxy"],
	[["coredns", "pihole", "adguardhome", "wireguard", "tailscale", "kube-proxy"], "network"],
	[["buildkit", "kaniko", "jenkins", "gitlab-runner", "act_runner", "woodpecker-agent", "drone-runner-docker", "cpp", "zig", "rust", "go"], "build"],
	[["plex", "pms-docker", "jellyfin", "emby"], "media"],
	[["sonarr", "radarr", "lidarr", "bazarr", "jackett", "prowlarr", "qbittorrent", "overseerr", "flaresolverr", "transmission", "sabnzbd"], "download"],
	[["home-assistant", "zigbee2mqtt", "esphome", "node-red", "frigate", "zwave-js-ui", "python-matter-server"], "home"],
	[["nginx", "httpd", "caddy", "apache"], "web"],
]

static var _tex = {}

static func kind_of(pod: Dictionary) -> String:
	var conts: Array = pod.get("containers", [])
	if conts.is_empty():
		return "app"
	var name = Models.image_name(str(conts[0].get("image", "")))
	for row in BY_IMAGE:
		if name in row[0]:
			return row[1]
	return "app"

static func label_of(kind: String) -> String:
	return str(KINDS.get(kind, KINDS["app"])[1])

static func texture(kind: String) -> ImageTexture:
	if not KINDS.has(kind):
		kind = "app"
	if not _tex.has(kind):
		_tex[kind] = ImageTexture.create_from_image(_draw(kind))
	return _tex[kind]

# ---- drawing: shapes as distance tests, on a 64 x 64 tile

static func _draw(kind: String) -> Image:
	var img = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var tile: Color = KINDS[kind][0]
	var shapes = _shapes(kind)
	for y in SIZE:
		for x in SIZE:
			var p = Vector2(x + 0.5, y + 0.5)
			var a = _cover(_round_box(p, Vector2(32, 32), Vector2(30, 30), 12.0))
			if a <= 0.0:
				continue
			var c = tile
			var w = 0.0
			for s in shapes:
				w = maxf(w, _cover(s.call(p)))
			c = c.lerp(Color(1, 1, 1), w)
			c.a = a
			img.set_pixel(x, y, c)
	return img

# a signed distance (negative inside) -> 0..1 coverage, one pixel of soft edge
static func _cover(d: float) -> float:
	return clampf(0.5 - d, 0.0, 1.0)

static func _round_box(p: Vector2, c: Vector2, half: Vector2, r: float) -> float:
	var q = (p - c).abs() - half + Vector2(r, r)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - r

static func _circle(p: Vector2, c: Vector2, r: float) -> float:
	return p.distance_to(c) - r

static func _seg(p: Vector2, a: Vector2, b: Vector2, w: float) -> float:
	var ab = b - a
	var t = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t) - w

static func _tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> float:
	var d1 = (p - a).cross(b - a)
	var d2 = (p - b).cross(c - b)
	var d3 = (p - c).cross(a - c)
	var inside = (d1 >= 0 and d2 >= 0 and d3 >= 0) or (d1 <= 0 and d2 <= 0 and d3 <= 0)
	var edge = minf(minf(_seg(p, a, b, 0.0), _seg(p, b, c, 0.0)), _seg(p, c, a, 0.0))
	return -edge if inside else edge

static func _shapes(kind: String) -> Array:
	var s = []
	match kind:
		"database":      # three stacked discs
			for y in [20.0, 32.0, 44.0]:
				s.append(func(p): return _round_box(p, Vector2(32, y), Vector2(16, 4), 4.0))
		"cache":         # a bolt
			s.append(func(p): return _tri(p, Vector2(36, 12), Vector2(20, 35), Vector2(31, 35)))
			s.append(func(p): return _tri(p, Vector2(28, 52), Vector2(44, 29), Vector2(33, 29)))
		"queue":         # messages in a row, moving right
			for x in [17.0, 29.0]:
				s.append(func(p): return _round_box(p, Vector2(x, 32), Vector2(4, 9), 2.0))
			s.append(func(p): return _tri(p, Vector2(38, 21), Vector2(38, 43), Vector2(51, 32)))
		"monitor":       # rising bars
			var hs = [8.0, 14.0, 20.0, 27.0]
			for i in 4:
				var h = hs[i]
				var x = 17.0 + i * 10.0
				s.append(func(p): return _round_box(p, Vector2(x, 48 - h / 2.0), Vector2(3.5, h / 2.0), 1.5))
		"logs":          # lines of text
			var ws = [17.0, 12.0, 15.0, 9.0]
			for i in 4:
				var w = ws[i]
				var y = 20.0 + i * 8.0
				s.append(func(p): return _seg(p, Vector2(15, y), Vector2(15 + w * 2.0, y), 1.8))
		"registry":      # a crate
			s.append(func(p): return absf(_round_box(p, Vector2(32, 34), Vector2(15, 13), 2.0)) - 1.8)
			s.append(func(p): return _seg(p, Vector2(17, 29), Vector2(47, 29), 1.6))
			s.append(func(p): return _seg(p, Vector2(32, 21), Vector2(32, 29), 1.6))
		"proxy":         # one in, three out
			s.append(func(p): return _circle(p, Vector2(17, 32), 5.0))
			for y in [17.0, 32.0, 47.0]:
				s.append(func(p): return _circle(p, Vector2(47, y), 4.0))
				s.append(func(p): return _seg(p, Vector2(17, 32), Vector2(47, y), 1.5))
		"network":       # a hub and its spokes
			s.append(func(p): return _circle(p, Vector2(32, 32), 6.0))
			for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
				s.append(func(p): return _circle(p, Vector2(32, 32) + d * 15.0, 3.8))
				s.append(func(p): return _seg(p, Vector2(32, 32), Vector2(32, 32) + d * 15.0, 1.4))
		"build":         # a cog
			s.append(func(p): return absf(_circle(p, Vector2(32, 32), 10.0)) - 3.2)
			for i in 8:
				var d = Vector2.RIGHT.rotated(i * TAU / 8.0)
				s.append(func(p): return _seg(p, Vector2(32, 32) + d * 13.0, Vector2(32, 32) + d * 18.0, 2.6))
		"media":         # play
			s.append(func(p): return _tri(p, Vector2(24, 16), Vector2(24, 48), Vector2(49, 32)))
		"download":      # arrow into a tray
			s.append(func(p): return _seg(p, Vector2(32, 14), Vector2(32, 34), 2.6))
			s.append(func(p): return _tri(p, Vector2(21, 30), Vector2(43, 30), Vector2(32, 42)))
			s.append(func(p): return _seg(p, Vector2(17, 49), Vector2(47, 49), 2.4))
		"home":          # a house
			s.append(func(p): return _tri(p, Vector2(32, 13), Vector2(13, 31), Vector2(51, 31)))
			s.append(func(p): return _round_box(p, Vector2(32, 40), Vector2(12, 10), 1.5))
		"web":           # a browser window
			s.append(func(p): return absf(_round_box(p, Vector2(32, 32), Vector2(17, 14), 3.0)) - 1.8)
			s.append(func(p): return _seg(p, Vector2(16, 25), Vector2(48, 25), 1.6))
		_:               # a plain block
			s.append(func(p): return _round_box(p, Vector2(32, 32), Vector2(12, 12), 3.0))
	return s
