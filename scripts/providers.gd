extends Node
# LiveView providers: Grafana and Tautulli.
#
# The companion (agent/providers.go) owns the provider list, the tokens and all
# the talking to the two applications. This node asks it for what the game
# shows and keeps the pinned summary screens:
#   - Grafana: dashboards and panels are opened as real pages through LiveView,
#     in the operator's own browser session (the link carries no credential)
#   - Tautulli: aggregate activity (stream counts and bandwidth, nothing about
#     who is watching what) drawn as a native panel, which can be pinned to a
#     machine's screen
# A token typed into the game goes to the companion once and is not kept here.
# Nothing in this file runs in the browser build: it has no companion.

const K = preload("res://scripts/kutil.gd")
const Models = preload("res://scripts/models.gd")
const Agent = preload("res://scripts/agent.gd")

signal pins_changed()

const REFRESH = 15.0            # seconds between reads for a pinned summary
const STALE_AFTER = 60.0        # older than this, the figures are marked stale

var live = null                 # the LiveView node: its ordered request queue is reused
var world = null
var cluster = null

var pins = {}                   # machine uid -> {provider, name, key, vp, ui, at, data, error, t}

func available() -> bool:
	return live != null and live.available()

# Ask the companion; `done` is called on the main thread with {ok, data, kind, msg}.
func ask(op: String, args: Dictionary, done: Callable, timeout: float = 20.0) -> void:
	if not available():
		done.call({"ok": false, "kind": "unsupported", "msg": "The companion is not running.", "data": {}})
		return
	live._post(op, args, done, timeout)

# ---- candidates: machines that look like one of the two applications

# [{type, name, ns, pod, uid, url}]: found by the image a pod runs, never by a
# port number. `url` is filled only where the address is already known (a Docker
# published port); it is a suggestion for the form, to be confirmed by the operator.
static func candidates(state: Dictionary, source: String) -> Array:
	var res = []
	var rx = RegEx.new()
	rx.compile("(?:0\\.0\\.0\\.0|127\\.0\\.0\\.1|\\[?::\\]?):(\\d+)->(\\d+)/tcp")
	for p in state.get("pods", []):
		var conts: Array = p.get("containers", [])
		if conts.is_empty():
			continue
		var img = Models.image_name(str(conts[0].get("image", "")))
		var type = "grafana" if img == "grafana" else ("tautulli" if img == "tautulli" else "")
		if type == "":
			continue
		var url = ""
		if source == "docker":
			var want = 3000 if type == "grafana" else 8181
			for m in rx.search_all(str(p.get("ip", ""))):
				if m.get_string(2).to_int() == want or url == "":
					url = "http://127.0.0.1:%d" % m.get_string(1).to_int()
		res.append({"type": type, "name": str(p["name"]), "ns": str(p["ns"]), "pod": str(p["name"]), "uid": str(p["uid"]), "url": url})
	return res

# Machines a media summary belongs on: Plex or Tautulli itself.
static func media_machines(state: Dictionary) -> Array:
	var res = []
	for p in state.get("pods", []):
		var conts: Array = p.get("containers", [])
		if conts.is_empty():
			continue
		var img = Models.image_name(str(conts[0].get("image", "")))
		if img in ["plex", "pms-docker", "tautulli", "jellyfin", "emby"]:
			res.append(p)
	return res

# ---- formatting shared by the panel in the HUD and the pinned screen

static func fmt_count(v) -> String:
	return "unavailable" if v == null else str(int(v))

static func fmt_kbps(v) -> String:
	if v == null:
		return "unavailable"
	var k = float(v)
	return "%.1f Mbps" % (k / 1000.0) if k >= 1000.0 else "%d kbps" % int(k)

# seconds since an RFC 3339 UTC timestamp (as the companion stamps its answers)
static func age_of(at: String) -> float:
	if at == "":
		return INF
	return maxf(Time.get_unix_time_from_system() - float(Time.get_unix_time_from_datetime_string(at.trim_suffix("Z"))), 0.0)

static func summary_lines(d: Dictionary) -> Array:
	return [
		["STREAMS", fmt_count(d.get("streams"))],
		["DIRECT PLAY", fmt_count(d.get("direct_play"))],
		["DIRECT STREAM", fmt_count(d.get("direct_stream"))],
		["TRANSCODE", fmt_count(d.get("transcode"))],
		["BANDWIDTH", fmt_kbps(d.get("total_kbps"))],
		["LAN", fmt_kbps(d.get("lan_kbps"))],
		["WAN", fmt_kbps(d.get("wan_kbps"))],
	]

# ---- pins: a Tautulli summary on a machine's screen

func _pin_file() -> String:
	return OS.get_user_data_dir().path_join("provider_pins.json")

# what a pin is saved under: the connection and the workload, not a pod name that changes
func _key_of(p: Dictionary) -> String:
	var ctx = (cluster.backend.label + "/" + cluster.backend.context) if cluster != null and cluster.backend != null else ""
	return "%s|%s/%s" % [ctx, p["ns"], p["wname"] if str(p.get("wname", "")) != "" else p["name"]]

func _saved() -> Dictionary:
	var d = K.read_json(_pin_file())
	return d if typeof(d) == TYPE_DICTIONARY else {}

