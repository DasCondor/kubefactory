extends CanvasLayer
# Touch controls for the browser demo.
#
# Only the browser build shows these, and only once a finger has actually
# touched the screen (or the page was opened with ?touch=1; ?touch=0 keeps them
# off on a hybrid device). A desktop browser with a mouse and keyboard keeps the
# desktop controls. The native editions never show them (--touch is a testing
# switch). They add nothing to the game: every control feeds the same actions
# the keyboard and mouse do, so tiers, hold-to-act and typed confirmations are
# exactly as on the desktop, and the browser demo is simulation-only either way.
#
#   left thumb     joystick: move and strafe (dead zone 15%, proportional)
#   drag the view  look around (no pointer lock)
#   ACTION         whatever the crosshair offers: open screen, inspect, logs,
#                  build, or hold for the tool's action
#   JUMP           jump (double-tap: hoverpack)
#   AIM            turn to the nearest machine in front of you
#   bottom bar     Scanner, Datapad, Build Gun, All tools
#   MENU           the game menu (touch controls on/off, look sensitivity)
#
# Each finger has one job from the moment it lands until it lifts, so two
# thumbs work independently, and a dialog on screen takes every touch.

const DEAD = 0.15
const LOOK = 0.0052          # radians per CSS pixel dragged, at sensitivity 1

var main = null
var hud = null
var player = null

var active = false            # the controls are on screen and own the input
var allowed = true            # the player's own on/off switch (menu)
var sensitivity = 1.0

var _u = 100.0                # one control unit, in canvas pixels (about 52 CSS px)
var _css = 1.0                # canvas pixels -> CSS pixels
var _vp = Vector2(1600, 900)
var _margin = [0.0, 0.0, 0.0, 0.0]     # left, top, right, bottom: safe area
var _pad: Control
var _fingers = {}             # finger index -> {role, id, start}
var _stick = Vector2.ZERO
var _stick_at = Vector2.ZERO
var _picker = false
var _buttons = {}             # id -> {rect, label, round}
var _down = {}                # button id -> true while held
var _seen_touch = false

func _ready() -> void:
	layer = 5
	_pad = Control.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.draw.connect(_draw_pad)
	add_child(_pad)
	visible = false
	get_viewport().size_changed.connect(func():
		_release_all()
		_layout())
	if OS.has_feature("web"):
		var q = str(JavaScriptBridge.eval("window.location.search", true))
		if q.contains("touch=0"):
			allowed = false
		elif q.contains("touch=1"):
			set_active(true)

func set_active(on: bool) -> void:
	on = on and allowed
	if on == active:
		return
	active = on
	visible = on
	_release_all()
	if on:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE      # never pointer lock on touch
		_layout()
	if hud != null:
		hud.set_touch(on, _u)

func set_allowed(on: bool) -> void:
	allowed = on
	set_active(on and (_seen_touch or active))
	if not on:
		set_active(false)

# ---- layout: sizes in units of one comfortable touch target

