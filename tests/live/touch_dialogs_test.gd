extends SceneTree
# Dialogs on a phone stay upright, use readable text, and scroll when needed.
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
	var upright = win.y > win.x
	print("window ", win, "  (portrait)" if upright else "  (landscape)", "  interface scale ", own)
	var touch = game.touch
	_check("Menu has a phone-sized hit target", touch._buttons["menu"]["rect"].size.y * touch._css >= 37.0)
	_check("Touch controls fit the viewport", touch._buttons.values().all(func(b): return Rect2(Vector2.ZERO, touch._vp).encloses(b["rect"])))
	_check("The held scanner is reframed in portrait", game.player.view._pivot.scale.x < 1.0 if upright else is_equal_approx(game.player.view._pivot.scale.x, 1.0))
	var all_tools: Vector2 = touch._buttons["bar3"]["rect"].get_center()
	touch._begin(0, all_tools)
	touch._end(0)
	for i in 6:
		var box: Rect2 = touch._buttons.get("tool%d" % i, {}).get("rect", Rect2())
		_check("Tool %d is visible and clear of Aim" % (i + 1), box.has_area() and Rect2(Vector2.ZERO, touch._vp).encloses(box) and not box.intersects(touch._buttons["aim"]["rect"]))
	touch._begin(0, all_tools)
	touch._end(0)
	var shots = OS.get_environment("KF_SHOTS")
	for d in [["welcome", hud.open_welcome], ["demos", hud.open_demos], ["foreman", hud.open_foreman], ["krew", hud.open_krew], ["settings", hud.open_settings], ["pause", hud.open_pause], ["vpn", hud.open_vpn]]:
		d[1].call()
		for i in 8:
			await process_frame
		var scroll = hud._modal.get_child(1)
		var vp = root.get_visible_rect().size
		_check("%s: scroll frame fits the viewport" % d[0], Rect2(Vector2.ZERO, vp).encloses(scroll.get_rect()), scroll.get_rect())
		_check("%s: stays upright" % d[0], is_zero_approx(scroll.rotation), scroll.rotation)
		if d[0] == "demos":
			_check("Demo cards use the available width", hud._demo_cards.columns == (2 if win.x >= 660.0 else 1))
		# body text (13 px in the dialog) as drawn on the screen, in window pixels
		var text_px = 13.0 * win.x / vp.x
		_check("%s: body text at least 10 px on screen" % d[0], text_px >= 9.95,"%.1f px" % text_px)
		if shots != "":
			DirAccess.make_dir_recursive_absolute(shots)
			root.get_texture().get_image().save_png(shots.path_join("touch_%s_%s.png" % [d[0], "upright" if upright else "sideways"]))
	# A tap reaches a button through the interface scale.
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
	var portrait = Vector2i(mini(root.size.x, root.size.y), maxi(root.size.x, root.size.y))
	var landscape = Vector2i(portrait.y, portrait.x)
	root.size = portrait
	for i in 8:
		await process_frame
	touch._begin(0, touch._buttons["menu"]["rect"].get_center())
	root.size = landscape
	for i in 8:
		await process_frame
	touch._end(0)
	_check("rotation cancels a held Menu touch without opening a dialog", touch.active and not hud.modal_open() and touch._fingers.is_empty())
	touch._begin(0, touch._buttons["menu"]["rect"].get_center())
	touch._end(0)
	_check("a fresh landscape tap still opens the menu", hud._modal_kind == "pause")
	var uid = game.cluster.state["pods"][0]["uid"]
	for dialog in [["pause", hud.open_pause], ["vpn", hud.open_vpn], ["dashboard", func(): hud.open_screen(uid)]]:
		dialog[1].call()
		var modal: Control = hud._modal
		var scroll = modal.get_child(1)
		for size in [portrait, landscape]:
			root.size = size
			for i in 12:
				await process_frame
			var turned = size == portrait
			_check("%s reflows when turned %s" % [dialog[0], "to portrait" if turned else "to landscape"],
				hud._modal == modal and touch.active and is_equal_approx(hud.touch_u, touch._u) and
				is_zero_approx(scroll.rotation) and root.get_visible_rect().encloses(scroll.get_rect()), scroll.get_rect())
			if shots != "":
				root.get_texture().get_image().save_png(shots.path_join("rotated_%s_%s.png" % [dialog[0], "portrait" if turned else "landscape"]))
		hud.close_modal()
		await process_frame
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
