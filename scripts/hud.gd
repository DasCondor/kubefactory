extends CanvasLayer
# Heads-up display plus every menu (pod / node / service panels, cluster
# codex, build menu, pause menu). All built in code, Helmsman-orange on dark.

signal blueprint_chosen(bp)
signal target_requested(target)
signal graphics_requested(id)
signal storage_requested(uid)        # open this machine's service door and its storage panel

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")
const Bob = preload("res://scripts/bob.gd")
const Gauge = preload("res://scripts/gauge.gd")
const DemoSim = preload("res://scripts/backend_demo.gd")
const Gfx = preload("res://scripts/gfx.gd")
const Minimap = preload("res://scripts/minimap.gd")
const Models = preload("res://scripts/models.gd")
const Agent = preload("res://scripts/agent.gd")
const Native = preload("res://scripts/backend_native.gd")
const Connections = preload("res://scripts/connections.gd")
const ORANGE = Color(0.98, 0.584, 0.286)
const BG = Color(0.075, 0.085, 0.095, 0.95)
const BG2 = Color(0.15, 0.16, 0.18, 1.0)
const TXT = Color(0.92, 0.93, 0.94)
const DIM = Color(0.6, 0.63, 0.67)
const RED = Color(0.95, 0.3, 0.25)

# The tool belt. Higher Mk = more destructive = hotter colour and longer hold.
const TOOLS = [
	{"name": "SCANNER", "mk": 1, "hint": "click anything to inspect it"},
	{"name": "DATAPAD", "mk": 1, "hint": "click a machine to read its log ledger"},
	{"name": "BUILD GUN", "mk": 2, "hint": "place replicas and new deployments"},
	{"name": "WRENCH", "mk": 3, "hint": "hold on a machine: rolling restart   ·   hold on a node sign: cordon / uncordon"},
	{"name": "DISMANTLER", "mk": 4, "hint": "hold on a machine: delete that pod"},
	{"name": "DEMOLISHER", "mk": 5, "hint": "hold on a machine: delete its whole workload   ·   hold on a node sign: drain the node"},
]

const RECIPES = [["nginx", "nginx:1.27"], ["httpd", "httpd:2.4"], ["redis", "redis:7.4"],
	["memcached", "memcached:1.6"], ["whoami", "traefik/whoami:v1.10"], ["busybox", "busybox:1.36"]]

var cluster
var world
var player
var sfx = null
var settings = {}
var version = ""

var _root: Control
var _src: Label
var _stats: Label
var _err: Label
var _target: Label
var _bp: Label
var _prog: ColorRect
var _prog_bg: ColorRect
var _slots = []
var _help: Label = null
var touch: CanvasLayer = null     # the touch controls, when the browser demo is on a touch screen
var minimap: Control = null

# N, or the pause menu: show or hide the minimap (kept in settings.json)
func toggle_minimap() -> void:
	settings["minimap"] = not bool(settings.get("minimap", true))
	K.save_settings(settings)
	_minimap_visibility()
	notify("Minimap %s" % ("shown" if settings["minimap"] else "hidden"), "info")

func _minimap_visibility() -> void:
	if minimap != null:
		minimap.enabled = bool(settings.get("minimap", true))
		minimap.visible = minimap.enabled and not (touch != null and touch.active)
var touch_u = 0.0                 # their unit size while they are on; 0 = desktop

var _notes: VBoxContainer
var _mono: SystemFont
var _who: Label
var _mode = 0
var _bp_cur = null
var _lock_tier = 5
var _prob_panel: PanelContainer
var _prob_box: VBoxContainer
var _prob_sig = "-"
var problems = []

var _modal: Control = null
var _modal_kind = ""
var _modal_arg = null
var _dyn: VBoxContainer = null
var _dyn_sig = ""
var _logs: TextEdit = null
var _log_pick: OptionButton = null
var _log_key = ""
var _ls = {"tab": "pods", "ns": "", "pod": "", "container": "", "tail": 200, "previous": false,
	"follow": false, "warnings": true, "ens": "", "filter": "", "provider": "kube"}
var _ls_raw = ""
var _ls_timer = 0.0
var offer_demos = false   # started on the simulation without naming a world: offer the chooser
var _case = {}            # Bob's open case file: pod uid, config, fetched log and events
var _gauge = {"seq": 0, "key": "", "signature": ""}
var _gauge_rows: VBoxContainer
var _gauge_readout: Label
var _gauge_pick: OptionButton
var _gauge_scroll: ScrollContainer
var _gauge_table: VBoxContainer
var _gauge_head: Control
var _gauge_over_limit = false
var _talk = {"screen": "main", "app": "web", "tpl": {}, "search": "", "cat": {}}
var _lists = {}          # list url -> {source, templates, skipped}, or an error string
var _tpl_key = ""
var _tpl_url = ""
var _ls_count: Label = null
var _ls_shown = ""
var _ledger: RichTextLabel = null
var _link_lbl: Label = null
var _link_bars = []

# ---------------------------------------------------------------- helpers

func _sb(bg: Color, border: Color = Color(0, 0, 0, 0), bw: int = 0, pad: int = 10) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(pad)
	return s

func _lbl(text: String, size: int = 15, color: Color = TXT) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _btn(text: String, cb: Callable, kind: String = "normal", enabled: bool = true) -> Button:
	var b = Button.new()
	b.text = text
	b.disabled = not enabled
	b.focus_mode = Control.FOCUS_NONE
	var base = BG2
	var edge = Color(0.32, 0.34, 0.37)
	var fc = TXT
	if kind == "primary":
		base = ORANGE.darkened(0.1)
		edge = ORANGE
		fc = Color(0.08, 0.08, 0.08)
	elif kind == "danger":
		base = Color(0.4, 0.1, 0.09)
		edge = RED
	elif kind.begins_with("mk"):
		# action tiers: the stronger the action, the hotter the colour
		var mk = int(kind.trim_prefix("mk"))
		edge = K.tier_color(mk)
		base = edge.darkened(0.72)
		fc = edge.lightened(0.55)
		if text.strip_edges().length() > 3:
			b.text = "MK.%d  %s" % [mk, text]
	b.add_theme_stylebox_override("normal", _sb(base, edge, 1, 7))
	b.add_theme_stylebox_override("hover", _sb(base.lightened(0.15), ORANGE, 1, 7))
	b.add_theme_stylebox_override("pressed", _sb(base.darkened(0.2), ORANGE, 1, 7))
	b.add_theme_stylebox_override("disabled", _sb(Color(0.12, 0.12, 0.13), Color(0.2, 0.2, 0.2), 1, 7))
	b.add_theme_color_override("font_color", fc)
	b.add_theme_color_override("font_hover_color", fc)
	b.add_theme_color_override("font_pressed_color", fc)
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(cb)
	return b

func _tier_legend() -> HBoxContainer:
	var r = _row(14)
	r.add_child(_lbl("ACTION TIERS", 11, DIM))
	for mk in range(1, 6):
		r.add_child(_lbl("MK.%d %s" % [mk, K.TIERS[mk]], 11, K.tier_color(mk)))
	return r

func _row(sep: int = 8) -> HBoxContainer:
	var h = HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h

func _col(sep: int = 8) -> VBoxContainer:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v

func _spacer() -> Control:
	var c = Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _fixed(l: Control, w: float) -> Control:
	l.custom_minimum_size.x = w
	if l is Label:
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l

func _clear(c: Node) -> void:
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()

func _ignore_mouse(c: Node) -> void:
	if c is Control:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in c.get_children():
		_ignore_mouse(ch)

# ---------------------------------------------------------------- HUD

func _ready() -> void:
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(["Consolas", "Cascadia Mono", "Courier New", "monospace"])
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var status = PanelContainer.new()
	var ssb = _sb(BG, ORANGE, 0, 12)
	ssb.border_width_left = 4
	status.add_theme_stylebox_override("panel", ssb)
	status.position = Vector2(16, 16)
	var sv = _col(2)
	sv.add_child(_lbl("KUBEFACTORY", 20, ORANGE))
	_src = _lbl("connecting...", 14, TXT)
	_stats = _lbl("", 14, DIM)
	_who = _lbl("", 13, Color(0.6, 0.92, 1.0))
	_err = _lbl("", 13, RED)
	_err.visible = false
	sv.add_child(_src)
	sv.add_child(_stats)
	sv.add_child(_who)
	sv.add_child(_err)
	status.add_child(sv)
	_root.add_child(status)

	_prob_panel = PanelContainer.new()
	var psb = _sb(BG, RED, 0, 12)
	psb.border_width_left = 4
	_prob_panel.add_theme_stylebox_override("panel", psb)
	_prob_panel.position = Vector2(16, 146)
	_prob_box = _col(2)
	_prob_panel.add_child(_prob_box)
	_prob_panel.visible = false
	_root.add_child(_prob_panel)

	for r in [Rect2(-2, -2, 4, 4), Rect2(-14, -1, 8, 2), Rect2(6, -1, 8, 2), Rect2(-1, -14, 2, 8), Rect2(-1, 6, 2, 8)]:
		var c = ColorRect.new()
		c.color = Color(1, 1, 1, 0.85)
		c.set_anchors_preset(Control.PRESET_CENTER)
		c.offset_left = r.position.x
		c.offset_top = r.position.y
		c.offset_right = r.position.x + r.size.x
		c.offset_bottom = r.position.y + r.size.y
		_root.add_child(c)

	_target = _lbl("", 17)
	_target.anchor_left = 0.0
	_target.anchor_right = 1.0
	_target.anchor_top = 0.5
	_target.anchor_bottom = 0.5
	_target.offset_top = 200
	_target.offset_bottom = 330
	_target.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target.add_theme_constant_override("outline_size", 6)
	_target.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_root.add_child(_target)

	_prog_bg = ColorRect.new()
	_prog_bg.color = Color(0, 0, 0, 0.6)
	_prog_bg.set_anchors_preset(Control.PRESET_CENTER)
	_prog_bg.offset_left = -90
	_prog_bg.offset_right = 90
	_prog_bg.offset_top = 22
	_prog_bg.offset_bottom = 32
	_prog = ColorRect.new()
	_prog.color = RED
	_prog.position = Vector2(2, 2)
	_prog.size = Vector2(0, 6)
	_prog_bg.add_child(_prog)
	_prog_bg.visible = false
	_root.add_child(_prog_bg)

	var bar = _row(10)
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -92
	bar.offset_bottom = -34
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in TOOLS.size():
		var tool = TOOLS[i]
		var tc = K.tier_color(tool["mk"])
		var pc = PanelContainer.new()
		pc.custom_minimum_size = Vector2(158, 54)
		var v = _col(0)
		var h = _row(8)
		h.alignment = BoxContainer.ALIGNMENT_CENTER
		h.add_child(_lbl(str(i + 1), 17, tc))
		h.add_child(_lbl(tool["name"], 15))
		v.add_child(h)
		var tier = _lbl("MK.%d  ·  %s" % [tool["mk"], K.TIERS[tool["mk"]]], 10, tc)
		tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(tier)
		pc.add_child(v)
		bar.add_child(pc)
		_slots.append(pc)
	_root.add_child(bar)

	_bp = _lbl("", 14, ORANGE)
	_bp.anchor_left = 0.0
	_bp.anchor_right = 1.0
	_bp.anchor_top = 1.0
	_bp.anchor_bottom = 1.0
	_bp.offset_top = -122
	_bp.offset_bottom = -98
	_bp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bp.add_theme_constant_override("outline_size", 5)
	_bp.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_root.add_child(_bp)

	var help = _lbl("WASD move · Shift sprint · Space jump (double-tap: hoverpack, Ctrl descend) · 1-6 / wheel tools · E inspect · Q build menu · MMB copy machine · Tab codex · L datapad · G next problem · K Krew · H Foreman · N map · B belts · F storage · V screen · R next view · M sound · Esc menu", 12, Color(1, 1, 1, 0.7))
	help.anchor_left = 0.0
	help.anchor_right = 1.0
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_top = -26
	help.offset_bottom = -6
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_help = help
	help.add_theme_constant_override("outline_size", 4)
	help.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_root.add_child(help)

	_notes = _col(6)
	_notes.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_notes.offset_left = -436
	_notes.offset_right = -16
	_notes.offset_top = 16
	_root.add_child(_notes)

	minimap = Minimap.new()
	minimap.world = world
	minimap.player = player
	minimap.hud = self
	minimap.anchor_top = 1.0
	minimap.anchor_bottom = 1.0
	minimap.offset_left = 16
	minimap.offset_top = -258
	minimap.offset_right = 16 + Minimap.SIZE
	minimap.offset_bottom = -48
	_root.add_child(minimap)

	_ignore_mouse(_root)
	set_mode(0, null)

func set_mode(mode: int, bp) -> void:
	_mode = mode
	_bp_cur = bp
	_lock_tier = cluster.max_tier() if cluster != null else 5
	for i in _slots.size():
		var on = i == mode
		var tc = K.tier_color(TOOLS[i]["mk"])
		var locked = TOOLS[i]["mk"] > _lock_tier
		_slots[i].add_theme_stylebox_override("panel", _sb(BG if not on else tc.darkened(0.8), tc if on else Color(0.3, 0.3, 0.32), 3 if on else 1, 5))
		_slots[i].modulate = Color(1, 1, 1, 0.35) if locked else Color.WHITE
	var tool = TOOLS[mode]
	var txt = "%s  ·  MK.%d %s  ·  %s" % [tool["name"], tool["mk"], K.TIERS[tool["mk"]], tool["hint"]]
	if tool["mk"] > _lock_tier:
		txt = "%s  ·  LOCKED: your limit on this cluster is MK.%d %s" % [tool["name"], _lock_tier, K.TIERS[_lock_tier]]
	if mode == 2:
		txt = "BUILD GUN  ·  BLUEPRINT:  " + bp_text(bp) if bp != null else "BUILD GUN  ·  NO BLUEPRINT  -  press Q for the build menu, or middle-click a machine to copy it"
	_bp.text = txt
	_bp.add_theme_color_override("font_color", K.tier_color(tool["mk"]))
	_prog.color = K.tier_color(tool["mk"])

func bp_text(bp) -> String:
	if bp == null:
		return ""
	if bp["type"] == "replica":
		return "+1 replica of %s / %s" % [bp["ns"], bp["name"]]
	return "new deployment %s / %s  (%s x%d)" % [bp["ns"], bp["name"], bp["image"], bp["replicas"]]

# "who am I here" line: identity, tool limit, visibility scope, who else is online
func refresh_who() -> void:
	var st = cluster.state
	var txt = "YOU  %s  ·  tools up to MK.%d" % [cluster.display_name(), cluster.max_tier()]
	if str(st.get("scoped_ns", "")) != "":
		txt += "  ·  namespace %s only" % st["scoped_ns"]
	if st.get("multiuser", false):
		if cluster.peers.is_empty():
			txt += "\nONLINE  just you"
		else:
			var names = []
			for p in cluster.peers:
				names.append("%s (%s)" % [p["user"], TOOLS[clampi(p["tool"], 0, TOOLS.size() - 1)]["name"].capitalize()])
			txt += "\nONLINE  %d other%s:  %s" % [names.size(), "" if names.size() == 1 else "s", ",  ".join(PackedStringArray(names))]
	_who.text = txt

# Touch controls on or off: the keyboard ribbon and the key-number hotbar make way.
func set_touch(on: bool, unit: float) -> void:
	touch_u = unit if on else 0.0
	if _help != null:
		_help.visible = not on
	for s in _slots:
		s.get_parent().visible = not on
	if _target != null:
		_target.add_theme_font_size_override("font_size", int(clampf(unit * 0.26, 17, 60)) if on else 17)
		_target.offset_top = unit * 0.6 if on else 200
		_target.offset_bottom = unit * 1.9 if on else 330

# ----- tables: click a column to sort by it, type to keep the rows that contain something
#
# One strip above a table: a CONTAINS box and the column headings as buttons.
# First click sorts A-Z (or low to high), second click reverses, third goes
# back to the order the rows came in. What you choose is remembered per table.

var _tables = {}     # table key -> {col, desc, filter}

func _table_state(key: String) -> Dictionary:
	if not _tables.has(key):
		_tables[key] = {"col": "", "desc": false, "filter": ""}
	return _tables[key]

# cols: [[id, title, width]]   refill: called when the sort or the filter changes
func _table_head(key: String, cols: Array, refill: Callable, count: int = 0, font_size: int = 12) -> Control:
	var st = _table_state(key)
	var v = _col(4)
	var fr = _row(8)
	fr.add_child(_lbl("CONTAINS", font_size, DIM))
	var e = LineEdit.new()
	e.text = st["filter"]
	e.placeholder_text = "show only rows containing..."
	if font_size != 12:
		e.add_theme_font_size_override("font_size", font_size)
	e.custom_minimum_size.x = 300
	e.clear_button_enabled = true
	fr.add_child(e)
	if count >= K.TABLE_LIMIT:
		e.editable = false
		fr.add_child(_lbl("%d rows: too many to sort or filter here" % count, 12, K.health_color("warn")))
	v.add_child(fr)
	var hd = _row(10)
	var buttons = []
	var relabel = func():
		for i in cols.size():
			buttons[i].text = str(cols[i][1]) + (("  ▼" if st["desc"] else "  ▲") if st["col"] == cols[i][0] else "")
			buttons[i].add_theme_color_override("font_color", ORANGE if st["col"] == cols[i][0] else DIM)
	for c in cols:
		var b = Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", font_size)
		b.tooltip_text = "Sort by this column"
		b.disabled = count >= K.TABLE_LIMIT
		b.pressed.connect(func():
			if st["col"] != c[0]:
				st["col"] = c[0]
				st["desc"] = false
			elif not st["desc"]:
				st["desc"] = true
			else:
				st["col"] = ""
				st["desc"] = false
			relabel.call()
			refill.call())
		buttons.append(b)
		hd.add_child(_fixed(b, c[2]))
	relabel.call()
	e.text_changed.connect(func(t):
		st["filter"] = t
		refill.call())
	v.add_child(hd)
	return v

func _table_rows(key: String, rows: Array, getters: Dictionary) -> Array:
	var st = _table_state(key)
	return K.table_rows(rows, st["col"], st["desc"], st["filter"], getters)

func set_target(text: String) -> void:
	_target.text = text

func set_progress(f: float) -> void:
	_prog_bg.visible = f > 0.0
	_prog.size.x = 176.0 * clampf(f, 0.0, 1.0)

func notify(msg: String, kind: String = "info") -> void:
	if msg.strip_edges() == "":
		return
	msg = K.tidy_text(msg)       # a path in a note never shows the account's folder
	var col = {"ok": K.health_color("ok"), "warn": K.health_color("warn"), "bad": RED}.get(kind, ORANGE)
	var pc = PanelContainer.new()
	var s = _sb(BG, col, 0, 9)
	s.border_width_left = 4
	pc.add_theme_stylebox_override("panel", s)
	var l = _lbl(msg, 13)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 390
	pc.add_child(l)
	_ignore_mouse(pc)
	_notes.add_child(pc)
	while _notes.get_child_count() > 8:
		var old = _notes.get_child(0)
		_notes.remove_child(old)
		old.queue_free()
	var tw = pc.create_tween()
	tw.tween_interval(5.5)
	tw.tween_property(pc, "modulate:a", 0.0, 0.8)
	tw.tween_callback(pc.queue_free)

func on_state(st: Dictionary) -> void:
	var src = str(st["source"]).to_upper()
	if str(st.get("provider", "")) != "":
		src = str(st["provider"]).to_upper() + ("" if st["source"] != "simulation" else "  (SIMULATED)")
	_src.text = "%s  ·  %s%s" % [src, st["context"], "    [READ-ONLY]" if cluster.read_only else ""]
	var ready = 0
	for n in st["nodes"]:
		if n["ready"]:
			ready += 1
	var c = {"ok": 0, "warn": 0, "bad": 0, "done": 0}
	for p in st["pods"]:
		c[p["health"]] += 1
	_stats.text = "NODES %d/%d   PODS %d running · %d pending · %d failing   WORKLOADS %d" % [
		ready, st["nodes"].size(), c["ok"], c["warn"], c["bad"], st["workloads"].size()]
	_err.text = str(st["error"])
	_err.visible = st["error"] != ""
	refresh_who()
	if cluster.max_tier() != _lock_tier:
		set_mode(_mode, _bp_cur)
	# Problems list: failing pods, unschedulable pods and unhealthy nodes
	problems = []
	var lines = []
	for n in st["nodes"]:
		if not n["ready"]:
			lines.append(["node " + n["name"], "NotReady", RED])
	for p in st["pods"]:
		if p["health"] == "bad":
			problems.append(p["uid"])
			lines.append([p["name"], p["status"], RED])
		elif p["node"] == "":
			problems.append(p["uid"])
			lines.append([p["name"], "Unschedulable", K.health_color("warn")])
	var sig = JSON.stringify(lines)
	if sig != _prob_sig:
		_prob_sig = sig
		_clear(_prob_box)
		_prob_panel.visible = lines.size() > 0
		_prob_box.add_child(_lbl("PROBLEMS  (%d)        [G] jump to next" % lines.size(), 14, RED))
		for l in lines.slice(0, 7):
			var r = _row(10)
			r.add_child(_fixed(_lbl("■ " + l[0], 13), 300))
			r.add_child(_fixed(_lbl(l[1], 13, l[2]), 150))
			_prob_box.add_child(r)
		if lines.size() > 7:
			_prob_box.add_child(_lbl("+ %d more" % (lines.size() - 7), 12, DIM))
		_ignore_mouse(_prob_panel)
	_refresh_modal()

# ---------------------------------------------------------------- modals

func modal_open() -> bool:
	return _modal != null

# On a touch screen a dialog is scaled to use the screen it has, so its buttons are as large as they can be.
func _fit_modal(center: Control, panel: Control) -> void:
	if not is_instance_valid(panel) or not is_instance_valid(center):
		return
	var vp = get_viewport().get_visible_rect().size
	var s = minf(vp.x * 0.98 / maxf(panel.size.x, 1.0), vp.y * 0.97 / maxf(panel.size.y, 1.0))
	center.pivot_offset = center.size * 0.5
	center.scale = Vector2(s, s)

