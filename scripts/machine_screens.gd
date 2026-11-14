extends Node
# What a machine's screen is showing, and switching between the four things it
# can show:
#   dashboard  the application's own page (LiveView), a provider summary, or in
#              a simulated world the demo dashboard: whichever is on the screen
#   metrics    what the pod is using (CPU, memory, network, disk) as graphs,
#              then its state: phase, restarts, node, its containers. A figure
#              the source does not report is shown as unavailable, never guessed
#   logs       the tail of its log
#   storage    what is mounted into it
# Metrics, logs and storage are drawn here from the same data the panels use
# (the real cluster's, or the simulation's), never invented. R on a machine
# steps to the next view; clicking its screen opens it large.

const K = preload("res://scripts/kutil.gd")
const Icons = preload("res://scripts/icons.gd")

const MODES = ["dashboard", "metrics", "logs", "storage"]
const TITLES = {"dashboard": "Dashboard", "metrics": "Metrics", "logs": "Logs", "storage": "Storage"}
const SIZE = Vector2i(640, 448)
const MAX_PANELS = 8            # screens showing metrics / logs / storage at once
const LOG_REFRESH = 8.0
const LOG_LINES = 13
const USAGE_REFRESH = 5.0
const USAGE_HISTORY = 30

signal mode_changed(uid)

var world = null
var cluster = null
var live = null
var providers = null
var demo_screens = null

var _mode = {}        # uid -> mode (absent = dashboard)
var _panels = {}      # uid -> {vp, panel, t}
var _logs = {}        # uid -> Array of lines
var _mounts = {}      # uid -> Array of mounts, or a String (why not)
var _usage = {}       # uid -> {cpu, mem, net, disk: histories; last: the latest answer; error; t}

func mode_of(uid: String) -> String:
	return str(_mode.get(uid, "dashboard"))

# true while this machine's screen belongs to metrics / logs / storage
func holds(uid: String) -> bool:
	return _mode.has(uid)

func cycle(uid: String, step: int = 1) -> String:
	var m = MODES[posmod(MODES.find(mode_of(uid)) + step, MODES.size())]
	set_mode(uid, m)
	return m

func set_mode(uid: String, mode: String) -> void:
	if world == null or not world.machines.has(uid):
		return
	if mode == "dashboard":
		_release(uid)
	else:
		if not _panels.has(uid):
			if _panels.size() >= MAX_PANELS:
				_release(_panels.keys()[0])       # the oldest goes back to its dashboard
			var vp = SubViewport.new()
			vp.size = SIZE
			vp.transparent_bg = false
			vp.gui_disable_input = true
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			add_child(vp)
			var panel = InfoPanel.new()
			panel.size = Vector2(SIZE)
			vp.add_child(panel)
			_panels[uid] = {"vp": vp, "panel": panel, "t": LOG_REFRESH}
		_mode[uid] = mode
		world.machines[uid].set_screen_texture(_panels[uid]["vp"].get_texture())
		if mode == "metrics":
			_ask_usage(uid)
		elif mode == "logs":
			_panels[uid]["t"] = LOG_REFRESH        # ask straight away
		elif mode == "storage":
			_ask_mounts(uid)
		_fill(uid)
	mode_changed.emit(uid)

func _release(uid: String) -> void:
	_mode.erase(uid)
	if _panels.has(uid):
		if is_instance_valid(_panels[uid]["vp"]):
			_panels[uid]["vp"].queue_free()
		_panels.erase(uid)
	restore_dashboard(uid)

# Put back whatever the dashboard view of this screen is.
func restore_dashboard(uid: String) -> void:
	var m = world.machines.get(uid) if world != null else null
	if m == null:
		return
	if providers != null and providers.pins.has(uid):
		m.set_screen_texture(providers.pins[uid]["vp"].get_texture())
		return
	if live != null:
		for s in live.sessions.values():
			if str(s.get("mounted", "")) == uid and s.get("tex") != null:
				m.set_screen_texture(s["tex"])
				return
	if demo_screens != null and demo_screens.has(uid):
		m.set_screen_texture(demo_screens.texture_of(uid))
		return
	m.set_screen_texture(null)