func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	var win = Vector2(get_window().size)
	_css = win.x / maxf(_vp.x, 1.0)
	_u = clampf(52.0 / maxf(_css, 0.05), 56.0, 320.0)
	# the area clear of notches and home indicators, where the system reports one
	var safe = DisplayServer.get_display_safe_area()
	var screen = Vector2(DisplayServer.screen_get_size())
	var k = 1.0 / maxf(_css, 0.05)
	_margin = [0.0, 0.0, 0.0, 0.0]
	if safe.size.x > 0 and screen.x > 0 and safe.size.x <= screen.x and safe.size.y <= screen.y:
		_margin = [safe.position.x * k, safe.position.y * k, maxf(screen.x - safe.end.x, 0.0) * k, maxf(screen.y - safe.end.y, 0.0) * k]
	for i in 4:
		_margin[i] = clampf(_margin[i], 0.0, _u * 1.2) + _u * 0.22
	var portrait = _vp.y > _vp.x
	var left = _margin[0]
	var right = _vp.x - _margin[2]
	var bottom = _vp.y - _margin[3]
	var bar_h = _u * 0.95
	var above_bar = bottom - (bar_h + _u * 0.3 if portrait else 0.0)
	_buttons.clear()
	_stick_at = Vector2(left + _u * 1.55, above_bar - _u * 1.55)
	_buttons["action"] = {"rect": Rect2(right - _u * 2.25, above_bar - _u * 2.25, _u * 2.1, _u * 2.1), "round": true}
	_buttons["jump"] = {"rect": Rect2(right - _u * 3.75, above_bar - _u * 1.35, _u * 1.3, _u * 1.3), "round": true, "label": "JUMP"}
	_buttons["aim"] = {"rect": Rect2(right - _u * 1.85, above_bar - _u * 3.85, _u * 1.3, _u * 1.3), "round": true, "label": "AIM"}
	_buttons["menu"] = {"rect": Rect2(right - _u * 1.6, _margin[1], _u * 1.6, _u * 0.85), "label": "MENU"}
	# the tool bar: bottom centre in landscape, the whole bottom edge in portrait
	var names = ["SCANNER", "DATAPAD", "BUILD", "ALL TOOLS"]
	var bw = (right - left - _u * 0.3 * 3) / 4.0 if portrait else _u * 1.7
	var x0 = left if portrait else (_vp.x - (bw * 4 + _u * 0.25 * 3)) * 0.5
	var gap = _u * 0.3 if portrait else _u * 0.25
	for i in 4:
		_buttons["bar%d" % i] = {"rect": Rect2(x0 + i * (bw + gap), bottom - bar_h, bw, bar_h), "label": names[i]}
	if _picker:
		var all = ["SCANNER", "DATAPAD", "BUILD GUN", "WRENCH", "DISMANTLER", "DEMOLISHER"]
		var cols = 3 if portrait else 6
		var pw = (right - left - _u * 0.25 * (cols - 1)) / cols if portrait else _u * 1.9
		var px0 = left if portrait else (_vp.x - (pw * cols + _u * 0.25 * (cols - 1))) * 0.5
		var rows = int(ceil(6.0 / cols))
		for i in 6:
			var row = int(i / cols)
			_buttons["tool%d" % i] = {"rect": Rect2(px0 + (i % cols) * (pw + _u * 0.25), bottom - bar_h - _u * 0.3 - (rows - row) * (bar_h + _u * 0.2), pw, bar_h), "label": all[i]}
	_pad.queue_redraw()

func _process(_d: float) -> void:
	if not active:
		return
	var modal = hud != null and hud.modal_open()
	_pad.visible = not modal
	if modal and not _fingers.is_empty():
		_release_all()
	_pad.queue_redraw()

# ---- input: one job per finger

func _input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch and not _seen_touch:
		_seen_touch = true
		if OS.has_feature("web") or main._touch_forced:
			set_active(true)
	if not active or (hud != null and hud.modal_open()):
		return
	if ev is InputEventScreenTouch:
		if ev.pressed:
			_begin(ev.index, ev.position)
		else:
			_end(ev.index)
		get_viewport().set_input_as_handled()
	elif ev is InputEventScreenDrag:
		_move(ev.index, ev.position, ev.relative)
		get_viewport().set_input_as_handled()
	elif ev is InputEventMouse and ev.device == InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()      # the mouse copy of a touch: already handled above
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		# a real mouse on a hybrid device (or a test): it drives the controls as one more finger
		if ev.pressed:
			_begin(-1, ev.position)
		else:
			_end(-1)
		get_viewport().set_input_as_handled()
	elif ev is InputEventMouseMotion and _fingers.has(-1):
		_move(-1, ev.position, ev.relative)
		get_viewport().set_input_as_handled()

func _begin(idx: int, pos: Vector2) -> void:
	var order = _buttons.keys()
	order.sort_custom(func(a, b): return a.begins_with("tool") and not b.begins_with("tool"))
	for id in order:
		var b = _buttons[id]
		var hit = pos.distance_to(b["rect"].get_center()) <= b["rect"].size.x * 0.55 if b.get("round", false) else b["rect"].grow(_u * 0.08).has_point(pos)
		if hit:
			_fingers[idx] = {"role": "button", "id": id}
			_press(id)
			return
	if pos.distance_to(_stick_at) <= _u * 2.1:
		_fingers[idx] = {"role": "stick"}
		_set_stick(pos)
		return
	_fingers[idx] = {"role": "look"}

func _move(idx: int, pos: Vector2, rel: Vector2) -> void:
	var f = _fingers.get(idx)
	if f == null:
		return
	match f["role"]:
		"stick":
			_set_stick(pos)
		"look":
			if player != null and player.enabled:
				player.look_by(rel * _css * LOOK * sensitivity)

func _end(idx: int) -> void:
	var f = _fingers.get(idx)
	if f == null:
		return
	_fingers.erase(idx)
	match f["role"]:
		"stick":
			_set_stick(_stick_at)
		"button":
			_release(f["id"])

func _set_stick(pos: Vector2) -> void:
	var v = (pos - _stick_at) / (_u * 1.25)
	if v.length() > 1.0:
		v = v.normalized()
	_stick = v
	var m = v.length()
	var out = Vector2.ZERO if m < DEAD else v.normalized() * ((m - DEAD) / (1.0 - DEAD))
	for pair in [["move_right", out.x], ["move_left", -out.x], ["move_back", out.y], ["move_forward", -out.y]]:
		if pair[1] > 0.0:
			Input.action_press(pair[0], pair[1])
		else:
			Input.action_release(pair[0])