func close_modal(recapture: bool = true) -> void:
	if _modal != null:
		_modal.queue_free()
		_modal = null
	_modal_kind = ""
	_dyn = null
	_dyn_sig = ""
	_logs = null
	_log_pick = null
	if recapture:
		player.enabled = true
		if not (touch != null and touch.active):       # touch never locks the pointer
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _open_modal(kind: String, arg, title: String, size: Vector2, pad: bool = false) -> VBoxContainer:
	var was_pad = _modal_kind == "logs"
	close_modal(false)
	_modal_kind = kind
	_modal_arg = arg
	_modal = Control.new()
	_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(dim)
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(center)
	var panel = PanelContainer.new()
	panel.custom_minimum_size = size
	var psb = _sb(BG, ORANGE, 0, 18)
	psb.border_width_top = 4
	if pad:
		# a handheld datapad: chunky rubberised bezel around a dark screen
		psb = _sb(Color(0.035, 0.05, 0.055, 0.985), Color(0.2, 0.21, 0.23), 14, 20)
		psb.set_corner_radius_all(30)
		psb.border_width_bottom = 30
		psb.shadow_color = Color(0, 0, 0, 0.6)
		psb.shadow_size = 24
		if not was_pad:
			# slide up into view like something pulled off your belt
			_modal.position.y = 700
			_modal.modulate.a = 0.0
			var tw = _modal.create_tween().set_parallel(true)
			tw.tween_property(_modal, "position:y", 0.0, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(_modal, "modulate:a", 1.0, 0.18)
	panel.add_theme_stylebox_override("panel", psb)
	center.add_child(panel)
	var vb = _col(10)
	panel.add_child(vb)
	var head = _row()
	head.add_child(_lbl(title, 22, ORANGE))
	head.add_child(_spacer())
	var xb = _btn("  X  ", close_modal)
	if touch_u > 0.0:
		xb.custom_minimum_size = Vector2(touch_u * 1.1, touch_u * 0.9)
		xb.add_theme_font_size_override("font_size", int(touch_u * 0.3))
	head.add_child(xb)
	vb.add_child(head)
	var body = _col(10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(body)
	add_child(_modal)
	if touch_u > 0.0 and kind != "screen":
		_fit_modal.call_deferred(center, panel)
	if sfx != null and not (pad and was_pad):
		sfx.play("pad" if pad else "click", -12.0)
	player.enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return body

func _refresh_modal() -> void:
	match _modal_kind:
		"pod":
			_fill_pod()
		"codex":
			_fill_codex()
		"node":
			_fill_node()
		"service":
			_fill_service()
		"bob":
			_fill_bob()
		"gauge":
			_fill_gauge()
		"krew":
			_fill_krew(false)

func _kv(grid: GridContainer, k: String, v: String, color: Color = TXT) -> void:
	grid.add_child(_fixed(_lbl(k, 13, DIM), 110))
	grid.add_child(_fixed(_lbl(v, 15, color), 290))

# must_type: for the most destructive actions the player has to type the
# target's name before the Confirm button unlocks.
func _confirm(text: String, cb: Callable, must_type: String = "") -> void:
	var body = _open_modal("confirm", null, "CONFIRM" if must_type == "" else "CONFIRM  //  MK.5 CRITICAL", Vector2(600, 220))
	var l = _lbl(text, 16)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 560
	body.add_child(l)
	body.add_child(_lbl("Target: %s (%s)   ·   You: %s" % [cluster.state["context"], cluster.state["source"], cluster.display_name()], 13, DIM))
	var ok = _btn("Confirm", func():
		close_modal()
		cb.call(), "mk5" if must_type != "" else "danger", must_type == "")
	if must_type != "":
		body.add_child(_lbl("Type  %s  to confirm:" % must_type, 14, K.tier_color(5)))
		var e = LineEdit.new()
		e.placeholder_text = must_type
		e.text_changed.connect(func(v): ok.disabled = v.strip_edges() != must_type)
		body.add_child(e)
		e.grab_focus.call_deferred()
	var r = _row()
	r.add_child(_spacer())
	r.add_child(_btn("Cancel", close_modal))
	r.add_child(ok)
	body.add_child(r)

# Run an action, asking for a typed confirmation first if its tier calls for it.
func guarded_act(a: Dictionary, what: String, target_name: String) -> void:
	if K.tier_of(a, cluster.state) >= cluster.confirm_tier():
		_confirm(what, func(): cluster.act(a), target_name)
	else:
		cluster.act(a)

# ----- pod

func open_pod(uid: String) -> void:
	var body = _open_modal("pod", uid, "MACHINE  //  POD", Vector2(900, 680))
	_dyn = _col(8)
	body.add_child(_dyn)
	var lh = _row()
	lh.add_child(_lbl("LOGS / EVENTS", 15, ORANGE))
	_log_pick = OptionButton.new()
	_log_pick.focus_mode = Control.FOCUS_NONE
	var p = K.find_pod(cluster.state, uid)
	if p != null:
		for c in p["containers"]:
			_log_pick.add_item(c["name"])
	_log_pick.add_item("(events)")
	if p != null and p["health"] != "ok" and p["health"] != "done":
		_log_pick.select(_log_pick.item_count - 1)
	_log_pick.item_selected.connect(func(_i): _request_logs())
	lh.add_child(_log_pick)
	lh.add_child(_btn("Refresh", _request_logs))
	lh.add_child(_spacer())
	lh.add_child(_btn("Storage", func(): storage_requested.emit(uid)))
	lh.add_child(_btn("Open in logging station", func(): open_logs(uid)))
	body.add_child(lh)
	_logs = TextEdit.new()
	_logs.editable = false
	_logs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_logs.custom_minimum_size = Vector2(0, 250)
	_logs.add_theme_font_override("font", _mono)
	_logs.add_theme_font_size_override("font_size", 13)
	_logs.add_theme_stylebox_override("normal", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
	_logs.add_theme_stylebox_override("read_only", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
	_logs.add_theme_color_override("font_readonly_color", Color(0.78, 0.86, 0.8))
	body.add_child(_logs)
	_fill_pod()
	_request_logs()

func _request_logs() -> void:
	var p = K.find_pod(cluster.state, _modal_arg)
	if p == null or _logs == null:
		return
	var cname = _log_pick.get_item_text(_log_pick.selected)
	_log_key = p["uid"] + "/" + cname
	_logs.text = "fetching..."
	if cname == "(events)":
		cluster.act({"op": "events", "ns": p["ns"], "name": p["name"], "key": _log_key})
	else:
		cluster.act({"op": "logs", "ns": p["ns"], "name": p["name"], "container": cname, "key": _log_key})

func on_logs(key: String, text: String) -> void:
	if key.begins_with("bob:"):
		_on_case(key, text)
		return
	if key == _tpl_key and key != "":
		_tpl_key = ""
		var d = JSON.parse_string(text)
		if typeof(d) == TYPE_DICTIONARY and d.has("templates"):
			_lists[_tpl_url] = d
		else:
			_lists[_tpl_url] = text if text != "" else "No answer."
		if _modal_kind == "talk" and _talk["screen"] == "catalogue":
			open_talk("catalogue")
		return
	if _modal_kind == "logs":
		if key == _log_key:
			_ls_raw = text
			_ls_apply()
			_set_link("ok" if cluster.last_link.get("ok", false) else "down", int(cluster.last_link.get("ms", 0)))
		return
	if _logs != null and key == _log_key:
		_logs.text = text
		_logs.scroll_vertical = _logs.get_line_count()

func _fill_pod() -> void:
	var st = cluster.state
	var p = K.find_pod(st, _modal_arg)
	var sig = JSON.stringify(p) + str(cluster.read_only)
	var w = null
	if p != null:
		w = K.find_workload(st, p["ns"], p["wkind"], p["wname"])
		sig += JSON.stringify(w)
	if sig == _dyn_sig:
		return
	_dyn_sig = sig
	_clear(_dyn)
	if p == null:
		_dyn.add_child(_lbl("This machine has been dismantled - the pod no longer exists.", 16, K.health_color("warn")))
		return
	_dyn.add_child(_lbl(p["name"], 19))
	var g = GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 4)
	_kv(g, "STATUS", p["status"], K.health_color(p["health"]))
	_kv(g, "NAMESPACE", p["ns"])
	_kv(g, "NODE", p["node"] if p["node"] != "" else "(unscheduled)")
	_kv(g, "POD IP", p["ip"] if p["ip"] != "" else "-")
	_kv(g, "RESTARTS", str(p["restarts"]), RED if p["restarts"] > 0 else TXT)
	_kv(g, "AGE", K.fmt_age(p["created"]))
	_kv(g, "WORKLOAD", "%s / %s" % [p["wkind"], p["wname"]] if p["wname"] != "" else "bare pod")
	_kv(g, "REPLICAS", "%d ready of %d" % [w["ready"], w["replicas"]] if w != null else "-")
	_dyn.add_child(g)
	_dyn.add_child(_lbl("CONTAINERS", 13, DIM))
	for c in p["containers"]:
		var r = _row(12)
		var cc = K.health_color("ok" if c["state"] == "running" and c["ready"] else ("warn" if c["state"] != "terminated" else "bad"))
		r.add_child(_fixed(_lbl("■ " + c["name"], 14, cc), 190))
		r.add_child(_fixed(_lbl(c["image"], 14), 440))
		r.add_child(_fixed(_lbl(c["state"] + ("  (" + c["reason"] + ")" if c["reason"] != "" else ""), 14, DIM), 220))
		_dyn.add_child(r)
	var b = _row()
	if w != null and w["kind"] != "DaemonSet" and cluster.cap("scale"):
		b.add_child(_lbl("SCALE", 13, DIM))
		b.add_child(_btn("  -  ", func(): _scale(w, -1), "mk3", w["replicas"] > 0))
		b.add_child(_lbl(str(w["replicas"]), 17, ORANGE))
		b.add_child(_btn("  +  ", func(): _scale(w, 1), "mk2"))
	if cluster.backend != null and cluster.backend.label == "docker":
		b.add_child(_btn("Restart container", func(): cluster.act({"op": "restart", "ns": p["ns"], "kind": p["wkind"], "name": p["wname"], "pod": p["name"]}), "mk3"))
	elif w != null and cluster.cap("restart"):
		b.add_child(_btn("Rolling restart", func(): cluster.act({"op": "restart", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}), "mk3"))
	b.add_child(_spacer())
	if w != null and cluster.cap("delete_workload"):
		b.add_child(_btn("Delete workload", func(): _ask_delete_workload(w), "mk5"))
	b.add_child(_btn("Dismantle pod", func(): cluster.act({"op": "delete_pod", "ns": p["ns"], "name": p["name"]}), "mk4"))
	_dyn.add_child(b)
	_dyn.add_child(_tier_legend())

func _scale(w: Dictionary, d: int) -> void:
	cluster.act({"op": "scale_by", "ns": w["ns"], "kind": w["kind"], "name": w["name"], "delta": d})

func _ask_delete_workload(w: Dictionary) -> void:
	_confirm("Delete %s %s / %s and all %d of its pods?" % [w["kind"], w["ns"], w["name"], w["replicas"]],
		func(): cluster.act({"op": "delete_workload", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}), w["name"])

# ----- node

func open_node(nm: String) -> void:
	var body = _open_modal("node", nm, "NODE TERMINAL", Vector2(640, 380))
	_dyn = _col(10)
	body.add_child(_dyn)
	_fill_node()

func _fill_node() -> void:
	var n = null
	for x in cluster.state["nodes"]:
		if x["name"] == _modal_arg:
			n = x
	var count = 0
	for p in cluster.state["pods"]:
		if p["node"] == _modal_arg:
			count += 1
	var sig = JSON.stringify(n) + str(count)
	if sig == _dyn_sig:
		return
	_dyn_sig = sig
	_clear(_dyn)
	if n == null:
		_dyn.add_child(_lbl("Pods parked here have not been scheduled onto any node yet\n(no node has room, or every node is cordoned).", 15))
		return
	_dyn.add_child(_lbl(n["name"], 19))
	var g = GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	var status = "Ready" if n["ready"] else "NotReady"
	if n["cordoned"]:
		status += ", SchedulingDisabled"
	_kv(g, "STATUS", status, K.health_color("bad" if not n["ready"] else ("warn" if n["cordoned"] else "ok")))
	_kv(g, "ROLES", n["roles"])
	_kv(g, "VERSION", n["version"])
	_kv(g, "PODS", str(count))
	_kv(g, "CPU REQUESTS", "%.2f of %.1f cores" % [n["cpu_req"], n["cpu"]])
	_kv(g, "MEM REQUESTS", "%s of %s" % [K.fmt_mem(n["mem_req"]), K.fmt_mem(n["mem"])])
	_dyn.add_child(g)
	var b = _row()
	if cluster.cap("cordon"):
		if n["cordoned"]:
			b.add_child(_btn("Uncordon (allow scheduling)", func(): cluster.act({"op": "cordon", "node": n["name"], "on": false}), "mk2"))
		else:
			b.add_child(_btn("Cordon (stop scheduling)", func(): cluster.act({"op": "cordon", "node": n["name"], "on": true}), "mk3"))
	if cluster.cap("drain"):
		b.add_child(_btn("Drain node", func(): _confirm("Drain %s? It will be cordoned and every pod on it (except DaemonSet pods) evicted." % n["name"],
			func(): cluster.act({"op": "drain", "node": n["name"]}), n["name"]), "mk5"))
	_dyn.add_child(b)
	_dyn.add_child(_tier_legend())

# ----- service

func open_service(ns: String, sname: String) -> void:
	var body = _open_modal("service", [ns, sname], "SERVICE DEPOT", Vector2(640, 420))
	_dyn = _col(8)
	body.add_child(_dyn)
	_fill_service()

func _fill_service() -> void:
	var s = null
	for x in cluster.state["services"]:
		if x["ns"] == _modal_arg[0] and x["name"] == _modal_arg[1]:
			s = x
	var backs = []
	if s != null:
		for p in cluster.state["pods"]:
			if p["ns"] == s["ns"] and K.selects(s["selector"], p["labels"]):
				backs.append(p)
	var sig = JSON.stringify(s) + JSON.stringify(backs)
	if sig == _dyn_sig:
		return
	_dyn_sig = sig
	_clear(_dyn)
	if s == null:
		_dyn.add_child(_lbl("This service no longer exists.", 16))
		return
	_dyn.add_child(_lbl("%s / %s" % [s["ns"], s["name"]], 19))
	var g = GridContainer.new()
	g.columns = 2
	_kv(g, "TYPE", s["type"])
	_kv(g, "CLUSTER IP", s["cluster_ip"])
	_kv(g, "PORTS", s["ports"])
	var sel = []
	for k in s["selector"]:
		sel.append("%s=%s" % [k, s["selector"][k]])
	_kv(g, "SELECTOR", ", ".join(PackedStringArray(sel)) if sel.size() > 0 else "(none)")
	_dyn.add_child(g)
	_dyn.add_child(_lbl("BELTS TO %d POD(S)" % backs.size(), 13, DIM))
	for p in backs.slice(0, 8):
		var r = _row(12)
		r.add_child(_fixed(_lbl("■ " + p["name"], 14, K.health_color(p["health"])), 380))
		r.add_child(_fixed(_lbl(p["status"], 14, DIM), 180))
		_dyn.add_child(r)
	if backs.size() > 8:
		_dyn.add_child(_lbl("... and %d more" % (backs.size() - 8), 13, DIM))

# ----- codex (cluster overview at the HUB)

func open_codex() -> void:
	var body = _open_modal("codex", null, "CLUSTER CODEX", Vector2(1220, 700))
	var top = _row(10)
	top.add_child(_lbl("NAMESPACE", 13, DIM))
	var pick = OptionButton.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.add_item("All namespaces")
	var nss = _namespaces()
	for i in nss.size():
		pick.add_item(nss[i])
		if nss[i] == world.ns_filter:
			pick.select(i + 1)
	pick.item_selected.connect(func(i):
		world.ns_filter = "" if i == 0 else pick.get_item_text(i)
		world.apply_state(cluster.state)
		_fill_codex())
	top.add_child(pick)
	top.add_child(_spacer())
	top.add_child(_lbl("The namespace filter also hides other namespaces' machines in the world.", 13, DIM))
	body.add_child(top)
	body.add_child(_table_head("codex", [["kind", "KIND", 100], ["ns", "NAMESPACE", 130], ["name", "WORKLOAD", 210], ["ready", "READY", 70], ["image", "IMAGE", 270]],
		func(): _fill_codex(), cluster.state["workloads"].size()))
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size.y = 520
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dyn = _col(4)
	_dyn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_dyn)
	body.add_child(sc)
	_fill_codex()

func _namespaces() -> Array:
	var seen = {}
	for p in cluster.state["pods"]:
		seen[p["ns"]] = true
	for w in cluster.state["workloads"]:
		seen[w["ns"]] = true
	var a = seen.keys()
	a.sort()
	return a

func _fill_codex() -> void:
	var rows = []
	for w in cluster.state["workloads"]:
		if world.ns_filter == "" or w["ns"] == world.ns_filter:
			rows.append(w)
	rows.sort_custom(func(a, b): return a["ns"] + "/" + a["name"] < b["ns"] + "/" + b["name"])
	var total = rows.size()
	rows = _table_rows("codex", rows, {"kind": func(w): return w["kind"], "ns": func(w): return w["ns"], "name": func(w): return w["name"],
		"ready": func(w): return float(w["ready"]) / maxf(float(w["replicas"]), 1.0), "image": func(w): return w["image"]})
	var sig = JSON.stringify(rows) + str(cluster.read_only)
	if sig == _dyn_sig:
		return
	_dyn_sig = sig
	_clear(_dyn)
	if rows.is_empty():
		_dyn.add_child(_lbl("No workloads here yet. Press Q in the world to build one." if total == 0 else "No workload contains that.", 15, DIM))
	for w in rows:
		var pc = PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _sb(BG2, Color(0, 0, 0, 0), 0, 6))
		var r = _row(10)
		var ok = w["ready"] >= w["replicas"]
		r.add_child(_fixed(_lbl(w["kind"], 13, DIM), 100))
		r.add_child(_fixed(_lbl(w["ns"], 14), 130))
		r.add_child(_fixed(_lbl(w["name"], 15, K.hue_color(w["ns"] + "/" + w["name"], 0.45, 1.0)), 210))
		r.add_child(_fixed(_lbl("%d/%d" % [w["ready"], w["replicas"]], 15, K.health_color("ok" if ok else "warn")), 70))
		r.add_child(_fixed(_lbl(w["image"], 13, DIM), 270))
		r.add_child(_spacer())
		var can_scale = w["kind"] != "DaemonSet" and cluster.cap("scale")
		r.add_child(_btn(" - ", func(): _scale(w, -1), "mk3", can_scale and w["replicas"] > 0))
		r.add_child(_btn(" + ", func(): _scale(w, 1), "mk2", can_scale))
		r.add_child(_btn("Restart", func(): cluster.act({"op": "restart", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}), "mk3", cluster.cap("restart")))
		r.add_child(_btn("Go to", func(): _goto(w)))
		r.add_child(_btn("Delete", func(): _ask_delete_workload(w), "mk5", cluster.cap("delete_workload")))
		pc.add_child(r)
		_dyn.add_child(pc)

func _goto(w: Dictionary) -> void:
	var spot = world.workload_spot(w["ns"], w["kind"], w["name"])
	if spot == null:
		notify("%s has no machines to visit" % w["name"], "warn")
		return
	close_modal()
	player.teleport(spot[0], spot[1])

# ----- build menu

func open_build() -> void:
	var body = _open_modal("build", null, "BUILD MENU", Vector2(860, 520))
	body.add_child(_lbl("REPLICATE AN EXISTING WORKLOAD", 14, ORANGE))
	var r1 = _row(10)
	var pick = OptionButton.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.custom_minimum_size.x = 520
	var options = []
	for w in cluster.state["workloads"]:
		if w["kind"] != "DaemonSet":
			options.append(w)
			pick.add_item("%s / %s   (%s, %d replicas)" % [w["ns"], w["name"], w["kind"], w["replicas"]])
	r1.add_child(pick)
	r1.add_child(_btn("Use as blueprint", func():
		if options.size() > 0:
			var w = options[pick.selected]
			_choose({"type": "replica", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}), "primary", options.size() > 0 and cluster.cap("scale")))
	body.add_child(r1)
	body.add_child(_lbl("Every click on a foundation adds one replica. Tip: middle-click any machine in the world to copy it.", 13, DIM))
	body.add_child(HSeparator.new())
	body.add_child(_lbl("NEW DEPLOYMENT", 14, ORANGE))
	var name_edit = LineEdit.new()
	var image_edit = LineEdit.new()
	var rec = _row(6)
	rec.add_child(_lbl("RECIPES", 13, DIM))
	for rc in RECIPES:
		rec.add_child(_btn(rc[0], func():
			name_edit.text = rc[0]
			image_edit.text = rc[1]))
	body.add_child(rec)
	var g = GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 8)
	name_edit.custom_minimum_size.x = 420
	name_edit.placeholder_text = "lowercase-name"
	image_edit.placeholder_text = "registry/image:tag"
	g.add_child(_lbl("NAME", 13, DIM))
	g.add_child(name_edit)
	g.add_child(_lbl("IMAGE", 13, DIM))
	g.add_child(image_edit)
	g.add_child(_lbl("NAMESPACE", 13, DIM))
	var ns_pick = OptionButton.new()
	var nss = _namespaces()
	if not nss.has("default"):
		nss.insert(0, "default")
	for i in nss.size():
		ns_pick.add_item(nss[i])
		if nss[i] == (world.ns_filter if world.ns_filter != "" else "default"):
			ns_pick.select(i)
	g.add_child(ns_pick)
	g.add_child(_lbl("REPLICAS", 13, DIM))
	var reps = SpinBox.new()
	reps.min_value = 1
	reps.max_value = 20
	reps.value = 1
	g.add_child(reps)
	body.add_child(g)
	var r2 = _row()
	var warn = _lbl("", 13, RED)
	r2.add_child(warn)
	r2.add_child(_spacer())
	r2.add_child(_btn("Use as blueprint", func():
		var nm = name_edit.text.strip_edges()
		var img = image_edit.text.strip_edges()
		if not K.valid_name(nm):
			warn.text = "Name must be lowercase letters, digits and dashes."
			return
		if img == "" or img.contains(" "):
			warn.text = "Enter a container image."
			return
		_choose({"type": "new", "ns": ns_pick.get_item_text(ns_pick.selected), "name": nm, "image": img, "replicas": int(reps.value)}), "primary", cluster.cap("create")))
	body.add_child(r2)
	body.add_child(_lbl("Then aim at any foundation and click to place it. The cluster's scheduler picks the node that actually runs each pod.", 13, DIM))

func _choose(bp: Dictionary) -> void:
	close_modal()
	blueprint_chosen.emit(bp)

# ----- cluster switcher

func open_clusters() -> void:
	var body = _open_modal("clusters", null, "CLUSTERS", Vector2(980, 600))
	var top = _row(10)
	top.add_child(_lbl("Built-in simulations and discovered local connections.", 13, DIM))
	top.add_child(_spacer())
	if not OS.has_feature("web") and cluster.edition != "demo":
		top.add_child(_btn("Searching..." if cluster.finding_targets else "Discover local connections", func():
			cluster.discover_targets()
			open_clusters(), "", not cluster.finding_targets and not cluster.detecting and cluster.backend != null))
	top.add_child(_btn("Add or manage kubeconfigs...", func(): open_connect(), "primary"))
	body.add_child(top)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size.y = 460
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	var cl_get = {"provider": func(t): return t["provider"], "source": func(t): return t["source"], "context": func(t): return t["context"], "profile": func(t): return str(t.get("profile_name", ""))}
	var cl_fill = func():
		_clear(list)
		if cluster.targets.is_empty():
			list.add_child(_lbl("Still looking for clusters...", 15, DIM))
		for t in _table_rows("clusters", cluster.targets, cl_get):
			list.add_child(_cluster_row(t))
	body.add_child(_table_head("clusters", [["provider", "PROVIDER", 220], ["source", "SOURCE", 100], ["context", "CONTEXT", 300], ["profile", "KUBECONFIG", 140]], cl_fill, cluster.targets.size()))
	body.move_child(body.get_child(body.get_child_count() - 1), sc.get_index())
	cl_fill.call()

func _cluster_row(t: Dictionary) -> Control:
	if true:
		var active = cluster.backend != null and t["source"] == cluster.backend.label and t["context"] == cluster.backend.context
		var pc = PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _sb(BG2, ORANGE if active else Color(0, 0, 0, 0), 1 if active else 0, 6))
		var r = _row(10)
		r.add_child(_fixed(_lbl("■ " + t["provider"], 15, K.provider_color(t["provider"]).lightened(0.3)), 220))
		r.add_child(_fixed(_lbl(t["source"], 13, DIM), 100))
		r.add_child(_fixed(_lbl(t["context"], 15), 300))
		r.add_child(_fixed(_lbl(str(t.get("profile_name", "")), 12, DIM), 140))
		r.add_child(_spacer())
		if active:
			r.add_child(_lbl("ACTIVE   ", 14, K.health_color("ok")))
		else:
			r.add_child(_btn("Connect", func():
				close_modal()
				target_requested.emit(t), "primary"))
		pc.add_child(r)
		return pc
	return null

# ----- storage: what is behind a machine's service door.
# A read-only look at the pod's (or container's) mounted volumes: what is mounted
# where, directory listings, and bounded previews. Nothing is ever written, no
# file is opened until it is picked, and secret volumes are listed but not read.

signal storage_modules(uid, mounts)

var _store = {}