# What the dashboard view of this machine is: "live", "provider", "demo" or "".
func dashboard_kind(uid: String) -> String:
	if providers != null and providers.pins.has(uid):
		return "provider"
	if live != null:
		for s in live.sessions.values():
			if str(s.get("mounted", "")) == uid:
				return "live"
	if demo_screens != null and demo_screens.has(uid):
		return "demo"
	return ""

func clear() -> void:
	for uid in _panels.keys():
		if is_instance_valid(_panels[uid]["vp"]):
			_panels[uid]["vp"].queue_free()
	_panels.clear()
	_mode.clear()
	_logs.clear()
	_mounts.clear()
	_usage.clear()

# A second, larger copy of a machine's panel for the window.
func make_panel(uid: String) -> Control:
	var p = InfoPanel.new()
	if _panels.has(uid):
		p.source = _panels[uid]["panel"]
	return p

# Called with every cluster state: keep the panels current, drop the ones whose machine is gone.
func sync(_state: Dictionary) -> void:
	for uid in _panels.keys():
		if world == null or not world.machines.has(uid):
			if is_instance_valid(_panels[uid]["vp"]):
				_panels[uid]["vp"].queue_free()
			_panels.erase(uid)
			_mode.erase(uid)
			_logs.erase(uid)
			_mounts.erase(uid)
			_usage.erase(uid)
		else:
			_fill(uid)

func _process(delta: float) -> void:
	for uid in _panels:
		if _mode.get(uid) == "metrics":
			_panels[uid]["t"] += delta
			if _panels[uid]["t"] >= USAGE_REFRESH:
				_panels[uid]["t"] = 0.0
				_ask_usage(uid)
			continue
		if _mode.get(uid) != "logs":
			continue
		_panels[uid]["t"] += delta
		if _panels[uid]["t"] >= LOG_REFRESH:
			_panels[uid]["t"] = 0.0
			var p = K.find_pod(cluster.state, uid)
			if p != null and not p["containers"].is_empty():
				cluster.act({"op": "logs", "ns": p["ns"], "name": p["name"], "container": p["containers"][0]["name"], "key": "screen:" + uid})

