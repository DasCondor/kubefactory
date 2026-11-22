extends SceneTree
# The Clean slate wizard on a desktop and on a phone: it looks at this machine,
# fits the screen without sideways scrolling, and hands over the right command.
#
#   Godot --path . --resolution 1600x900 -s tests/live/clean_slate_ui_test.gd -- --demo
#   Godot --path . --resolution 390x844 -s tests/live/clean_slate_ui_test.gd -- --demo --touch
#
# KF_SHOTS=<dir> saves screenshots. The operator's settings.json is restored afterwards.
# It never saves the script and never runs it.

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(200)])
	if not ok:
		_fails.append(what)

func _button(hud: Node, caption: String) -> Button:
	for node in hud._modal.find_children("*", "Button", true, false):
		if node.text.strip_edges().begins_with(caption):
			return node
	return null

func _commands(hud: Node) -> Array:
	return hud._modal.find_children("*", "LineEdit", true, false).map(func(le): return le.text)

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _settle(hud: Node) -> void:
	var deadline = Time.get_ticks_msec() + 15000
	while hud._cs["checking"] and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	for i in 6:
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
	var phone = hud.touch_u > 0.0
	var tag = "phone" if phone else "desktop"
	hud.open_startup()
	await process_frame
	_check("the start menu offers Clean slate", _button(hud, "Clean slate") != null)
	hud.open_pause()
	await process_frame
	_check("the game menu offers Clean slate", _button(hud, "Clean slate") != null)

	hud.open_clusters()
	await process_frame
	var link = _button(hud, "Clean slate...")
	_check("Switch cluster links to Clean slate", link != null)
	link.pressed.emit()
	await _settle(hud)
	_check("the wizard opens", hud._modal_kind == "clean_slate")
	var det = hud._cs["det"]
	_check("it looked at this machine", det.get("checked", false), det)
	_check("WSL distributions are read whole", det.get("distros", []).all(func(n): return n.length() > 1), det.get("distros", []))
	var labels = hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)
	_check("it lists what it found", labels.any(func(t): return t == "Docker") and labels.any(func(t): return t.contains("engine")), "")
	var vp = root.get_visible_rect().size
	var widest = 0.0
	for c in hud._modal.find_children("*", "Control", true, false):
		if c.is_visible_in_tree() and not c is ScrollContainer and c.get_parent() != null:
			widest = maxf(widest, c.get_global_rect().end.x)
	_check("%s: nothing runs off the right edge" % tag, widest <= vp.x + 1.0, "%s > %s" % [widest, vp.x])
	if phone:
		var tb = _button(hud, "kind cluster")
		_check("phone: target buttons are thumb-sized", tb != null and tb.size.y >= 46, tb.size if tb else null)
	await _shot("clean-slate-%s-docker" % tag)

	for t in ["kind", "k3s", "docker-desktop"]:
		var b = _button(hud, {"kind": "kind cluster", "k3s": "k3s cluster", "docker-desktop": "Docker Desktop Kubernetes"}[t])
		b.pressed.emit()
		await _settle(hud)
		var cmds = _commands(hud)
		_check("%s: the command names it" % t, cmds.size() >= 3 and cmds[0].contains("-Target " + t), cmds)
		_check("%s: a plan-only command is offered" % t, cmds[1].contains("-Plan"), cmds)
	await _shot("clean-slate-%s-docker-desktop" % tag)
	_button(hud, "Also install the host service").pressed.emit()
	await _settle(hud)
	_check("the host service is added to the command", _commands(hud)[0].ends_with("-HostService"), _commands(hud))
	_button(hud, "k3s cluster").pressed.emit()
	await _settle(hud)
	_check("k3s on Windows leaves the host service out", not _commands(hud)[0].contains("-HostService"), _commands(hud))
	_button(hud, "Linux").pressed.emit()
	await _settle(hud)
	_check("the Linux script can be picked for another machine", _commands(hud)[0].begins_with("sudo sh install-kubefactory.sh --target k3s --host-service"), _commands(hud))
	_check("Docker Desktop Kubernetes is Windows only", _button(hud, "Docker Desktop Kubernetes").disabled)
	await _shot("clean-slate-%s-linux" % tag)
	hud._cs["os"] = ""
	hud._cs["host"] = false
	hud._cs["target"] = "docker"
	hud.close_modal(false)

	if before != "":
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("CLEAN SLATE UI PASSED (%s)" % tag if _fails.is_empty() else "CLEAN SLATE UI FAILED: %s" % ", ".join(PackedStringArray(_fails)))
	quit(0 if _fails.is_empty() else 1)
