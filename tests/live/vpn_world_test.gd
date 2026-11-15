extends SceneTree
# The VPN gateway in the media demo world: Deluge's pod has a Gluetun sidecar.
# Checks the tunnel and its two signs (inside: the pod's address; outside: the
# simulated exit address, marked SIMULATED) and the machine's panel.
#   ... -s tests/live/vpn_world_test.gd -- --demo=media
# KF_SHOTS=<dir> saves screenshots. The operator's settings.json is restored.

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
	await create_timer(3.0).timeout
	game.hud.close_modal(false)
	var w = game.world
	var gw = null
	for p in game.cluster.state["pods"]:
		if not p.get("net", {}).get("vpn", {}).is_empty() and p["status"] == "Running":
			gw = p
	_check("the media world has a VPN gateway (Deluge with its Gluetun sidecar)", gw != null)
	if gw == null:
		_finish(game, path, before)
		return
	var v = gw["net"]["vpn"]
	_check("inside: the pod's address", not gw["net"]["addrs"].is_empty(), gw["net"]["addrs"])
	_check("outside: a documentation-range address, marked SIMULATED", str(v["exit_ip"]).begins_with("203.0.113.") and v["exit_note"] == "SIMULATED", "%s %s" % [v["exit_ip"], v["exit_note"]])
	_check("what goes through it: deluge", "deluge" in v["through"], v["through"])
	var s = w._vpn_signs.get(gw["uid"])
	_check("both signs stand in the world", s != null and is_instance_valid(s["inside"]) and is_instance_valid(s["outside"]))
	if s != null:
		_check("the inside sign shows the inside address", s["inside"].text.contains(str(gw["net"]["addrs"][0]).get_slice(" ", 0)), s["inside"].text.replace("\n", " | "))
		_check("the outside sign shows the exit address", s["outside"].text.contains(v["exit_ip"]), s["outside"].text.replace("\n", " | "))
		_check("the outside sign is at the top of the tunnel", s["outside"].position.y > s["inside"].position.y + 15.0, [s["inside"].position.y, s["outside"].position.y])
	var tunnel = w._paths.filter(func(pa): return pa["color"] == w.VPN_TUNNEL_COL)
	_check("a tunnel rises from the gateway", tunnel.size() == 1, tunnel.size())
	game.hud.open_pod(gw["uid"])
	await create_timer(0.8).timeout
	var panel_text = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("the machine's panel shows both sides", panel_text.contains("INSIDE") and panel_text.contains(v["exit_ip"]))
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		root.get_texture().get_image().save_png(dir.path_join("vpn_panel.png"))
		var m = w.machines[gw["uid"]]
		var c = m.get_parent().position + m.position
		game.hud.close_modal(false)
		game.player.flying = true
		for view in [["vpn_tunnel", c + Vector3(-9, 9, 16), c + Vector3(1.4, 14, -1)], ["vpn_inside", c + Vector3(-3.5, 5, 9), c + Vector3(1.2, 6.5, -0.5)],
				["vpn_outside", c + Vector3(-6, 24, 12), c + Vector3(1.4, 28, -1)]]:
			game.player.teleport(view[1], view[2])
			await create_timer(1.3).timeout
			root.get_texture().get_image().save_png(dir.path_join(view[0] + ".png"))
	_finish(game, path, before)

func _finish(game, path, before) -> void:
	game.queue_free()
	await process_frame
	if before == "":
		DirAccess.remove_absolute(path)
	else:
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("VPN WORLD PASSED" if _fails.is_empty() else "VPN WORLD FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