func _save(d: Dictionary) -> void:
	var f = FileAccess.open(_pin_file(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "  "))

func pin(uid: String, provider: Dictionary) -> bool:
	var m = world.machines.get(uid) if world != null else null
	if m == null or m.screen_rect().is_empty():
		return false
	unpin(uid, false)
	var vp = SubViewport.new()
	vp.size = Vector2i(640, 448)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	vp.gui_disable_input = true
	add_child(vp)
	var bg = ColorRect.new()
	bg.color = Color(0.055, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(bg)
	var ui = VBoxContainer.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.offset_left = 28
	ui.offset_right = -28
	ui.offset_top = 20
	ui.offset_bottom = -16
	ui.add_theme_constant_override("separation", 6)
	vp.add_child(ui)
	var key = _key_of(m.pod)
	pins[uid] = {"provider": str(provider["id"]), "name": str(provider["name"]), "key": key, "vp": vp, "ui": ui, "data": {}, "error": "", "t": 0.0}
	m.set_screen_texture(vp.get_texture())
	var d = _saved()
	d[key] = {"provider": str(provider["id"]), "kind": "tautulli.activity"}
	_save(d)
	_draw(uid)
	_read(uid)
	pins_changed.emit()
	return true

func unpin(uid: String, forget: bool = true) -> void:
	if not pins.has(uid):
		return
	var pn = pins[uid]
	pins.erase(uid)
	if is_instance_valid(pn["vp"]):
		pn["vp"].queue_free()
	var m = world.machines.get(uid) if world != null else null
	if m != null:
		m.set_screen_texture(null)
	if forget:
		var d = _saved()
		d.erase(pn["key"])
		_save(d)
		pins_changed.emit()

# Every screen goes dark when the connection changes: what one cluster's
# provider showed must not stay up in another.
func clear() -> void:
	for uid in pins.keys():
		unpin(uid, false)

# Put saved pins back on the machines of the current connection as they appear.
func restore(state: Dictionary) -> void:
	if state.get("source", "") == "simulation" or not available() or world == null:
		return
	var saved = _saved()
	for uid in pins.keys():
		if not world.machines.has(uid):
			unpin(uid, false)
	if saved.is_empty():
		return
	for p in state.get("pods", []):
		var uid = str(p["uid"])
		var key = _key_of(p)
		if pins.has(uid) or not saved.has(key) or not world.machines.has(uid):
			continue
		var want = str(saved[key].get("provider", ""))
		var gen = cluster._gen if cluster != null else -1
		ask("provider.list", {}, func(r):
			if cluster == null or cluster._gen != gen or cluster.backend == null or cluster.backend.label == "simulation" or not r["ok"] or pins.has(uid):
				return
			for pr in r["data"].get("providers", []):
				if str(pr["id"]) == want and str(pr["type"]) == "tautulli":
					pin(uid, pr))
		return      # one at a time; the next state update picks up the rest

func _read(uid: String) -> void:
	if not pins.has(uid):
		return
	ask("tautulli.activity", {"id": pins[uid]["provider"]}, func(r):
		if not pins.has(uid):
			return
		var pn = pins[uid]
		if r["ok"]:
			pn["data"] = r["data"]
			pn["error"] = ""
		else:
			pn["error"] = "%s: %s" % [Agent.kind_title(str(r["kind"])), str(r["msg"])]
		_draw(uid))

func _process(delta: float) -> void:
	for uid in pins:
		var pn = pins[uid]
		pn["t"] += delta
		if pn["t"] >= REFRESH:
			pn["t"] = 0.0
			_read(uid)

func _text(parent: Control, text: String, size: int, col: Color, wrap: bool = false) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 580
	parent.add_child(l)
	return l

func _draw(uid: String) -> void:
	var pn = pins[uid]
	var ui: VBoxContainer = pn["ui"]
	for c in ui.get_children():
		c.queue_free()
	_text(ui, "MEDIA ACTIVITY", 34, Color(0.957, 0.647, 0.227))
	var d: Dictionary = pn["data"]
	if d.is_empty():
		_text(ui, pn["error"] if pn["error"] != "" else "Reading...", 24, K.health_color("warn") if pn["error"] != "" else Color(0.7, 0.75, 0.8), true)
	else:
		var grid = GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 40)
		grid.add_theme_constant_override("v_separation", 2)
		ui.add_child(grid)
		for row in summary_lines(d):
			_text(grid, row[0], 26, Color(0.62, 0.68, 0.74))
			_text(grid, row[1], 30, Color(0.92, 0.95, 0.98) if row[1] != "unavailable" else Color(0.55, 0.58, 0.62))
	var sp = Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ui.add_child(sp)
	var age = age_of(str(d.get("at", "")))
	var foot = "Source: %s (Tautulli)" % pn["name"]
	if not d.is_empty():
		foot += "   ·   as of %s UTC" % str(d["at"]).get_slice("T", 1).trim_suffix("Z")
	if pn["error"] != "" and not d.is_empty():
		foot += "\nSTALE: %s" % pn["error"]
	elif age > STALE_AFTER and not d.is_empty():
		foot += "\nSTALE: last read %d s ago" % int(age)
	_text(ui, foot, 18, K.health_color("warn") if foot.contains("STALE") else Color(0.55, 0.6, 0.66), true)
