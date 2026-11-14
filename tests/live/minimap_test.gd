extends SceneTree
# The minimap on the simulation: shown, turned so that what you face is up,
# machines in their health colours, N hides it and the choice is saved.
# The operator's settings.json is restored afterwards. KF_SHOTS=<dir> saves screenshots.

const K = preload("res://scripts/kutil.gd")

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
	game.hud.close_modal(false)
	await create_timer(2.0).timeout
	var mm = game.hud.minimap
	_check("the minimap is on screen", mm != null and mm.visible)
	# face a machine: it should sit straight above the middle of the map
	var m = game.world.machines.values()[0]
	var spot = game.world.machine_spot(m.uid)
	game.player.teleport(spot[0], spot[1])
	await create_timer(0.5).timeout
	var v: Vector2 = mm._to_map(m.global_position)
	var c = mm._centre()
	_check("what you face is up on the map", v.y < c.y - 4.0 and absf(v.x - c.x) < absf(v.y - c.y), [v, c])
	var behind: Vector2 = mm._to_map(game.player.global_position + game.player.global_transform.basis.z * 10.0)
	_check("what is behind you is below", behind.y > c.y + 4.0, behind)
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		game.player.teleport(Vector3(0, 2, 24), Vector3(0, 1.5, -10))
		await create_timer(1.0).timeout
		DirAccess.make_dir_recursive_absolute(dir)
		root.get_texture().get_image().save_png(dir.path_join("minimap.png"))
	game.hud.toggle_minimap()
	await process_frame
	_check("N hides it, and the choice is saved", not mm.visible and K.load_settings().get("minimap") == false)
	game.hud.toggle_minimap()
	await process_frame
	_check("and shows it again", mm.visible and K.load_settings().get("minimap") == true)
	game.queue_free()
	await process_frame
	if before == "":
		DirAccess.remove_absolute(path)
	else:
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("MINIMAP PASSED" if _fails.is_empty() else "MINIMAP FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
