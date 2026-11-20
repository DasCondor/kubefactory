extends Node
# What the screens show in the simulated worlds (and so in the browser demo).
#
# A simulated cluster has no real Grafana or Tautulli behind it, so LiveView
# has nothing to open there. To show what those screens are for, the demo draws
# its own content on them, and says so on every one:
#   - a Grafana machine shows a small dashboard of the simulated cluster's own
#     figures (requested CPU and memory, pod states, per-node load): the same
#     numbers the HUD shows, drawn as charts
#   - a Plex or Tautulli machine shows simulated stream activity
# Every panel carries a SIMULATED banner. None of this runs against a real
# cluster or a Docker engine: there the screens stay neutral until a real page
# or a real provider is put on them.
# It needs no companion and no network, so it works in the browser build.
#
# V on the machine opens the dashboard large, where the view
# can be switched (the machine's own screen follows).

const K = preload("res://scripts/kutil.gd")
const Models = preload("res://scripts/models.gd")

const SIZE = Vector2i(640, 448)
const HISTORY = 40
const VIEWS = {"grafana": ["Cluster overview", "Nodes", "Ports", "Shared disks"], "streams": ["Activity", "Bandwidth", "Ports", "Shared disks"],
	"pod": ["Overview", "Connections", "Ports", "Shared disks"], "heimdall": ["Apps", "Recent failures", "Ports", "Shared disks"]}

var world = null
var live = null
var providers = null
var mode_screens = null     # the screen-mode switcher: metrics / logs / storage take the screen while shown

var _screens = {}      # machine uid -> {kind, vp, panel, name}
var _cpu_hist = []     # share of CPU requested, one sample per state update
var _bw_hist = []      # simulated total bandwidth (kbps), one sample per state update
var _figures = {}
var recent_failures = {}
var _t = 0.0

# What a simulated machine's screen shows: "grafana", "streams" or "".
static func kind_of(pod: Dictionary) -> String:
	if pod.get("wname") == "heimdall":
		return "heimdall"
	var conts: Array = pod.get("containers", [])
	if conts.is_empty():
		return "pod"
	var img = Models.image_name(str(conts[0].get("image", "")))
	if img == "grafana":
		return "grafana"
	if img in ["plex", "pms-docker", "tautulli", "jellyfin"]:
		return "streams"
	return "pod"

# Simulated stream activity at time t (seconds): a few streams that come and go.
# Deterministic, so a test can say what it should be.
static func streams_at(t: float) -> Dictionary:
	var n = 2 + int(round(1.5 + 1.5 * sin(t / 11.0)))          # 2..5 streams
	var transcode = clampi(int(round(n * (0.35 + 0.25 * sin(t / 17.0 + 1.0)))), 0, n)
	var direct_stream = clampi(int(round((n - transcode) * 0.3)), 0, n - transcode)
	var direct_play = n - transcode - direct_stream
	var wan = transcode * 4200 + direct_stream * 6500
	var lan = direct_play * 14500
	return {"streams": n, "direct_play": direct_play, "direct_stream": direct_stream, "transcode": transcode,
		"total_kbps": wan + lan, "lan_kbps": lan, "wan_kbps": wan}

# The simulated cluster's own figures, as the dashboard draws them.
static func cluster_figures(state: Dictionary) -> Dictionary:
	var cpu = 0.0
	var cpu_req = 0.0
	var mem = 0.0
	var mem_req = 0.0
	var nodes = []
	for n in state.get("nodes", []):
		cpu += float(n.get("cpu", 0.0))
		cpu_req += float(n.get("cpu_req", 0.0))
		mem += float(n.get("mem", 0.0))
		mem_req += float(n.get("mem_req", 0.0))
		nodes.append({"name": str(n["name"]), "load": float(n.get("cpu_req", 0.0)) / maxf(float(n.get("cpu", 0.0)), 0.001)})
	var ok = 0
	var pending = 0
	var bad = 0
	for p in state.get("pods", []):
		match str(p.get("health", "")):
			"ok", "done":
				ok += 1
			"warn":
				pending += 1
			_:
				bad += 1
	return {"cpu": cpu_req / maxf(cpu, 0.001), "mem": mem_req / maxf(mem, 0.001), "running": ok, "pending": pending, "failing": bad, "nodes": nodes}

