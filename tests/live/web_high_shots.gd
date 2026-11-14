extends SceneTree
# The browser's High preset, rendered on the desktop with the same renderer the
# browser uses (run with --rendering-method gl_compatibility). The model files
# go through the same in-memory path as in the browser (Models.web_load), read
# here from assets/ instead of fetched. KF_SHOTS=<dir> saves screenshots.

const Models = preload("res://scripts/models.gd")
const Gfx = preload("res://scripts/gfx.gd")

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(200)])
	if not ok:
		_fails.append(what)

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		await create_timer(0.8).timeout
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _run() -> void:
	var cat = JSON.parse_string(FileAccess.get_file_as_string("res://assets/catalog.json".replace("res://", ProjectSettings.globalize_path("res://"))))
	var files = {}
	for m in cat["models"]:
		if str(m["category"]) in ["machines", "krew", "tools"]:
			var rel = str(m["variants"]["standard"]["path"]).trim_prefix("assets/")
			files[rel] = FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://").path_join("assets/" + rel))
	Models.web_load(cat, files)
	Gfx.web_high = true
	_check("the light renderer is in use, as in the browser", Gfx.lite())
	_check("the library is available through the in-memory path", Models.available())
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	game.hud.close_modal(false)
	await create_timer(3.0).timeout
	_check("4x anti-aliasing", game.get_viewport().msaa_3d == Viewport.MSAA_4X)
	var modelled = game.world.machines.values().filter(func(m): return m.get("model_id") != null and str(m.get("model_id")) != "")
	print("machines: ", game.world.machines.size())
	game.player.flying = true
	var pos: Vector3 = game.world._krew_tags["scout"].get_parent().global_position
	game.player.teleport(pos + Vector3(-1.5, 0.6, 7.5), pos + Vector3(0, 1.4, 0))
	await _shot("web_high_krew")
	var m = game.world.machines.values()[0]
	game.player.teleport(m.global_position + Vector3(2.5, 1.5, 6.0), m.global_position + Vector3(0, 1.0, 0))
	await _shot("web_high_machines")
	game.queue_free()
	await process_frame
	print("WEB HIGH PASSED" if _fails.is_empty() else "WEB HIGH FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
