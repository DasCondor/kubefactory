extends SceneTree
# Screenshot of the Krew stations in the simulation, for checking each graphics
# preset and renderer:  ... -s tests/live/krew_shots.gd -- --demo --gfx=<preset>
# KF_KREW_SHOTS=<dir>, KF_SHOT_NAME=<file name without .png>

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	game.hud.close_modal(false)
	await create_timer(3.0).timeout
	game.player.flying = true
	var worker = OS.get_environment("KF_SHOT_WORKER") if OS.get_environment("KF_SHOT_WORKER") != "" else "scout"
	if worker == "all":              # every station, from in front of both rows
		var c: Vector3 = (game.world._krew_tags["scout"].get_parent().global_position + game.world._krew_tags["forge"].get_parent().global_position) * 0.5
		game.player.teleport(c + Vector3(-3.0, 4.5, 15.0), c + Vector3(0, 1.0, -1.0))
	elif worker == "foreman":        # Foreman has his own desk, not a Krew station
		var st: Vector3 = game.world._foreman.global_position
		game.player.teleport(st + Vector3(-2.0, 0.5, 6.5), st + Vector3(0.6, 1.4, 0))
	else:
		var pos: Vector3 = game.world._krew_tags[worker].get_parent().global_position
		game.player.teleport(pos + Vector3(-1.5, 0.6, 7.5), pos + Vector3(0, 1.4, 0))
	await create_timer(1.5).timeout
	var dir = OS.get_environment("KF_KREW_SHOTS")
	DirAccess.make_dir_recursive_absolute(dir)
	root.get_texture().get_image().save_png(dir.path_join(OS.get_environment("KF_SHOT_NAME") + ".png"))
	print("SHOT SAVED")
	game.queue_free()
	await process_frame
	quit(0)
