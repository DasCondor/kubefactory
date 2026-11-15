extends SceneTree
# Dialogs on a phone: with touch controls on, a dialog is enlarged (the window's
# interface scale) until it fills the screen's long edge, turned sideways when
# the phone is upright, scrolls if it is taller than the screen, and the
# player's own interface size comes back when it closes.
#
#   Godot --path . --resolution 390x844 -s tests/live/touch_dialogs_test.gd -- --demo --touch
#
# Run it upright (390x844) and sideways (844x390). The operator's settings.json
# is restored afterwards. KF_SHOTS=<dir> saves a screenshot of each dialog.

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(220)])
	if not ok:
		_fails.append(what)

func _run() -> void:
	var path = OS.get_user_data_dir().path_join("settings.json")
	var before = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	await create_timer(1.0).timeout
	var hud = game.hud
	hud.close_modal(false)
	await process_frame
	_check("touch controls are on", game.touch != null and game.touch.active)
	var own = root.content_scale_factor
	var win = Vector2(root.size)
	var upright = win.y > win.x * 1.6
	print("window ", win, "  (upright)" if upright else "  (sideways)", "  interface scale ", own)
	var shots = OS.get_environment("KF_SHOTS")
	for d in [["welcome", hud.open_welcome], ["demos", hud.open_demos], ["foreman", hud.open_foreman], ["settings", hud.open_settings], ["pause", hud.open_pause]]:
		d[1].call()
		for i in 8:
			await process_frame
		var scroll = hud._modal.get_child(1)
		var panel = scroll.get_child(0).get_child(0)
		var vp = root.get_visible_rect().size
		var long_edge = vp.y if upright else vp.x
		var fill = panel.size.x / long_edge
		# a small dialog stops at the 4x limit instead
		_check("%s: fills the long edge" % d[0], (fill > 0.9 or root.content_scale_factor >= 3.99) and fill <= 1.0,"%.2f of the edge, interface scale %.2f" % [fill, root.content_scale_factor])
		_check("%s: %s" % [d[0], "turned sideways" if upright else "upright"], is_equal_approx(scroll.rotation, PI / 2.0) == upright, scroll.rotation)
		_check("%s: enlarged, never shrunk below the player's size" % d[0], root.content_scale_factor >= own - 0.01, root.content_scale_factor)
		if shots != "":
			DirAccess.make_dir_recursive_absolute(shots)
			root.get_texture().get_image().save_png(shots.path_join("touch_%s_%s.png" % [d[0], "upright" if upright else "sideways"]))
	# a tap reaches a button through the enlargement (and the turn, upright)
	hud.open_demos()
	for i in 8:
		await process_frame
	var b: Button = null
	for x in hud._modal.find_children("*", "Button", true, false):
		if x.text.strip_edges() != "X":
			b = x
			break
	var label = b.text.strip_edges()             # pressing it may close the dialog
	var hit = [false]
	b.pressed.connect(func(): hit[0] = true)
	var at =root.get_final_transform() * (b.get_global_transform_with_canvas() * (b.size * 0.5))
	for down in [true, false]:
		var e = InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = at
		e.global_position = at
		root.push_input(e)
		await process_frame
	_check("a tap on '%s' presses it" % label, hit[0], at.round())
	hud.close_modal()
	await process_frame
	_check("closing restores the player's interface size", is_equal_approx(root.content_scale_factor, own), root.content_scale_factor)
	game.queue_free()
	await process_frame
	if before == "":
		DirAccess.remove_absolute(path)
	else:
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("TOUCH DIALOGS PASSED" if _fails.is_empty() else "TOUCH DIALOGS FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
