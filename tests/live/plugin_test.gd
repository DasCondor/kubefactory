extends SceneTree
# A backend plugin end to end: the static-world example, copied into the user
# plugins folder for the test and removed afterwards (with its trust entry).

const Plugins = preload("res://scripts/plugins.gd")

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(220)])
	if not ok:
		_fails.append(what)

func _wait(cond: Callable, seconds: float) -> bool:
	var deadline = Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.3).timeout
	return cond.call()

func _run() -> void:
	var dir = OS.get_user_data_dir().path_join("plugins/kf-test-static")
	DirAccess.make_dir_recursive_absolute(dir)
	for f in ["plugin.json", "plugin.py", "world.json"]:
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://examples/plugins/static-world/" + f), dir.path_join(f))
	var trust_path = OS.get_user_data_dir().path_join("plugin-trust.json")
	var trust_before = FileAccess.get_file_as_string(trust_path) if FileAccess.file_exists(trust_path) else ""
	var p = Plugins.find("kf-test-static")
	_check("the plugin is found and its manifest read", not p.is_empty() and p["error"] == "" and p["name"] == "Static world", p.get("error", "not found"))
	_check("it is not trusted yet", not p.get("trusted", true))
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var c = game.cluster
	await _wait(func(): return c.backend != null, 25.0)
	game.hud.close_modal(false)
	c.start("plugin", "Static world")
	await _wait(func(): return c.backend != null, 20.0)
	_check("an untrusted plugin does not run", c.state.get("source", "") != "plugin", c.state.get("source", ""))
	Plugins.set_trust(Plugins.find("kf-test-static"), true, false)
	c.start("plugin", "Static world")
	var up = await _wait(func(): return c.backend != null and c.state.get("source", "") == "plugin" and not c.state["pods"].is_empty(), 25.0)
	_check("once trusted, it serves its world", up and c.state["nodes"].map(func(n): return n["name"]) == ["garage-pi", "attic-nuc"], [c.state.get("source"), c.state.get("error")])
	if up:
		_check("its pods are machines on its nodes", c.state["pods"].filter(func(x): return x["name"] == "jellyfin")[0]["node"] == "attic-nuc")
		_check("a failing one is failing", c.state["pods"].filter(func(x): return x["name"] == "backup-job")[0]["health"] == "bad")
		await create_timer(2.0).timeout
		_check("the world built them", game.world.machines.size() == 4, game.world.machines.size())
		var r = c.backend.run_action({"op": "logs", "ns": "ops", "name": "backup-job"})
		_check("logs come from the plugin", r["ok"] and str(r["text"]).contains("backup-job"), r)
		var done = []
		c.action_done.connect(func(ok, msg): done.append([ok, msg]))
		c.act({"op": "restart", "ns": "network", "kind": "Deployment", "name": "pihole"})
		await _wait(func(): return not done.is_empty(), 10.0)
		_check("without 'allow changes' it cannot act", not done.is_empty() and not done[0][0], done)
	# a changed plugin is untrusted again
	var f = FileAccess.open(dir.path_join("world.json"), FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string("\n")
	f.close()
	_check("changing one of its files withdraws the trust", not Plugins.find("kf-test-static")["trusted"])
	game.queue_free()
	await process_frame
	for fn in ["plugin.json", "plugin.py", "world.json"]:
		DirAccess.remove_absolute(dir.path_join(fn))
	DirAccess.remove_absolute(dir)
	if trust_before == "":
		DirAccess.remove_absolute(trust_path)
	else:
		var tf = FileAccess.open(trust_path, FileAccess.WRITE)
		tf.store_string(trust_before)
		tf.close()
	print("PLUGIN PASSED" if _fails.is_empty() else "PLUGIN FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
