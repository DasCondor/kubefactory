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

func _button(hud: Node, caption: String) -> Button:
	for node in hud._modal.find_children("*", "Button", true, false):
		if node.text.strip_edges() == caption or node.tooltip_text == caption:
			return node
	return null

func _tap(button: Button) -> void:
	if button == null:
		_check("A menu action is available to tap", false)
		return
	var at = root.get_final_transform() * (button.get_global_transform_with_canvas() * (button.size * 0.5))
	for down in [true, false]:
		var e = InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = at
		e.global_position = at
		root.push_input(e)
		await process_frame

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
		var scroll = hud._mobile_scroll
		var vp = root.get_visible_rect().size
		_check("%s: scroll frame fits the viewport" % d[0], Rect2(Vector2.ZERO, vp).encloses(scroll.get_global_rect()), scroll.get_global_rect())
		_check("%s: stays upright" % d[0], is_zero_approx(scroll.rotation), scroll.rotation)
		if d[0] == "demos":
			_check("Demo cards use the available width", hud._demo_cards.columns == (2 if win.x >= 660.0 else 1))
		# body text (13 px in the dialog) as drawn on the screen, in window pixels
		var text_px = 13.0 * win.x / vp.x
		_check("%s: body text at least 10 px on screen" % d[0], text_px >= 9.95,"%.1f px" % text_px)
		if d[0] in ["settings", "demos", "pause", "vpn", "foreman", "krew"]:
			_check("%s: fits without horizontal swiping" % d[0], not scroll.get_h_scroll_bar().visible)
		var close = _button(hud, "Close")
		var close_pos = close.get_global_rect()
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await process_frame
		_check("%s: Close stays pinned after scrolling" % d[0], root.get_visible_rect().encloses(close_pos) and close.get_global_rect().is_equal_approx(close_pos))
		scroll.scroll_vertical = 0
		await process_frame
		if shots != "":
			DirAccess.make_dir_recursive_absolute(shots)
			root.get_texture().get_image().save_png(shots.path_join("touch_%s_%s.png" % [d[0], "upright" if upright else "sideways"]))
	# A tap reaches a button through the interface scale.
	hud.open_demos()
	for i in 8:
		await process_frame
	var b = _button(hud, "Play")
	if b == null:
		b = _button(hud, "Resume")
	var label = b.text.strip_edges()             # pressing it may close the dialog
	var hit = [false]
	b.pressed.connect(func(): hit[0] = true)
	await _tap(b)
	_check("a tap on '%s' presses it" % label, hit[0])
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
	for i in 8:
		await process_frame
	await _tap(_button(hud, "Network"))
	for i in 8:
		await process_frame
	_check("Network opens from the pause menu", hud._modal_kind == "network" and not hud._mobile_scroll.get_h_scroll_bar().visible)
	await _tap(_button(hud, "Ports and readiness"))
	for i in 8:
		await process_frame
	_check("Ports open from Network", hud._modal_kind == "ports" and not hud._mobile_scroll.get_h_scroll_bar().visible)
	await _tap(_button(hud, "Back"))
	for i in 8:
		await process_frame
	_check("Back from Ports returns to Network", hud._modal_kind == "network")
	await _tap(_button(hud, "Back"))
	_check("Back from Network returns to the pause menu", hud._modal_kind == "pause")
	for i in 8:
		await process_frame
	await _tap(_button(hud, "Settings"))
	_check("Settings opens the touch controls page", hud._modal_kind == "touch_settings")
	var look_slider = hud._modal.find_children("*", "HSlider", true, false)[0]
	look_slider.value = 1.7
	_check("Touch look speed updates and is saved", is_equal_approx(touch.sensitivity, 1.7) and is_equal_approx(float(hud.settings.get("touch_sensitivity", 0.0)), 1.7))
	hud.open_liveview()
	var search = hud._modal.find_children("*", "LineEdit", true, false)[0]
	var count_views = func(): return hud._modal.find_children("*", "Button", true, false).filter(func(button): return button.text == "View" and button.is_visible_in_tree()).size()
	var all_views = count_views.call()
	_check("Dashboards lists every pod with a blank search", all_views > 0 and all_views == game.demo_screens.screens().size())
	search.text_changed.emit("coredns")
	var filtered = count_views.call()
	_check("Dashboard search filters the pod list", filtered > 0 and filtered < all_views)
	search.clear()
	_check("Clearing search restores the pod list", count_views.call() == all_views)
	var uid = game.cluster.state["pods"][0]["uid"]
	for dialog in [["pause", hud.open_pause], ["vpn", hud.open_vpn], ["dashboard", func(): hud.open_screen(uid)]]:
		dialog[1].call()
		var modal: Control = hud._modal
		var scroll = hud._mobile_scroll
		for size in [portrait, landscape]:
			root.size = size
			for i in 12:
				await process_frame
			var turned = size == portrait
			_check("%s reflows when turned %s" % [dialog[0], "to portrait" if turned else "to landscape"],
				hud._modal == modal and touch.active and is_equal_approx(hud.touch_u, touch._u) and
				is_zero_approx(scroll.rotation) and root.get_visible_rect().encloses(scroll.get_global_rect()), scroll.get_global_rect())
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
