extends SceneTree
# The Krew in the running game, on a simulated world:
#   - every worker's rules run on the world's state
#   - a station opens the operations center on its worker
#   - an approved cleanup goes through the guard rails, and the finding is then
#     seen as resolved in the next state (not taken from the action's own answer)
#   - read-only mode disables the approval button
#
#   engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/krew_ui_test.gd -- --demo
# KF_KREW_SHOTS=<dir> also saves screenshots.

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(200)])
	if not ok:
		_fails.append(what)

func _find_button(node: Node, prefix: String) -> Button:
	if node is Button and node.text.begins_with(prefix) and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var found = _find_button(child, prefix)
		if found != null:
			return found
	return null

func _wait(game, cond: Callable, seconds: float) -> bool:
	var deadline = Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	return cond.call()

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_KREW_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		await create_timer(0.4).timeout
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var loaded = await _wait(game, func(): return game.cluster.backend != null and not game.world.machines.is_empty(), 25.0)
	if not loaded:
		printerr("Simulation did not load")
		quit(1)
		return
	game.hud.close_modal(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var k = game.krew
	await _wait(game, func(): return not k.findings.is_empty(), 10.0)
	_check("the Krew reports on the simulated world", k.findings.size() > 0, "%d findings" % k.findings.size())
	_check("Sentinel: kube-proxy runs privileged (system namespace, so medium)", k.findings.get("sentinel:privileged:kube-system/kube-proxy", {}).get("severity") == "medium")
	_check("Sentinel: node-exporter mounts the host's root", k.findings.has("sentinel:host-path:monitoring/node-exporter"))
	_check("Sentinel: checkout explicitly runs as root", k.findings.has("sentinel:root:shop/checkout"))
	_check("Scout: shop/search selects no pods", k.findings.has("scout:no-pods:shop/search"))
	_check("Scout: the LoadBalancer front door is noted", k.findings.has("scout:exposed:shop/frontend"))
	# in the demo world the migration Job finishes, and the broken pods start failing, a few seconds in
	await _wait(game, func(): return not k.of_worker("bob").is_empty() and k.of_worker("scrappy").any(func(f): return f["rule"] == "finished"), 40.0)
	_check("Bob's fix list feeds the Krew", k.of_worker("bob").size() > 0, k.status_of("bob"))
	var finished = k.of_worker("scrappy").filter(func(f): return f["rule"] == "finished")
	_check("Scrappy: the finished migration Job pod", finished.size() == 1, finished.map(func(f): return f["resource"]))
	_check("every finding in a simulated world says so", k.findings.values().all(func(f): return f["simulated"]))
	# the stations
	game.player.flying = true
	var tag = game.world._krew_tags["sentinel"]
	var pos: Vector3 = tag.get_parent().global_position
	game.player.teleport(pos + Vector3(-3.0, 0.4, 10.0), pos + Vector3(2.5, 1.6, 0))
	await create_timer(0.8).timeout
	_check("each station shows its worker's state", tag.text.contains("finding"), tag.text.replace("\n", " | "))
	await _shot("krew_stations")
	game.player.teleport(pos + Vector3(0, 0.0, 4.0), pos + Vector3(0, 1.2, 0))
	await create_timer(0.6).timeout
	_check("aiming at Sentinel", game.player.hit.get("meta", {}).get("type", "") == "krew" and game.player.hit.get("meta", {}).get("worker", "") == "sentinel")
	game._interact()
	_check("its station opens the operations center on Sentinel", game.hud._modal_kind == "krew" and game.hud._krew_focus == "sentinel")
	game.hud._krew_open["sentinel:engine-socket:ci/nightly-engine-build"] = true
	game.hud._krew_open["sentinel:privileged:kube-system/kube-proxy"] = true
	game.hud._fill_krew(true)
	await _shot("krew_panel_sentinel")
	# approve a cleanup, in read-only mode first
	game.hud.open_krew("scrappy")
	var fkey = str(finished[0]["key"]) if not finished.is_empty() else ""
	game.hud._krew_open[fkey] = true
	game.cluster.read_only = true
	game.hud._fill_krew(true)
	var b = _find_button(game.hud._modal, "MK.4  Remove pod")
	_check("read-only mode: the approval button is disabled", b != null and b.disabled)
	game.cluster.read_only = false
	game.hud._fill_krew(true)
	b = _find_button(game.hud._modal, "MK.4  Remove pod")
	_check("the approval button is offered", b != null and not b.disabled)
	await _shot("krew_panel_scrappy")
	if b != null:
		b.pressed.emit()
		if game.hud._modal_kind == "confirm" or game.hud._modal_kind == "guard":
			print("NOTE  a typed confirmation was asked for")
	var pod_name = str(finished[0]["action"]["name"]) if not finished.is_empty() else ""
	var resolved = await _wait(game, func(): return k.history.any(func(f): return f["key"] == fkey) and not game.cluster.state["pods"].any(func(p): return p["name"] == pod_name), 15.0)
	_check("the approved removal ran, and the next state shows it resolved", resolved, "%s still present: %s" % [pod_name, game.cluster.state["pods"].any(func(p): return p["name"] == pod_name)])
	# Scrappy's image scan, and removing one unused image
	game.cluster.act({"op": "cleanup_scan", "ns": "", "name": "", "key": "krew:scan"})
	var scanned = await _wait(game, func(): return k.findings.keys().any(func(x): return str(x).begins_with("scrappy:unused-image")), 15.0)
	_check("the scan finds unused images", scanned, k.status_of("scrappy"))
	_check("the unattached volume is reported but offered no removal", k.findings.get("scrappy:unattached-volume:volume/old-catalog-backup", {}).get("action", null) == {})
	var img = k.findings.values().filter(func(f): return f["rule"] == "unused-image")
	if not img.is_empty():
		var ikey = str(img[0]["key"])
		game.hud.guarded_act(img[0]["action"], "remove", str(img[0]["action"]["name"]))
		var gone = await _wait(game, func(): return k.history.any(func(f): return f["key"] == ikey), 15.0)
		_check("an approved image removal is followed by a fresh scan that no longer lists it", gone)
	game.hud.open_krew()
	await _shot("krew_panel_all")
	var md = k.report_markdown()
	_check("the report says SIMULATED and lists the resolved", md.contains("SIMULATED") and md.contains("## Resolved"))
	game.queue_free()
	await process_frame
	await process_frame
	if _fails.is_empty():
		print("KREW UI PASSED")
	else:
		printerr("KREW UI FAILED: ", ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
