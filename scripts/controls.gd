extends RefCounted
# Controls: rebindable keys, controller support, and the key hints in text.
#
# main.gd builds the default key map; snapshot() keeps a copy of it, and
# apply(saved) lays the player's own bindings (settings.json "keys") on top.
# A binding is stored as plain data: {"key": keycode} or {"mouse": button}.
#
# Text all over the game says "[E] inspect", "(K)" and so on. hint() swaps
# each default key for the one the action is bound to now, so a player who
# moved Interact to F sees "[F] inspect". Text without a changed key is
# returned unchanged.
#
# Controller (any XInput / SDL pad Godot knows): left stick moves, right stick
# looks, RT uses the tool, LT samples, LB / RB change tool, A jump (twice:
# hoverpack), B descend, X inspect, Y build menu, L3 sprint, R3 next screen
# view, D-pad up next problem / right Krew / left Foreman / down datapad,
# Back codex, Start menu. In a menu the left stick moves a pointer and A
# clicks, the right stick scrolls, B closes.

# rebindable actions, in the order the settings menu lists them
const ACTIONS = [
	["move_forward", "Move forward"], ["move_back", "Move back"], ["move_left", "Move left"], ["move_right", "Move right"],
	["jump", "Jump (twice: hoverpack)"], ["descend", "Descend"], ["sprint", "Sprint"],
	["fire", "Use tool"], ["sample", "Copy machine"], ["interact", "Inspect / talk"],
	["build_menu", "Build menu"], ["codex", "Codex"], ["logs", "Datapad (logs)"], ["next_problem", "Next problem"],
	["krew", "Krew"], ["foreman", "Foreman"], ["minimap", "Minimap"], ["storage", "Storage"], ["liveview", "Screen / LiveView"],
	["screen_next", "Next screen view"], ["belts", "Belts"], ["mute", "Sound"], ["fullscreen", "Fullscreen"],
	["tool1", "Tool 1"], ["tool2", "Tool 2"], ["tool3", "Tool 3"], ["tool4", "Tool 4"], ["tool5", "Tool 5"], ["tool6", "Tool 6"],
]

const PAD_DEADZONE = 0.18

static var _defaults = {}     # action -> [binding dict], the shipped map

# ---- bindings as data

