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
		if p["wname"] == "deluge" and not p.get("net", {}).get("vpn", {}).is_empty() and p["status"] == "Running":
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
	_check("a tunnel rises from every gateway", tunnel.size() == 11, tunnel.size())
	var machine = w.machines[gw["uid"]]
	var unit = s.get("unit") if s != null else null
	_check("the sidecar is seated on and attached to the pod roof",
		is_instance_valid(unit) and unit.get_parent() == machine and unit.position.is_equal_approx(machine.pipe_port(w.VPN_ROOF_OFFSET)))
	var plex = w.machines.values().filter(func(m): return m.pod["wname"] == "plex")[0]
	_check("one container pillar for Plex, two for Deluge and its sidecar", plex._tanks.size() == 1 and machine._tanks.size() == 2)
	var stand: StaticBody3D = machine._tanks[1]["stand"]
	var foot: MeshInstance3D = stand.get_child(1)
	_check("each indicator foot meets the platform", stand.position.y == 0 and is_zero_approx(foot.position.y - foot.mesh.height * 0.5))
	var centre = stand.to_global(Vector3(0, 1.25, 0))
	await physics_frame
	var ray = PhysicsRayQueryParameters3D.create(centre + Vector3(0.8, 0, 0), centre, 2)
	var aim = machine.get_world_3d().direct_space_state.intersect_ray(ray)
	var meta: Dictionary = aim["collider"].get_meta("kf") if not aim.is_empty() else {}
	_check("aiming at the second pillar identifies gluetun", meta.get("container_index") == 1 and
		game._tooltip("pod", meta, {}).contains("gluetun · Container 2 of 2"))
	var mode = game.mode
	game.mode = 5
	_check("aiming the Demolisher at an indicator gives no destructive action", not meta.is_empty() and game._hold_action("pod", meta).is_empty())
	game.mode = mode
	var feed = w._paths.filter(func(pa): return pa["color"] == w.VPN_FEED_COL)
	_check("a direct pipe seats against each sidecar", feed.size() == tunnel.size() and feed[0]["pts"].size() == 4, feed.size())
	var st = game.cluster.state
	var protected = st["pods"].filter(func(p): return w.Topology.protects(p["ns"], p["wname"]))
	_check("all downloaders and search apps use their own VPN", protected.size() == 11 and protected.all(func(p): return not p["net"]["vpn"].is_empty()))
	var links: Array = st["links"]
	_check("Tautulli reads Plex and Prometheus reads the simulated exporter",
		links.any(func(l): return l["from_name"] == "media/tautulli" and l["to_name"] == "media/plex") and
		links.any(func(l): return l["from_name"] == "monitoring/prometheus" and l["to_name"] == "media/tautulli"))
	_check("file transfers get separate animated pipes", w._paths.any(func(pa): return pa.get("kind") == "Files" and pa["n"] > 0))
	_check("each placed pod has a demo screen", w.machines.keys().all(func(uid): return game.demo_screens.has(uid)))
	game.hud.open_liveview()
	await process_frame
	_check("demo dashboard directory works without the desktop companion", game.hud._modal.find_children("*", "Button", true, false).size() == w.machines.size() + 1)
	game.hud.open_vpn()
	await create_timer(0.6).timeout
	var vtext = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("the VPN panel shows both sides", vtext.contains("INSIDE") and vtext.contains(v["exit_ip"]))
	_check("the VPN list includes qBittorrent and detects no unprotected downloaders", vtext.contains("qbittorrent") and vtext.contains("No unprotected downloaders detected"))
	if OS.get_environment("KF_SHOTS") != "":
		DirAccess.make_dir_recursive_absolute(OS.get_environment("KF_SHOTS"))
		root.get_texture().get_image().save_png(OS.get_environment("KF_SHOTS").path_join("vpn_panel_list.png"))
	game.hud.close_modal(false)
	game.hud.open_pod(gw["uid"])
	await create_timer(0.8).timeout
	var panel_text = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("the machine's panel shows both sides", panel_text.contains("INSIDE") and panel_text.contains(v["exit_ip"]))
	game.hud.open_network(gw["uid"])
	await process_frame
	var net_text = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("Deluge shows the VPN, VLAN and shared downloads mount", net_text.contains("VLAN 30") and net_text.contains("Gluetun") and net_text.contains("/downloads") and not net_text.contains("media/qbittorrent"))
	game.hud.open_blueprint_graph()
	await process_frame
	var graph = game.hud._modal.find_children("*", "GraphEdit", true, false)[0]
	var planner = graph.get_parent()
	planner.load_preset(true)
	var media_plan: Dictionary = planner.snapshot()
	_check("media planner has typed links, including VPN and files", media_plan["edges"].any(func(e): return e[2] == 3) and media_plan["edges"].any(func(e): return e[2] == 2))
	planner.load_preset(false)
	_check("shop preset has its own dependencies", planner.snapshot()["edges"].size() == 6)
	planner.restore(media_plan)
	_check("save data preserves all links and VLANs", planner.snapshot() == media_plan)
	game.hud._open_heimdall()
	await process_frame
	_check("Heimdall shows its recent failures and app directory", game.hud._modal_kind == "heimdall" and game.hud._modal.find_children("*", "Button", true, false).size() > 10)
	game.hud._open_image_updates()
	await process_frame
	_check("image updater has two simulated recommendations", st.get("image_updates", []).size() == 2)
	var check_update = st["image_updates"].filter(func(update): return update["name"] == "library-check")[0]
	var update_action: Dictionary = check_update.duplicate()
	update_action["op"] = "demo_update_image"
	_check("Heimdall caught the failed library check", demo_failure(game))
	_check("a sample update fixes the bad image tag", game.cluster.backend.run_action(update_action)["ok"] and
		not game.cluster.backend.fetch()["image_updates"].any(func(update): return update["name"] == "library-check"))
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		root.get_texture().get_image().save_png(dir.path_join("vpn_panel.png"))
		var m = w.machines[gw["uid"]]
		var c = m.get_parent().position + m.position
		game.hud.close_modal(false)
		game.player.flying = true
		var from = centre + Vector3(2.7, -1.1, 1.7)
		for view in [["vpn_tunnel", c + Vector3(-9, 9, 16), c + Vector3(1.4, 14, -1)], ["vpn_inside", c + Vector3(-3.5, 5, 9), c + Vector3(1.2, 6.5, -0.5)],
				["vpn_outside", c + Vector3(-6, 24, 12), c + Vector3(1.4, 28, -1)], ["container_pillars", from, centre]]:
			game.player.teleport(view[1], view[2])
			await create_timer(1.3).timeout
			root.get_texture().get_image().save_png(dir.path_join(view[0] + ".png"))
	_finish(game, path, before)

func demo_failure(game) -> bool:
	return game.demo_screens.recent_failures.values().any(func(p): return p["wname"] == "library-check" and p["status"] == "ImagePullBackOff")

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
