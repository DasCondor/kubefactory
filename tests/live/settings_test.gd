extends SceneTree
# The in-game settings: key rebinding (through the real capture path), hints
# following the binding, field of view, colour palettes and the controller.
# The operator's settings.json is restored afterwards.
#   engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/settings_test.gd -- --demo
# KF_SHOTS=<dir> saves screenshots.

const K = preload("res://scripts/kutil.gd")
const Controls = preload("res://scripts/controls.gd")

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(220)])
	if not ok:
		_fails.append(what)

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		await create_timer(0.6).timeout
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _key(code: int) -> InputEventKey:
	var e = InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e

func _run() -> void:
	var path = OS.get_user_data_dir().path_join("settings.json")
	var before = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	game.hud.close_modal(false)
	var hud = game.hud
	# --- rebinding Interact from E to F, through the capture path
	hud.open_settings()
	hud._rebind = "interact"
	hud._input(_key(KEY_F))
	await process_frame
	_check("Interact is now F", Controls.label("interact") == "F", Controls.label("interact"))
	var saved = K.load_settings().get("keys", {})
	_check("only the change is saved", saved.keys() == ["interact"] and int(saved["interact"][0]["key"]) == KEY_F, saved)
	_check("the clash with Storage is pointed out", hud._settings_note.contains("Storage"), hud._settings_note)
	_check("hints follow the binding", Controls.hint("[E] inspect   [MMB] copy   (K)") == "[F] inspect   [MMB] copy   (K)", Controls.hint("[E] inspect   [MMB] copy   (K)"))
	_check("the help line follows the binding", hud._help.text.contains("F inspect") and not hud._help.text.contains("E inspect"))
	await create_timer(0.3).timeout
	var gtag = game.world._gauge.get_children().filter(func(c): return c is Label3D and str(c.text).contains("resource desk"))
	_check("signs in the world follow the binding", not gtag.is_empty() and gtag.any(func(c): return c.text.contains("[F]")), gtag.map(func(c): return c.text))
	await _shot("settings_menu")
	hud._rebind = "jump"
	hud._input(_key(KEY_ESCAPE))
	_check("Esc cancels a rebinding", Controls.label("jump") == "Space")
	# --- reset
	var reset = _find(hud._modal, "Reset all keys")
	if reset != null:
		reset.pressed.emit()
	_check("reset restores the defaults and saves nothing", Controls.label("interact") == "E" and K.load_settings().get("keys", {}).is_empty())
	# --- field of view and palette
	hud._save_setting("fov", 95.0)
	game.player.camera.fov = 95.0
	_check("field of view", is_equal_approx(game.player.camera.fov, 95.0) and float(K.load_settings()["fov"]) == 95.0)
	hud.open_settings()
	var pal = _find(hud._modal, K.PALETTES["red_green"]["label"])
	if pal != null:
		pal.pressed.emit()
	await create_timer(1.0).timeout
	_check("the red-green palette is in use and saved", K.palette == "red_green" and K.load_settings()["palette"] == "red_green")
	_check("healthy is now blue, failing vermilion", K.health_color("ok").b > 0.8 and K.health_color("bad").g < 0.5)
	_check("the Krew's severity colours follow", hud.SEV_COLORS["high"].is_equal_approx(K.health_color("bad").lightened(0.1)))
	hud.close_modal(false)
	game.player.teleport(Vector3(0, 2, 30), Vector3(0, 1.5, 0))
	await _shot("palette_red_green")
	# --- controller
	var mode0 = game.mode
	var rb = InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	game._unhandled_input(rb)
	_check("RB changes tool, without the mouse captured", game.mode == posmod(mode0 + 1, 6), "%d -> %d" % [mode0, game.mode])
	var st = InputEventJoypadButton.new()
	st.button_index = JOY_BUTTON_START
	st.pressed = true
	game._unhandled_input(st)
	_check("Start opens the menu", hud._modal_kind == "pause")
	var bb = InputEventJoypadButton.new()
	bb.button_index = JOY_BUTTON_B
	bb.pressed = true
	game._unhandled_input(bb)
	_check("B closes it", not hud.modal_open())
	game._unhandled_input(bb)
	_check("B in the world does not open the menu (it descends)", not hud.modal_open())
	var stick = InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = -1.0
	_check("the left stick drives movement", stick.is_action("move_forward") and InputMap.action_get_events("move_forward").any(func(e): return e is InputEventJoypadMotion))
	# --- restore the operator's settings
	game.queue_free()
	await process_frame
	K.palette = "standard"
	if before == "":
		DirAccess.remove_absolute(path)
	else:
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("SETTINGS PASSED" if _fails.is_empty() else "SETTINGS FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)

func _find(node: Node, needle: String) -> Button:
	if node is Button and node.text.contains(needle):
		return node
	for c in node.get_children():
		var r = _find(c, needle)
		if r != null:
			return r
	return null