static func to_data(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		return {"key": int(ev.physical_keycode if ev.keycode == 0 else ev.keycode)}
	if ev is InputEventMouseButton:
		return {"mouse": int(ev.button_index)}
	return {}

static func to_event(d: Dictionary) -> InputEvent:
	if d.has("key"):
		var k = InputEventKey.new()
		k.keycode = int(d["key"])
		return k
	if d.has("mouse"):
		var m = InputEventMouseButton.new()
		m.button_index = int(d["mouse"])
		return m
	return null

# The keyboard and mouse bindings of an action (controller events are not rebindable here).
static func bindings(action: String) -> Array:
	var out = []
	if InputMap.has_action(action):
		for ev in InputMap.action_get_events(action):
			var d = to_data(ev)
			if not d.is_empty():
				out.append(d)
	return out

static func snapshot() -> void:
	_defaults.clear()
	for a in ACTIONS:
		_defaults[a[0]] = bindings(a[0])

static func defaults(action: String) -> Array:
	return _defaults.get(action, [])

# Replace an action's keyboard / mouse bindings, keeping its controller ones.
static func set_bindings(action: String, list: Array) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey or ev is InputEventMouseButton:
			InputMap.action_erase_event(action, ev)
	for d in list:
		var ev = to_event(d)
		if ev != null:
			InputMap.action_add_event(action, ev)

# saved: settings["keys"], {action: [binding dicts]}; anything unknown is ignored.
static func apply(saved) -> void:
	if typeof(saved) != TYPE_DICTIONARY:
		return
	for a in ACTIONS:
		if saved.has(a[0]) and typeof(saved[a[0]]) == TYPE_ARRAY:
			set_bindings(a[0], saved[a[0]].filter(func(d): return typeof(d) == TYPE_DICTIONARY))

# Only what differs from the defaults is saved, so a later default change reaches players who never rebound.
static func changed() -> Dictionary:
	var out = {}
	for a in ACTIONS:
		var now = bindings(a[0])
		if JSON.stringify(now) != JSON.stringify(defaults(a[0])):
			out[a[0]] = now
	return out

# Which other actions already use this binding (their ids).
static func conflicting_actions(action: String, d: Dictionary) -> Array:
	var out = []
	for a in ACTIONS:
		if a[0] != action and bindings(a[0]).any(func(x): return x == d):
			out.append(a[0])
	return out

# The same, as the names the settings menu shows.
static func conflicts(action: String, d: Dictionary) -> Array:
	return conflicting_actions(action, d).map(func(id): return title(id))

# The settings menu's name for an action.
static func title(action: String) -> String:
	for a in ACTIONS:
		if a[0] == action:
			return a[1]
	return action

# Give d to action alone: every other action that had it loses it (and may be left unbound).
# Returns the actions that lost it.
static func move_binding(action: String, d: Dictionary) -> Array:
	var others = conflicting_actions(action, d)
	for o in others:
		set_bindings(o, bindings(o).filter(func(x): return x != d))
	set_bindings(action, [d])
	return others

# Actions with no key or mouse button (a controller may still drive them).
static func unbound() -> Array:
	var out = []
	for a in ACTIONS:
		if bindings(a[0]).is_empty():
			out.append(a[0])
	return out

# ---- names

static func name_of(d: Dictionary) -> String:
	if d.has("key"):
		var k = int(d["key"])
		match k:
			KEY_CTRL:
				return "Ctrl"
			KEY_SHIFT:
				return "Shift"
			KEY_ALT:
				return "Alt"
		return OS.get_keycode_string(k)
	if d.has("mouse"):
		return {MOUSE_BUTTON_LEFT: "LMB", MOUSE_BUTTON_RIGHT: "RMB", MOUSE_BUTTON_MIDDLE: "MMB", MOUSE_BUTTON_XBUTTON1: "Mouse 4", MOUSE_BUTTON_XBUTTON2: "Mouse 5"}.get(int(d["mouse"]), "Mouse %d" % int(d["mouse"]))
	return "?"

# The first binding's name, or "unbound".
static func label(action: String) -> String:
	var b = bindings(action)
	return name_of(b[0]) if not b.is_empty() else "unbound"

static func default_label(action: String) -> String:
	var b = defaults(action)
	return name_of(b[0]) if not b.is_empty() else ""

# ---- hints in text

static var _hint_map = {}      # default key name -> current key name, for changed actions only
static var _hint_sig = ""

static func _refresh_map() -> void:
	var sig = JSON.stringify(changed())
	if sig == _hint_sig:
		return
	_hint_sig = sig
	_hint_map.clear()
	for a in ACTIONS:
		var d = default_label(a[0])
		var c = label(a[0])
		if d != "" and d != c:
			_hint_map[d] = c

static func hint(text: String) -> String:
	if _defaults.is_empty():
		return text
	_refresh_map()
	if _hint_map.is_empty() or (not text.contains("[") and not text.contains("(")):
		return text
	var rx = RegEx.new()
	rx.compile("([\\[(])(Hold )?([A-Za-z0-9]+)([\\])])")
	var out = ""
	var at = 0
	for m in rx.search_all(text):
		out += text.substr(at, m.get_start() - at)
		var k = m.get_string(3)
		out += m.get_string(1) + m.get_string(2) + str(_hint_map.get(k, k)) + m.get_string(4)
		at = m.get_end()
	return out + text.substr(at)

# The help line at the bottom of the screen, from the bindings in force.
static func ribbon() -> String:
	var mv = [label("move_forward"), label("move_left"), label("move_back"), label("move_right")]
	var move = "WASD" if mv == ["W", "A", "S", "D"] else "/".join(PackedStringArray(mv))
	return " · ".join(PackedStringArray([
		"%s move" % move, "%s sprint" % label("sprint"), "%s jump (double-tap: hoverpack, %s descend)" % [label("jump"), label("descend")],
		"1-6 / wheel tools", "%s inspect" % label("interact"), "%s build menu" % label("build_menu"), "%s copy machine" % label("sample"),
		"%s codex" % label("codex"), "%s datapad" % label("logs"), "%s next problem" % label("next_problem"), "%s Krew" % label("krew"),
		"%s Foreman" % label("foreman"), "%s map" % label("minimap"), "%s belts" % label("belts"), "%s storage" % label("storage"), "%s screen" % label("liveview"),
		"%s next view" % label("screen_next"), "%s sound" % label("mute"), "Esc menu"]))

# ---- controller

static func _pad_button(action: String, button: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev = InputEventJoypadButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)

static func _pad_axis(action: String, axis: int, value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev = InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)

static func add_controller() -> void:
	for pair in [["move_left", JOY_AXIS_LEFT_X, -1.0], ["move_right", JOY_AXIS_LEFT_X, 1.0], ["move_forward", JOY_AXIS_LEFT_Y, -1.0], ["move_back", JOY_AXIS_LEFT_Y, 1.0],
			["fire", JOY_AXIS_TRIGGER_RIGHT, 1.0], ["sample", JOY_AXIS_TRIGGER_LEFT, 1.0]]:
		_pad_axis(pair[0], pair[1], pair[2])
		InputMap.action_set_deadzone(pair[0], PAD_DEADZONE if pair[1] < JOY_AXIS_TRIGGER_LEFT else 0.5)
	for pair in [["jump", JOY_BUTTON_A], ["descend", JOY_BUTTON_B], ["interact", JOY_BUTTON_X], ["build_menu", JOY_BUTTON_Y],
			["sprint", JOY_BUTTON_LEFT_STICK], ["screen_next", JOY_BUTTON_RIGHT_STICK], ["tool_prev", JOY_BUTTON_LEFT_SHOULDER], ["tool_next", JOY_BUTTON_RIGHT_SHOULDER],
			["next_problem", JOY_BUTTON_DPAD_UP], ["krew", JOY_BUTTON_DPAD_RIGHT], ["foreman", JOY_BUTTON_DPAD_LEFT], ["logs", JOY_BUTTON_DPAD_DOWN],
			["codex", JOY_BUTTON_BACK], ["pad_menu", JOY_BUTTON_START]]:
		_pad_button(pair[0], pair[1])

static func pad_connected() -> bool:
	return not Input.get_connected_joypads().is_empty()

static func pad_name() -> String:
	var pads = Input.get_connected_joypads()
	return Input.get_joy_name(pads[0]) if not pads.is_empty() else ""

# A stick as a vector, with the deadzone removed and the rest rescaled.
static func stick(right: bool) -> Vector2:
	var pads = Input.get_connected_joypads()
	if pads.is_empty():
		return Vector2.ZERO
	var v = Vector2(Input.get_joy_axis(pads[0], JOY_AXIS_RIGHT_X if right else JOY_AXIS_LEFT_X), Input.get_joy_axis(pads[0], JOY_AXIS_RIGHT_Y if right else JOY_AXIS_LEFT_Y))
	var l = v.length()
	if l < PAD_DEADZONE:
		return Vector2.ZERO
	return v / l * minf((l - PAD_DEADZONE) / (1.0 - PAD_DEADZONE), 1.0)
