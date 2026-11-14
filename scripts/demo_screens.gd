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

const K = preload("res://scripts/kutil.gd")
const Models = preload("res://scripts/models.gd")

const SIZE = Vector2i(640, 448)
const HISTORY = 40

var world = null
var live = null
var providers = null

var _screens = {}      # machine uid -> {kind, vp, panel}
var _cpu_hist = []     # share of CPU requested, one sample per state update
var _t = 0.0

# What a simulated machine's screen shows: "grafana", "streams" or "".
static func kind_of(pod: Dictionary) -> String:
	var conts: Array = pod.get("containers", [])
	if conts.is_empty():
		return ""
	var img = Models.image_name(str(conts[0].get("image", "")))
	if img == "grafana":
		return "grafana"
	if img in ["plex", "pms-docker", "tautulli"]:
		return "streams"
	return ""

# Simulated stream activity at time t (seconds): a few streams that come and go.
# Deterministic, so a test can say what it should be.
static func streams_at(t: float) -> Dictionary:
	var n = 2 + int(round(1.5 + 1.5 * sin(t / 37.0)))          # 2..5 streams
	var transcode = clampi(int(round(n * (0.35 + 0.25 * sin(t / 53.0 + 1.0)))), 0, n)
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

func clear() -> void:
	for uid in _screens.keys():
		_drop(uid)
	_cpu_hist.clear()

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
	var fig = cluster_figures(state)
	_cpu_hist.append(fig["cpu"])
	if _cpu_hist.size() > HISTORY:
		_cpu_hist.pop_front()
	var want = {}
	for p in state.get("pods", []):
		var kind = kind_of(p)
		if kind != "" and world.machines.has(str(p["uid"])):
			want[str(p["uid"])] = kind
	for uid in _screens.keys():
		if not want.has(uid):
			_drop(uid)
	for uid in want:
		if not _screens.has(uid):
			var vp = SubViewport.new()
			vp.size = SIZE
			vp.transparent_bg = false
			vp.gui_disable_input = true
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			add_child(vp)
			var panel = ScreenPanel.new()
			panel.kind = want[uid]
			panel.size = Vector2(SIZE)
			vp.add_child(panel)
			_screens[uid] = {"kind": want[uid], "vp": vp, "panel": panel}
		var s = _screens[uid]
		s["panel"].figures = fig
		s["panel"].history = _cpu_hist
		s["panel"].streams = streams_at(_t)
		s["panel"].queue_redraw()
		if not _taken(uid):
			world.machines[uid].set_screen_texture(s["vp"].get_texture())

func _process(delta: float) -> void:
	_t += delta

