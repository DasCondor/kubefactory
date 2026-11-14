extends SceneTree
# A Komodo connection in the running game, against tests/live/mock_komodo.py:
# saved through the companion, listed as a connection, connected read-only,
# servers become platforms and containers machines, the Krew reads them, and
# nothing but /read is ever sent. Needs KF_MOCK_KOMODO_PORT, KF_MOCK_KOMODO_RECORD
# and KF_CONFIG_DIR (a throw-away folder for the companion's settings).
# KF_SHOTS=<dir> saves a screenshot.

const Agent = preload("res://scripts/agent.gd")

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
	var port = OS.get_environment("KF_MOCK_KOMODO_PORT")
	var saved = Agent.request("komodo.save", {"name": "Home Komodo", "base_url": "http://127.0.0.1:" + port, "key": "K-mock-key-0000", "secret": "S-mock-secret-0000"}, 15.0)
	_check("the companion saves the connection", saved["ok"], saved["msg"])
	_check("the key and secret do not come back", not JSON.stringify(saved).contains("mock-key") and not JSON.stringify(saved).contains("mock-secret"))
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var c = game.cluster
	await _wait(func(): return c.backend != null, 30.0)
	game.hud.close_modal(false)
	c.discover_targets()
	await _wait(func(): return c.targets.any(func(t): return t["source"] == "komodo"), 20.0)
	_check("it is listed as a connection", c.targets.any(func(t): return t["source"] == "komodo" and t["context"] == "Home Komodo"))
	c.start("komodo", "Home Komodo")
	var up = await _wait(func(): return c.backend != null and c.state.get("source", "") == "komodo" and not c.state["pods"].is_empty(), 30.0)
	_check("connected", up, [c.state.get("source"), c.state.get("error")])
	if up:
		_check("opened read-only", c.read_only)
		_check("servers are platforms", c.state["nodes"].map(func(n): return n["name"]) == ["pve-docker-1", "pve-docker-2", "nas"])
		_check("a server Komodo cannot reach is shown not ready", c.state["nodes"].filter(func(n): return n["name"] == "nas")[0]["ready"] == false)
		_check("containers are machines on their server", c.state["pods"].filter(func(p): return p["name"] == "paperless")[0]["node"] == "pve-docker-2")
		_check("an exited container is failing", c.state["pods"].filter(func(p): return p["name"] == "immich-postgres")[0]["health"] == "bad")
		await _wait(func(): return game.krew.source == "komodo" and game.krew.findings.keys().any(func(k): return str(k).begins_with("scout:")), 15.0)
		_check("Bob sees the failed container", game.krew.findings.keys().any(func(k): return str(k).begins_with("bob:") and str(k).contains("immich-postgres")))
		_check("Scout sees the port open on every address", game.krew.findings.has("scout:host-ports:pve-docker-1/immich-server"))
		await create_timer(2.0).timeout
		_check("the world built the machines", game.world.machines.size() == 4, game.world.machines.size())
		var done = []
		c.action_done.connect(func(ok, msg): done.append([ok, msg]))
		c.read_only = false
		c.act({"op": "restart", "ns": "pve-docker-1", "kind": "Container", "name": "immich-server", "pod": "immich-server"})
		await _wait(func(): return not done.is_empty(), 10.0)
		_check("even with read-only off, nothing can be changed through Komodo", not done.is_empty() and not done[0][0], done)
		var dir = OS.get_environment("KF_SHOTS")
		if dir != "":
			game.player.teleport(Vector3(0, 3, 26), Vector3(0, 1.5, -8))
			await create_timer(1.0).timeout
			DirAccess.make_dir_recursive_absolute(dir)
			root.get_texture().get_image().save_png(dir.path_join("komodo.png"))
	var rec = FileAccess.get_file_as_string(OS.get_environment("KF_MOCK_KOMODO_RECORD"))
	var lines = Array(rec.split("\n", false)).map(func(l): return JSON.parse_string(l))
	_check("only /read was ever called, with the three read requests", lines.all(func(l): return l["path"] == "/read" and l["type"] in ["GetVersion", "ListServers", "ListAllDockerContainers"]), lines.size())
	game.queue_free()
	await process_frame
	print("KOMODO PASSED" if _fails.is_empty() else "KOMODO FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