func has(uid: String) -> bool:
	return _screens.has(uid)

# [{uid, kind, name}] for the list in the LiveView panel
func screens() -> Array:
	var res = []
	for uid in _screens:
		res.append({"uid": uid, "kind": _screens[uid]["kind"], "name": _screens[uid]["name"]})
	return res

func texture_of(uid: String) -> Texture2D:
	return _screens[uid]["vp"].get_texture() if _screens.has(uid) else null

func view_of(uid: String) -> int:
	return int(_screens[uid]["panel"].view) if _screens.has(uid) else 0

func set_view(uid: String, v: int) -> void:
	if _screens.has(uid):
		var screen = _screens[uid]
		screen["panel"].view = v
		screen["panel"].queue_redraw()
		screen["vp"].render_target_update_mode = SubViewport.UPDATE_ONCE

# A second, larger copy of a machine's panel for the window (same data, same view).
func make_panel(uid: String, compact: bool = false) -> Control:
	if not _screens.has(uid):
		return null
	var p = ScreenPanel.new()
	p.compact = compact
	p.kind = _screens[uid]["kind"]
	p.source = _screens[uid]["panel"]
	return p

func clear() -> void:
	for uid in _screens.keys():
		_drop(uid)
	_cpu_hist.clear()
	_bw_hist.clear()
	recent_failures.clear()

func _drop(uid: String) -> void:
	var s = _screens[uid]
	_screens.erase(uid)
	if is_instance_valid(s["vp"]):
		s["vp"].queue_free()
	var m = world.machines.get(uid) if world != null else null
	if m != null and not _taken(uid):
		m.set_screen_texture(null)

# a real page or a real provider on that screen always wins
func _taken(uid: String) -> bool:
	if mode_screens != null and mode_screens.holds(uid):
		return true
	if providers != null and providers.pins.has(uid):
		return true
	if live != null:
		for s in live.sessions.values():
			if str(s.get("mounted", "")) == uid:
				return true
	return false

