extends SceneTree
# Archie, Forge and Blueprint on the real Docker engine (read-only), with
# throw-away containers the runner creates and removes:
#   kf-afb-db       image kf-afb/postgres:dev, built locally, no volume
#   kf-afb-anon     busybox with an unnamed volume at /data
#   compose project kfafb, service web with 2 containers, one stopped
# Blueprint holds drift for two minutes, so this test takes about three.

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
		await create_timer(0.5).timeout
	return cond.call()

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var up = await _wait(func(): return game.cluster.state.get("source", "") == "docker" and not game.cluster.state["pods"].is_empty(), 60.0)
	_check("connected to the real Docker engine", up)
	if not up:
		quit(1)
		return
	game.hud.close_modal(false)
	var k = game.krew
	await _wait(func(): return k.findings.has("archie:anonymous-volume:default/kf-afb-anon"), 20.0)
	_check("Archie: a database image with no volume is high", k.findings.get("archie:no-persistent-storage:default/kf-afb-db", {}).get("severity") == "high", k.of_worker("archie").map(func(f): return f["key"]))
	_check("Archie: an unnamed volume", k.findings.has("archie:anonymous-volume:default/kf-afb-anon"))
	_check("Forge says it needs a scan first", k.status_of("forge") == "images not scanned yet")
	game.cluster.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "krew:scan"})
	await _wait(func(): return not k.scan.is_empty(), 40.0)
	await create_timer(3.0).timeout
	var local = k.of_worker("forge").filter(func(f): return f["rule"] == "local-build")
	if str(k.scan.get("data", {}).get("provenance", "")) == "unrecorded":
		# Docker Desktop's containerd image store: every image carries a digest of its own
		_check("Forge says this engine does not record image origin, and guesses nothing", local.is_empty() and k.status_of("forge").contains("does not record"), k.status_of("forge"))
	else:
		_check("Forge: the locally built image in use, and only images without a registry digest", local.any(func(f): return f["title"].contains("kf-afb/postgres:dev")) and not local.any(func(f): return f["title"].contains("busybox")), local.map(func(f): return f["title"]))
	_check("Blueprint waits before calling it drift", not k.findings.has("blueprint:drift:kfafb/web"))
	var drift = await _wait(func(): return k.findings.has("blueprint:drift:kfafb/web"), 170.0)
	_check("Blueprint: the Compose service runs 1 of 2 containers", drift and k.findings["blueprint:drift:kfafb/web"]["title"].contains("1 of 2"), k.findings.get("blueprint:drift:kfafb/web", {}).get("title", ""))
	_check("none of them offers an action", k.findings.values().filter(func(f): return f["worker"] in ["archie", "forge", "blueprint"] and not f["action"].is_empty()).is_empty())
	_check("nothing is marked simulated", k.findings.values().all(func(f): return not f["simulated"]))
	game.queue_free()
	await process_frame
	if _fails.is_empty():
		print("KREW AFB LIVE PASSED")
	else:
		printerr("KREW AFB LIVE FAILED: ", ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