# One screen's picture, drawn by hand so it costs a single small viewport.
class ScreenPanel extends Control:
	var kind = ""
	var figures = {}
	var history = []
	var streams = {}

	const BG = Color(0.067, 0.082, 0.102)
	const CARD = Color(0.106, 0.129, 0.157)
	const TXT = Color(0.9, 0.93, 0.96)
	const DIM = Color(0.58, 0.64, 0.7)
	const ORANGE = Color(0.957, 0.647, 0.227)
	const GREEN = Color(0.35, 0.82, 0.5)
	const AMBER = Color(0.95, 0.75, 0.25)
	const RED = Color(0.93, 0.36, 0.3)
	const BLUE = Color(0.36, 0.62, 0.95)

	func _text(pos: Vector2, s: String, size: int, col: Color, width: float = -1.0, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
		draw_string(ThemeDB.fallback_font, pos, s, align, width, size, col)

	func _card(r: Rect2, title: String) -> void:
		draw_rect(r, CARD)
		_text(r.position + Vector2(10, 20), title, 13, DIM)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), BG)
		# the banner: on every panel, always
		draw_rect(Rect2(0, 0, size.x, 30), Color(0.2, 0.14, 0.05))
		_text(Vector2(12, 21), "SIMULATED  ·  demo content, not a real " + ("Grafana" if kind == "grafana" else "media server"), 14, ORANGE)
		if kind == "grafana":
			_grafana()
		else:
			_streams()

	func _grafana() -> void:
		_text(Vector2(12, 56), "Cluster overview", 20, TXT)
		# requested CPU over time
		var chart = Rect2(12, 68, 400, 170)
		_card(chart, "CPU REQUESTED  (share of the cluster)")
		var plot = Rect2(chart.position + Vector2(12, 32), chart.size - Vector2(24, 44))
		for i in 3:
			var y = plot.position.y + plot.size.y * i / 2.0
			draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(1, 1, 1, 0.07), 1.0)
		if history.size() >= 2:
			var pts = PackedVector2Array()
			for i in history.size():
				pts.append(Vector2(plot.position.x + plot.size.x * i / float(maxi(history.size() - 1, 1)), plot.end.y - plot.size.y * clampf(history[i], 0.0, 1.0)))
			draw_polyline(pts, BLUE, 2.5, true)
		_text(Vector2(chart.end.x - 80, chart.position.y + 20), "%d%%" % int(round(float(figures.get("cpu", 0.0)) * 100.0)), 15, TXT, 70, HORIZONTAL_ALIGNMENT_RIGHT)
		# memory gauge
		var g = Rect2(424, 68, 204, 170)
		_card(g, "MEMORY REQUESTED")
		var mem = clampf(float(figures.get("mem", 0.0)), 0.0, 1.0)
		var c = g.position + Vector2(g.size.x / 2.0, 118)
		draw_arc(c, 58, PI, TAU, 40, Color(1, 1, 1, 0.1), 12.0, true)
		draw_arc(c, 58, PI, PI + PI * mem, 40, GREEN if mem < 0.7 else (AMBER if mem < 0.9 else RED), 12.0, true)
		_text(c + Vector2(-50, 6), "%d%%" % int(round(mem * 100.0)), 26, TXT, 100, HORIZONTAL_ALIGNMENT_CENTER)
		# pod state tiles
		var tiles = [["RUNNING", int(figures.get("running", 0)), GREEN], ["PENDING", int(figures.get("pending", 0)), AMBER], ["FAILING", int(figures.get("failing", 0)), RED]]
		for i in tiles.size():
			var r = Rect2(12 + i * 138, 250, 126, 84)
			_card(r, tiles[i][0])
			_text(r.position + Vector2(10, 66), str(tiles[i][1]), 36, tiles[i][2] if tiles[i][1] > 0 or i == 0 else DIM)
		# per-node load
		var nr = Rect2(426, 250, 202, 186)
		_card(nr, "NODE CPU REQUESTED")
		var nodes: Array = figures.get("nodes", [])
		for i in mini(nodes.size(), 6):
			var y = nr.position.y + 36 + i * 24
			var share = clampf(float(nodes[i]["load"]), 0.0, 1.0)
			_text(Vector2(nr.position.x + 10, y + 11), str(nodes[i]["name"]).right(12), 11, DIM)
			draw_rect(Rect2(nr.position.x + 100, y, 92, 12), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(nr.position.x + 100, y, 92 * share, 12), GREEN if share < 0.7 else (AMBER if share < 0.9 else RED))
		_text(Vector2(12, 362), "These are the simulated cluster's own figures,", 13, DIM)
		_text(Vector2(12, 380), "the same ones the HUD shows, drawn as a dashboard.", 13, DIM)
		_text(Vector2(12, 410), "On a real cluster this screen shows your real Grafana.", 13, DIM)

	func _streams() -> void:
		_text(Vector2(12, 56), "Media activity", 20, TXT)
		var n = int(streams.get("streams", 0))
		var big = Rect2(12, 68, 200, 150)
		_card(big, "STREAMS")
		_text(big.position + Vector2(10, 118), str(n), 84, TXT)
		var kinds = [["DIRECT PLAY", int(streams.get("direct_play", 0)), GREEN], ["DIRECT STREAM", int(streams.get("direct_stream", 0)), BLUE], ["TRANSCODE", int(streams.get("transcode", 0)), AMBER]]
		var kr = Rect2(224, 68, 404, 150)
		_card(kr, "HOW THEY ARE SERVED")
		for i in kinds.size():
			var y = kr.position.y + 42 + i * 34
			_text(Vector2(kr.position.x + 10, y + 16), kinds[i][0], 14, DIM)
			draw_rect(Rect2(kr.position.x + 150, y, 200, 20), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(kr.position.x + 150, y, 200.0 * kinds[i][1] / float(maxi(n, 1)), 20), kinds[i][2])
			_text(Vector2(kr.position.x + 360, y + 16), str(kinds[i][1]), 16, TXT)
		var bw = [["TOTAL", streams.get("total_kbps", 0)], ["LAN", streams.get("lan_kbps", 0)], ["WAN", streams.get("wan_kbps", 0)]]
		for i in bw.size():
			var r = Rect2(12 + i * 208, 230, 198, 92)
			_card(r, "BANDWIDTH  " + bw[i][0])
			_text(r.position + Vector2(10, 70), "%.1f Mbps" % (float(bw[i][1]) / 1000.0), 30, TXT)
		_text(Vector2(12, 356), "Invented activity, to show what this screen is for.", 13, DIM)
		_text(Vector2(12, 374), "Totals only: no viewer, address or title, as with a real Tautulli.", 13, DIM)
		_text(Vector2(12, 404), "On a real server: LiveView > Grafana and Tautulli.", 13, DIM)