func _fire(pressed: bool) -> void:
	var e = InputEventAction.new()
	e.action = "fire"
	e.pressed = pressed
	Input.parse_input_event(e)

func _press(id: String) -> void:
	_down[id] = true
	match id:
		"action":
			_fire(true)
		"jump":
			Input.action_press("jump")
			if player != null:
				player.jump_tap()

func _release(id: String) -> void:
	if not _down.has(id):
		return
	_down.erase(id)
	if id == "action":
		_fire(false)
	elif id == "jump":
		Input.action_release("jump")
	elif id == "aim":
		main.touch_aim()
	elif id == "menu":
		hud.open_pause()
	elif id == "bar3":
		_picker = not _picker
		_layout()
	elif id.begins_with("bar"):
		main._set_mode(id.trim_prefix("bar").to_int())
	elif id.begins_with("tool"):
		main._set_mode(id.trim_prefix("tool").to_int())      # choosing a tool never uses it
		_picker = false
		_layout()

# Lift every finger: a dialog opened, the window lost focus, or the screen turned.
func _release_all() -> void:
	for idx in _fingers.keys():
		_end(idx)
	_fingers.clear()
	for id in _down.keys():
		if id == "action":
			_fire(false)
		elif id == "jump":
			Input.action_release("jump")
	_down.clear()
	_stick = Vector2.ZERO
	for a in ["move_left", "move_right", "move_forward", "move_back", "jump"]:
		Input.action_release(a)

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_release_all()

# ---- drawing

func _draw_pad() -> void:
	if not active:
		return
	var font = ThemeDB.fallback_font
	var line = Color(1, 1, 1, 0.55)
	var fill = Color(0.07, 0.09, 0.11, 0.55)
	var hot = Color(0.957, 0.647, 0.227, 0.9)
	# joystick
	_pad.draw_circle(_stick_at, _u * 1.25, fill)
	_pad.draw_arc(_stick_at, _u * 1.25, 0, TAU, 48, line, maxf(_u * 0.035, 2.0), true)
	_pad.draw_circle(_stick_at + _stick * _u * 1.25, _u * 0.52, Color(1, 1, 1, 0.8) if _stick != Vector2.ZERO else Color(1, 1, 1, 0.45))
	var mode = int(main.mode) if main != null else 0
	for id in _buttons:
		var b = _buttons[id]
		var r: Rect2 = b["rect"]
		var label = str(b.get("label", ""))
		var on = _down.has(id)
		var chosen = (id.begins_with("bar") and id != "bar3" and id.trim_prefix("bar").to_int() == mode) or (id.begins_with("tool") and id.trim_prefix("tool").to_int() == mode) or (id == "bar3" and (_picker or mode > 2))
		if id == "action":
			label = main.touch_action_label()
		var col = hot if (on or chosen) else line
		if b.get("round", false):
			_pad.draw_circle(r.get_center(), r.size.x * 0.5, Color(0.957, 0.647, 0.227, 0.3) if (id == "action" and label != "") else fill)
			_pad.draw_arc(r.get_center(), r.size.x * 0.5, 0, TAU, 48, col, maxf(_u * 0.04, 2.0), true)
		else:
			_pad.draw_rect(r, Color(0.957, 0.647, 0.227, 0.25) if chosen else fill)
			_pad.draw_rect(r, col, false, maxf(_u * 0.03, 2.0))
		var lines = label.split("\n")
		var px = int(_u * (0.3 if id == "action" else 0.24))
		for i in lines.size():
			var y = r.get_center().y + px * 0.36 + (i - (lines.size() - 1) * 0.5) * px * 1.15
			_pad.draw_string(font, Vector2(r.position.x, y), lines[i], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, px, Color(1, 1, 1, 0.95) if label != "" else Color(1, 1, 1, 0.35))
	# always visible: this is the simulation
	var chip = "SIMULATION  ·  nothing here is real"
	var cpx = int(_u * 0.22)
	var cw = font.get_string_size(chip, HORIZONTAL_ALIGNMENT_LEFT, -1, cpx).x + _u * 0.4
	var cr = Rect2((_vp.x - cw) * 0.5, _margin[1], cw, _u * 0.5)
	_pad.draw_rect(cr, Color(0.22, 0.15, 0.05, 0.85))
	_pad.draw_string(font, Vector2(cr.position.x, cr.position.y + _u * 0.34), chip, HORIZONTAL_ALIGNMENT_CENTER, cw, cpx, Color(0.957, 0.647, 0.227))
