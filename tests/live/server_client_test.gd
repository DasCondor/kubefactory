extends SceneTree
# A player's game against a KubeFactory server (another process started with
# --server on the simulation). KF_SERVER_URL, KF_TOKEN_VIEWER, KF_TOKEN_OPERATOR
# come from the server's server-new-tokens.txt in a throw-away KF_SERVER_DIR.

const Remote = preload("res://scripts/backend_remote.gd")

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
	var url = OS.get_environment("KF_SERVER_URL")
	var bad = Remote.new()
	bad.url = url
	bad.token = "0123456789abcdef0123456789abcdef"
	var br = bad.probe()
	_check("a wrong token is refused", not br.ok and str(br.msg).contains("not valid"), br.msg)
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var c = game.cluster
	await _wait(func(): return c.backend != null, 25.0)
	game.hud.close_modal(false)
	c.remote_token = OS.get_environment("KF_TOKEN_VIEWER")
	c.start("remote", url)
	var up = await _wait(func(): return c.backend != null and c.backend.label == "remote" and not c.state.get("pods", []).is_empty(), 30.0)
	_check("a viewer gets the server's world", up and c.state.get("source", "") == "simulation", [c.state.get("source"), c.state.get("error")])
	_check("the token is not kept by the client", c.remote_token == "" and up and c.backend.token == "")
	if up:
		_check("a viewer's game is read-only", c.read_only and c.backend.role == "viewer")
		await create_timer(2.0).timeout
		_check("the world is built from it", game.world.machines.size() > 5, game.world.machines.size())
		var pod = c.state["pods"][0]
		var lr = c.backend.run_action({"op": "logs", "ns": pod["ns"], "name": pod["name"], "tail": 20})
		_check("a viewer can read logs through the server", lr.get("ok", false) and str(lr.get("text", "")) != "", lr.get("msg", ""))
		var rr = c.backend.run_action({"op": "restart", "ns": "shop", "kind": "Deployment", "name": "cart"})
		_check("the server refuses a viewer's restart", not rr.get("ok", true) and str(rr.get("msg", "")).contains("MK.1"), rr.get("msg", ""))
	var op = Remote.new()
	op.url = url
	op.token = OS.get_environment("KF_TOKEN_OPERATOR")
	var orr = op.probe()
	_check("an operator signs in", orr.ok and op.role == "operator", orr.msg)
	if orr.ok:
		var r2 = op.run_action({"op": "restart", "ns": "shop", "kind": "Deployment", "name": "cart"})
		_check("an operator's restart runs on the server", r2.get("ok", false), r2)
		op.cleanup()
	game.queue_free()
	await process_frame
	print("SERVER PASSED" if _fails.is_empty() else "SERVER FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
