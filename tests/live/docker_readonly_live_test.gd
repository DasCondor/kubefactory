extends SceneTree
# A Docker host behind the read-only proxy (deploy/docker-readonly), reached
# through a Docker context, as docs/DOCKER_HOSTS.md sets it up. The runner
# creates a throw-away proxy, context and container and removes them after.
#   KF_RO_CONTEXT=<context>  KF_RO_VICTIM=<container name>
#   engine\...console.exe --path . -s tests/live/docker_readonly_live_test.gd -- --docker --context=<context>

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
	var ctx = OS.get_environment("KF_RO_CONTEXT")
	var victim = OS.get_environment("KF_RO_VICTIM")
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var c = game.cluster
	var up = await _wait(func(): return c.backend != null and c.state.get("source", "") == "docker" and not c.state["pods"].is_empty(), 60.0)
	_check("connected to the Docker context through the proxy", up and c.state["context"] == ctx, [c.state.get("source"), c.state.get("context")])
	if not up:
		quit(1)
		return
	game.hud.close_modal(false)
	_check("the context is listed as a connection of its own", c.targets.any(func(t): return t["source"] == "docker" and t["context"] == ctx))
	_check("another host's engine opens read-only", c.read_only and c.backend.remote)
	_check("its containers are read through the proxy", c.state["pods"].any(func(p): return p["name"] == victim))
	_check("docker inspect works through the proxy (Sentinel sees the floating tag)", c.state["pods"].filter(func(p): return p["name"] == victim).any(func(p): return not p["sec"]["latest"].is_empty()))
	var got = []
	c.data_ready.connect(func(key, r): got.append([key, r]))
	c.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "ro:scan"})
	await _wait(func(): return got.any(func(x): return x[0] == "ro:scan"), 30.0)
	var scan = got.filter(func(x): return x[0] == "ro:scan")
	_check("the image and volume scan works through the proxy", not scan.is_empty() and scan[0][1].get("ok", false), scan[0][1].get("msg", "") if not scan.is_empty() else "no answer")
	# the game's own read-only switch blocks the removal first
	var done = []
	c.action_done.connect(func(ok, msg): done.append([ok, msg]))
	c.act({"op": "delete_pod", "ns": "default", "name": victim})
	await _wait(func(): return not done.is_empty(), 10.0)
	_check("read-only mode blocks the removal in the game", not done.is_empty() and not done[0][0] and str(done[0][1]).contains("Read-only"), done)
	# and with it off, the host's proxy refuses it
	c.read_only = false
	done.clear()
	c.act({"op": "delete_pod", "ns": "default", "name": victim})
	await _wait(func(): return not done.is_empty(), 30.0)
	_check("with read-only off, the engine behind the proxy refuses the removal, and says so plainly", not done.is_empty() and not done[0][0] and str(done[0][1]).contains("read-only proxy"), done)
	await create_timer(4.0).timeout
	_check("the container is still there", c.state["pods"].any(func(p): return p["name"] == victim))
	game.queue_free()
	await process_frame
	print("DOCKER READ-ONLY PASSED" if _fails.is_empty() else "DOCKER READ-ONLY FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