# Called with every state of a simulated world.
func sync(state: Dictionary) -> void:
	if world == null:
		return
	_figures = cluster_figures(state)
	var st = streams_at(_t)
	_cpu_hist.append(_figures["cpu"])
	_bw_hist.append(float(st["total_kbps"]))
	for h in [_cpu_hist, _bw_hist]:
		if h.size() > HISTORY:
			h.pop_front()
	var want = {}
	var connections = {}
	var ports = {}
	for row in K.port_rows(state):
		for uid in row["pods"]:
			if not ports.has(uid):
				ports[uid] = []
			ports[uid].append(row)
	var disks = {}
	for disk in K.shared_disks(state):
		for mount in disk["mounts"]:
			var uid: String = mount["uid"]
			if not disks.has(uid):
				disks[uid] = []
			if disk not in disks[uid]:
				disks[uid].append(disk)
	for l in state.get("links", []):
		for side in ["from", "to"]:
			var id: String = l[side]
			if not connections.has(id):
				connections[id] = []
			connections[id].append("%s %s · %s%s%s" % ["→" if side == "from" else "←", l["to_name" if side == "from" else "from_name"],
				l["kind"], " · " + str(l["port"]) if str(l.get("port", "")) != "" else "", "" if l.get("ready", true) else " · unavailable"])
	for p in state.get("pods", []):
		var kind = kind_of(p)
		if p.get("health") == "bad":
			recent_failures[p["uid"]] = p
			if recent_failures.size() > 20:
				recent_failures.erase(recent_failures.keys()[0])
		if world.machines.has(str(p["uid"])):
			want[str(p["uid"])] = [kind, str(p["name"]), p]
	for uid in _screens.keys():
		if not want.has(uid):
			_drop(uid)
	for uid in want:
		if not _screens.has(uid):
			var vp = SubViewport.new()
			vp.size = Vector2i(320, 224) if want[uid][0] == "pod" else SIZE
			vp.transparent_bg = false
			vp.gui_disable_input = true
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			add_child(vp)
			var panel = ScreenPanel.new()
			panel.kind = want[uid][0]
			panel.size = Vector2(vp.size)
			vp.add_child(panel)
			_screens[uid] = {"kind": want[uid][0], "vp": vp, "panel": panel, "name": want[uid][1]}
		var s = _screens[uid]
		var pod: Dictionary = want[uid][2]
		var net: Dictionary = pod.get("net", {})
		var gateway = K.find_pod(state, str(net["via"])) if str(net.get("via", "")) != "" else null
		var vpn: Dictionary = net.get("vpn", {})
		var links: Array = connections.get(uid, [])
		var route = "No VPN route configured"
		if gateway != null:
			route = "Via %s%s" % [gateway["wname"], "" if gateway["ready"] else " · offline"]
			links.push_front("→ %s → Internet Output" % gateway["wname"])
		elif not vpn.is_empty():
			route = "%s · %d apps" % [vpn.get("product", "VPN"), vpn.get("through", []).size()]
			links.push_front("→ %s → Internet Output" % vpn.get("product", "VPN"))
		s["panel"].pod = pod
		s["panel"].lab = state.get("lab", {})
		s["panel"].route = route
		s["panel"].ports = ports.get(uid, [])
		s["panel"].disks = disks.get(uid, [])
		s["panel"].connections = links
		s["panel"].failures = recent_failures.values()
		s["panel"].figures = _figures
		s["panel"].history = _cpu_hist
		s["panel"].bw_history = _bw_hist
		s["panel"].streams = st if pod["ready"] else {}
		s["panel"].queue_redraw()
		s["vp"].render_target_update_mode = SubViewport.UPDATE_ONCE
		if not _taken(uid):
			world.machines[uid].set_screen_texture(s["vp"].get_texture())

func _process(delta: float) -> void:
	_t += delta