func _ask_usage(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	if p != null:
		cluster.act({"op": "pod_metrics", "ns": p["ns"], "name": p["name"], "key": "metric:" + uid})

# One answer to "what is this pod using" folded into its history. Network and
# disk arrive as running totals, so their rate needs two answers.
static func add_usage(u: Dictionary, r: Dictionary, now: float) -> Dictionary:
	if u.is_empty():
		u = {"cpu": [], "mem": [], "net": [], "disk": [], "last": {}, "error": "", "t": 0.0, "rates": {}}
	if not r.get("ok", false):
		u["error"] = str(r.get("msg", "not available"))
		return u
	var d: Dictionary = r.get("data", {})
	var prev: Dictionary = u["last"]
	var dt = now - float(u["t"])
	u["error"] = ""
	if d.get("cpu_cores") != null:
		u["cpu"].append(float(d["cpu_cores"]))
	if d.get("mem_bytes") != null:
		u["mem"].append(float(d["mem_bytes"]))
	for pair in [["net", "net_rx_bytes", "net_tx_bytes"], ["disk", "disk_read_bytes", "disk_write_bytes"]]:
		if d.get(pair[1]) == null or d.get(pair[2]) == null:
			continue
		if not u["rates"].has(pair[0]):
			u["rates"][pair[0]] = null       # reported, but a rate needs a second reading
		if prev.get(pair[1]) != null and dt > 0.2:
			var a = maxf(float(d[pair[1]]) - float(prev[pair[1]]), 0.0) / dt
			var b = maxf(float(d[pair[2]]) - float(prev[pair[2]]), 0.0) / dt
			u["rates"][pair[0]] = [a, b]
			u[pair[0]].append(a + b)
	for k in ["cpu", "mem", "net", "disk"]:
		while u[k].size() > USAGE_HISTORY:
			u[k].pop_front()
	u["last"] = d
	u["t"] = now
	return u

static func fmt_cpu(c: float) -> String:
	return "%d m" % int(round(c * 1000.0)) if c < 1.0 else "%.2f cores" % c

# The four tiles of the metrics view: [{title, value, values, note}]
static func usage_tiles(u: Dictionary) -> Array:
	var none = "unavailable"
	if u.is_empty():
		var wait = []
		for t in ["CPU", "MEMORY", "NETWORK", "DISK I/O"]:
			wait.append({"title": t, "value": "reading...", "values": [], "note": ""})
		return wait
	var failed = str(u["error"]) != "" and u["last"].is_empty()
	var src = str(u["last"].get("source", ""))
	var gap = "not reported by " + ("the cluster's metrics API" if src == "metrics.k8s.io" else "this source")
	if failed:
		gap = ""
	var tiles = []
	tiles.append({"title": "CPU", "value": fmt_cpu(u["cpu"][-1]) if not u["cpu"].is_empty() else none, "values": u["cpu"], "note": "" if not u["cpu"].is_empty() else gap})
	tiles.append({"title": "MEMORY", "value": K.fmt_bytes(u["mem"][-1]) if not u["mem"].is_empty() else none, "values": u["mem"], "note": "" if not u["mem"].is_empty() else gap})
	for pair in [["net", "NETWORK", "in", "out"], ["disk", "DISK I/O", "read", "write"]]:
		if not u["rates"].has(pair[0]):
			tiles.append({"title": pair[1], "value": none, "values": [], "note": gap})
		elif u["rates"][pair[0]] == null:
			tiles.append({"title": pair[1], "value": "measuring...", "values": [], "note": ""})
		else:
			var rt = u["rates"][pair[0]]
			tiles.append({"title": pair[1], "value": K.fmt_bytes(rt[0] + rt[1]) + "/s", "values": u[pair[0]], "note": "%s %s/s   %s %s/s" % [pair[2], K.fmt_bytes(rt[0]), pair[3], K.fmt_bytes(rt[1])]})
	return tiles

func _ask_mounts(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	if p != null:
		cluster.act({"op": "file_mounts", "ns": p["ns"], "name": p["name"], "key": "screen:" + uid})

# answers from the cluster (wired by main)
func on_logs(key: String, text: String) -> void:
	if not key.begins_with("screen:"):
		return
	var uid = key.trim_prefix("screen:")
	var lines = []
	for ln in text.split("\n"):
		if ln.strip_edges() != "":
			lines.append(ln.strip_edges(false, true))
	_logs[uid] = lines.slice(maxi(lines.size() - LOG_LINES, 0))
	if _panels.has(uid):
		_fill(uid)

func on_data(key: String, r: Dictionary) -> void:
	if key.begins_with("metric:"):
		var muid = key.trim_prefix("metric:")
		_usage[muid] = add_usage(_usage.get(muid, {}), r, Time.get_ticks_msec() / 1000.0)
		if _panels.has(muid):
			_fill(muid)
		return
	if not key.begins_with("screen:"):
		return
	var uid = key.trim_prefix("screen:")
	if r.get("ok", false):
		_mounts[uid] = r.get("data", {}).get("mounts", [])
	else:
		_mounts[uid] = str(r.get("msg", "not available"))
	if _panels.has(uid):
		_fill(uid)

# ---- what each view says: [[text, colour]] rows

static func metrics_rows(p: Dictionary) -> Array:
	var rows = []
	rows.append(["%s   ·   %s   ·   %s" % [str(p["status"]), p["ns"], p["node"] if str(p["node"]) != "" else "not scheduled"], K.health_color(str(p["health"]))])
	if str(p.get("wname", "")) != "":
		rows.append(["owner %s/%s   ·   restarts %d%s" % [p.get("wkind", ""), p["wname"], int(p.get("restarts", 0)), ("   ·   age " + K.fmt_age(p["created"])) if float(p.get("created", 0.0)) > 0.0 else ""],
			K.health_color("warn") if int(p.get("restarts", 0)) > 0 else Color.WHITE])
	else:
		rows.append(["restarts %d" % int(p.get("restarts", 0)), K.health_color("warn") if int(p.get("restarts", 0)) > 0 else Color.WHITE])
	for c in p.get("containers", []):
		var state = str(c["state"]) if str(c.get("reason", "")) == "" else str(c["reason"])
		var good = str(c["state"]) == "running" and bool(c.get("ready", false))
		rows.append(["%s  %s%s" % [str(c["name"]).left(22), state, ("  x%d" % int(c["restarts"])) if int(c.get("restarts", 0)) > 0 else ""],
			K.health_color("ok") if good else K.health_color("warn" if str(c["state"]) != "terminated" else "bad")])
	return rows

static func storage_rows(mounts) -> Array:
	if typeof(mounts) == TYPE_STRING:
		return [[mounts, K.health_color("warn")]]
	if mounts == null:
		return [["Reading...", Color(0.7, 0.75, 0.8)]]
	if mounts.is_empty():
		return [["Nothing is mounted into this workload.", Color(0.7, 0.75, 0.8)]]
	var rows = []
	for m in mounts:
		rows.append([str(m.get("path", "")), Color.WHITE])
		var what = str(m.get("claim", "")) if str(m.get("claim", "")) != "" else str(m.get("type", ""))
		var extra = "   read-only" if bool(m.get("read_only", false)) else ""
		if not bool(m.get("readable", true)):
			extra += "   contents never shown"
		rows.append(["    %s%s" % [what, extra], Color(0.62, 0.68, 0.74)])
	return rows

func rows_of(uid: String) -> Array:
	var p = K.find_pod(cluster.state, uid)
	if p == null:
		return [["This machine is gone.", K.health_color("warn")]]
	match mode_of(uid):
		"metrics":
			return metrics_rows(p)
		"logs":
			if not _logs.has(uid):
				return [["Reading...", Color(0.7, 0.75, 0.8)]]
			if _logs[uid].is_empty():
				return [["(no log lines)", Color(0.7, 0.75, 0.8)]]
			var rows = []
			for ln in _logs[uid]:
				var low = str(ln).to_lower()
				rows.append([str(ln), K.health_color("bad") if (low.contains("error") or low.contains("fatal") or low.contains("panic")) else (K.health_color("warn") if low.contains("warn") else Color(0.82, 0.9, 0.84))])
			return rows
		"storage":
			return storage_rows(_mounts.get(uid))
	return []

func _fill(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	var panel = _panels[uid]["panel"]
	panel.title = TITLES[mode_of(uid)].to_upper()
	panel.name_text = str(p["name"]) if p != null else ""
	panel.icon = Icons.texture(Icons.kind_of(p)) if p != null else null
	panel.rows = rows_of(uid)
	panel.small = mode_of(uid) == "logs"
	panel.tiles = usage_tiles(_usage.get(uid, {})) if mode_of(uid) == "metrics" else []
	panel.tile_error = str(_usage.get(uid, {}).get("error", "")) if mode_of(uid) == "metrics" else ""
	panel.simulated = cluster.backend != null and cluster.backend.label == "simulation"
	panel.queue_redraw()

# One screen of text in large print, on a 640 x 448 sheet scaled to the control.
class InfoPanel extends Control:
	var title = ""
	var name_text = ""
	var icon: Texture2D = null
	var rows = []
	var small = false
	var simulated = false
	var tiles = []          # the metrics view: four usage tiles above the rows
	var tile_error = ""
	var source: Control = null

	func _process(_d: float) -> void:
		if source != null and is_instance_valid(source):
			title = source.title
			name_text = source.name_text
			icon = source.icon
			rows = source.rows
			small = source.small
			simulated = source.simulated
			tiles = source.tiles
			tile_error = source.tile_error
			queue_redraw()

	func _draw() -> void:
		var fit = minf(size.x / 640.0, size.y / 448.0)
		draw_set_transform((size - Vector2(640, 448) * fit) * 0.5, 0.0, Vector2(fit, fit))
		var font = ThemeDB.fallback_font
		draw_rect(Rect2(0, 0, 640, 448), Color(0.067, 0.082, 0.102))
		draw_rect(Rect2(0, 0, 640, 44), Color(0.106, 0.129, 0.157))
		if icon != null:
			draw_texture_rect(icon, Rect2(8, 6, 32, 32), false)
		draw_string(font, Vector2(50, 31), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(0.957, 0.647, 0.227))
		draw_string(font, Vector2(210, 30), name_text, HORIZONTAL_ALIGNMENT_RIGHT, 418, 18, Color(0.75, 0.8, 0.86))
		var px = 17 if small else 24
		var step = 29.0 if small else 36.0
		var y = 44.0 + step
		if not tiles.is_empty():
			var cols = [Color(0.36, 0.62, 0.95), Color(0.35, 0.82, 0.5), Color(0.95, 0.75, 0.25), Color(0.75, 0.55, 0.95)]
			for i in tiles.size():
				var r = Rect2(10 + (i % 2) * 314, 52 + int(i / 2) * 124, 306, 116)
				var tl: Dictionary = tiles[i]
				draw_rect(r, Color(0.106, 0.129, 0.157))
				draw_string(font, r.position + Vector2(10, 22), str(tl["title"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.62, 0.68, 0.74))
				var have = not (str(tl["value"]) in ["unavailable", "reading...", "measuring..."])
				draw_string(font, r.position + Vector2(10, 60), str(tl["value"]), HORIZONTAL_ALIGNMENT_LEFT, 290, 34 if have else 24, Color(0.92, 0.95, 0.98) if have else Color(0.55, 0.58, 0.62))
				var note = str(tl.get("note", ""))
				if note != "":
					draw_string(font, r.position + Vector2(10, 82), note, HORIZONTAL_ALIGNMENT_LEFT, 290, 13, Color(0.62, 0.68, 0.74))
				var vals: Array = tl["values"]
				if vals.size() >= 2:
					var top = 0.0001
					for v in vals:
						top = maxf(top, float(v))
					var pts = PackedVector2Array()
					for k in vals.size():
						pts.append(Vector2(r.position.x + 10 + 286.0 * k / float(vals.size() - 1), r.end.y - 6 - 22.0 * float(vals[k]) / (top * 1.1)))
					draw_polyline(pts, cols[i % 4], 2.5, true)
			if tile_error != "":
				draw_string(font, Vector2(14, 316), tile_error, HORIZONTAL_ALIGNMENT_LEFT, 612, 15, Color(0.95, 0.75, 0.25))
			px = 18
			step = 25.0
			y = 322.0 + step
		for r in rows:
			if y > (424.0 if simulated else 444.0):
				break
			draw_string(font, Vector2(14, y), str(r[0]), HORIZONTAL_ALIGNMENT_LEFT, 612, px, r[1], TextServer.JUSTIFICATION_NONE, TextServer.DIRECTION_AUTO, TextServer.ORIENTATION_HORIZONTAL)
			y += step
		if simulated:
			draw_rect(Rect2(0, 426, 640, 22), Color(0.22, 0.15, 0.05))
			draw_string(font, Vector2(12, 443), "SIMULATED cluster: this is the simulation's own data", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.957, 0.647, 0.227))