func open_storage(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	if p == null:
		notify("That machine is gone already", "warn")
		return
	var body = _open_modal("storage", uid, "STORAGE  //  " + str(p["name"]), Vector2(1000, 700))
	# dock the panel to the right so the open door and its bays stay in view
	_modal.get_child(0).color.a = 0.12
	_modal.get_child(1).anchor_left = 0.36
	var sim = cluster.backend != null and cluster.backend.label == "simulation"
	var note = _lbl("Read-only. Files are listed and previewed in pages of 64 KiB; nothing is copied, changed or sent anywhere." +
		("   SIMULATED: this listing is invented by the demo." if sim else ""), 12, K.health_color("warn") if sim else DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 950
	body.add_child(note)
	_dyn = _col(8)
	_dyn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_dyn)
	_store = {"uid": uid, "ns": p["ns"], "pod": p["name"], "mounts": null, "mount": {}, "path": "", "list": null, "file": null, "error": "", "busy": true}
	cluster.act({"op": "file_mounts", "ns": p["ns"], "name": p["name"], "key": "store:%s:mounts" % uid})
	_fill_storage()

func _store_req(op: String, extra: Dictionary, tag: String) -> void:
	var a = {"op": op, "ns": _store["ns"], "name": _store["pod"], "container": str(_store["mount"].get("container", "")),
		"root": str(_store["mount"].get("path", "")), "key": "store:%s:%s" % [_store["uid"], tag]}
	a.merge(extra)
	_store["busy"] = true
	_store["error"] = ""
	cluster.act(a)
	_fill_storage()

func _store_dir(mount: Dictionary, path: String) -> void:
	_store["mount"] = mount
	_store["path"] = path
	_store["file"] = null
	_store["list"] = null
	_store_req("file_list", {"path": path}, "list")

func _store_file(path: String, page: int) -> void:
	_store["file"] = {"path": path, "page": page, "data": null}
	_store_req("file_read", {"path": path, "page": page}, "read")

# Answers to the storage requests (and, further down, LiveView's).
func on_data(key: String, r: Dictionary) -> void:
	if key.begins_with("gauge:"):
		if _modal_kind == "gauge" and key == _gauge["key"]:
			_gauge_readout.text = str(_gauge["target"]) + "\n" + Gauge.reading(r)
		return
	if key.begins_with("live:"):
		_on_live_data(key, r)
		return
	if not key.begins_with("store:") or _modal_kind != "storage" or key.get_slice(":", 1) != str(_store.get("uid", "")):
		return
	_store["busy"] = false
	var d = r.get("data", {})
	var err = "" if r.get("ok", false) else "%s: %s" % [Agent.kind_title(str(r.get("kind", "other"))), str(r.get("msg", "failed"))]
	match key.get_slice(":", 2):
		"mounts":
			_store["mounts"] = d.get("mounts", []) if r.get("ok", false) else []
			_store["error"] = err
			storage_modules.emit(_store["uid"], _store["mounts"])
			for m in _store["mounts"]:
				if m.get("running", true):
					_store_dir(m, "")
					return
		"list":
			_store["list"] = d if r.get("ok", false) else null
			_store["error"] = err
		"read":
			if r.get("ok", false) and _store["file"] != null:
				_store["file"]["data"] = d
			else:
				_store["file"] = null
			_store["error"] = err
	_fill_storage()

# ----- LiveView: real applications on screens (scripts/liveview.gd)

var live: Node = null          # the LiveView manager, set by main
var _lv = {}                   # the session shown in the viewer
var _lv_pending = {}           # an endpoint waiting for its port-forward
var _lv_rect: TextureRect = null
var _lv_move_t = 0

func open_liveview() -> void:
	var body = _open_modal("livelist", null, "LIVEVIEW", Vector2(1000, 640))
	var intro = _lbl("Open a running application's own web page on a screen. It is the real page, drawn by this computer's browser engine in a private, throw-away profile, and it takes your mouse and keyboard.", 13, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 950
	body.add_child(intro)
	if live == null or not live.available():
		var l = _lbl("LiveView is not available here. " + Agent.why_unavailable(), 15, K.health_color("warn"))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 950
		body.add_child(l)
		return
	var src = cluster.backend.label if cluster.backend != null else ""
	var mr = _row(8)
	mr.add_child(_lbl("ADDRESS", 12, DIM))
	var url = LineEdit.new()
	url.placeholder_text = "http://127.0.0.1:3000/"
	url.custom_minimum_size.x = 520
	mr.add_child(url)
	var go = func():
		var u = url.text.strip_edges()
		if not (u.begins_with("http://") or u.begins_with("https://")):
			u = "http://" + u
		open_live(live.open(u, u.get_slice("//", 1).get_slice("/", 0)))
	url.text_submitted.connect(func(_t): go.call())
	mr.add_child(_btn("Open", go, "primary"))
	mr.add_child(_spacer())
	mr.add_child(_btn("Grafana and Tautulli...", func(): open_providers()))
	body.add_child(mr)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	if not live.sessions.is_empty():
		list.add_child(_lbl("LIVE NOW  (%d of %d)" % [live.sessions.size(), live.MAX_SESSIONS], 13, ORANGE))
		for s in live.sessions.values():
			var r = _row(10)
			r.add_child(_fixed(_lbl(str(s["title"]), 14), 300))
			var ul = _lbl(str(s["url"]), 12, DIM)
			ul.clip_text = true
			ul.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.add_child(ul)
			r.add_child(_btn("View", func(): open_live(s), "primary"))
			r.add_child(_btn("Close", func():
				live.close(s)
				open_liveview()))
			list.add_child(r)
	list.add_child(_lbl("DISCOVERED ENDPOINTS", 13, ORANGE))
	if src == "simulation":
		var l = _lbl("This is a simulated cluster. Its services have no real application behind them, so LiveView has no page to open here. The Grafana and media machines in this world show demo content on their screens instead, each marked SIMULATED. Connect Docker or a Kubernetes cluster, or type an address above, for the real thing.", 14, K.health_color("warn"))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 930
		list.add_child(l)
		if demo_screens != null:
			list.add_child(_lbl("DEMO SCREENS IN THIS WORLD", 13, ORANGE))
			for ds in demo_screens.screens():
				var r = _row(10)
				r.add_child(_fixed(_lbl(str(ds["name"]), 14), 420))
				r.add_child(_lbl("simulated dashboard" if ds["kind"] == "grafana" else "simulated stream activity", 12, DIM))
				r.add_child(_spacer())
				r.add_child(_btn("View", func(): open_screen(str(ds["uid"])), "primary"))
				list.add_child(r)
		return
	var eps = live.endpoints(cluster.state, src)
	if eps.is_empty():
		list.add_child(_lbl("Nothing that looks like a web endpoint was found (Docker published ports, Kubernetes Services).", 14, DIM))
	if src == "kubernetes" and not cluster.backend.get("native"):
		list.add_child(_lbl("Kubernetes Services need a port-forward, which the kubectl mode does not do here. Use the native connection (Esc > Clusters).", 13, K.health_color("warn")))
	for e in eps:
		var r = _row(10)
		r.add_child(_fixed(_lbl(str(e["title"]), 14), 420))
		r.add_child(_lbl("published port" if e["kind"] == "url" else "Service, opened through a loopback port-forward", 12, DIM))
		r.add_child(_spacer())
		r.add_child(_btn("Open", func(): _live_open_endpoint(e), "primary", e["kind"] == "url" or bool(cluster.backend.get("native"))))
		list.add_child(r)

func _live_open_endpoint(e: Dictionary) -> void:
	if e["kind"] == "url":
		var s = live.open(str(e["url"]), str(e["title"]))
		s["target"] = e
		open_live(s)
		return
	_lv_pending = e
	var body = _open_modal("liveforward", null, "LIVEVIEW", Vector2(640, 200))
	body.add_child(_lbl(str(e["title"]), 16))
	body.add_child(_lbl("Opening a port-forward on this computer only (127.0.0.1)...", 13, DIM))
	cluster.act({"op": "forward", "ns": e["ns"], "service": e["service"], "port": int(e["port"]), "key": "live:forward"})

func _on_live_data(_key: String, r: Dictionary) -> void:
	if _modal_kind != "liveforward" or _lv_pending.is_empty():
		return
	var e = _lv_pending
	_lv_pending = {}
	if not r.get("ok", false):
		var s = {"key": "", "sid": "", "url": "", "title": str(e["title"]), "state": "failed", "kind": str(r.get("kind", "other")), "msg": str(r.get("msg", "failed")),
			"tex": null, "w": 1280, "h": 720, "status": 0, "mounted": "", "blocked": ""}
		open_live(s)
		return
	var s = live.open("%s://%s/" % [e.get("scheme", "http"), r["address"]], str(e["title"]))
	s["target"] = e
	open_live(s)

# The viewer: one display, full size, taking your input.
func open_live(s: Dictionary) -> void:
	_lv = s
	var body = _open_modal("liveview", null, "LIVEVIEW  //  " + str(s["title"]), Vector2(1500, 850))
	_dyn = _col(6)
	_dyn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_dyn)
	_fill_live()

func on_live_changed(s: Dictionary) -> void:
	if _modal_kind == "liveview" and s == _lv:
		if s["state"] == "live" and _lv_rect != null and is_instance_valid(_lv_rect) and s["tex"] != null and _lv_rect.texture == s["tex"]:
			return     # only the picture changed, and the texture updates itself
		_fill_live()
	elif _modal_kind == "livelist":
		open_liveview()

func _fill_live() -> void:
	_clear(_dyn)
	_lv_rect = null
	var s = _lv
	var bar = _row(8)
	_dyn.add_child(bar)
	if s["state"] == "live":
		bar.add_child(_btn("  <  ", func(): live.navigate(s, "back")))
		bar.add_child(_btn("Reload", func(): live.navigate(s, "reload")))
	var ul = _lbl(str(s["url"]), 13, DIM)
	ul.clip_text = true
	ul.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(ul)
	if int(s.get("status", 0)) in [401, 403]:
		bar.add_child(_lbl("the application asks you to sign in (%d)" % s["status"], 13, K.health_color("warn")))
	if str(s.get("blocked", "")) != "":
		bar.add_child(_lbl("blocked a jump to %s" % s["blocked"], 13, K.health_color("warn")))
	# mount it on the machine this endpoint belongs to, where there is one
	var t = s.get("target", {})
	var uid = ""
	if not t.is_empty():
		for p in cluster.state["pods"]:
			if p["ns"] == t["ns"] and (p["name"] == t["service"] or p["wname"] == t["service"]):
				uid = p["uid"]
				break
	if s["state"] == "live" and uid != "":
		if str(s["mounted"]) == uid:
			bar.add_child(_btn("Take it off the machine", func():
				s["mounted"] = ""
				live.changed.emit(s)
				_fill_live()))
		else:
			bar.add_child(_btn("Show it on the machine's screen", func():
				s["mounted"] = uid
				live.changed.emit(s)
				_fill_live(), "primary"))
	if str(s["url"]) != "":
		bar.add_child(_btn("Open in your browser", func(): OS.shell_open(str(s["url"]))))
	if s["state"] in ["live", "opening"]:
		bar.add_child(_btn("Close display", func():
			live.close(s)
			close_modal(), "danger"))
	match s["state"]:
		"opening":
			_dyn.add_child(_lbl("Opening the page...", 16, DIM))
		"failed", "closed":
			var what = {"unreachable": "NOTHING ANSWERED", "tls": "CERTIFICATE NOT ACCEPTED", "timeout": "NO ANSWER IN TIME", "unsupported": "UNAVAILABLE",
				"rbac": "NOT ALLOWED", "invalid": "NOT A WEB ADDRESS"}.get(str(s["kind"]), "COULD NOT OPEN") if s["state"] == "failed" else "DISPLAY CLOSED"
			_dyn.add_child(_lbl(what, 20, RED))
			var l = _lbl(str(s["msg"]), 15)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 1400
			_dyn.add_child(l)
			_dyn.add_child(_lbl("Nothing is shown in its place: a LiveView screen only ever shows the real application.", 13, DIM))
		"live":
			if cluster.read_only:
				_dyn.add_child(_lbl("Read-only mode is on: you can watch this page, but your clicks and keys are not sent to it.", 13, K.health_color("warn")))
			var tr = TextureRect.new()
			tr.texture = s["tex"]
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
			tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tr.focus_mode = Control.FOCUS_ALL
			tr.mouse_filter = Control.MOUSE_FILTER_STOP
			tr.gui_input.connect(_live_input)
			_dyn.add_child(tr)
			_lv_rect = tr
			tr.grab_focus.call_deferred()
			if s["tex"] == null:
				_dyn.add_child(_lbl("Waiting for the first frame...", 13, DIM))

# Where a point on the viewer lands on the page, in page pixels (or null if outside it).
func _live_page_pos(local: Vector2) -> Variant:
	var s = _lv
	var box = _lv_rect.size
	var scale = minf(box.x / float(s["w"]), box.y / float(s["h"]))
	var shown = Vector2(s["w"], s["h"]) * scale
	var p = (local - (box - shown) / 2.0) / scale
	if p.x < 0 or p.y < 0 or p.x > s["w"] or p.y > s["h"]:
		return null
	return p

const LIVE_KEYS = {KEY_ENTER: ["Enter", "Enter", 13], KEY_KP_ENTER: ["Enter", "NumpadEnter", 13], KEY_BACKSPACE: ["Backspace", "Backspace", 8], KEY_TAB: ["Tab", "Tab", 9],
	KEY_DELETE: ["Delete", "Delete", 46], KEY_LEFT: ["ArrowLeft", "ArrowLeft", 37], KEY_UP: ["ArrowUp", "ArrowUp", 38], KEY_RIGHT: ["ArrowRight", "ArrowRight", 39],
	KEY_DOWN: ["ArrowDown", "ArrowDown", 40], KEY_HOME: ["Home", "Home", 36], KEY_END: ["End", "End", 35], KEY_PAGEUP: ["PageUp", "PageUp", 33], KEY_PAGEDOWN: ["PageDown", "PageDown", 34]}

func _live_input(ev: InputEvent) -> void:
	if _lv.get("state") != "live" or _lv_rect == null or cluster.read_only:
		return
	if ev is InputEventMouseMotion:
		var now = Time.get_ticks_msec()
		if now - _lv_move_t < 33:
			return
		_lv_move_t = now
		var p = _live_page_pos(ev.position)
		if p != null:
			live.input(_lv, "move", {"x": p.x, "y": p.y})
	elif ev is InputEventMouseButton:
		var p = _live_page_pos(ev.position)
		if p == null:
			return
		_lv_rect.grab_focus()
		match ev.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if ev.pressed:
					live.input(_lv, "wheel", {"x": p.x, "y": p.y, "dy": -100.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 100.0})
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				var b = {MOUSE_BUTTON_LEFT: "left", MOUSE_BUTTON_RIGHT: "right", MOUSE_BUTTON_MIDDLE: "middle"}[ev.button_index]
				live.input(_lv, "down" if ev.pressed else "up", {"x": p.x, "y": p.y, "button": b})
		_lv_rect.accept_event()
	elif ev is InputEventKey:
		if ev.keycode == KEY_ESCAPE:
			return     # Esc always belongs to the game: it closes the viewer
		var mods = {"shift": ev.shift_pressed, "ctrl": ev.ctrl_pressed, "alt": ev.alt_pressed}
		if LIVE_KEYS.has(ev.keycode):
			var k = LIVE_KEYS[ev.keycode]
			var a = {"key": k[0], "code": k[1], "vk": k[2], "down": ev.pressed}
			a.merge(mods)
			live.input(_lv, "key", a)
		elif ev.pressed and ev.unicode >= 32 and not ev.ctrl_pressed:
			live.input(_lv, "text", {"text": char(ev.unicode)})
		elif ev.ctrl_pressed and ev.keycode >= KEY_A and ev.keycode <= KEY_Z:
			var ch = char(ev.keycode).to_lower()
			var a = {"key": ch, "code": "Key" + ch.to_upper(), "vk": ev.keycode, "down": ev.pressed}
			a.merge(mods)
			live.input(_lv, "key", a)
		_lv_rect.accept_event()

static func _hexdump(bytes: PackedByteArray, base: int) -> String:
	var lines = PackedStringArray()
	for off in range(0, mini(bytes.size(), 4096), 16):
		var hx = ""
		var asc = ""
		for i in 16:
			if off + i < bytes.size():
				var b = bytes[off + i]
				hx += "%02x " % b
				asc += char(b) if b >= 32 and b < 127 else "."
			else:
				hx += "   "
		lines.append("%08x  %s %s" % [base + off, hx, asc])
	if bytes.size() > 4096:
		lines.append("... (%d more bytes on this page not shown as hex)" % (bytes.size() - 4096))
	return "\n".join(lines)

func _fill_storage() -> void:
	if _dyn == null or _modal_kind != "storage":
		return
	_clear(_dyn)
	var h = _row(14)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dyn.add_child(h)
	# left: the mounts, with the PV / PVC behind each
	var left = _col(6)
	left.custom_minimum_size.x = 330
	h.add_child(left)
	left.add_child(_lbl("MOUNTED VOLUMES", 13, ORANGE))
	if _store["mounts"] == null:
		left.add_child(_lbl("Reading the pod's volumes...", 13, DIM))
	elif _store["mounts"].is_empty():
		left.add_child(_lbl("Nothing is mounted into this workload." if _store["error"] == "" else _store["error"], 13, DIM if _store["error"] == "" else RED))
	else:
		for m in _store["mounts"]:
			var sel = m.get("path") == _store["mount"].get("path") and m.get("container") == _store["mount"].get("container")
			var pc = PanelContainer.new()
			pc.add_theme_stylebox_override("panel", _sb(BG2, ORANGE if sel else Color(0, 0, 0, 0), 1 if sel else 0, 8))
			var v = _col(2)
			pc.add_child(v)
			var pl = _lbl(str(m["path"]), 14)
			pl.clip_text = true
			pl.custom_minimum_size.x = 300
			v.add_child(pl)
			var kind = {"pvc": "PersistentVolumeClaim", "configmap": "ConfigMap", "secret": "Secret", "projected": "service-account token", "emptydir": "emptyDir (scratch)",
				"hostpath": "host path", "bind": "bind mount", "volume": "Docker volume", "csi": "CSI volume", "nfs": "NFS"}.get(str(m.get("type", "")), str(m.get("type", "")))
			var line = kind + ("  ·  read-only" if m.get("read_only", false) else "")
			v.add_child(_lbl(line, 12, DIM))
			if str(m.get("claim", "")) != "":
				var cl = _lbl("%s%s" % [m["claim"], ("  ->  PV " + str(m["pv"])) if str(m.get("pv", "")) != "" else ""], 12, K.tier_color(1))
				cl.clip_text = true
				cl.custom_minimum_size.x = 300
				v.add_child(cl)
			if str(m.get("capacity", "")) != "":
				v.add_child(_lbl("%s  ·  %s  ·  %s" % [m["capacity"], m.get("storage_class", ""), m.get("phase", "")], 12, DIM))
			if not m.get("readable", true):
				v.add_child(_lbl("contents are never shown", 12, RED))
			if not m.get("running", true):
				v.add_child(_lbl("container not running", 12, K.health_color("warn")))
			elif not sel:
				v.add_child(_btn("Browse", func(): _store_dir(m, "")))
			left.add_child(pc)
	# right: the directory, or the file being previewed
	var right = _col(6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(right)
	if _store["mount"].is_empty():
		right.add_child(_lbl("Pick a volume to look inside." if _store["mounts"] != null else "", 14, DIM))
		return
	var crumbs = _row(4)
	var root = str(_store["mount"]["path"])
	crumbs.add_child(_btn(root, func(): _store_dir(_store["mount"], "")))
	var acc = ""
	for seg in str(_store["path"]).split("/", false):
		acc = (acc + "/" + seg).trim_prefix("/")
		var here = acc
		crumbs.add_child(_lbl("/", 14, DIM))
		crumbs.add_child(_btn(seg, func(): _store_dir(_store["mount"], here)))
	right.add_child(crumbs)
	if _store["error"] != "":
		var el = _lbl(_store["error"], 14, RED)
		el.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		el.custom_minimum_size.x = 580
		right.add_child(el)
	if _store["busy"]:
		right.add_child(_lbl("Reading...", 13, DIM))
	var f = _store["file"]
	if f != null and f.get("data") != null:
		var d = f["data"]
		var bytes = Marshalls.base64_to_raw(str(d.get("data", "")))
		var binary = false
		var odd = 0
		for i in mini(bytes.size(), 2048):
			var b = bytes[i]
			if b == 0:
				binary = true
			if b < 9 or (b > 13 and b < 32):
				odd += 1
		binary = binary or odd > 40
		var head = _row(10)
		head.add_child(_lbl(str(f["path"]).get_file(), 15))
		head.add_child(_lbl("%s  ·  page %d of %d  ·  %s" % [K.fmt_bytes(float(d.get("size", 0))), int(d.get("page", 0)) + 1, maxi(int(d.get("pages", 1)), 1), "binary, shown as hex" if binary else "text"], 12, DIM))
		head.add_child(_spacer())
		head.add_child(_btn("  <  ", func(): _store_file(f["path"], int(d["page"]) - 1), "normal", int(d.get("page", 0)) > 0))
		head.add_child(_btn("  >  ", func(): _store_file(f["path"], int(d["page"]) + 1), "normal", int(d.get("page", 0)) + 1 < int(d.get("pages", 1))))
		head.add_child(_btn("Back to the folder", func(): _store_dir(_store["mount"], _store["path"])))
		right.add_child(head)
		var te = TextEdit.new()      # plain text only: nothing in a file is ever rendered or run
		te.editable = false
		te.size_flags_vertical = Control.SIZE_EXPAND_FILL
		te.add_theme_font_override("font", _mono)
		te.add_theme_font_size_override("font_size", 12)
		te.add_theme_stylebox_override("read_only", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
		te.add_theme_color_override("font_readonly_color", Color(0.78, 0.86, 0.8))
		te.text = _hexdump(bytes, int(d.get("page", 0)) * 65536) if binary else bytes.get_string_from_utf8()
		if bytes.is_empty():
			te.text = "(this page is empty)"
		right.add_child(te)
		return
	var li = _store["list"]
	if li == null:
		return
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows = _col(2)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(rows)
	right.add_child(sc)
	var es = li.get("entries", [])
	var st_get = {"name": func(e): return e["name"], "size": func(e): return float(e["size"]) if e["type"] == "file" else -1.0, "mode": func(e): return str(e.get("mode", "")), "mtime": func(e): return str(e.get("mtime", ""))}
	var st_fill = func():
		_clear(rows)
		var shown = _table_rows("storage", es, st_get)
		if es.is_empty():
			rows.add_child(_lbl("This folder is empty.", 13, DIM))
		elif shown.is_empty():
			rows.add_child(_lbl("Nothing in this folder contains that.", 13, DIM))
		for e in shown:
			rows.add_child(_storage_row(e, li))
		if li.get("truncated", false):
			rows.add_child(_lbl("Only the first 500 entries are listed.", 12, K.health_color("warn")))
		if not li.get("readable", true):
			rows.add_child(_lbl("Names only: the contents of this kind of volume are never shown.", 12, RED))
	right.add_child(_table_head("storage", [["name", "NAME", 300], ["size", "SIZE", 110], ["mode", "MODE", 96], ["mtime", "CHANGED", 160]], st_fill, es.size()))
	right.move_child(right.get_child(right.get_child_count() - 1), sc.get_index())
	st_fill.call()

func _storage_row(e: Dictionary, li: Dictionary) -> Control:
	if true:
		var r = _row(8)
		var sub = (str(_store["path"]) + "/" + str(e["name"])).trim_prefix("/")
		match str(e["type"]):
			"dir":
				r.add_child(_fixed(_btn(str(e["name"]) + "/", func(): _store_dir(_store["mount"], sub)), 300))
			"file":
				r.add_child(_fixed(_btn(str(e["name"]), func(): _store_file(sub, 0), "normal", li.get("readable", true)), 300))
			"link":
				var ll = _lbl("%s  ->  %s" % [e["name"], e.get("link", "")], 13, K.health_color("warn"))
				ll.clip_text = true
				r.add_child(_fixed(ll, 300))
			_:
				r.add_child(_fixed(_lbl(str(e["name"]), 13, DIM), 300))
		r.add_child(_fixed(_lbl(K.fmt_bytes(float(e["size"])) if e["type"] == "file" else ("link, not followed" if e["type"] == "link" else ""), 12, DIM), 110))
		r.add_child(_fixed(_lbl(str(e.get("mode", "")), 12, DIM), 96))
		r.add_child(_lbl(str(e.get("mtime", "")), 12, DIM))
		return r
	return null

# ----- connecting a cluster from a kubeconfig, without kubectl (native companion)

const AUTH_WORDS = {"token": "bearer token", "client-cert": "client certificate", "exec": "credential helper",
	"auth-provider": "auth provider plugin", "basic": "username and password", "none": "no credentials"}

func open_connect(focus_profile: String = "", failure: Dictionary = {}) -> void:
	var body = _open_modal("connect", focus_profile, "CONNECT A CLUSTER", Vector2(1040, 660))
	if not Agent.available():
		var l = _lbl(Agent.why_unavailable() + "\n\nWithout it, Kubernetes is reached the old way: through a kubectl on PATH and whatever kubeconfig kubectl is set up with (start with --kubectl-cli).", 15, K.health_color("warn"))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 980
		body.add_child(l)
		return
	var intro = _lbl("Add a kubeconfig and pick a context. No kubectl, WSL or Docker is needed: the game talks to the cluster's API itself. The file is only read to connect; its contents are never logged or copied anywhere.", 13, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 990
	body.add_child(intro)
	var add = _row(10)
	add.add_child(_btn("Choose a kubeconfig file...", func():
		DisplayServer.file_dialog_show("Choose a kubeconfig", OS.get_environment("USERPROFILE").path_join(".kube"), "", true,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.yaml,*.yml,*.conf,*.config;Kubeconfig", "*;All files"]),
			func(ok, paths, _i):
				if ok and paths.size() > 0:
					var p = Connections.add_file(str(paths[0]))
					open_connect.call_deferred(str(p.get("id", "")))), "primary"))
	add.add_child(_btn("Paste a kubeconfig...", _open_connect_paste))
	add.add_child(_lbl("or drop a kubeconfig file onto this window", 13, DIM))
	body.add_child(add)
	if not failure.is_empty():
		body.add_child(_connect_failure(failure))
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	var profs = Connections.profiles()
	if profs.is_empty():
		list.add_child(_lbl("No kubeconfig yet. Nothing was found in the default place (%s)." % "~/.kube/config", 15, DIM))
	for pr in profs:
		var pc = PanelContainer.new()
		var focus = str(pr["id"]) == focus_profile
		pc.add_theme_stylebox_override("panel", _sb(BG2, ORANGE if focus else Color(0, 0, 0, 0), 1 if focus else 0, 10))
		var v = _col(6)
		pc.add_child(v)
		var head = _row(10)
		head.add_child(_lbl(str(pr["name"]), 17, ORANGE))
		head.add_child(_lbl("pasted, kept in the game's user folder" if pr.get("pasted", false) else K.tidy_path(str(pr["path"])), 12, DIM))
		head.add_child(_spacer())
		if not pr.get("implicit", false):
			head.add_child(_btn("Forget", func():
				Connections.remove(str(pr["id"]))
				open_connect()))
		v.add_child(head)
		var ctxs = Native.contexts_of(Connections.source_of(pr))
		if ctxs.is_empty():
			v.add_child(_lbl("This file could not be read as a kubeconfig.", 14, RED))
		for c in ctxs:
			var r = _row(10)
			var active = cluster.backend != null and cluster.backend.label == "kubernetes" and cluster.backend.context == c["context"]
			r.add_child(_fixed(_lbl(("● " if active else "") + str(c["context"]), 15, K.health_color("ok") if active else TXT), 250))
			r.add_child(_fixed(_lbl(str(c["provider"]), 13, K.provider_color(c["provider"]).lightened(0.3)), 120))
			var detail = "%s  ·  %s" % [str(c["server"]).trim_prefix("https://"), AUTH_WORDS.get(c["auth"], c["auth"])]
			if c["auth"] in ["exec", "auth-provider"]:
				detail += ": " + str(c["exec"])
			if c["insecure"]:
				detail += "  ·  TLS verification is switched off in this file"
			var dl = _lbl(detail if c["problem"] == "" else c["problem"], 12, DIM if c["problem"] == "" else K.health_color("warn"))
			dl.clip_text = true
			dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.add_child(dl)
			if active:
				r.add_child(_lbl("CONNECTED  ", 13, K.health_color("ok")))
			else:
				r.add_child(_btn("Connect", func():
					_connect_wait(pr, c), "primary"))
			v.add_child(r)
		list.add_child(pc)

func _connect_wait(pr: Dictionary, c: Dictionary) -> void:
	var t = c.duplicate()
	t["source"] = "kubernetes"
	t["profile"] = str(pr["id"])
	var body = _open_modal("connecting", t, "CONNECTING", Vector2(640, 200))
	body.add_child(_lbl("%s\n%s" % [c["context"], str(c["server"])], 16))
	body.add_child(_lbl("Checking the certificate, signing in, reading what this account may do...", 13, DIM))
	target_requested.emit(t)

# The cluster manager reports how a connection attempt ended.
func on_connect_result(failure: Dictionary) -> void:
	if _modal_kind != "connecting":
		return
	if failure.is_empty():
		close_modal()
	else:
		open_connect(str(failure.get("profile", "")), failure)

# Each kind of failure is shown as what it is, with the one thing that fixes it.
func _connect_failure(f: Dictionary) -> Control:
	var kind = str(f.get("kind", "other"))
	var pc = PanelContainer.new()
	var sb = _sb(Color(0.2, 0.07, 0.06), RED, 0, 12)
	sb.border_width_left = 4
	pc.add_theme_stylebox_override("panel", sb)
	var v = _col(6)
	pc.add_child(v)
	v.add_child(_lbl("%s  -  could not connect to %s" % [Agent.kind_title(kind), f.get("context", "")], 15, RED))
	var why = {"auth": "The cluster did not accept these credentials. They may have expired: get a fresh kubeconfig or token.",
		"tls": "The cluster's certificate does not match the authority in this kubeconfig, so the connection was refused. Nothing was sent.",
		"rbac": "You are signed in, but this account is not allowed to do that.",
		"timeout": "The cluster did not answer in time. Check the network or VPN.",
		"unreachable": "Nothing answered at the cluster's address. Check the network, VPN, or whether the cluster is running.",
		"needs_base_dir": "The pasted kubeconfig points at certificate or token files by relative path. Choose the folder they are in.",
		"exec_untrusted": "This context gets its credentials by running a program on this computer. A kubeconfig can name any program, so it is not run until you approve it."}.get(kind, "")
	for line in [why, str(f.get("msg", ""))]:
		if line == "":
			continue
		var l = _lbl(line, 13, TXT if line == why else DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 960
		v.add_child(l)
	var prof = Connections.find(str(f.get("profile", "")))
	var retry = func():
		for c in Native.contexts_of(Connections.source_of(prof)):
			if c["context"] == f.get("context", ""):
				_connect_wait(prof, c)
	if kind == "exec_untrusted" and not prof.is_empty():
		var cmd = str(f.get("extra", {}).get("command", ""))
		v.add_child(_lbl("Program:  " + cmd, 15, K.health_color("warn")))
		v.add_child(_btn("I trust this kubeconfig: allow \"%s\" for this context and connect" % cmd, func():
			Connections.trust_exec(prof, str(f.get("context", "")), cmd)
			retry.call(), "mk3"))
	elif kind == "needs_base_dir" and not prof.is_empty():
		v.add_child(_btn("Choose the folder...", func():
			DisplayServer.file_dialog_show("Folder holding the certificate files", "", "", true, DisplayServer.FILE_DIALOG_MODE_OPEN_DIR, PackedStringArray(),
				func(ok, paths, _i):
					if ok and paths.size() > 0:
						Connections.set_base_dir(str(prof["id"]), str(paths[0]))
						open_connect.call_deferred(str(prof["id"]))), "primary"))
	elif not prof.is_empty():
		v.add_child(_btn("Try again", retry))
	return pc

func _open_connect_paste() -> void:
	var body = _open_modal("connect_paste", null, "PASTE A KUBECONFIG", Vector2(900, 620))
	body.add_child(_lbl("Paste the whole file. It is saved in the game's own user folder so the connection can be reused, and nowhere else.", 13, DIM))
	var nr = _row(10)
	nr.add_child(_lbl("NAME", 12, DIM))
	var name_edit = LineEdit.new()
	name_edit.placeholder_text = "e.g. homelab"
	name_edit.custom_minimum_size.x = 300
	nr.add_child(name_edit)
	body.add_child(nr)
	var te = TextEdit.new()
	te.size_flags_vertical = Control.SIZE_EXPAND_FILL
	te.custom_minimum_size.y = 380
	te.add_theme_font_override("font", _mono)
	te.add_theme_font_size_override("font_size", 12)
	te.placeholder_text = "apiVersion: v1\nkind: Config\n..."
	body.add_child(te)
	var warn = _lbl("", 13, RED)
	body.add_child(warn)
	var r = _row()
	r.add_child(_btn("Paste from clipboard", func(): te.text = DisplayServer.clipboard_get()))
	r.add_child(_spacer())
	r.add_child(_btn("Back", func(): open_connect()))
	r.add_child(_btn("Read it", func():
		var chk = Agent.request("kubeconfig.inspect", {"content": te.text, "base_dir": "."}, 15.0)
		if not chk["ok"]:
			warn.text = chk["msg"]
			return
		var p = Connections.add_pasted(te.text, name_edit.text.strip_edges())
		open_connect(str(p.get("id", ""))), "primary"))
	body.add_child(r)
	te.grab_focus.call_deferred()

# ----- demo worlds: the simulated clusters you can try without connecting to anything

func open_demos() -> void:
	offer_demos = false
	var body = _open_modal("demos", null, "CHOOSE A DEMO", Vector2(980, 600))
	var intro = _lbl("Four simulated worlds. Nothing here is real, so break whatever you like. Switch any time from the pause menu (Esc).", 14, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 930
	body.add_child(intro)
	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for d in DemoSim.DEMO_TYPES:
		var f = DemoSim.FLAVORS[d["flavor"]]
		var active = cluster.backend != null and cluster.backend.label == "simulation" and cluster.backend.context == d["flavor"]
		var col = K.provider_color(f["provider"]).lightened(0.25)
		var pc = PanelContainer.new()
		pc.custom_minimum_size = Vector2(458, 210)
		var sb = _sb(BG2, col, 0, 14)
		sb.border_width_top = 4
		pc.add_theme_stylebox_override("panel", sb)
		var v = _col(6)
		pc.add_child(v)
		v.add_child(_lbl(str(d["name"]).to_upper(), 18, col))
		v.add_child(_lbl("%s  ·  %d nodes" % [f["provider"], f["nodes"].size() + (1 if f["cp"] != "" else 0)], 12, DIM))
		var desc = _lbl(d["desc"], 14)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size.x = 420
		desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
		v.add_child(desc)
		var r = _row()
		r.add_child(_spacer())
		if active:
			r.add_child(_btn("Keep playing this one", close_modal, "primary"))
		else:
			r.add_child(_btn("Play", func():
				close_modal()
				target_requested.emit({"source": "simulation", "context": d["flavor"], "provider": f["provider"]}), "primary"))
		v.add_child(r)
		grid.add_child(pc)
	body.add_child(grid)

# ----- logging station

func open_logs(pod_uid: String = "") -> void:
	var st = cluster.state
	if pod_uid != "":
		var p = K.find_pod(st, pod_uid)
		if p != null:
			_ls["tab"] = "pods"
			_ls["ns"] = p["ns"]
			_ls["pod"] = p["name"]
			_ls["container"] = ""
	var body = _open_modal("logs", null, "HELMSMAN DATAPAD  //  LOG LEDGER", Vector2(1260, 740), true)
	var tabs = _row()
	for t in [["pods", "POD LOGS"], ["events", "CLUSTER EVENTS"], ["audit", "AUDIT LOG"]]:
		tabs.add_child(_btn("  " + t[1] + "  ", func():
			_ls["tab"] = t[0]
			open_logs(), "primary" if _ls["tab"] == t[0] else "normal"))
	# wireless uplink indicator: signal bars + provider + link state
	tabs.add_child(_spacer())
	var bars = _row(3)
	bars.alignment = BoxContainer.ALIGNMENT_END
	_link_bars = []
	for i in 4:
		var holder = Control.new()
		holder.custom_minimum_size = Vector2(6, 22)
		var bar = ColorRect.new()
		bar.size = Vector2(6, 6 + i * 5)
		bar.position = Vector2(0, 22 - bar.size.y)
		holder.add_child(bar)
		bars.add_child(holder)
		_link_bars.append(bar)
	tabs.add_child(bars)
	_link_lbl = _lbl("", 13)
	tabs.add_child(_link_lbl)
	body.add_child(tabs)
	var provs = cluster.backend.providers if cluster.backend != null else []
	if _ls["tab"] == "pods":
		var has = false
		for pr in provs:
			if pr["id"] == _ls["provider"]:
				has = true
		if not has:
			_ls["provider"] = "kube"
		var prow = _row(8)
		prow.add_child(_lbl("LOG PROVIDER", 12, DIM))
		for pr in provs:
			var on = pr["id"] == _ls["provider"]
			var pb = _btn(("((•))  " if on else "") + pr["name"] + ("" if pr["ready"] else "  (offline)"), func():
				_ls["provider"] = pr["id"]
				open_logs(), "primary" if on else "normal")
			pb.tooltip_text = pr["note"]
			prow.add_child(pb)
		body.add_child(prow)
	var ctl = _row(10)
	var nss = _namespaces()
	if _ls["tab"] == "pods":
		# default to the first failing pod, so the station opens on the problem
		var pods = st["pods"]
		var cur = null
		for p in pods:
			if p["ns"] == _ls["ns"] and p["name"] == _ls["pod"]:
				cur = p
		if cur == null:
			for p in pods:
				if (_ls["ns"] == "" or p["ns"] == _ls["ns"]) and (cur == null or (p["health"] == "bad" and cur["health"] != "bad")):
					cur = p
		if cur != null:
			_ls["ns"] = cur["ns"]
			_ls["pod"] = cur["name"]
		ctl.add_child(_lbl("NAMESPACE", 12, DIM))
		var nsp = _pick(nss, _ls["ns"], func(v):
			_ls["ns"] = v
			_ls["pod"] = ""
			open_logs())
		ctl.add_child(nsp)
		ctl.add_child(_lbl("POD", 12, DIM))
		var names = []
		for p in pods:
			if p["ns"] == _ls["ns"]:
				names.append(p["name"])
		names.sort()
		var pp = _pick(names, _ls["pod"], func(v):
			_ls["pod"] = v
			_ls["container"] = ""
			open_logs())
		pp.custom_minimum_size.x = 330
		ctl.add_child(pp)
		var cnames = []
		if cur != null:
			for c in cur["containers"]:
				cnames.append(c["name"])
		if not cnames.has(_ls["container"]):
			_ls["container"] = cnames[0] if cnames.size() > 0 else ""
		ctl.add_child(_lbl("CONTAINER", 12, DIM))
		ctl.add_child(_pick(cnames, _ls["container"], func(v):
			_ls["container"] = v
			_ls_fetch()))
		ctl.add_child(_lbl("TAIL", 12, DIM))
		ctl.add_child(_pick(["100", "200", "500", "2000"], str(_ls["tail"]), func(v):
			_ls["tail"] = int(v)
			_ls_fetch()))
		ctl.add_child(_check("Previous", _ls["previous"], func(on):
			_ls["previous"] = on
			_ls_fetch()))
	elif _ls["tab"] == "events":
		ctl.add_child(_lbl("NAMESPACE", 12, DIM))
		ctl.add_child(_pick(["(all)"] + nss, _ls["ens"] if _ls["ens"] != "" else "(all)", func(v):
			_ls["ens"] = "" if v == "(all)" else v
			_ls_fetch()))
		ctl.add_child(_check("Warnings only", _ls["warnings"], func(on):
			_ls["warnings"] = on
			_ls_fetch()))
	else:
		ctl.add_child(_lbl("Every action taken through KubeFactory. Also written to  " + K.tidy_path(cluster.log_dir), 13, DIM))
	body.add_child(ctl)
	var fr = _row(10)
	fr.add_child(_lbl("FILTER", 12, DIM))
	var fe = LineEdit.new()
	fe.text = _ls["filter"]
	fe.placeholder_text = "show only lines containing...  (e.g. error)"
	fe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fe.text_changed.connect(func(v):
		_ls["filter"] = v
		_ls_apply())
	fr.add_child(fe)
	_ls_count = _lbl("", 12, DIM)
	fr.add_child(_ls_count)
	if _ls["tab"] != "audit":
		fr.add_child(_check("Follow", _ls["follow"], func(on): _ls["follow"] = on))
	fr.add_child(_btn("Refresh", func(): open_logs()))
	fr.add_child(_btn("Save to file", _ls_save))
	fr.add_child(_btn("Open log folder", func(): OS.shell_open(cluster.log_dir)))
	body.add_child(fr)
	# the ledger page: numbered entries, colour-coded by severity
	var page = PanelContainer.new()
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.custom_minimum_size = Vector2(0, 470)
	var pg = _sb(Color(0.02, 0.03, 0.032), Color(0.16, 0.3, 0.26), 1, 10)
	pg.border_width_left = 5
	page.add_theme_stylebox_override("panel", pg)
	_ledger = RichTextLabel.new()
	_ledger.bbcode_enabled = true
	_ledger.scroll_following = true
	_ledger.selection_enabled = true
	_ledger.autowrap_mode = TextServer.AUTOWRAP_OFF
	_ledger.add_theme_font_override("normal_font", _mono)
	_ledger.add_theme_font_size_override("normal_font_size", 13)
	page.add_child(_ledger)
	body.add_child(page)
	_ls_fetch()

func _set_link(state: String, ms: int = 0) -> void:
	if _link_lbl == null or not is_instance_valid(_link_lbl):
		return
	var who = "LOCAL LEDGER"
	if _ls["tab"] == "events":
		who = "Kubernetes API"
	elif _ls["tab"] == "pods" and cluster.backend != null:
		for pr in cluster.backend.providers:
			if pr["id"] == _ls["provider"]:
				who = pr["name"]
	var col = K.health_color("ok")
	var lit = 4
	var txt = ""
	match state:
		"sync":
			col = K.health_color("warn")
			lit = 2
			txt = "UPLINK  %s  ·  SYNCING..." % who
		"ok":
			lit = 4 if ms < 150 else (3 if ms < 500 else (2 if ms < 1500 else 1))
			txt = "UPLINK  %s  ·  LINKED  ·  %d ms" % [who, ms]
		"local":
			txt = "%s  ·  ON DEVICE" % who
		_:
			col = RED
			lit = 0
			txt = "UPLINK  %s  ·  NO SIGNAL" % who
	_link_lbl.text = txt
	_link_lbl.add_theme_color_override("font_color", col)
	for i in _link_bars.size():
		_link_bars[i].color = col if i < lit else Color(0.25, 0.26, 0.28)
	if state != "sync" and state != "local":
		world.set_uplink(who, state == "ok")

func _pick(items: Array, current: String, cb: Callable) -> OptionButton:
	var ob = OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	for i in items.size():
		ob.add_item(items[i])
		if items[i] == current:
			ob.select(i)
	ob.item_selected.connect(func(i): cb.call(ob.get_item_text(i)))
	return ob

func _check(text: String, on: bool, cb: Callable) -> CheckBox:
	var c = CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	return c

func _log_view() -> TextEdit:
	var t = TextEdit.new()
	t.editable = false
	t.size_flags_vertical = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", _mono)
	t.add_theme_font_size_override("font_size", 13)
	t.add_theme_stylebox_override("normal", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
	t.add_theme_stylebox_override("read_only", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
	t.add_theme_color_override("font_readonly_color", Color(0.78, 0.86, 0.8))
	return t

func _ls_fetch(quiet: bool = false) -> void:
	_ls_timer = 0.0
	if _ls["tab"] == "audit":
		_ls_raw = "\n".join(PackedStringArray(cluster.audit_lines))
		_ls_apply()
		_set_link("local")
		return
	_log_key = "ls/%d" % Time.get_ticks_msec()
	if not quiet:
		_set_link("sync")
	if _ls["tab"] == "events":
		cluster.act({"op": "cluster_events", "ns": _ls["ens"], "warnings": _ls["warnings"], "key": _log_key, "quiet": quiet})
	elif _ls["pod"] != "":
		cluster.act({"op": "logs", "ns": _ls["ns"], "name": _ls["pod"], "container": _ls["container"],
			"tail": _ls["tail"], "previous": _ls["previous"], "provider": _ls["provider"], "key": _log_key, "quiet": quiet})
	else:
		_ls_raw = "No pods to show logs for."
		_ls_apply()

func _ls_apply() -> void:
	if _ledger == null or not is_instance_valid(_ledger):
		return
	var raw = _ls_raw.strip_edges(false, true)
	var all = raw.split("\n") if raw != "" else PackedStringArray()
	var needle = _ls["filter"].strip_edges().to_lower()
	var keep = []
	var bb = []
	for i in all.size():
		var line = all[i]
		var low = line.to_lower()
		if needle != "" and not low.contains(needle):
			continue
		keep.append(line)
		# severity decides the ink: red for failures, amber for warnings
		var ink = "c4d8cc"
		var mark = "·"
		if low.contains("fatal") or low.contains("error") or low.contains("failed") or low.contains("panic") or low.contains("exception") or low.contains("no signal"):
			ink = "ff6b5e"
			mark = "■"
		elif low.contains("warn") or low.contains("backoff") or low.contains("blocked"):
			ink = "ffc93c"
			mark = "■"
		bb.append("[color=#4d6a60]%04d[/color]  [color=#%s]%s  %s[/color]" % [i + 1, ink, mark, line.replace("[", "[lb]")])
	var text = "\n".join(PackedStringArray(keep))
	if text != _ls_shown or _ledger.get_parsed_text() == "":
		_ls_shown = text
		_ledger.text = "\n".join(PackedStringArray(bb))
	_ls_count.text = "%d of %d entries" % [keep.size(), all.size()]

func _ls_save() -> void:
	var what = "audit"
	if _ls["tab"] == "pods":
		what = _ls["pod"] if _ls["pod"] != "" else "pod"
	elif _ls["tab"] == "events":
		what = "events"
	var stamp = Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var path = cluster.log_dir.path_join("%s-%s.log" % [what, stamp])
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		notify("Could not write " + path, "bad")
		return
	f.store_string(_ls_shown)
	f.close()
	cluster.audit("saved %s log to %s" % [what, path])
	notify("Saved to " + path, "ok")

func _process(delta: float) -> void:
	if _modal_kind != "logs":
		return
	_ls_timer += delta
	if _ls["tab"] == "audit":
		if _ls_timer > 1.0:
			_ls_fetch(true)
	elif _ls["follow"] and _ls_timer > 3.0:
		_ls_fetch(true)

# ----- Porter, the Portainer NPC

# Live pods belonging to something Porter installed.
func _installed_pods(e: Dictionary) -> Array:
	var names = [e["name"]]
	if e["kind"] == "app":
		names = []
		var app = Apps.find(str(e.get("id", "")))
		if app != null:
			for s in app["sim"]:
				names.append(s[1])
	var res = []
	for p in cluster.state["pods"]:
		if e["kind"] == "template" and cluster.state["source"] == "docker":
			if p["name"] == e["name"]:
				res.append(p)
		elif p["ns"] == e["ns"] and names.has(p["wname"]):
			res.append(p)
	return res

func _installed_restart(e: Dictionary, pods: Array) -> void:
	if cluster.state["source"] == "docker":
		for p in pods:
			cluster.act({"op": "restart", "ns": p["ns"], "kind": p["wkind"], "name": p["wname"], "pod": p["name"]})
		return
	var done = {}
	for p in pods:
		var key = p["wkind"] + "/" + p["wname"]
		if not done.has(key):
			done[key] = true
			cluster.act({"op": "restart", "ns": p["ns"], "kind": p["wkind"], "name": p["wname"]})

func _installed_forget(e: Dictionary) -> void:
	var all = Apps.load_installed()
	for x in all.duplicate():
		if x.get("source") == e.get("source") and x.get("context") == e.get("context") and x["kind"] == e["kind"] and x["name"] == e["name"] and x["ns"] == e["ns"]:
			all.erase(x)
	Apps.save_installed(all)

# Keep the install ledger in step with what actually succeeded.
func on_action(a: Dictionary, r: Dictionary) -> void:
	if not r.get("ok", false):
		return
	var e = {"source": cluster.state["source"], "context": cluster.state["context"], "when": Time.get_datetime_string_from_system()}
	match a["op"]:
		"apply_app":
			var app = Apps.find(a["id"])
			e.merge({"kind": "app", "id": a["id"], "title": app["name"], "name": a["id"], "ns": a["ns"], "list": "Porter's dock"})
		"deploy_template":
			e.merge({"kind": "template", "title": str(a["template"].get("title", a["name"])), "image": str(a["template"].get("image", "")),
				"name": a["name"], "ns": a["ns"] if cluster.state["source"] != "docker" else "default", "list": str(a.get("list", ""))})
		"remove_app":
			_installed_forget({"source": e["source"], "context": e["context"], "kind": "app", "name": a["id"], "ns": a["ns"]})
			return
		"remove_template":
			_installed_forget({"source": e["source"], "context": e["context"], "kind": "template", "name": a["name"],
				"ns": a["ns"] if cluster.state["source"] != "docker" else "default"})
			return
		_:
			return
	_installed_forget(e)
	var all = Apps.load_installed()
	all.append(e)
	Apps.save_installed(all)

# ----- Bob, the pod fixer: a fix list with a diagnosis and a remedy per job

const BOB_COL = Color(1.0, 0.8, 0.45)

# Gauge observes current state and fetches one workload's usage on request.
func open_gauge() -> void:
	_gauge["key"] = ""
	_gauge["signature"] = ""
	var compact = touch != null and touch.active
	var wide_touch = compact and get_viewport().get_visible_rect().size.x > get_viewport().get_visible_rect().size.y
	var dialog_size = Vector2(850, 500) if wide_touch else (Vector2(500, 800) if compact else Vector2(1160, 720))
	var body = _open_modal("gauge", null, "GAUGE  //  RESOURCE DESK", dialog_size)
	if compact:
		var head = body.get_parent().get_child(0)
		head.get_child(0).add_theme_font_size_override("font_size", 24)
		var close: Button = head.get_child(head.get_child_count() - 1)
		close.custom_minimum_size = Vector2(70, 60)
		close.add_theme_font_size_override("font_size", 22)
		_gauge_scroll = ScrollContainer.new()
		_gauge_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_gauge_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		body.add_child(_gauge_scroll)
		var flow = _col(10)
		flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_gauge_scroll.add_child(flow)
		body = flow
	else:
		_gauge_scroll = null
	var top = _row(16)
	var portrait = null if compact else _krew_portrait("gauge", Color(0.04, 0.1, 0.12), false)
	if portrait != null:
		top.add_child(portrait)
	var info = _col(7)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(_lbl("GAUGE  ·  OBSERVER", 22 if compact else 18, Color(0.45, 0.95, 1.0)))
	if cluster.state.get("source", "") == "simulation":
		info.add_child(_lbl("SIMULATED DATA", 18 if compact else 13, K.health_color("warn")))
	var explanation = "Capacity is reported by the Docker host; container requests are unavailable." if cluster.state.get("source", "") == "docker" else "Capacity is allocatable; requests cover visible regular containers. Init containers and overhead may be omitted."
	if str(cluster.state.get("scoped_ns", "")) != "":
		explanation += " Only namespace %s is visible." % str(cluster.state["scoped_ns"])
	var note = _lbl(explanation + " Requests are not actual usage. Check sustained usage and workload requirements before changing resources. Gauge makes no changes.", 18 if compact else 13, DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = (770 if wide_touch else 430) if compact else (800 if portrait == null else 720)
	info.add_child(note)
	var stacked = compact and not wide_touch
	var controls = _col(6) if stacked else _row(8)
	_gauge_pick = OptionButton.new()
	_gauge_pick.custom_minimum_size = Vector2(300 if wide_touch else 200, 60) if compact else Vector2(430, 0)
	if compact:
		_gauge_pick.add_theme_font_size_override("font_size", 18)
	for p in cluster.state.get("pods", []):
		_gauge_pick.add_item("%s / %s" % [p["ns"], p["name"]])
		_gauge_pick.set_item_metadata(_gauge_pick.item_count - 1, str(p["uid"]))
	controls.add_child(_gauge_pick)
	var buttons = _row(8) if stacked else controls
	var read_button = _btn("Read usage", _gauge_request, "primary", _gauge_pick.item_count > 0)
	var open_button = _btn("Open machine", func():
		if _gauge_pick.selected >= 0:
			open_pod(str(_gauge_pick.get_item_metadata(_gauge_pick.selected))), "normal", _gauge_pick.item_count > 0)
	for button in [read_button, open_button]:
		if compact:
			button.custom_minimum_size.y = 60
			button.add_theme_font_size_override("font_size", 18)
		buttons.add_child(button)
	if stacked:
		controls.add_child(buttons)
	info.add_child(controls)
	_gauge_readout = _lbl("Choose a workload to read its current usage.", 17 if compact else 13, DIM)
	_gauge_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gauge_readout.custom_minimum_size.x = (770 if wide_touch else 430) if compact else 720
	info.add_child(_gauge_readout)
	top.add_child(info)
	body.add_child(top)
	if compact:
		body.add_child(_lbl("Swipe the table sideways for more columns.", 17, DIM))
	var rows = Gauge.node_rows(cluster.state)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if compact:
		sc.custom_minimum_size.y = 220
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_gauge_table = _col(4)
	_gauge_table.custom_minimum_size.x = 960
	_gauge_over_limit = rows.size() >= K.TABLE_LIMIT
	_gauge_head = _gauge_table_head(rows.size())
	_gauge_table.add_child(_gauge_head)
	_gauge_rows = _col(4)
	_gauge_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gauge_table.add_child(_gauge_rows)
	sc.add_child(_gauge_table)
	body.add_child(sc)
	_fill_gauge(true)

func _gauge_table_head(count: int) -> Control:
	return _table_head("gauge-nodes", [["name", "NODE", 210], ["cpu_requested", "CPU REQUEST", 145], ["cpu", "CPU CAPACITY", 145],
		["memory_requested", "MEM REQUEST", 145], ["memory", "MEM CAPACITY", 145], ["ready", "STATE", 100]],
		func(): _fill_gauge(true), count, 17 if touch != null and touch.active else 12)

func _gauge_sync_head(count: int) -> void:
	var over_limit = count >= K.TABLE_LIMIT
	if over_limit == _gauge_over_limit:
		return
	_gauge_over_limit = over_limit
	_gauge_table.remove_child(_gauge_head)
	_gauge_head.queue_free()
	_gauge_head = _gauge_table_head(count)
	_gauge_table.add_child(_gauge_head)
	_gauge_table.move_child(_gauge_head, 0)

func _gauge_request() -> void:
	if cluster.detecting or cluster.backend == null:
		_gauge_readout.text = "The data source is connecting. Try again when it is ready."
		return
	if _gauge_pick.selected < 0:
		return
	var uid = str(_gauge_pick.get_item_metadata(_gauge_pick.selected))
	var pod = K.find_pod(cluster.state, uid)
	if pod == null:
		_gauge_readout.text = "That workload is no longer present."
		return
	_gauge["seq"] += 1
	_gauge["key"] = "gauge:%d" % _gauge["seq"]
	_gauge["target"] = "%s / %s" % [pod["ns"], pod["name"]]
	_gauge_readout.text = "Reading %s / %s..." % [pod["ns"], pod["name"]]
	cluster.act({"op": "pod_metrics", "ns": pod["ns"], "name": pod["name"], "key": _gauge["key"]})

func _fill_gauge(force: bool = false) -> void:
	if _modal_kind != "gauge" or not is_instance_valid(_gauge_rows):
		return
	var rows = Gauge.node_rows(cluster.state)
	_gauge_sync_head(rows.size())
	var signature = JSON.stringify(rows) + str(cluster.state.get("error", ""))
	if not force and signature == _gauge["signature"]:
		return
	_gauge["signature"] = signature
	_clear(_gauge_rows)
	if str(cluster.state.get("error", "")) != "":
		_gauge_rows.add_child(_lbl("Last state may be stale: " + str(cluster.state["error"]), 13, RED))
	if rows.is_empty():
		_gauge_rows.add_child(_lbl("No node capacity data is available.", 13, DIM))
	var getters = {"name": func(n): return n["name"], "cpu_requested": func(n): return n["cpu_requested"], "cpu": func(n): return n["cpu"],
		"memory_requested": func(n): return n["memory_requested"], "memory": func(n): return n["memory"], "ready": func(n): return Gauge.readiness(n["ready"])}
	var table = _table_state("gauge-nodes")
	var filtered = rows if rows.size() >= K.TABLE_LIMIT else rows.filter(func(n): return Gauge.node_matches(n, table["filter"]))
	var text_size = 17 if touch != null and touch.active else 13
	for n in K.table_rows(filtered, table["col"], table["desc"], "", getters):
		var row = _row(10)
		row.add_child(_fixed(_lbl(n["name"], text_size), 210))
		row.add_child(_fixed(_lbl(Gauge.cpu(n["cpu_requested"]), text_size), 145))
		row.add_child(_fixed(_lbl(Gauge.cpu(n["cpu"]), text_size), 145))
		row.add_child(_fixed(_lbl(Gauge.memory(n["memory_requested"]), text_size), 145))
		row.add_child(_fixed(_lbl(Gauge.memory(n["memory"]), text_size), 145))
		var health = "warn" if n["ready"] == null else ("ok" if n["ready"] else "bad")
		row.add_child(_fixed(_lbl(Gauge.readiness(n["ready"]), text_size, K.health_color(health)), 100))
		_gauge_rows.add_child(row)

# A Krew member's portrait as they now are: their own model from the library,
# lit and slowly turning in a little viewport of its own. Returns null where the
# library is not used (the browser build), and the drawn portrait is shown instead.
func _krew_portrait(id: String, bg: Color, head: bool) -> Control:
	if not Models.available():
		return null
	var model = Models.instance(id)
	if model == null:
		return null
	var box = TextureRect.new()
	box.custom_minimum_size = Vector2(210, 230)
	box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	box.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var vp = SubViewport.new()
	vp.size = Vector2i(420, 460)
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	box.add_child(vp)
	box.texture = vp.get_texture()
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.8, 0.9)
	env.ambient_light_energy = 0.9
	var we = WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun = DirectionalLight3D.new()
	sun.rotation = Vector3(-0.7, 0.6, 0)
	sun.light_energy = 1.5
	vp.add_child(sun)
	var b: AABB = model.get_meta("bounds")
	var pivot = Node3D.new()
	vp.add_child(pivot)
	model.position = Vector3(-b.get_center().x, 0, -b.get_center().z)     # it turns about its own middle
	pivot.add_child(model)
	var cam = Camera3D.new()
	cam.fov = 32.0
	# a head-and-shoulders view for a figure, the whole of it for a vehicle
	var look = Vector3(0, b.position.y + b.size.y * (0.68 if head else 0.5), 0)
	var dist = b.size.y * 1.25 if head else maxf(b.size.x, maxf(b.size.y, b.size.z)) * 1.55
	var cam_at = look + Vector3(0.28, 0.12 if head else 0.3, 1.0).normalized() * dist
	cam.transform = Transform3D(Basis.looking_at(look - cam_at), cam_at)      # set outright: the viewport is not in the tree yet
	vp.add_child(cam)
	var tw = pivot.create_tween().set_loops()
	pivot.rotation.y = -0.45
	tw.tween_property(pivot, "rotation:y", 0.45, 4.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(pivot, "rotation:y", -0.45, 4.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return box

func _bob_portrait() -> Control:
	var model_view = _krew_portrait("bob", Color(0.1, 0.085, 0.06), true)
	if model_view != null:
		return model_view
	# an old hand drawn from rectangles: flat cap, white hair and moustache, glasses, green cardigan
	var c = Control.new()
	c.custom_minimum_size = Vector2(210, 230)
	var skin = Color(0.89, 0.72, 0.6)
	var white = Color(0.93, 0.93, 0.9)
	var tweed = Color(0.45, 0.42, 0.38)
	var parts = [[Rect2(0, 0, 210, 230), Color(0.1, 0.085, 0.06)], [Rect2(30, 158, 150, 72), Color(0.34, 0.44, 0.3)],
		[Rect2(78, 170, 54, 60), Color(0.42, 0.29, 0.18)], [Rect2(58, 60, 94, 96), skin],
		[Rect2(48, 70, 12, 56), white], [Rect2(150, 70, 12, 56), white],
		[Rect2(46, 38, 118, 26), tweed], [Rect2(40, 60, 96, 10), tweed],
		[Rect2(66, 80, 34, 8), white], [Rect2(110, 80, 34, 8), white],
		[Rect2(64, 90, 36, 24), Color(0.15, 0.15, 0.17)], [Rect2(110, 90, 36, 24), Color(0.15, 0.15, 0.17)],
		[Rect2(68, 94, 28, 16), Color(0.75, 0.92, 1.0)], [Rect2(114, 94, 28, 16), Color(0.75, 0.92, 1.0)],
		[Rect2(100, 98, 10, 4), Color(0.15, 0.15, 0.17)], [Rect2(98, 110, 14, 18), Color(0.82, 0.62, 0.52)],
		[Rect2(74, 128, 62, 12), white], [Rect2(84, 140, 42, 14), white]]
	for p in parts:
		var r = ColorRect.new()
		r.color = p[1]
		r.position = p[0].position
		r.size = p[0].size
		c.add_child(r)
	return c

func open_bob() -> void:
	var body = _open_modal("bob", null, "BOB  //  REPAIR STAND", Vector2(1080, 660))
	var h = _row(18)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left = _col(6)
	left.add_child(_bob_portrait())
	left.add_child(_lbl("BOB", 18, BOB_COL))
	left.add_child(_lbl("Pod fixer", 12, DIM))
	left.add_child(_lbl("Forty years on the floor", 12, DIM))
	h.add_child(left)
	var box = _col(10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(box)
	body.add_child(h)
	var n = K.issues(cluster.state).size()
	# he opens with a zinger or some rizz, then gets down to business
	var opener = K.bob_line(n > 0)
	if n == 0:
		_say(box, opener + "\n\nNothing on my bench and every machine is humming. Come back when something starts smoking.", BOB_COL)
	else:
		_say(box, opener + "\n\nRight. I have %d %s on the list, worst first. I will tell you what is wrong and what I would do about it. You hold the tools, mind - I only point." % [n, "job" if n == 1 else "jobs"], BOB_COL)
	var chat = _row()
	chat.add_child(_btn("Got another one, Bob?", open_bob))
	chat.add_child(_spacer())
	box.add_child(chat)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dyn = _col(8)
	_dyn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_dyn)
	box.add_child(sc)
	_dyn_sig = ""
	_fill_bob()

func _fill_bob() -> void:
	var jobs = K.issues(cluster.state)
	var sig = JSON.stringify(jobs) + str(cluster.read_only)
	if sig == _dyn_sig:
		return
	_dyn_sig = sig
	_clear(_dyn)
	if jobs.is_empty():
		_dyn.add_child(_lbl("FIX LIST  -  empty", 15, K.health_color("ok")))
		_dyn.add_child(_lbl("No failing pods, no stuck pods, no unhealthy nodes.", 14, DIM))
		return
	_dyn.add_child(_lbl("FIX LIST  (%d)" % jobs.size(), 15, BOB_COL))
	var docker = cluster.backend != null and cluster.backend.label == "docker"
	for j in jobs:
		var col = K.health_color(j["sev"])
		var pc = PanelContainer.new()
		var sb = _sb(BG2, col, 0, 10)
		sb.border_width_left = 4
		pc.add_theme_stylebox_override("panel", sb)
		var v = _col(4)
		pc.add_child(v)
		var top = _row(12)
		top.add_child(_lbl(("NODE  " if j["kind"] == "node" else "") + str(j["name"]), 16))
		top.add_child(_lbl(str(j["status"]), 15, col))
		top.add_child(_spacer())
		if j["kind"] == "pod":
			var where = "%s  ·  %s" % [j["ns"], j["node"] if j["node"] != "" else "not on any node"]
			if j["restarts"] > 0:
				where += "  ·  %d restarts" % j["restarts"]
			top.add_child(_lbl(where, 12, DIM))
		v.add_child(top)
		var lines = [[j["why"], TXT], ["Bob:  " + j["fix"], BOB_COL]]
		if K.BOB_QUIPS.has(j["status"]):
			lines.insert(1, ["\"" + K.BOB_QUIPS[j["status"]] + "\"", DIM])
		for line in lines:
			var l = _lbl(line[0], 14, line[1])
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 740
			v.add_child(l)
		var b = _row()
		if j["kind"] == "node":
			b.add_child(_btn("Go there", func(): _bob_goto(world.node_spot(j["node"]))))
			b.add_child(_btn("Node terminal", func(): open_node(j["node"])))
			if j["action"] == "uncordon" and cluster.cap("cordon"):
				b.add_child(_spacer())
				b.add_child(_btn("Uncordon", func(): cluster.act({"op": "cordon", "node": j["node"], "on": false}), "mk2"))
		else:
			b.add_child(_btn("Go there", func(): _bob_goto(world.machine_spot(j["uid"]))))
			b.add_child(_btn("Logs and events", func(): open_pod(j["uid"])))
			if Bob.config()["log_review"] and cluster.cap("logs"):
				b.add_child(_btn("Read the log with me, Bob", func(): open_bob_case(j["uid"]), "primary"))
			b.add_child(_spacer())
			var w = K.find_workload(cluster.state, j["ns"], j["wkind"], j["wname"])
			match j["action"]:
				"restart":
					if docker:
						b.add_child(_btn("Restart container", func(): cluster.act({"op": "restart", "ns": j["ns"], "kind": j["wkind"], "name": j["wname"], "pod": j["name"]}), "mk3"))
					elif w != null and cluster.cap("restart"):
						b.add_child(_btn("Rolling restart", func(): cluster.act({"op": "restart", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}), "mk3"))
				"delete_pod":
					b.add_child(_btn("Rebuild pod" if w != null else "Dismantle pod", func(): cluster.act({"op": "delete_pod", "ns": j["ns"], "name": j["name"]}), "mk4"))
				"uncordon":
					for n in cluster.state["nodes"]:
						if n["cordoned"] and cluster.cap("cordon"):
							b.add_child(_btn("Uncordon " + str(n["name"]).left(24), func(): cluster.act({"op": "cordon", "node": n["name"], "on": false}), "mk2"))
							break
		v.add_child(b)
		_dyn.add_child(pc)
	_dyn.add_child(_tier_legend())

# ----- Bob 2.0: the case file. He reads the pod's log and events and explains
# the lines that matter (scripts/bob.gd; optional settings in bob.json).

func open_bob_case(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	if p == null:
		notify("That machine is gone already", "warn")
		return
	var cfg = Bob.config()
	var body = _open_modal("bobcase", uid, "BOB  //  CASE FILE", Vector2(1080, 680))
	var h = _row(18)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left = _col(6)
	left.add_child(_bob_portrait())
	left.add_child(_lbl("BOB", 18, BOB_COL))
	left.add_child(_lbl("Reading the log", 12, DIM))
	left.add_child(_spacer())
	left.add_child(_btn("Back to the fix list", open_bob))
	left.add_child(_btn("Open the full log", func(): open_pod(uid)))
	h.add_child(left)
	var box = _col(8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(box)
	body.add_child(h)
	var head = _row(12)
	head.add_child(_lbl(p["name"], 18))
	head.add_child(_lbl(str(p["status"]), 15, K.health_color(p["health"])))
	head.add_child(_spacer())
	head.add_child(_lbl("%s  ·  %d restarts" % [p["ns"], p["restarts"]], 12, DIM))
	box.add_child(head)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dyn = _col(8)
	_dyn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_dyn)
	box.add_child(sc)
	_dyn.add_child(_lbl("Hold on. Let me find my place...", 15, BOB_COL))
	# the container that is in trouble (or the first one), its previous run if it has crashed before
	var cname = ""
	for c in p["containers"]:
		if cname == "" or not (c["state"] == "running" and c["ready"]):
			cname = c["name"]
			if not (c["state"] == "running" and c["ready"]):
				break
	var previous = cfg["previous"] and int(p["restarts"]) > 0 and p["health"] != "ok"
	_case = {"uid": uid, "cfg": cfg, "container": cname, "previous": previous, "log": null, "events": null}
	cluster.act({"op": "events", "ns": p["ns"], "name": p["name"], "key": "bob:%s:events" % uid})
	cluster.act({"op": "logs", "ns": p["ns"], "name": p["name"], "container": cname, "tail": cfg["tail"],
		"previous": previous, "key": "bob:%s:log" % uid})

func _on_case(key: String, text: String) -> void:
	var parts = key.split(":")
	if _modal_kind != "bobcase" or parts.size() < 3 or parts[1] != str(_case.get("uid", "")):
		return
	# no previous container to read (it never got far enough): fall back to the current one
	if parts[2] == "log" and _case["previous"] and text.contains("previous terminated container"):
		_case["previous"] = false
		var p = K.find_pod(cluster.state, _case["uid"])
		if p != null:
			cluster.act({"op": "logs", "ns": p["ns"], "name": p["name"], "container": _case["container"],
				"tail": _case["cfg"]["tail"], "key": "bob:%s:log" % _case["uid"]})
			return
	_case[parts[2]] = text
	if _case["log"] != null and _case["events"] != null:
		_fill_case()

func _fill_case() -> void:
	_clear(_dyn)
	var cfg = _case["cfg"]
	var compiled = Bob.compile(cfg)
	var found = Bob.review(_case["log"], "log", compiled) + Bob.review(_case["events"], "events", compiled)
	var ranked = Bob.rank(found, cfg["max_findings"])
	_say(_dyn, Bob.verdict(ranked), BOB_COL)
	var log_lines = str(_case["log"]).split("\n").size()
	var note = "Read %d log lines from container %s%s and %d event lines." % [log_lines, _case["container"],
		" (its previous run, the one that crashed)" if _case["previous"] else "", maxi(str(_case["events"]).split("\n").size() - 1, 0)]
	if compiled["bad"] > 0:
		note += "  %d rule(s) in bob.json were skipped: bad regex." % compiled["bad"]
	_dyn.add_child(_lbl(note, 12, DIM))
	for f in ranked:
		var col = K.health_color("bad") if f["weight"] >= 3 else (K.health_color("warn") if f["weight"] == 2 else DIM)
		var pc = PanelContainer.new()
		var sb = _sb(BG2, col, 0, 10)
		sb.border_width_left = 4
		pc.add_theme_stylebox_override("panel", sb)
		var v = _col(4)
		pc.add_child(v)
		var top = _row(10)
		top.add_child(_lbl("%s  line %d" % ["LOG" if f["source"] == "log" else "EVENTS", f["n"]], 13, col))
		top.add_child(_lbl(["", "symptom", "strong lead", "likely cause"][f["weight"]], 12, col))
		if f["count"] > 1:
			top.add_child(_lbl("seen %d times, this is the last" % f["count"], 12, DIM))
		if f["custom"]:
			top.add_child(_lbl("your rule", 12, DIM))
		v.add_child(top)
		var code = _lbl(f["line"], 13, Color(0.78, 0.86, 0.8))
		code.add_theme_font_override("font", _mono)
		code.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		code.custom_minimum_size.x = 740
		var cp = PanelContainer.new()
		cp.add_theme_stylebox_override("panel", _sb(Color(0.03, 0.035, 0.04), Color(0.25, 0.26, 0.28), 1, 8))
		cp.add_child(code)
		v.add_child(cp)
		for line in [[f["means"], TXT], [("Bob:  " + f["fix"]) if f["fix"] != "" else "", BOB_COL]]:
			if line[0] == "":
				continue
			var l = _lbl(line[0], 14, line[1])
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 740
			v.add_child(l)
		_dyn.add_child(pc)
	var hidden = found.size() - ranked.size()
	if hidden > 0:
		_dyn.add_child(_lbl("+ %d more kinds of line I did not bother you with (max_findings in bob.json)." % hidden, 12, DIM))

func _bob_goto(spot) -> void:
	if spot == null:
		notify("Nothing to walk to for that one", "warn")
		return
	close_modal()
	player.teleport(spot[0], spot[1])

func _portainer_installed() -> bool:
	for p in cluster.state["pods"]:
		if p["ns"] == "portainer" or p["name"] == "portainer":
			return true
	return false

func _portrait() -> Control:
	var model_view = _krew_portrait("porter", Color(0.05, 0.09, 0.11), false)
	if model_view != null:
		return model_view
	# a little robot face drawn from rectangles: hard hat, visor, blue overalls
	var c = Control.new()
	c.custom_minimum_size = Vector2(210, 230)
	var blue = Color(0.075, 0.745, 0.976)
	var parts = [[Rect2(0, 0, 210, 230), Color(0.05, 0.09, 0.11)], [Rect2(35, 150, 140, 80), blue],
		[Rect2(85, 165, 40, 28), Color(0.98, 0.8, 0.12)], [Rect2(55, 62, 100, 86), Color(0.58, 0.61, 0.65)],
		[Rect2(66, 86, 78, 24), Color(0.3, 0.95, 1.0)], [Rect2(84, 124, 42, 6), Color(0.2, 0.22, 0.25)],
		[Rect2(48, 30, 114, 36), Color(0.98, 0.8, 0.12)], [Rect2(34, 58, 142, 10), Color(0.98, 0.8, 0.12)],
		[Rect2(160, 6, 8, 60), Color(0.98, 0.8, 0.12)], [Rect2(120, 6, 48, 8), Color(0.98, 0.8, 0.12)],
		[Rect2(122, 14, 3, 18), Color(0.3, 0.3, 0.32)]]
	for p in parts:
		var r = ColorRect.new()
		r.color = p[1]
		r.position = p[0].position
		r.size = p[0].size
		c.add_child(r)
	return c

func _say(box: VBoxContainer, text: String, accent: Color = Color(0.075, 0.745, 0.976)) -> void:
	var pc = PanelContainer.new()
	var sb = _sb(accent.darkened(0.86), accent, 0, 14)
	sb.border_width_left = 4
	pc.add_theme_stylebox_override("panel", sb)
	var l = _lbl(text, 16)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 760
	pc.add_child(l)
	box.add_child(pc)
	# typewriter, so he "speaks" the line
	l.visible_ratio = 0.0
	l.create_tween().tween_property(l, "visible_ratio", 1.0, minf(1.2, text.length() * 0.012))

func _valid_ns(edit: LineEdit, warn: Label) -> String:
	var v = edit.text.strip_edges()
	if not K.valid_name(v):
		warn.text = "Use lowercase letters, digits and dashes."
		return ""
	return v

func open_talk(screen: String = "main") -> void:
	_talk["screen"] = screen
	var docker = cluster.backend != null and cluster.backend.label == "docker"
	var where = "Compose project" if docker else "namespace"
	if screen == "catalogue" and _talk["cat"].is_empty():
		screen = "lists"
		_talk["screen"] = screen
	var body = _open_modal("talk", null, "PORTER  //  PORTAINER DOCK", Vector2(1080, 640))
	var h = _row(18)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left = _col(6)
	left.add_child(_portrait())
	left.add_child(_lbl("PORTER", 18, Color(0.075, 0.745, 0.976)))
	left.add_child(_lbl("Container logistics", 12, DIM))
	left.add_child(_lbl("Portainer: %s" % ("installed" if _portainer_installed() else "not installed"), 12, K.health_color("ok") if _portainer_installed() else DIM))
	h.add_child(left)
	var box = _col(10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(box)
	body.add_child(h)
	var back = func(): open_talk("main")
	match screen:
		"main":
			_say(box, "Need something built? I do complete setups: the workloads, the services in front of them, storage and generated passwords. Tell me what you want and I will crane it onto the %s." % ("engine" if docker else "cluster"))
			box.add_child(_btn("Build me an app  (complete setup)", func(): open_talk("apps"), "mk2"))
			box.add_child(_btn("Show me the app lists  (Portainer templates and others)", func(): open_talk("lists"), "mk2"))
			box.add_child(_btn("What have you built for me?  (manage installs)", func(): open_talk("installed")))
			box.add_child(_btn("About Portainer itself  (optional)", func(): open_talk("portainer")))
			box.add_child(_btn("Never mind", close_modal))
		"apps":
			_say(box, "These are the setups I keep on the dock. Each one comes wired up and ready.")
			for app in Apps.APPS:
				var pc = PanelContainer.new()
				pc.add_theme_stylebox_override("panel", _sb(BG2, Color(0, 0, 0, 0), 0, 8))
				var r = _row(12)
				var v = _col(2)
				v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				v.add_child(_lbl(app["name"], 16, ORANGE))
				var d = _lbl(app["desc"], 13, DIM)
				d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				d.custom_minimum_size.x = 600
				v.add_child(d)
				r.add_child(v)
				r.add_child(_btn("Look closer", func():
					_talk["app"] = app["id"]
					open_talk("app")))
				pc.add_child(r)
				box.add_child(pc)
			box.add_child(_btn("Back", back))
		"app":
			var app = Apps.find(_talk["app"])
			_say(box, "%s. %s Here is everything I will set down:" % [app["name"], app["desc"]])
			for part in app["parts"]:
				box.add_child(_lbl("   ■  " + part, 14))
			if docker:
				box.add_child(_lbl("On a Docker engine this runs as a Compose project with named volumes.", 12, DIM))
			var r = _row(10)
			r.add_child(_lbl(where.to_upper(), 12, DIM))
			var ns = LineEdit.new()
			ns.text = app["id"]
			ns.custom_minimum_size.x = 260
			r.add_child(ns)
			var warn = _lbl("", 12, RED)
			r.add_child(warn)
			box.add_child(r)
			var b = _row(8)
			b.add_child(_btn("Deploy this setup", func():
				var v = _valid_ns(ns, warn)
				if v != "":
					cluster.act({"op": "apply_app", "id": app["id"], "ns": v})
					close_modal(), "mk2"))
			b.add_child(_btn("Remove this setup", func():
				var v = _valid_ns(ns, warn)
				if v != "":
					_confirm("Remove the %s setup from %s %s? Its workloads and services are deleted; volumes and the secret are kept." % [app["name"], where, v],
						func(): cluster.act({"op": "remove_app", "id": app["id"], "ns": v}), v), "mk5"))
			b.add_child(_spacer())
			b.add_child(_btn("Back", func(): open_talk("apps")))
			box.add_child(b)
		"portainer":
			if _portainer_installed():
				_say(box, "Portainer is running here. I can open its console for you. If you put its address and an API key in portainer.json, my template list comes straight from your Portainer instead of the public catalogue.")
				box.add_child(_btn("Open the Portainer console", func():
					cluster.act({"op": "portainer_open"})
					close_modal()))
			else:
				_say(box, "Portainer is optional. I work fine without it, but if you want its web console for this %s I can install the Community Edition for you." % ("engine" if docker else "cluster"))
				box.add_child(_lbl("   ■  " + ("Container  portainer  (portainer/portainer-ce:lts), console on https://localhost:9443, with access to the Docker socket" if docker else "Namespace  portainer,  Deployment + Service + volume from Portainer's official manifest"), 13))
				box.add_child(_btn("Install Portainer", func():
					cluster.act({"op": "portainer_install"})
					close_modal(), "mk2"))
			box.add_child(_btn("Back", back))
		"lists":
			var cats = Apps.load_catalogs()
			_say(box, "These are the app lists I can order from. Anything in Portainer's template format works, so hand me the address of another list and I will add it to the board.")
			var sc = ScrollContainer.new()
			sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
			sc.custom_minimum_size.y = 230
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			var rows = _col(4)
			rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sc.add_child(rows)
			box.add_child(sc)
			for cat in cats:
				var pc = PanelContainer.new()
				pc.add_theme_stylebox_override("panel", _sb(BG2, Color(0, 0, 0, 0), 0, 6))
				var r = _row(10)
				var loaded = _lists.get(cat["url"])
				r.add_child(_fixed(_lbl(cat["name"], 15, ORANGE), 210))
				r.add_child(_fixed(_lbl(cat["url"], 12, DIM), 400))
				r.add_child(_fixed(_lbl("%d apps" % loaded["templates"].size() if typeof(loaded) == TYPE_DICTIONARY else "", 12, K.health_color("ok")), 70))
				r.add_child(_spacer())
				r.add_child(_btn("Browse", func():
					_talk["cat"] = cat
					_talk["search"] = ""
					open_talk("catalogue"), "primary"))
				if not cat.get("builtin", false):
					r.add_child(_btn("Forget", func():
						cats.erase(cat)
						Apps.save_user_catalogs(cats)
						cluster.audit("removed app list %s" % cat["url"])
						open_talk("lists")))
				pc.add_child(r)
				rows.add_child(pc)
			box.add_child(_lbl("ADD A LIST", 12, DIM))
			var ar = _row(8)
			var an = LineEdit.new()
			an.placeholder_text = "name"
			an.custom_minimum_size.x = 170
			var au = LineEdit.new()
			au.placeholder_text = "https://.../templates.json   (Portainer app-template format)"
			au.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ar.add_child(an)
			ar.add_child(au)
			var aw = _lbl("", 12, RED)
			ar.add_child(_btn("Add", func():
				var url = au.text.strip_edges()
				var nm = an.text.strip_edges()
				if nm == "" or not (url.begins_with("https://") or url.begins_with("http://")):
					aw.text = "Give it a name and an http(s) address."
					return
				for c in cats:
					if c["url"] == url:
						aw.text = "That list is already on the board."
						return
				var cat = {"name": nm, "url": url, "builtin": false}
				cats.append(cat)
				Apps.save_user_catalogs(cats)
				cluster.audit("added app list %s (%s)" % [nm, url])
				_talk["cat"] = cat
				_talk["search"] = ""
				open_talk("catalogue"), "mk2"))
			box.add_child(ar)
			box.add_child(aw)
			box.add_child(_btn("Back", back))
		"installed":
			var mine = []
			for e in Apps.load_installed():
				if e.get("source", "") == cluster.state["source"] and e.get("context", "") == cluster.state["context"]:
					mine.append(e)
			_say(box, "Here is everything I have set down on this %s." % ("engine" if docker else "cluster") if mine.size() > 0 else "I have not built anything here yet.")
			var sc = ScrollContainer.new()
			sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
			sc.custom_minimum_size.y = 330
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			var rows = _col(4)
			rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sc.add_child(rows)
			box.add_child(sc)
			for e in mine:
				var pods = _installed_pods(e)
				var okc = 0
				for p in pods:
					if p["health"] == "ok":
						okc += 1
				var pc = PanelContainer.new()
				pc.add_theme_stylebox_override("panel", _sb(BG2, Color(0, 0, 0, 0), 0, 6))
				var r = _row(8)
				r.add_child(_fixed(_lbl(str(e.get("title", e["name"])), 15, ORANGE), 180))
				r.add_child(_fixed(_lbl("%s / %s" % [e["ns"], e["name"]], 13), 190))
				r.add_child(_fixed(_lbl(str(e.get("list", "")), 12, DIM), 130))
				r.add_child(_fixed(_lbl("%d/%d running" % [okc, pods.size()] if pods.size() > 0 else "not found", 13,
					K.health_color("ok" if pods.size() > 0 and okc == pods.size() else ("warn" if pods.size() > 0 else "bad"))), 100))
				r.add_child(_spacer())
				if pods.size() > 0:
					r.add_child(_btn("Go to", func():
						var spot = world.machine_spot(pods[0]["uid"])
						if spot != null:
							close_modal()
							player.teleport(spot[0], spot[1])))
					r.add_child(_btn("Logs", func(): open_logs(pods[0]["uid"])))
					r.add_child(_btn("Restart", func(): _installed_restart(e, pods), "mk3"))
					r.add_child(_btn("Remove", func(): _confirm("Remove %s (%s / %s)? Its containers are deleted; data volumes are kept." % [e.get("title", e["name"]), e["ns"], e["name"]],
						func(): cluster.act({"op": "remove_app", "id": e["id"], "ns": e["ns"]} if e["kind"] == "app" else {"op": "remove_template", "name": e["name"], "ns": e["ns"]}), e["name"]), "mk5"))
				else:
					r.add_child(_btn("Forget", func():
						_installed_forget(e)
						open_talk("installed")))
				pc.add_child(r)
				rows.add_child(pc)
			box.add_child(_btn("Back", back))
		"catalogue":
			var cat = _talk["cat"]
			var data = _lists.get(cat["url"])
			if typeof(data) != TYPE_DICTIONARY:
				var err = str(data) if data != null else ""
				_say(box, ("Radioing %s..." % cat["name"]) if err == "" else "I could not read that list. " + err.left(220))
				if err == "" and _tpl_key == "":
					_tpl_key = "tpl/%d" % Time.get_ticks_msec()
					_tpl_url = cat["url"]
					cluster.act({"op": "templates", "catalog": cat, "key": _tpl_key})
				if err != "":
					box.add_child(_btn("Try again", func():
						_lists.erase(cat["url"])
						open_talk("catalogue")))
				box.add_child(_btn("Back", func(): open_talk("lists")))
			else:
				var _templates = data
				_say(box, "%s: %d container apps%s. Pick one and I will build it with its ports, settings and storage." % [cat["name"], data["templates"].size(),
					(" (%d stack templates skipped, those need Portainer itself)" % data["skipped"]) if int(data.get("skipped", 0)) > 0 else ""])
				var search = LineEdit.new()
				search.placeholder_text = "search templates..."
				search.text = _talk["search"]
				box.add_child(search)
				var sc = ScrollContainer.new()
				sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
				sc.custom_minimum_size.y = 330
				sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				var list = _col(4)
				list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sc.add_child(list)
				box.add_child(sc)
				var fill = func(needle: String):
					_clear(list)
					var shown = 0
					for t in _templates["templates"]:
						var title = str(t.get("title", ""))
						if needle != "" and not (title + " " + str(t.get("description", ""))).to_lower().contains(needle.to_lower()):
							continue
						shown += 1
						if shown > 120:
							list.add_child(_lbl("... more apps match; type in the search box to narrow it down", 12, DIM))
							break
						var pc = PanelContainer.new()
						pc.add_theme_stylebox_override("panel", _sb(BG2, Color(0, 0, 0, 0), 0, 6))
						var r = _row(10)
						r.add_child(_fixed(_lbl(title, 15, ORANGE), 190))
						r.add_child(_fixed(_lbl(str(t.get("description", "")), 13, DIM), 330))
						r.add_child(_fixed(_lbl(str(t.get("image", "")), 12, DIM), 190))
						r.add_child(_spacer())
						r.add_child(_btn("Pick", func():
							_talk["tpl"] = t
							open_talk("tpl")))
						pc.add_child(r)
						list.add_child(pc)
				fill.call(_talk["search"])
				search.text_changed.connect(func(v):
					_talk["search"] = v
					fill.call(v))
				box.add_child(_btn("Back", func(): open_talk("lists")))
		"tpl":
			var t = _talk["tpl"]
			_say(box, "%s: %s" % [t.get("title", ""), t.get("description", "")])
			var g = GridContainer.new()
			g.columns = 2
			g.add_theme_constant_override("h_separation", 10)
			_kv(g, "IMAGE", str(t.get("image", "")))
			var ports = []
			for p in t.get("ports", []):
				ports.append(str(p))
			_kv(g, "PORTS", ", ".join(PackedStringArray(ports)) if ports.size() > 0 else "-")
			var envinfo = Apps.template_env(t)
			var envs = []
			for e in envinfo[0]:
				envs.append(e[0] + (" (generated)" if envinfo[1].has(e[0]) else ""))
			_kv(g, "SETTINGS", ", ".join(PackedStringArray(envs)) if envs.size() > 0 else "-")
			var vols = []
			var binds = []
			for v in t.get("volumes", []):
				if v.has("bind"):
					binds.append(str(v["bind"]))
				else:
					vols.append(str(v.get("container", "")))
			_kv(g, "STORAGE", ", ".join(PackedStringArray(vols)) if vols.size() > 0 else "-")
			box.add_child(g)
			var allow_binds = CheckBox.new()
			allow_binds.visible = false
			if binds.size() > 0:
				var bw = _lbl("Heads up: this template asks to mount host paths (%s). %s" % [", ".join(PackedStringArray(binds)),
					"They are left out unless you tick the box below. Mounting them gives the container access to those paths; the Docker socket means control of the whole engine." if docker else "Those are skipped on Kubernetes, so it may not work there."], 13, K.health_color("warn"))
				bw.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				bw.custom_minimum_size.x = 760
				box.add_child(bw)
				if docker:
					allow_binds.text = "Mount these host paths (I trust this template)"
					allow_binds.focus_mode = Control.FOCUS_NONE
					allow_binds.visible = true
			box.add_child(allow_binds)
			if not docker:
				box.add_child(_lbl("On Kubernetes I build it as a Deployment plus a Service; its storage is scratch space (emptyDir).", 12, DIM))
			var r = _row(10)
			r.add_child(_lbl("NAME", 12, DIM))
			var nm = LineEdit.new()
			nm.text = Apps.slug(str(t.get("title", "app")))
			nm.custom_minimum_size.x = 220
			r.add_child(nm)
			var ns = LineEdit.new()
			ns.text = "apps"
			ns.custom_minimum_size.x = 180
			if not docker:
				r.add_child(_lbl("NAMESPACE", 12, DIM))
				r.add_child(ns)
			var warn = _lbl("", 12, RED)
			r.add_child(warn)
			box.add_child(r)
			var b = _row(8)
			b.add_child(_btn("Build it", func():
				var n = _valid_ns(nm, warn)
				var s = _valid_ns(ns, warn)
				if n != "" and s != "":
					cluster.act({"op": "deploy_template", "template": t, "name": n, "ns": s, "list": str(_talk["cat"].get("name", "")), "host_binds": allow_binds.button_pressed})
					close_modal(), "mk2"))
			b.add_child(_spacer())
			b.add_child(_btn("Back", func(): open_talk("catalogue")))
			box.add_child(b)

# ----- settings + first-run welcome

func _save_setting(key: String, value) -> void:
	settings[key] = value
	K.save_settings(settings)

func open_welcome() -> void:
	var body = _open_modal("welcome", null, "WELCOME TO KUBEFACTORY", Vector2(900, 560))
	var intro = _lbl("Your cluster is a factory. Walk it, spot what is broken, and fix it with the tool belt.", 16)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 850
	body.add_child(intro)
	var g = GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 18)
	g.add_theme_constant_override("v_separation", 6)
	for row in [["Platforms", "nodes. The gantry sign shows status, CPU and memory."],
			["Machines", "pods. Green screen = healthy; a red light column = failing."],
			["Depots and belts", "services and the pods they route to."],
			["The HUB", "cluster overview. Beside it: cluster gates, the Logging Station and Porter."],
			["WASD / Shift / Space", "move, sprint, jump. Double-tap Space for the hoverpack."],
			["1-6 or mouse wheel", "pick a tool. Higher Mk = more destructive = longer hold."],
			["E", "inspect or talk.    Q  build menu.    L  log datapad.    Tab  cluster codex."],
			["G", "jump to the next problem.    Esc  menu and settings."]]:
		g.add_child(_fixed(_lbl(row[0], 14, ORANGE), 200))
		g.add_child(_lbl(row[1], 14))
	body.add_child(g)
	body.add_child(_tier_legend())
	var note = _lbl("You are signed in as %s. Tools above your allowed tier are locked; every change is written to the audit log." % cluster.display_name(), 13, DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 850
	body.add_child(note)
	body.add_child(_spacer())
	body.add_child(_btn("Start" if not offer_demos else "Next: choose a demo", func():
		_save_setting("welcomed", true)
		if offer_demos:
			open_demos()
		else:
			close_modal(), "primary"))

# ----- graphics presets (scripts/gfx.gd). They change how the world is drawn,
# never what you can do in it.

func open_graphics() -> void:
	var body = _open_modal("graphics", null, "GRAPHICS", Vector2(820, 520))
	var rec = Gfx.recommend()
	var intro = _lbl("Three presets on the same world. Every tool, panel and action works identically on all of them; Standard is the look the game has always had and nothing is ever drawn below it.", 14, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 780
	body.add_child(intro)
	for lv in 3:
		var active = Gfx.level == lv
		var pc = PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _sb(BG2, ORANGE if active else Color(0, 0, 0, 0), 1 if active else 0, 10))
		var r = _row(12)
		var v = _col(2)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var head = _row(10)
		head.add_child(_lbl(Gfx.NAMES[lv].to_upper(), 17, ORANGE if active else TXT))
		if rec["level"] == lv:
			head.add_child(_lbl("recommended for this machine", 12, K.health_color("ok")))
		v.add_child(head)
		v.add_child(_lbl(Gfx.BLURB[lv], 13, DIM))
		r.add_child(v)
		if active and Gfx.chosen != "auto":
			r.add_child(_lbl("IN USE   ", 14, K.health_color("ok")))
		else:
			r.add_child(_btn("In use (automatic) - pin it" if active else "Use", func():
				graphics_requested.emit(Gfx.id_of(lv))
				open_graphics(), "primary" if not active else "normal"))
		pc.add_child(r)
		body.add_child(pc)
	var auto = _row(10)
	auto.add_child(_btn("Automatic: follow the recommendation", func():
		graphics_requested.emit("auto")
		open_graphics(), "normal", Gfx.chosen != "auto"))
	auto.add_child(_spacer())
	auto.add_child(_btn("Back", open_pause))
	body.add_child(auto)
	var hw = _lbl("Detected: %s%s. Changing preset rebuilds the scenery in place; the cluster connection, your position and open work are not affected." % [rec["gpu"], (" - " + rec["why"]) if rec["why"] != "" else ""], 12, DIM)
	hw.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hw.custom_minimum_size.x = 780
	body.add_child(hw)

# ----- pause menu

func open_pause() -> void:
	var body = _open_modal("pause", null, "KUBEFACTORY  %s" % version, Vector2(480, 540))
	body.add_child(_btn("Resume", close_modal, "primary"))
	if touch != null:
		body.add_child(_btn("Touch controls:  %s" % ("ON" if touch.allowed else "OFF"), func():
			touch.set_allowed(not touch.allowed)
			open_pause()))
		if touch.active:
			var sr = _row(8)
			sr.add_child(_lbl("Look sensitivity  %d%%" % int(round(touch.sensitivity * 100.0)), 14))
			sr.add_child(_spacer())
			sr.add_child(_btn("  -  ", func():
				touch.sensitivity = clampf(touch.sensitivity - 0.2, 0.4, 2.6)
				open_pause()))
			sr.add_child(_btn("  +  ", func():
				touch.sensitivity = clampf(touch.sensitivity + 0.2, 0.4, 2.6)
				open_pause()))
			body.add_child(sr)
			var th = _lbl("Left thumb: move.  Drag the view: look.  ACTION: what the crosshair offers (hold it for a tool's action).  JUMP twice: hoverpack.  AIM: face the nearest machine ahead.", 12, DIM)
			th.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			th.custom_minimum_size.x = 440
			body.add_child(th)
	body.add_child(_lbl("CONNECTED TO  %s  ·  %s" % [cluster.state.get("provider", ""), cluster.state["context"]], 13, DIM))
	body.add_child(_btn("Switch cluster  (AWS / Azure / GCP / Rancher / Docker ...)", open_clusters))
	body.add_child(_btn("Demo worlds  (Kubernetes / Home Assistant / Dev containers / Media)", open_demos))
	body.add_child(_btn("Minimap:  %s   (N)" % ("ON" if bool(settings.get("minimap", true)) else "OFF"), func():
		toggle_minimap()
		open_pause()))
	body.add_child(_btn("Krew operations  (K)", func(): open_krew()))
	body.add_child(_btn("Foreman  (H)", func(): open_foreman()))
	body.add_child(_btn("Gauge  (resource desk)", open_gauge))
	body.add_child(_btn("Gauge in the world:  %s" % ("ON" if world._gauge.visible else "OFF"), func():
		var show = not world._gauge.visible
		world.set_gauge_visible(show)
		_save_setting("gauge_visible", show)
		open_pause()))
	body.add_child(_btn("Logging station  (L)", func(): open_logs()))
	body.add_child(_btn("LiveView: applications on screens  (V)", open_liveview))
	body.add_child(_btn("Read-only mode:  %s" % ("ON" if cluster.read_only else "OFF"), func():
		cluster.read_only = not cluster.read_only
		on_state(cluster.state)
		open_pause()))
	if not Gfx.lite():
		body.add_child(_btn("Graphics  (%s)" % (Gfx.NAMES[Gfx.level] + (", automatic" if Gfx.chosen == "auto" else "")), open_graphics))
	body.add_child(_btn("Conveyor belts:  %s" % ("ON" if world.show_belts else "OFF"), func():
		world.show_belts = not world.show_belts
		world.apply_state(cluster.state)
		_save_setting("belts", world.show_belts)
		open_pause()))
	body.add_child(_btn("Sound:  %s   (M)" % ("OFF" if sfx.muted else "ON"), func():
		sfx.set_muted(not sfx.muted)
		_save_setting("muted", sfx.muted)
		open_pause()))
	body.add_child(_btn("Toggle fullscreen  (F11)", func():
		var w = get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		_save_setting("fullscreen", w.mode == Window.MODE_FULLSCREEN)))
	var sr = _row(10)
	sr.add_child(_lbl("MOUSE SENSITIVITY", 12, DIM))
	var sl = HSlider.new()
	sl.min_value = 0.3
	sl.max_value = 3.0
	sl.step = 0.05
	sl.value = player.sensitivity
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.focus_mode = Control.FOCUS_NONE
	var sv = _lbl("%.2f" % player.sensitivity, 13)
	sl.value_changed.connect(func(v):
		player.sensitivity = v
		sv.text = "%.2f" % v
		_save_setting("sensitivity", v))
	sr.add_child(sl)
	sr.add_child(sv)
	body.add_child(sr)
	body.add_child(_btn("How to play", open_welcome))
	body.add_child(_spacer())
	body.add_child(_btn("Quit to desktop", func(): get_tree().quit(), "danger"))

# ----- LiveView providers: Grafana and Tautulli (scripts/providers.gd, agent/providers.go)
#
# Setting one up, choosing a dashboard or panel, and the media activity panel.
# A token typed here goes straight to the companion and is not kept by the game.

var providers: Node = null       # set by main
var _prov_list = []
var _prov_cur = {}

func _prov_fail(r: Dictionary) -> String:
	return "%s: %s" % [Agent.kind_title(str(r.get("kind", "other"))), str(r.get("msg", "failed"))]

func open_providers(msg: String = "", ok: bool = true) -> void:
	var body = _open_modal("providers", null, "LIVEVIEW  //  GRAFANA AND TAUTULLI", Vector2(1060, 660))
	var intro = _lbl("Point KubeFactory at a Grafana or Tautulli you already run. Dashboards and panels open as the real pages, in a private browser where you sign in yourself. An API token is only used to list dashboards and read activity; it is kept by this computer's own protected storage and never shown again.", 13, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 1010
	body.add_child(intro)
	if providers == null or not providers.available():
		var l = _lbl("Providers are not available here. " + Agent.why_unavailable(), 15, K.health_color("warn"))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 1010
		body.add_child(l)
		return
	_dyn = _col(6)
	_dyn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_dyn)
	_dyn.add_child(_lbl("Reading...", 13, DIM))
	providers.ask("provider.list", {}, func(r):
		if _modal_kind != "providers":
			return
		_clear(_dyn)
		if msg != "":
			var ml = _lbl(msg, 14, K.health_color("ok") if ok else K.health_color("warn"))
			ml.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ml.custom_minimum_size.x = 1010
			_dyn.add_child(ml)
		if not r["ok"]:
			_dyn.add_child(_lbl(_prov_fail(r), 14, RED))
			return
		_prov_list = r["data"].get("providers", [])
		var top = _row(8)
		top.add_child(_btn("Add Grafana", func(): _provider_form("grafana", {}), "primary"))
		top.add_child(_btn("Add Tautulli", func(): _provider_form("tautulli", {}), "primary"))
		top.add_child(_spacer())
		top.add_child(_btn("Back to LiveView", func(): open_liveview()))
		_dyn.add_child(top)
		if not bool(r["data"].get("can_store_tokens", false)):
			_dyn.add_child(_lbl("This system has no protected storage KubeFactory can use, so tokens cannot be saved here.", 13, K.health_color("warn")))
		_dyn.add_child(_lbl("YOUR PROVIDERS", 13, ORANGE))
		if _prov_list.is_empty():
			_dyn.add_child(_lbl("None yet.", 14, DIM))
		for p in _prov_list:
			var row = _row(8)
			row.add_child(_fixed(_lbl(str(p["name"]), 15), 230))
			var info = "%s   ·   %s   ·   %s" % ["Grafana" if p["type"] == "grafana" else "Tautulli", str(p["base_url"]), "token saved" if p["has_token"] else "no token"]
			if bool(p.get("plain_http", false)):
				info += "   ·   plain http"
			var il = _lbl(info, 12, DIM)
			il.clip_text = true
			il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(il)
			if p["type"] == "grafana":
				row.add_child(_btn("Dashboards", func(): open_grafana(p), "primary"))
			else:
				row.add_child(_btn("Activity", func(): open_tautulli(p), "primary"))
			row.add_child(_btn("Open", func(): _provider_open_ui(p)))
			row.add_child(_btn("Test", func(): _provider_test(p)))
			row.add_child(_btn("Edit", func(): _provider_form(str(p["type"]), p)))
			row.add_child(_btn("Remove", func():
				providers.ask("provider.remove", {"id": p["id"]}, func(_r): open_providers("%s removed. Its token is gone with it." % p["name"])), "danger"))
			_dyn.add_child(row)
		# machines that run one of the two: a suggestion, confirmed by you in the form
		var src = cluster.backend.label if cluster.backend != null else ""
		var cands = providers.candidates(cluster.state, src) if src != "simulation" else []
		if not cands.is_empty():
			_dyn.add_child(_lbl("FOUND RUNNING HERE  (by the image it runs; nothing has been contacted)", 13, ORANGE))
		for c in cands:
			var row = _row(8)
			row.add_child(_fixed(_lbl("%s/%s" % [c["ns"], c["name"]], 14), 420))
			row.add_child(_lbl(str(c["url"]) if c["url"] != "" else "address not known: open it from LiveView's endpoint list, or type its address", 12, DIM))
			row.add_child(_spacer())
			row.add_child(_btn("Set up", func(): _provider_form(str(c["type"]), {}, str(c["url"]))))
			_dyn.add_child(row)
		if src == "simulation":
			_dyn.add_child(_lbl("This is a simulated cluster: its Grafana and Tautulli machines are not real applications. A provider you add here still talks to a real one.", 13, DIM)))

func _provider_test(p: Dictionary) -> void:
	open_providers("Testing %s..." % p["name"])
	providers.ask("provider.test", {"id": p["id"]}, func(r):
		if _modal_kind != "providers":
			return
		if r["ok"]:
			var d = r["data"]
			open_providers("%s: this is %s%s. Token: %s." % [p["name"], d["app"], (" " + str(d["version"])) if str(d.get("version", "")) != "" else "", d["token"]])
		else:
			open_providers("%s: %s" % [p["name"], _prov_fail(r)], false))

func _provider_form(type: String, p: Dictionary, prefill_url: String = "") -> void:
	var title = "Grafana" if type == "grafana" else "Tautulli"
	var body = _open_modal("providerform", null, "LIVEVIEW  //  %s %s" % ["EDIT" if not p.is_empty() else "ADD", title.to_upper()], Vector2(820, 520))
	var mk = func(caption: String, text: String, hint: String, secret: bool) -> LineEdit:
		var r = _row(8)
		r.add_child(_fixed(_lbl(caption, 13, DIM), 130))
		var e = LineEdit.new()
		e.text = text
		e.placeholder_text = hint
		e.secret = secret
		e.custom_minimum_size.x = 600
		r.add_child(e)
		body.add_child(r)
		return e
	var name_e: LineEdit = mk.call("NAME", str(p.get("name", "")), "what to call it (optional)", false)
	var url_e: LineEdit = mk.call("ADDRESS", str(p.get("base_url", prefill_url)), "https://grafana.example.org/grafana" if type == "grafana" else "https://tautulli.example.org", false)
	var tok_e: LineEdit = mk.call("TOKEN" if type == "grafana" else "API KEY", "", "saved: leave empty to keep it" if bool(p.get("has_token", false)) else ("a service account token with Viewer rights" if type == "grafana" else "Tautulli > Settings > Web Interface > API key"), true)
	var help = _lbl("Grafana: Administration > Users and access > Service accounts > add one with the Viewer role > add a token. It is used only to list dashboards and panels; the pages themselves use your own sign-in." if type == "grafana"
		else "The key is used for one read-only request: current activity as totals. Nothing about who is watching what is read or shown. Tautulli keys are powerful, so it never leaves this computer's companion.", 12, DIM)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size.x = 770
	body.add_child(help)
	var allow_http = [bool(p.get("allow_http", false))]
	var legacy = [bool(p.get("legacy_query_key", false))]
	body.add_child(_check("Accept plain http to another computer (the token travels unprotected: only on a network you trust)", allow_http[0], func(on): allow_http[0] = on))
	if type == "tautulli":
		body.add_child(_check("Old Tautulli (before 2.18): send the key in the address instead of a header (it can end up in that server's logs)", legacy[0], func(on): legacy[0] = on))
	var status = _lbl("", 13, RED)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 770
	body.add_child(status)
	var bar = _row(8)
	bar.add_child(_btn("Save and test", func():
		var args = {"id": str(p.get("id", "")), "type": type, "name": name_e.text.strip_edges(), "base_url": url_e.text.strip_edges(),
			"token": tok_e.text, "allow_http": allow_http[0], "legacy_query_key": legacy[0]}
		tok_e.text = ""        # the game keeps no copy
		status.text = "Saving..."
		providers.ask("provider.save", args, func(r):
			if _modal_kind != "providerform":
				return
			if not r["ok"]:
				status.text = _prov_fail(r)
				return
			_provider_test(r["data"])), "primary"))
	bar.add_child(_btn("Cancel", func(): open_providers()))
	body.add_child(bar)

# The provider's own web interface on a display.
func _provider_open_ui(p: Dictionary) -> void:
	providers.ask("provider.link", {"id": p["id"]}, func(r):
		if r["ok"]:
			_provider_show(str(r["data"]["url"]), str(p["name"]), str(p["type"]))
		else:
			open_providers(_prov_fail(r), false))

# Open a provider page through LiveView, tied to the machine that runs the
# application (when there is one) so it can go on that machine's screen.
func _provider_show(url: String, title: String, type: String) -> void:
	var s = live.open(url, title)
	var src = cluster.backend.label if cluster.backend != null else ""
	for c in providers.candidates(cluster.state, src):
		if c["type"] == type:
			s["target"] = {"ns": c["ns"], "service": c["pod"]}
			break
	open_live(s)

# ---- Grafana: dashboards, then panels

func open_grafana(p: Dictionary, query: String = "") -> void:
	_prov_cur = p
	var body = _open_modal("grafana", null, "GRAFANA  //  %s" % p["name"], Vector2(1000, 660))
	var sr = _row(8)
	var q = LineEdit.new()
	q.text = query
	q.placeholder_text = "find a dashboard"
	q.custom_minimum_size.x = 520
	q.text_submitted.connect(func(t): open_grafana(p, t))
	sr.add_child(q)
	sr.add_child(_btn("Search", func(): open_grafana(p, q.text), "primary"))
	sr.add_child(_spacer())
	sr.add_child(_btn("Providers", func(): open_providers()))
	body.add_child(sr)
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	list.add_child(_lbl("Reading...", 13, DIM))
	providers.ask("grafana.dashboards", {"id": p["id"], "query": query, "page": 1}, func(r):
		if _modal_kind != "grafana":
			return
		_clear(list)
		if not r["ok"]:
			var l = _lbl(_prov_fail(r), 14, RED)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 940
			list.add_child(l)
			return
		var ds = r["data"].get("dashboards", [])
		var more = bool(r["data"].get("more", false))
		var rows_box = _col(4)
		var gd_fill = func():
			_clear(rows_box)
			var shown = _table_rows("grafana", ds, {"title": func(d): return d["title"], "folder": func(d): return str(d.get("folder", ""))})
			if shown.is_empty():
				rows_box.add_child(_lbl("No dashboard matches, or the token may not see any." if ds.is_empty() else "No dashboard here contains that.", 14, DIM))
			for d in shown:
				var row = _row(8)
				row.add_child(_fixed(_lbl(str(d["title"]), 15), 480))
				row.add_child(_fixed(_lbl(str(d.get("folder", "")), 12, DIM), 220))
				row.add_child(_spacer())
				row.add_child(_btn("Panels", func(): open_grafana_panels(p, d)))
				row.add_child(_btn("Open dashboard", func(): _grafana_open(p, d, 0, "", {}), "primary"))
				rows_box.add_child(row)
			if more:
				rows_box.add_child(_lbl("More than 100 match: narrow the search.", 12, DIM))
		list.add_child(_table_head("grafana", [["title", "DASHBOARD", 480], ["folder", "FOLDER", 220]], gd_fill, ds.size()))
		list.add_child(rows_box)
		gd_fill.call())

const GRAFANA_RANGES = [["the dashboard's own range", ""], ["last hour", "now-1h"], ["last 6 hours", "now-6h"], ["last 24 hours", "now-24h"], ["last 7 days", "now-7d"]]

func open_grafana_panels(p: Dictionary, dash: Dictionary) -> void:
	var body = _open_modal("grafana", null, "GRAFANA  //  %s" % dash["title"], Vector2(1000, 660))
	var top = _row(8)
	top.add_child(_lbl("TIME RANGE", 12, DIM))
	var range_pick = OptionButton.new()
	for g in GRAFANA_RANGES:
		range_pick.add_item(g[0])
	top.add_child(range_pick)
	top.add_child(_spacer())
	top.add_child(_btn("Dashboards", func(): open_grafana(p)))
	body.add_child(top)
	var var_box = _col(4)
	body.add_child(var_box)
	var var_edits = {}
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	list.add_child(_lbl("Reading...", 13, DIM))
	var open = func(panel: int):
		var vars = {}
		for k in var_edits:
			if var_edits[k].text.strip_edges() != "":
				vars[k] = var_edits[k].text.strip_edges()
		_grafana_open(p, dash, panel, GRAFANA_RANGES[range_pick.selected][1], vars)
	providers.ask("grafana.panels", {"id": p["id"], "uid": dash["uid"]}, func(r):
		if _modal_kind != "grafana":
			return
		_clear(list)
		if not r["ok"]:
			var l = _lbl(_prov_fail(r), 14, RED)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 940
			list.add_child(l)
			return
		var d = r["data"]
		# the dashboard's own variables: set by you, never guessed from a workload's name
		for v in d.get("variables", []):
			var vr = _row(8)
			vr.add_child(_fixed(_lbl("VARIABLE  " + str(v), 12, DIM), 260))
			var e = LineEdit.new()
			e.placeholder_text = "leave empty for the dashboard's default"
			e.custom_minimum_size.x = 400
			vr.add_child(e)
			var_box.add_child(vr)
			var_edits[str(v)] = e
		var whole = _row(8)
		whole.add_child(_fixed(_lbl("The whole dashboard", 15), 480))
		whole.add_child(_spacer())
		whole.add_child(_btn("Open", func(): open.call(0), "primary"))
		list.add_child(whole)
		if not bool(d.get("panels_readable", true)):
			var l = _lbl("This dashboard is in a layout whose panels KubeFactory cannot list. Nothing is made up: open the whole dashboard instead.", 13, K.health_color("warn"))
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 940
			list.add_child(l)
		var pns: Array = d.get("panels", [])
		var prow_box = _col(4)
		var gp_fill = func():
			_clear(prow_box)
			for pn in _table_rows("grafana-panels", pns, {"title": func(x): return x["title"], "type": func(x): return x["type"], "row": func(x): return str(x.get("row", ""))}):
				var row = _row(8)
				row.add_child(_fixed(_lbl(str(pn["title"]) if str(pn["title"]) != "" else "(untitled panel %d)" % int(pn["id"]), 14), 480))
				row.add_child(_fixed(_lbl(str(pn["type"]), 12, DIM), 140))
				row.add_child(_fixed(_lbl(str(pn.get("row", "")), 12, DIM), 180))
				row.add_child(_spacer())
				row.add_child(_btn("Open panel", func(): open.call(int(pn["id"]))))
				prow_box.add_child(row)
		if not pns.is_empty():
			list.add_child(_table_head("grafana-panels", [["title", "PANEL", 480], ["type", "TYPE", 140], ["row", "ROW", 180]], gp_fill, pns.size()))
		list.add_child(prow_box)
		gp_fill.call())

func _grafana_open(p: Dictionary, dash: Dictionary, panel: int, from: String, vars: Dictionary) -> void:
	var args = {"id": p["id"], "uid": dash["uid"], "panel": panel, "vars": vars}
	if from != "":
		args["from"] = from
		args["to"] = "now"
	providers.ask("grafana.link", args, func(r):
		if r["ok"]:
			_provider_show(str(r["data"]["url"]), "%s  ·  %s" % [p["name"], dash["title"]], "grafana")
		else:
			open_providers(_prov_fail(r), false))

# ---- Tautulli: media activity as totals

func open_tautulli(p: Dictionary) -> void:
	_prov_cur = p
	var body = _open_modal("tautulli", null, "TAUTULLI  //  %s" % p["name"], Vector2(900, 620))
	var note = _lbl("Plex activity as Tautulli reports it, as totals only. No user, address or title is read. This is monitoring, not playback.", 13, DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 850
	body.add_child(note)
	_dyn = _col(6)
	_dyn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_dyn)
	_dyn.add_child(_lbl("Reading...", 13, DIM))
	_tautulli_read(p)

func _tautulli_read(p: Dictionary) -> void:
	providers.ask("tautulli.activity", {"id": p["id"]}, _tautulli_fill.bind(p))

func _tautulli_tick(p: Dictionary) -> void:
	if _modal_kind == "tautulli" and _prov_cur.get("id") == p["id"]:
		_tautulli_read(p)

func _tautulli_fill(r: Dictionary, p: Dictionary) -> void:
	if true:
		if _modal_kind != "tautulli" or _prov_cur.get("id") != p["id"]:
			return
		_clear(_dyn)
		if r["ok"]:
			var d = r["data"]
			var grid = GridContainer.new()
			grid.columns = 2
			grid.add_theme_constant_override("h_separation", 60)
			for row in providers.summary_lines(d):
				grid.add_child(_lbl(row[0], 15, DIM))
				grid.add_child(_lbl(row[1], 20, TXT if row[1] != "unavailable" else DIM))
			_dyn.add_child(grid)
			_dyn.add_child(_lbl("Source: %s (Tautulli)   ·   read at %s UTC   ·   refreshes every 10 s while this is open" % [p["name"], str(d["at"]).get_slice("T", 1).trim_suffix("Z")], 12, DIM))
		else:
			var l = _lbl(_prov_fail(r), 14, RED)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 850
			_dyn.add_child(l)
		var bar = _row(8)
		bar.add_child(_btn("Refresh", func(): _tautulli_read(p)))
		bar.add_child(_btn("Open Tautulli", func(): _provider_open_ui(p)))
		bar.add_child(_spacer())
		bar.add_child(_btn("Providers", func(): open_providers()))
		_dyn.add_child(bar)
		# pin the summary to a machine that runs Plex or Tautulli
		_dyn.add_child(_lbl("ON A MACHINE'S SCREEN", 13, ORANGE))
		var media = providers.media_machines(cluster.state)
		if media.is_empty():
			_dyn.add_child(_lbl("No Plex or Tautulli machine in this world to put it on.", 13, DIM))
		for m in media:
			var uid = str(m["uid"])
			var row = _row(8)
			row.add_child(_fixed(_lbl("%s/%s" % [m["ns"], m["name"]], 14), 480))
			row.add_child(_spacer())
			if providers.pins.has(uid):
				row.add_child(_btn("Take it off", func():
					providers.unpin(uid)
					_tautulli_read(p)))
			else:
				row.add_child(_btn("Show activity on its screen", func():
					if not providers.pin(uid, p):
						notify("That machine has no screen to show it on.", "warn")
					_tautulli_read(p), "primary", r["ok"]))
			_dyn.add_child(row)
		get_tree().create_timer(10.0).timeout.connect(_tautulli_tick.bind(p))

# ----- a machine's screen, opened large (scripts/machine_screens.gd, demo_screens.gd)
#
# The same four views the screen itself steps through with R: the application's
# dashboard, the pod's metrics, its log and its storage. Choosing one here
# changes what the machine shows too.

const Icons = preload("res://scripts/icons.gd")

var demo_screens: Node = null     # set by main
var screens: Node = null          # set by main

# A button big enough for a finger, when the touch controls are on.
func _touch_size(b: Button) -> Button:
	if touch_u > 0.0:
		b.custom_minimum_size = Vector2(touch_u * 1.7, touch_u * 0.9)
		b.add_theme_font_size_override("font_size", int(touch_u * 0.27))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b

func open_demo_screen(uid: String) -> void:
	open_screen(uid)

func open_screen(uid: String) -> void:
	var p = K.find_pod(cluster.state, uid)
	if p == null or screens == null:
		open_liveview()
		return
	var mode: String = screens.mode_of(uid)
	var tvp = get_viewport().get_visible_rect().size
	var body = _open_modal("screen", uid, "SCREEN  //  " + str(p["name"]), Vector2(1180, 860) if touch_u <= 0.0 else Vector2(maxf(tvp.x * 0.94, 600.0), maxf(tvp.y * 0.9, 500.0)))
	var head = _row(10)
	var ic = TextureRect.new()
	ic.texture = Icons.texture(Icons.kind_of(p))
	ic.custom_minimum_size = Vector2(36, 36)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(ic)
	head.add_child(_lbl("%s   ·   %s   ·   %s" % [Icons.label_of(Icons.kind_of(p)), p["ns"], p["status"]], 13, DIM))
	head.add_child(_spacer())
	var tabs = head
	if touch_u > 0.0:
		# on a phone the tabs get a row of their own, each a full finger wide
		body.add_child(head)
		tabs = _row(int(touch_u * 0.2))
	for m in screens.MODES:
		tabs.add_child(_touch_size(_btn(str(screens.TITLES[m]), func():
			screens.set_mode(uid, m)
			open_screen(uid), "primary" if m == mode else "normal")))
	body.add_child(tabs)
	if mode != "dashboard":
		var bar = _row(8)
		bar.add_child(_lbl({"metrics": "This pod's own state, as the cluster reports it.", "logs": "The end of its log; it refreshes while this view is up.", "storage": "What is mounted into it."}[mode], 13, DIM))
		bar.add_child(_spacer())
		if mode == "logs":
			bar.add_child(_btn("Open the full log", func(): open_logs(uid)))
		elif mode == "storage":
			bar.add_child(_btn("Browse the files", func(): storage_requested.emit(uid)))
		elif mode == "metrics":
			bar.add_child(_btn("Inspect", func(): open_pod(uid)))
		body.add_child(bar)
		var panel: Control = screens.make_panel(uid)
		panel.custom_minimum_size = Vector2(1130, 700) if touch_u <= 0.0 else Vector2(tvp.x * 0.9, maxf(tvp.y * 0.9 - touch_u * 3.4, 300.0))
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body.add_child(panel)
		return
	# the dashboard: whatever application page is on this screen
	match screens.dashboard_kind(uid):
		"demo":
			var kind = ""
			for ds in demo_screens.screens():
				if ds["uid"] == uid:
					kind = str(ds["kind"])
			var bar = _row(8)
			bar.add_child(_lbl("Demo content from this simulated cluster, not a real page.   VIEW", 13, DIM))
			var views: Array = demo_screens.VIEWS[kind]
			for i in views.size():
				bar.add_child(_btn(str(views[i]), func():
					demo_screens.set_view(uid, i)
					open_screen(uid), "primary" if demo_screens.view_of(uid) == i else "normal"))
			bar.add_child(_spacer())
			bar.add_child(_btn("All LiveView", func(): open_liveview()))
			body.add_child(bar)
			var panel: Control = demo_screens.make_panel(uid)
			panel.custom_minimum_size = Vector2(1130, 700) if touch_u <= 0.0 else Vector2(tvp.x * 0.9, maxf(tvp.y * 0.9 - touch_u * 3.4, 300.0))
			panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
			body.add_child(panel)
		"live":
			for s in live.sessions.values():
				if str(s.get("mounted", "")) == uid:
					open_live(s)       # the real page, with mouse and keyboard
					return
		"provider":
			for pr in _prov_list:
				if str(pr["id"]) == str(providers.pins[uid]["provider"]):
					open_tautulli(pr)
					return
			open_providers()
		_:
			var l = _lbl("No application page is on this screen.\n\nLiveView puts a running application's own web page here, and a Grafana or Tautulli provider can pin its dashboard or activity. Until then the screen shows the pod's state.\n\nMetrics, Logs and Storage above work for every machine.", 15, DIM)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 1100
			body.add_child(l)
			body.add_child(_btn("Open LiveView", func(): open_liveview(), "primary"))

# ----- the Krew's operations center (scripts/krew.gd)
#
# Every worker's findings in one place: what, the evidence, the proposal and
# its risk. A proposed action runs only when you press its button, through
# guarded_act: the same tiers, read-only mode and typed confirmation as the tools.

var krew: Node = null              # set by main
var _krew_focus = ""               # "" = every worker
var _krew_open = {}                # finding key -> true while its details are shown
var _krew_history = false
var _krew_list: VBoxContainer = null
var _krew_sig = ""

const SEV_COLORS = {"high": Color(1.0, 0.36, 0.3), "medium": Color(1.0, 0.72, 0.25), "low": Color(0.55, 0.78, 1.0), "info": Color(0.62, 0.68, 0.74)}

func open_krew(focus: String = "") -> void:
	if krew == null:
		return
	_krew_focus = focus
	_krew_sig = ""
	var compact = touch != null and touch.active
	var body = _open_modal("krew", focus, "KREW  //  OPERATIONS", Vector2(1260, 800))
	# the roster: every worker, what it is doing, and how many findings it holds
	var roster = GridContainer.new()
	roster.columns = 4
	roster.add_theme_constant_override("h_separation", 8)
	roster.add_theme_constant_override("v_separation", 6)
	for w in krew.WORKERS:
		var id = str(w["id"])
		var pc = PanelContainer.new()
		var sb = _sb(BG2 if _krew_focus != id else Color(0.16, 0.13, 0.08), w["color"], 0, 8)
		sb.border_width_left = 4
		pc.add_theme_stylebox_override("panel", sb)
		var v = _col(2)
		v.add_child(_lbl("%s  ·  %s" % [w["name"], w["role"]], 14, w["color"]))
		var worst = krew.worst_of(id)
		v.add_child(_lbl(krew.status_of(id), 12, SEV_COLORS.get(worst, Color(0.45, 0.85, 0.5)) if worst != "" else Color(0.45, 0.85, 0.5)))
		var b = _btn("Only " + str(w["name"]).capitalize() if _krew_focus != id else "Showing", func(): open_krew("" if _krew_focus == id else id), "normal", true)
		v.add_child(b)
		pc.add_child(v)
		pc.custom_minimum_size.x = 296
		roster.add_child(pc)
	body.add_child(roster)
	var src = str(cluster.state.get("source", ""))
	var bar = _row(8)
	if src == "simulation":
		bar.add_child(_lbl("SIMULATED", 13, K.health_color("warn")))
	bar.add_child(_lbl("Nothing here changes by itself: a proposed action runs only when you approve it.", 12, DIM))
	bar.add_child(_spacer())
	if src in ["docker", "simulation"]:
		bar.add_child(_btn("Scan images and volumes", func():
			notify("Scrappy is scanning images and volumes...", "info")
			cluster.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "krew:scan"})))
	bar.add_child(_btn("Resolved (%d)" % krew.history.size() if not _krew_history else "Open findings", func():
		_krew_history = not _krew_history
		open_krew(_krew_focus)))
	bar.add_child(_btn("Export Markdown", func(): _krew_export("md")))
	bar.add_child(_btn("Export JSON", func(): _krew_export("json")))
	body.add_child(bar)
	body.add_child(_table_head("krew", [["sev", "SEVERITY", 100], ["worker", "WORKER", 110], ["title", "FINDING", 560], ["resource", "RESOURCE", 260], ["age", "SEEN FOR", 110]],
		func(): _fill_krew(true), krew.findings.size(), 17 if compact else 12))
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_krew_list = _col(4)
	_krew_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_krew_list)
	body.add_child(sc)
	_fill_krew(true)

func on_krew_changed() -> void:
	if _modal_kind == "krew":
		_fill_krew(false)

func _fill_krew(force: bool) -> void:
	if _modal_kind != "krew" or not is_instance_valid(_krew_list):
		return
	var rows = krew.history.filter(func(f): return _krew_focus == "" or f["worker"] == _krew_focus) if _krew_history else krew.of_worker(_krew_focus)
	var sig = JSON.stringify(rows.map(func(f): return [f["key"], f["severity"], f["evidence"]])) + JSON.stringify(_krew_open) + str(cluster.read_only)
	if not force and sig == _krew_sig:
		return
	_krew_sig = sig
	_clear(_krew_list)
	var getters = {"sev": func(f): return krew.SEVERITY_ORDER.get(f["severity"], 9), "worker": func(f): return f["worker"], "title": func(f): return f["title"],
		"resource": func(f): return f["resource"], "age": func(f): return -float(f.get("resolved_at", f["first_seen"]))}
	var shown = _table_rows("krew", rows, getters)
	if shown.is_empty():
		var l = _lbl(("Nothing resolved yet." if _krew_history else ("All clear." if rows.is_empty() else "No finding contains that.")), 15, DIM)
		_krew_list.add_child(l)
		if krew.status_of("scrappy") == "images not scanned yet" and not _krew_history:
			_krew_list.add_child(_lbl("Scrappy has not looked at images yet: use Scan images and volumes.", 13, DIM))
		return
	for f in shown:
		_krew_list.add_child(_krew_row(f))

func _krew_row(f: Dictionary) -> Control:
	var pc = PanelContainer.new()
	var sb = _sb(BG2, SEV_COLORS.get(f["severity"], DIM), 0, 8)
	sb.border_width_left = 4
	pc.add_theme_stylebox_override("panel", sb)
	var v = _col(4)
	pc.add_child(v)
	var r = _row(10)
	r.add_child(_fixed(_lbl(str(f["severity"]).to_upper(), 13, SEV_COLORS.get(f["severity"], DIM)), 100))
	r.add_child(_fixed(_lbl(krew.worker(f["worker"]).get("name", f["worker"]), 13, krew.worker(f["worker"]).get("color", TXT)), 110))
	var t = _lbl(str(f["title"]), 14)
	t.clip_text = true
	r.add_child(_fixed(t, 560))
	var res = _lbl(str(f["resource"]), 12, DIM)
	res.clip_text = true
	r.add_child(_fixed(res, 260))
	var when = float(f.get("resolved_at", f["first_seen"]))
	r.add_child(_fixed(_lbl(("resolved " if f.has("resolved_at") else "") + K.fmt_age(when), 12, DIM), 110))
	var key = str(f["key"])
	r.add_child(_btn("Hide" if _krew_open.has(key) else "Details", func():
		if _krew_open.has(key):
			_krew_open.erase(key)
		else:
			_krew_open[key] = true
		_fill_krew(true)))
	v.add_child(r)
	if not _krew_open.has(key):
		return pc
	for e in f["evidence"]:
		var el = _lbl("·  " + str(e), 13, TXT)
		el.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		el.custom_minimum_size.x = 1150
		v.add_child(el)
	if str(f["proposal"]) != "":
		var pl = _lbl("Proposed:  " + str(f["proposal"]), 13, Color(0.6, 0.9, 1.0))
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pl.custom_minimum_size.x = 1150
		v.add_child(pl)
	if str(f["risk"]) != "":
		var rl = _lbl("Risk:  " + str(f["risk"]), 13, K.health_color("warn"))
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.custom_minimum_size.x = 1150
		v.add_child(rl)
	var acts = _row(8)
	var uids: Array = f.get("uids", []).filter(func(u): return world.machines.has(str(u)))
	if not uids.is_empty():
		acts.add_child(_btn("Go there", func():
			var spot = world.machine_spot(str(uids[0]))
			if spot != null:
				close_modal()
				player.teleport(spot[0], spot[1])))
	if f["worker"] == "bob" and not f.has("resolved_at"):
		acts.add_child(_btn("Ask Bob", func(): open_bob()))
	var a: Dictionary = f.get("action", {})
	if not a.is_empty() and not f.has("resolved_at"):
		var tier = K.tier_of(a, cluster.state)
		var allowed = not cluster.read_only and tier <= cluster.max_tier(str(a.get("ns", ""))) and cluster.cap(str(a["op"]))
		var b = _btn(str(f["action_label"]), func():      # the mk style adds "MK.n" in front
			guarded_act(a, "%s: %s?" % [str(f["action_label"]), str(a.get("name", ""))], str(a.get("name", ""))), "mk%d" % tier, allowed)
		acts.add_child(b)
		if not allowed:
			acts.add_child(_lbl("read-only mode is on" if cluster.read_only else ("above your tool tier here" if tier > cluster.max_tier(str(a.get("ns", ""))) else "not supported by this source"), 12, DIM))
	if acts.get_child_count() > 0:
		v.add_child(acts)
	return pc

func _krew_export(fmt: String) -> void:
	var stamp = Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "-")
	var path = cluster.log_dir.path_join("krew-report-%s.%s" % [stamp, fmt])
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		notify("Could not write " + path, "bad")
		return
	f.store_string(krew.report_markdown() if fmt == "md" else krew.report_json())
	f.close()
	notify("Saved to " + path, "ok")

# ----- Foreman: incidents, the shift brief, and questions to an AI provider
#
# Rules always work: incidents come from the Krew's findings. With a provider
# chosen, a question goes out with a redacted summary the operator can read
# first; what comes back is shown as text, and any action it proposes is
# checked (foreman.gd) and offered as a button that runs through guarded_act.

var foreman: Node = null           # set by main
var _fm_question = ""
var _fm_show_context = false
var _fm_edit = {}                  # the provider form being edited
var _fm_test = {}                  # provider id -> last test result
var _fm_scroll: ScrollContainer = null

func open_foreman() -> void:
	if foreman == null:
		return
	var sc_keep = 0.0
	if _modal_kind == "foreman" and is_instance_valid(_fm_scroll):
		sc_keep = _fm_scroll.scroll_vertical
	var body = _open_modal("foreman", "", "FOREMAN  //  OPERATIONS", Vector2(1260, 820))
	var idn = foreman.identity()
	var head = _row(10)
	head.add_child(_lbl(str(idn["label"]).to_upper(), 16, idn["color"]))
	var st = _lbl(foreman.status_line(), 13, K.health_color("bad") if foreman.status in ["offline", "unavailable"] else DIM)
	st.clip_text = true
	head.add_child(_fixed(st, 640))
	head.add_child(_spacer())
	if foreman.available():
		var names = ["Rules only"]
		var current = "Rules only"
		for p in foreman.providers:
			names.append(str(p["name"]))
			if str(p["id"]) == foreman.active:
				current = str(p["name"])
		head.add_child(_pick(names, current, func(n):
			var id = ""
			for p in foreman.providers:
				if str(p["name"]) == n:
					id = str(p["id"])
			foreman.select(id)
			notify("Foreman now uses %s." % n, "info")))
		head.add_child(_btn("AI providers...", open_foreman_providers))
	head.add_child(_btn("Export incidents", func():
		var path = cluster.log_dir.path_join("foreman-incidents-%s.md" % Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "-"))
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			notify("Could not write " + path, "bad")
			return
		f.store_string(foreman.incidents_markdown())
		f.close()
		notify("Saved to " + path, "ok")))
	body.add_child(head)
	var brief = _lbl(foreman.brief(krew, cluster.state), 15, TXT)
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.custom_minimum_size.x = 1180
	body.add_child(brief)
	if foreman.status in ["offline", "unavailable"]:
		var off = _row(8)
		off.add_child(_lbl("%s is not answering. Foreman keeps working from rules; nothing is sent anywhere else." % foreman.provider().get("name", "The provider"), 13, K.health_color("warn")))
		off.add_child(_btn("Use rules only", func(): foreman.select("")))
		body.add_child(off)
	# asking
	var p = foreman.provider()
	if not p.is_empty():
		var ar = _row(8)
		var q = LineEdit.new()
		q.text = _fm_question
		q.placeholder_text = "Ask Foreman, e.g.  why is checkout failing?   what can be cleaned up safely?"
		q.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		q.text_changed.connect(func(v): _fm_question = v)
		var go = func():
			_fm_question = q.text
			foreman.ask(q.text)
		q.text_submitted.connect(func(_v): go.call())
		ar.add_child(q)
		if foreman.status == "asking":
			ar.add_child(_btn("Cancel", func(): foreman.cancel()))
		else:
			ar.add_child(_btn("Ask", go, "primary", not cluster.state.is_empty()))
		body.add_child(ar)
		var ctx: String = foreman.build_context(cluster.state, krew)
		var note = _row(8)
		note.add_child(_lbl("Sends a redacted summary of this world (%d characters) and your question to %s%s. Nothing runs without your approval." % [ctx.length(), p["name"],
			" on this computer" if p.get("local", false) else ", in the cloud"], 12, DIM))
		note.add_child(_btn("Hide what is sent" if _fm_show_context else "Show what is sent", func():
			_fm_show_context = not _fm_show_context
			open_foreman()))
		body.add_child(note)
		if _fm_show_context:
			var te = TextEdit.new()
			te.text = ctx
			te.editable = false
			te.custom_minimum_size = Vector2(1180, 160)
			body.add_child(te)
	elif foreman.available():
		body.add_child(_lbl("To ask in plain words, add an AI provider (a local Ollama or LM Studio, OpenAI, Claude, or your own endpoint). The incidents below need no AI.", 12, DIM))
	else:
		body.add_child(_lbl("This build has no companion, so Foreman works from rules only. AI providers need the desktop version.", 12, DIM))
	var sc = ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list = _col(6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	body.add_child(sc)
	_fm_scroll = sc
	(func(): if is_instance_valid(sc): sc.scroll_vertical = int(sc_keep)).call_deferred()
	var last: Dictionary = foreman.last
	if not last.is_empty():
		list.add_child(_foreman_answer(last))
	list.add_child(_lbl("INCIDENTS", 14, ORANGE))
	var incs = foreman.incidents(krew)
	if incs.is_empty():
		list.add_child(_lbl("None open.", 14, DIM))
	for inc in incs.slice(0, 60):
		list.add_child(_foreman_incident(inc))
	var u = foreman.usage
	if u["requests"] > 0:
		list.add_child(_lbl("This session: %d question%s, %d tokens in, %d out." % [u["requests"], "" if u["requests"] == 1 else "s", u["in"], u["out"]], 12, DIM))

func _foreman_answer(last: Dictionary) -> Control:
	var pc = PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _sb(BG2, foreman.identity()["color"], 1, 10))
	var v = _col(6)
	pc.add_child(v)
	var ql = _lbl("You asked:  " + str(last["question"]), 13, DIM)
	ql.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ql.custom_minimum_size.x = 1140
	v.add_child(ql)
	if foreman.status == "asking":
		v.add_child(_lbl("%s is thinking..." % last.get("provider", "The provider"), 14, DIM))
		return pc
	if last.has("error"):
		var el = _lbl(str(last["error"]), 14, K.health_color("bad"))
		el.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		el.custom_minimum_size.x = 1140
		v.add_child(el)
		return pc
	var al = _lbl(str(last["answer"]) if str(last["answer"]) != "" else "(no answer)", 15, TXT)
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	al.custom_minimum_size.x = 1140
	v.add_child(al)
	v.add_child(_lbl("%s · %s · %.1f s%s. An AI can be wrong: check before you approve." % [last.get("provider", ""), last.get("model", ""), float(last.get("ms", 0)) / 1000.0,
		" · SIMULATED world" if str(cluster.state.get("source", "")) == "simulation" else ""], 11, DIM))
	for a in last["actions"]:
		var r = _row(8)
		if a["ok"]:
			var tier = K.tier_of(a["action"], cluster.state)
			var allowed = not cluster.read_only and tier <= cluster.max_tier(str(a["action"].get("ns", ""))) and cluster.cap(str(a["action"]["op"]))
			r.add_child(_btn(str(a["label"]), func():
				guarded_act(a["action"], "%s?" % a["label"], str(a["action"].get("name", a["action"].get("node", "")))), "mk%d" % tier, allowed))
			if not allowed:
				r.add_child(_lbl("read-only mode is on" if cluster.read_only else ("above your tool tier here" if tier > cluster.max_tier(str(a["action"].get("ns", ""))) else "not supported by this source"), 12, DIM))
		else:
			r.add_child(_lbl("Not offered: %s (%s)" % [a["tool"] if a["tool"] != "" else "an action", a["reason"]], 13, K.health_color("warn")))
		v.add_child(r)
		var why = ("Why: " + str(a["why"]) if str(a["why"]) != "" else "") + ("    Risk: " + str(a["risk"]) if str(a["risk"]) != "" else "")
		if why != "":
			var wl = _lbl(why, 12, DIM)
			wl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			wl.custom_minimum_size.x = 1120
			v.add_child(wl)
	return pc

func _foreman_incident(inc: Dictionary) -> Control:
	var pc = PanelContainer.new()
	var sb = _sb(BG2, SEV_COLORS.get(inc["severity"], DIM), 0, 8)
	sb.border_width_left = 4
	pc.add_theme_stylebox_override("panel", sb)
	var r = _row(10)
	pc.add_child(r)
	r.add_child(_fixed(_lbl(str(inc["severity"]).to_upper(), 13, SEV_COLORS.get(inc["severity"], DIM)), 80))
	r.add_child(_fixed(_lbl(str(inc["id"]), 12, DIM), 100))
	var res = _lbl(str(inc["resource"]), 13)
	res.clip_text = true
	r.add_child(_fixed(res, 280))
	var t = _lbl(str(inc["findings"][0]["title"]) + ("  (+%d more)" % (inc["findings"].size() - 1) if inc["findings"].size() > 1 else ""), 13)
	t.clip_text = true
	r.add_child(_fixed(t, 470))
	r.add_child(_fixed(_lbl(", ".join(PackedStringArray(inc["workers"].map(func(w): return str(w).capitalize()))), 12, DIM), 150))
	r.add_child(_btn("%d proposal%s" % [inc["proposals"].size(), "" if inc["proposals"].size() == 1 else "s"] if not inc["proposals"].is_empty() else "Details", func():
		for f in inc["findings"]:
			_krew_open[str(f["key"])] = true
		open_krew(str(inc["workers"][0]) if inc["workers"].size() == 1 else "")))
	return pc

var _fm_sig = ""

func on_foreman_changed() -> void:
	if _modal_kind != "foreman" or foreman == null:
		return
	var sig = JSON.stringify([foreman.status, foreman.active, foreman.providers, foreman.last, foreman.incidents(krew).map(func(i): return [i["id"], i["severity"], i["findings"].size(), i["proposals"].size()]), cluster.read_only])
	if sig != _fm_sig:
		_fm_sig = sig
		open_foreman()

# --- the provider list and form

func open_foreman_providers() -> void:
	var body = _open_modal("foreman_providers", "", "FOREMAN  //  AI PROVIDERS", Vector2(1000, 780))
	var intro = _lbl("Foreman works without AI. A provider adds answers in plain words. Keys are kept by the companion with this computer's per-user protection, never in the game's files, logs or screenshots. A provider on another computer receives nothing until you allow it below.", 13, DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 940
	body.add_child(intro)
	for p in foreman.providers:
		var pc = PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _sb(BG2, foreman.IDENTITIES.get(str(p["type"]), foreman.IDENTITIES[""])["color"], 1, 8))
		var v = _col(4)
		pc.add_child(v)
		var r = _row(8)
		r.add_child(_fixed(_lbl(str(p["name"]), 14, TXT), 220))
		var info = _lbl("%s  ·  %s  ·  %s%s" % [p["model"], p["base_url"], "this computer" if p["local"] else ("cloud, allowed" if p["cloud_ok"] else "cloud, NOT allowed yet"), "  ·  key saved" if p["has_key"] else ""], 12, DIM)
		info.clip_text = true
		r.add_child(_fixed(info, 470))
		var id = str(p["id"])
		r.add_child(_btn("Test", func():
			_fm_test[id] = {"msg": "Testing..."}
			open_foreman_providers()
			foreman.test_provider(id, func(res):
				_fm_test[id] = res
				if _modal_kind == "foreman_providers":
					open_foreman_providers())))
		r.add_child(_btn("Edit", func():
			_fm_edit = p.duplicate()
			_fm_edit["key"] = ""
			open_foreman_providers()))
		r.add_child(_btn("Remove", func():
			foreman.remove_provider(id, func(_res): open_foreman_providers())))
		v.add_child(r)
		if _fm_test.has(id):
			var tr: Dictionary = _fm_test[id]
			var txt = str(tr.get("msg", ""))
			var col = DIM
			if tr.has("ok"):
				if tr["ok"]:
					var models: Array = tr["data"].get("models", [])
					txt = "Reached. %d models offered%s: %s" % [models.size(), "" if tr["data"].get("model_listed", false) else " (the chosen model is not among them)", ", ".join(PackedStringArray(models.slice(0, 12)))]
					col = K.health_color("ok") if tr["data"].get("model_listed", false) else K.health_color("warn")
				else:
					txt = str(tr["msg"])
					col = K.health_color("bad")
			var tl = _lbl(txt, 12, col)
			tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			tl.custom_minimum_size.x = 920
			v.add_child(tl)
		body.add_child(pc)
	# the form
	var e = _fm_edit
	body.add_child(_lbl("EDIT PROVIDER" if e.has("id") else "ADD A PROVIDER", 14, ORANGE))
	var types = ["ollama", "lmstudio", "openai", "claude", "custom"]
	var tnames = types.map(func(t): return foreman.IDENTITIES[t]["label"])
	if not e.has("type"):
		e["type"] = "ollama"
	var tr2 = _row(8)
	tr2.add_child(_fixed(_lbl("Type", 13, DIM), 120))
	tr2.add_child(_pick(tnames, foreman.IDENTITIES[e["type"]]["label"], func(n):
		e["type"] = types[tnames.find(n)]
		open_foreman_providers()))
	body.add_child(tr2)
	var hints = {"ollama": ["http://localhost:11434", "e.g. llama3.1"], "lmstudio": ["http://localhost:1234", "the model loaded in LM Studio"],
		"openai": ["https://api.openai.com", "the model to use"], "claude": ["https://api.anthropic.com", "claude-opus-5-5"], "custom": ["https://your-endpoint (OpenAI-compatible)", "model name"]}
	var field = func(label: String, key: String, hint: String, secret: bool = false):
		var r = _row(8)
		r.add_child(_fixed(_lbl(label, 13, DIM), 120))
		var le = LineEdit.new()
		le.text = str(e.get(key, ""))
		le.placeholder_text = hint
		le.secret = secret
		le.custom_minimum_size.x = 620
		le.text_changed.connect(func(v): e[key] = v)
		r.add_child(le)
		body.add_child(r)
	field.call("Name", "name", foreman.IDENTITIES[e["type"]]["label"])
	field.call("Address", "base_url", hints[e["type"]][0])
	field.call("Model", "model", hints[e["type"]][1])
	field.call("API key", "key", "kept from before (type to replace)" if e.get("has_key", false) else ("required" if e["type"] in ["openai", "claude"] else "optional"), true)
	# consent as buttons that say what is set: a tick box is too easy to miss
	var toggle = func(key: String, on_text: String, off_text: String, note: String):
		var r = _row(8)
		var on = bool(e.get(key, false))
		r.add_child(_btn(on_text if on else off_text, func():
			e[key] = not bool(e.get(key, false))
			open_foreman_providers(), "primary" if on else "normal"))
		var nl = _lbl(note, 12, DIM)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size.x = 640
		r.add_child(nl)
		body.add_child(r)
	toggle.call("cloud_ok", "Cloud: ALLOWED", "Cloud: NOT ALLOWED", "A provider that is not on this computer receives nothing until this is allowed. Questions include a redacted summary of your infrastructure: names, states and the Krew's findings.")
	toggle.call("allow_http", "Plain http: ALLOWED", "Plain http: NOT ALLOWED", "Only for another computer: the key and the questions would travel unencrypted. Not needed for this computer.")
	var br = _row(8)
	br.add_child(_btn("Save", func():
		var args = {"id": str(e.get("id", "")), "type": e["type"], "name": str(e.get("name", "")), "base_url": str(e.get("base_url", "")), "model": str(e.get("model", "")),
			"key": str(e.get("key", "")), "allow_http": bool(e.get("allow_http", false)), "cloud_ok": bool(e.get("cloud_ok", false))}
		foreman.save_provider(args, func(res):
			if res["ok"]:
				_fm_edit = {}
				notify("Saved %s." % res["data"].get("name", "the provider"), "ok")
				if foreman.active == "":
					foreman.select(str(res["data"]["id"]))
			else:
				notify(str(res["msg"]), "bad")
			if _modal_kind == "foreman_providers":
				open_foreman_providers()), "primary"))
	if e.has("id"):
		br.add_child(_btn("Cancel edit", func():
			_fm_edit = {}
			open_foreman_providers()))
	br.add_child(_spacer())
	br.add_child(_btn("Back to Foreman", open_foreman))
	body.add_child(br)