# One screen's picture, drawn by hand so it costs a single small viewport.
# Laid out on a 640 x 448 sheet in large print (it is read from across a
# walkway) and scaled to whatever size the control has.
class ScreenPanel extends Control:
	var compact = false
	var kind = ""
	var view = 0
	var figures = {}
	var history = []
	var bw_history = []
	var streams = {}
	var pod = {}
	var lab = {}
	var ports = []
	var disks = []
	var route = ""
	var connections = []
	var failures = []
	var source: Control = null     # the window's copy mirrors the machine's panel

	const BG = Color(0.067, 0.082, 0.102)
	const CARD = Color(0.106, 0.129, 0.157)
	const TXT = Color(0.92, 0.95, 0.98)
	const DIM = Color(0.62, 0.68, 0.74)
	const ORANGE = Color(0.957, 0.647, 0.227)
	const GREEN = Color(0.35, 0.82, 0.5)
	const AMBER = Color(0.95, 0.75, 0.25)
	const RED = Color(0.93, 0.36, 0.3)
	const BLUE = Color(0.36, 0.62, 0.95)

	func _process(_d: float) -> void:
		if source != null and is_instance_valid(source):
			view = source.view
			figures = source.figures
			history = source.history
			bw_history = source.bw_history
			streams = source.streams
			pod = source.pod
			lab = source.lab
			ports = source.ports
			disks = source.disks
			route = source.route
			connections = source.connections
			failures = source.failures
			queue_redraw()

	func _text(pos: Vector2, s: String, px: int, col: Color, width: float = -1.0, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
		draw_string(ThemeDB.fallback_font, pos, s, align, width, maxi(px, 21) if compact else px, col)

	func _card(r: Rect2, title: String) -> void:
		draw_rect(r, CARD)
		_text(r.position + Vector2(12, 24), title, 17, DIM, r.size.x - 24.0)

	func _level(v: float) -> Color:
		return GREEN if v < 0.7 else (AMBER if v < 0.9 else RED)

	func _line(plot: Rect2, values: Array, top: float, col: Color) -> void:
		for i in 3:
			var y = plot.position.y + plot.size.y * i / 2.0
			draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(1, 1, 1, 0.08), 1.0)
		if values.size() < 2:
			return
		var pts = PackedVector2Array()
		for i in values.size():
			pts.append(Vector2(plot.position.x + plot.size.x * i / float(values.size() - 1), plot.end.y - plot.size.y * clampf(float(values[i]) / maxf(top, 0.001), 0.0, 1.0)))
		draw_polyline(pts, col, 4.0, true)

	func _draw() -> void:
		var fit = minf(size.x / 640.0, size.y / 448.0)
		draw_set_transform((size - Vector2(640, 448) * fit) * 0.5, 0.0, Vector2(fit, fit))
		draw_rect(Rect2(0, 0, 640, 448), BG)
		# the banner: on every panel, always
		draw_rect(Rect2(0, 0, 640, 36), Color(0.22, 0.15, 0.05))
		_text(Vector2(12, 26), "SIMULATED", 22, ORANGE)
		_text(Vector2(150, 25), str(pod.get("wname", "Demo workload")), 17, Color(0.9, 0.78, 0.6), 470)
		var title: String = VIEWS.get(kind, VIEWS["pod"])[view]
		_text(Vector2(12, 70), title, 26, TXT)
		if title == "Ports":
			_port_panel()
		elif title == "Shared disks":
			_disk_panel()
		elif kind == "pod" or kind == "heimdall":
			_pod_panel()
		elif kind == "grafana":
			if view == 0:
				_overview()
			else:
				_nodes()
		elif view == 0:
			_activity()
		else:
			_bandwidth()

	func _pod_panel() -> void:
		var lines = []
		if kind == "heimdall":
			lines = ["Plex · Jellyfin · Requests", "Downloads · Indexers · Library", "Tautulli · Prometheus · Grafana"] if view == 0 else failures.map(func(p): return "%s · %s" % [p["wname"], p["status"]])
			if lines.is_empty():
				lines.append("No failures recorded in this session")
		elif view == 0:
			_pod_overview()
			return
		else:
			lines = connections
			if lines.is_empty():
				lines = ["No application links are defined for this workload"]
		for i in mini(lines.size(), 7):
			var y = 84 + i * 49
			draw_rect(Rect2(12, y, 616, 44), CARD)
			var color = RED if "unavailable" in lines[i] or (kind == "heimdall" and view == 1 and not failures.is_empty()) else TXT
			_text(Vector2(26, y + 30), str(lines[i]), 20, color, 585)

	func _pod_overview() -> void:
		if not lab.is_empty():
			_lab_overview()
			return
		var status = Rect2(12, 84, 616, 96)
		_card(status, "%s · %s" % [pod.get("ns", ""), pod.get("node", "Unscheduled")])
		_text(Vector2(24, 155), str(pod.get("status", "Waiting")), 29, K.health_color(pod.get("health", "warn")), 365)
		_text(Vector2(408, 155), "%d restarts" % pod.get("restarts", 0), 18, DIM, 196, HORIZONTAL_ALIGNMENT_RIGHT)
		_card(Rect2(12, 192, 280, 88), "SERVICE PORTS")
		var issue_count = ports.filter(func(row): return row["health"] != "ok").size()
		var port_color = AMBER if issue_count > 0 else TXT
		if compact:
			_text(Vector2(24, 246), "%d configured" % ports.size(), 16, port_color, 254)
			_text(Vector2(24, 271), "%d need attention" % issue_count, 16, port_color, 254)
		else:
			_text(Vector2(24, 254), "%d configured · %d need attention" % [ports.size(), issue_count], 16, port_color, 254)
		_card(Rect2(304, 192, 324, 88), "VPN ROUTE")
		_text(Vector2(316, 254), route, 18, TXT, 300)
		_card(Rect2(12, 292, 616, 144), "CONTAINERS")
		var containers: Array = pod.get("containers", [])
		for i in mini(containers.size(), 4):
			var c: Dictionary = containers[i]
			_text(Vector2(24, 342 + i * 25), str(c["name"]), 17, TXT, 340)
			_text(Vector2(376, 342 + i * 25), str(c["state"]), 17, GREEN if c.get("ready", false) else AMBER, 229, HORIZONTAL_ALIGNMENT_RIGHT)

	func _lab_overview() -> void:
		_card(Rect2(12, 84, 616, 66), str(pod.get("node", "")))
		_text(Vector2(24, 136), str(pod.get("status", "")), 22, K.health_color(pod.get("health", "warn")), 300)
		var detail = route
		match pod.get("wname", ""):
			"downloader":
				detail = "%d files awaiting sync" % lab["queued"]
			"syncthing", "media-sync":
				detail = "%s · %d files/hour" % ["Paused" if lab["paused"] else ("Copying" if lab["transfer"] else "Waiting"), lab["recent_count"]]
			"seerr":
				detail = "Discord · " + ("disabled" if not lab["discord"] else ("sample delivered" if lab["last_alert"] > 0 else "ready"))
			"prometheus":
				detail = "Stores metrics in prometheus-data"
			"tautulli-exporter":
				detail = "Tautulli JSON → Prometheus metrics"
			"blackbox":
				detail = "HTTP checks · 4 media services"
			"jackett":
				detail = "Index searches through Gluetun"
			"sonarr", "radarr":
				detail = "Seerr requests → indexer → downloader"
			"gatherer-metrics":
				detail = "Private Docker bridge" if lab.get("host_count", 2) == 1 else "Private management VLAN 40"
		_card(Rect2(12, 162, 616, 68), "ACTIVITY")
		_text(Vector2(24, 215), detail, 20, TXT, 590)
		_card(Rect2(12, 242, 616, 66), "LISTENER")
		if not ports.is_empty():
			_text(Vector2(24, 292), "%s · %s" % [ports[0]["port"], ports[0]["scope"]], 19, TXT, 590)
		_card(Rect2(12, 320, 616, 116), "DIRECT CONNECTIONS")
		for i in mini(connections.size(), 3):
			_text(Vector2(24, 366 + i * 25), str(connections[i]), 18, DIM, 590)

	func _port_panel() -> void:
		if ports.is_empty():
			_card(Rect2(12, 84, 616, 62), "No Service or host ports configured for this pod")
			return
		for i in mini(ports.size(), 5):
			var row: Dictionary = ports[i]
			var y = 84 + i * 65
			draw_rect(Rect2(12, y, 616, 60), CARD)
			var color = K.health_color(row["health"])
			draw_rect(Rect2(12, y, 4, 60), color)
			_text(Vector2(26, y + 23), row["port"], 20, TXT, 300)
			_text(Vector2(338, y + 23), row["status"], 17, color, 273, HORIZONTAL_ALIGNMENT_RIGHT)
			_text(Vector2(26, y + 47), "%s · %s" % [row["name"], row["scope"]], 16, DIM, 585)
		if ports.size() > 5:
			_text(Vector2(16, 432), "Port details shows all %d ports" % ports.size(), 16, DIM)

	func _disk_panel() -> void:
		if disks.is_empty():
			_card(Rect2(12, 84, 616, 62), "No shared backing volumes reported for this pod")
			return
		for i in mini(disks.size(), 4):
			var disk: Dictionary = disks[i]
			var y = 84 + i * 83
			_card(Rect2(12, y, 616, 75), "%s · %d containers" % [disk["label"], disk["containers"].size()])
			_text(Vector2(24, y + 55), K.shared_disk_usage(disk), 19, TXT, 582)

	func _overview() -> void:
		var chart = Rect2(12, 84, 616, 176)
		_card(chart, "CPU REQUESTED")
		_line(Rect2(chart.position + Vector2(14, 40), Vector2(440, 122)), history, 1.0, BLUE)
		_text(Vector2(480, 200), "%d%%" % int(round(float(figures.get("cpu", 0.0)) * 100.0)), 64, TXT, 140, HORIZONTAL_ALIGNMENT_RIGHT)
		var mem = clampf(float(figures.get("mem", 0.0)), 0.0, 1.0)
		var tiles = [["RUNNING", str(int(figures.get("running", 0))), GREEN], ["PENDING", str(int(figures.get("pending", 0))), AMBER if int(figures.get("pending", 0)) > 0 else DIM],
			["FAILING", str(int(figures.get("failing", 0))), RED if int(figures.get("failing", 0)) > 0 else DIM], ["MEMORY", "%d%%" % int(round(mem * 100.0)), _level(mem)]]
		for i in tiles.size():
			var r = Rect2(12 + i * 156, 272, 148, 164)
			_card(r, tiles[i][0])
			_text(r.position + Vector2(8, 118), tiles[i][1], 62, tiles[i][2], 132, HORIZONTAL_ALIGNMENT_CENTER)

	func _nodes() -> void:
		var nodes: Array = figures.get("nodes", [])
		var rows = mini(nodes.size(), 5)
		var h = 352.0 / maxi(rows, 1)
		for i in rows:
			var y = 84 + i * h
			var share = clampf(float(nodes[i]["load"]), 0.0, 1.0)
			draw_rect(Rect2(12, y, 616, h - 8), CARD)
			_text(Vector2(24, y + h * 0.5 + 4), str(nodes[i]["name"]).right(16), 22, TXT)
			draw_rect(Rect2(250, y + h * 0.5 - 16, 280, 26), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(250, y + h * 0.5 - 16, 280 * share, 26), _level(share))
			_text(Vector2(540, y + h * 0.5 + 6), "%d%%" % int(round(share * 100.0)), 26, TXT, 80, HORIZONTAL_ALIGNMENT_RIGHT)

	func _activity() -> void:
		var n = int(streams.get("streams", 0))
		var big = Rect2(12, 84, 220, 352)
		_card(big, "STREAMS")
		_text(big.position + Vector2(0, 250), str(n), 190, TXT, 220, HORIZONTAL_ALIGNMENT_CENTER)
		var kinds = [["DIRECT PLAY", int(streams.get("direct_play", 0)), GREEN], ["DIRECT STREAM", int(streams.get("direct_stream", 0)), BLUE], ["TRANSCODE", int(streams.get("transcode", 0)), AMBER]]
		var kr = Rect2(244, 84, 384, 226)
		draw_rect(kr, CARD)
		for i in kinds.size():
			var y = kr.position.y + 16 + i * 68
			_text(Vector2(kr.position.x + 14, y + 22), kinds[i][0], 20, DIM)
			draw_rect(Rect2(kr.position.x + 14, y + 32, 290, 24), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(kr.position.x + 14, y + 32, 290.0 * kinds[i][1] / float(maxi(n, 1)), 24), kinds[i][2])
			_text(Vector2(kr.position.x + 312, y + 56), str(kinds[i][1]), 36, TXT, 60, HORIZONTAL_ALIGNMENT_RIGHT)
		var br = Rect2(244, 322, 384, 114)
		_card(br, "BANDWIDTH")
		_text(br.position + Vector2(12, 92), "%.1f Mbps" % (float(streams.get("total_kbps", 0)) / 1000.0), 54, TXT)

	func _bandwidth() -> void:
		var bw = [["TOTAL", streams.get("total_kbps", 0)], ["LAN", streams.get("lan_kbps", 0)], ["WAN", streams.get("wan_kbps", 0)]]
		for i in bw.size():
			var r = Rect2(12 + i * 208, 84, 200, 130)
			_card(r, bw[i][0])
			_text(r.position + Vector2(10, 92), "%.1f" % (float(bw[i][1]) / 1000.0), 54, TXT)
			_text(r.position + Vector2(10, 118), "Mbps", 17, DIM)
		var chart = Rect2(12, 226, 616, 210)
		_card(chart, "TOTAL OVER TIME")
		var top = 1.0
		for v in bw_history:
			top = maxf(top, float(v))
		_line(Rect2(chart.position + Vector2(14, 44), Vector2(588, 150)), bw_history, top * 1.15, GREEN)
