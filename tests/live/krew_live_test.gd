extends SceneTree
# The Krew on real infrastructure (run the game against it):
#   Docker:  KF_KREW_MODE=docker  with a disposable container kf-krew-risky
#            (privileged, the engine socket mounted, a port on every address, a :latest image)
#   kind:    KF_KREW_MODE=kind    with namespace kf-krew-test holding a privileged pod that
#            mounts the host's root and shares its network, and a Service that selects nothing
# Read-only: it only checks what the workers report, and (Docker) runs the image scan.

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
		await create_timer(0.2).timeout
	return cond.call()

func _run() -> void:
	var mode = OS.get_environment("KF_KREW_MODE")
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var up = await _wait(func(): return game.cluster.backend != null and game.cluster.state.get("source", "") in ["docker", "kubernetes"] and not game.cluster.state["pods"].is_empty(), 60.0)
	_check("connected to a real %s" % mode, up, game.cluster.state.get("source", ""))
	if not up:
		quit(1)
		return
	game.hud.close_modal(false)
	var k = game.krew
	var keys = func(): return k.findings.keys()
	if mode == "docker":
		var o = "default/kf-krew-risky"
		await _wait(func(): return k.findings.has("sentinel:engine-socket:" + o), 20.0)
		_check("Sentinel: the engine socket is mounted", k.findings.get("sentinel:engine-socket:" + o, {}).get("severity") == "high")
		_check("Sentinel: privileged", k.findings.get("sentinel:privileged:" + o, {}).get("severity") == "high")
		_check("Sentinel: floating tag", k.findings.has("sentinel:floating-tag:" + o))
		_check("Scout: a port on every address of this machine", k.findings.has("scout:host-ports:" + o))
		_check("nothing is marked simulated", k.findings.values().all(func(f): return not f["simulated"]))
		game.cluster.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "krew:scan"})
		var expected = int(OS.get_environment("KF_KREW_UNUSED_IMAGES"))
		var count_unused = func(): return k.findings.values().filter(func(f): return f["rule"] == "unused-image").size()
		var scanned = await _wait(func(): return not k.scan.is_empty() and count_unused.call() >= expected, 30.0)
		await create_timer(3.0).timeout  # and nothing more than the engine's list turns up
		var unused = k.findings.values().filter(func(f): return f["rule"] == "unused-image")
		print("scan: ", k.scan.get("ok"), " ", k.scan.get("msg", ""), "  images ", k.scan.get("data", {}).get("images", []).size())
		_check("Scrappy: the engine's own list of unused images", scanned and unused.size() == expected, "%d reported, %d expected" % [unused.size(), expected])
		_check("Scrappy: each unused image offers a removal, nothing has been removed", unused.all(func(f): return f["action"].get("op") == "remove_image") and k.history.filter(func(f): return f["rule"] == "unused-image").is_empty())
	else:
		await _wait(func(): return k.findings.has("scout:no-pods:kf-krew-test/orphan"), 30.0)
		var o = "kf-krew-test/risky"
		_check("Sentinel: privileged pod", k.findings.get("sentinel:privileged:" + o, {}).get("severity") == "high")
		_check("Sentinel: the host's root is mounted", k.findings.get("sentinel:host-path:" + o, {}).get("severity") == "high")
		_check("Sentinel: shares the host's network", k.findings.has("sentinel:host-namespaces:" + o))
		_check("Sentinel: explicitly root", k.findings.has("sentinel:root:" + o))
		_check("Sentinel: kind's own kube-proxy is reported, lowered as a system component", k.findings.get("sentinel:privileged:kube-system/kube-proxy", {}).get("severity") == "medium")
		_check("Scout: the Service that selects nothing", k.findings.get("scout:no-pods:kf-krew-test/orphan", {}).get("severity") == "medium")
		game.cluster.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "krew:scan"})
		await _wait(func(): return not k.scan.is_empty(), 20.0)
		_check("Scrappy says the Kubernetes API cannot list unused images", not k.scan.get("ok", true) and str(k.scan.get("msg", "")).contains("container runtime"), k.scan.get("msg", ""))
	print("findings: ", k.findings.size(), "   by worker: ", k.WORKERS.map(func(w): return "%s %d" % [w["id"], k.of_worker(w["id"]).size()]))
	game.queue_free()
	await process_frame
	if _fails.is_empty():
		print("KREW LIVE PASSED")
	else:
		printerr("KREW LIVE FAILED: ", ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
