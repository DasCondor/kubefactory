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
		_check("the outside port identifies its pod and simulated exit address",
			s["outside"].text.contains(gw["name"]) and s["outside"].text.contains(v["exit_ip"]) and s["outside"].text.contains("SIMULATED"))
	var tunnel = w._paths.filter(func(pa): return pa["color"] == w.VPN_TUNNEL_COL)
	_check("each of the nine gateways has its own pipe to the station", tunnel.size() == 9 and is_instance_valid(w._internet_output), tunnel.size())
	var station: Node3D = w._internet_output
	var input_label: Label3D = station.get_node("FactoryInputs")
	var output_label: Label3D = station.get_node("PublicOutput")
	_check("inputs and the WWW outlet face opposite directions on opposite sides", input_label.position.z > 0.0 and
		output_label.position.z < station.get_node("PublicInternetPipe").position.z and
		is_equal_approx(input_label.rotation.y, 0.0) and is_equal_approx(absf(output_label.rotation.y), PI))
	var ends = {}
	for route in tunnel:
		var end: Vector3 = route["pts"].back()
		ends[end] = true
		var signs: Dictionary = w._vpn_signs[route["vpn_uid"]]
		var pod: Dictionary = w.machines[route["vpn_uid"]].pod
		var source = w.machines[route["vpn_uid"]]
		var start: Vector3 = w.to_local(signs["unit"].to_global(Vector3.UP * w.VPN_UNIT_H)) if is_instance_valid(signs["unit"]) else w._vpn_anchor(source)
		_check("%s runs from its VPN to its labeled port past every platform" % pod["wname"],
			route["pts"].size() == 4 and start.is_equal_approx(route["pts"].front()) and
			is_equal_approx(end.z, w._internet_output.position.z) and signs["outside"].position.distance_to(end) < 1.0 and
			signs["outside"].text.contains(pod["name"]) and
			w.platforms.values().all(func(pf): return end.z < pf.position.z - pf.depth))
	_check("no gateways share the same output port", ends.size() == tunnel.size())
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
	_check("eight sidecars keep their direct feeds", feed.filter(func(pa): return not pa.has("vpn_join") and pa["pts"].size() == 4).size() == 8)
	var st = game.cluster.state
	var shared = st["pods"].filter(func(p): return p["wname"] == w.Topology.SHARED_VPN)[0]
	var protected = st["pods"].filter(func(p): return w.Topology.protects(p["ns"], p["wname"]))
	var members = protected.filter(func(p): return p["net"]["via"] == shared["uid"])
	_check("Sonarr, Radarr, and Prowlarr use the same gateway", members.size() == 3 and
		members.all(func(p): return p["name"] in shared["net"]["vpn"]["through"]), shared["net"]["vpn"]["through"])
	_check("all eleven downloaders and search apps still have a VPN", protected.size() == 11 and
		protected.all(func(p): return not p["net"]["vpn"].is_empty() or p["net"]["via"] == shared["uid"]))
	_check("three pods feed the shared gateway through one collector", feed.filter(func(pa): return pa.get("vpn_join") == "branch" and pa["vpn_uid"] == shared["uid"]).size() == 3 and
		feed.filter(func(pa): return pa.get("vpn_join") == "riser" and pa["vpn_uid"] == shared["uid"]).size() == 1)
	var links: Array = st["links"]
	_check("Tautulli reads Plex and Prometheus reads the simulated exporter",
		links.any(func(l): return l["from_name"] == "media/tautulli" and l["to_name"] == "media/plex") and
		links.any(func(l): return l["from_name"] == "monitoring/prometheus" and l["to_name"] == "media/tautulli"))
	_check("file transfers get separate animated pipes", w._paths.any(func(pa): return pa.get("kind") == "Files" and pa["n"] > 0))
	_check("each placed pod has a demo screen", w.machines.keys().all(func(uid): return game.demo_screens.has(uid)))
	var sonarr = members.filter(func(p): return p["wname"] == "sonarr")[0]
	var sonarr_screen = game.demo_screens._screens[sonarr["uid"]]["panel"]
	_check("the Sonarr dashboard shows its shared VPN and service port", sonarr_screen.route.contains("arr-vpn") and
		sonarr_screen.ports.any(func(r): return r["port"] == "8989/TCP" and r["health"] == "ok"))
	var deluge_screen = game.demo_screens._screens[gw["uid"]]["panel"]
	var shared_downloads = sonarr_screen.disks.filter(func(d): return d["label"] == "media-vpn · downloads")[0]
	_check("Sonarr and Deluge see the same download volume and one used-space total", shared_downloads in deluge_screen.disks and
		shared_downloads["used"] == 3145728 and shared_downloads["capacity"] == 10737418240 and shared_downloads["containers"].size() == 3)
	game.hud.open_shared_disks(sonarr["uid"])
	var disk_text = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("shared disk details include every mount and exclude similarly named disks in other namespaces",
		disk_text.contains("deluge") and disk_text.contains("radarr") and disk_text.contains("Read-only") and disk_text.contains("Read/write") and
		not disk_text.contains("qbittorrent"))
	if OS.get_environment("KF_SHOTS") != "":
		DirAccess.make_dir_recursive_absolute(OS.get_environment("KF_SHOTS"))
		await create_timer(0.3).timeout
		root.get_texture().get_image().save_png(OS.get_environment("KF_SHOTS").path_join("shared_disk_space.png"))
	game.hud.open_ports()
	var port_text = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("the cluster port view distinguishes the failed health service and ready apps",
		port_text.contains("9101/TCP") and port_text.contains("0/1 pods ready") and port_text.contains("1/1 pods ready"))
	if OS.get_environment("KF_SHOTS") != "":
		DirAccess.make_dir_recursive_absolute(OS.get_environment("KF_SHOTS"))
		await process_frame
		root.get_texture().get_image().save_png(OS.get_environment("KF_SHOTS").path_join("demo_port_readiness.png"))
	game.hud.open_screen(sonarr["uid"])
	var port_tab = game.hud._modal.find_children("*", "Button", true, false).filter(func(b): return b.text == "Ports")[0]
	port_tab.pressed.emit()
	await process_frame
	_check("the dashboard Ports tab switches the pod's display too", game.demo_screens.view_of(sonarr["uid"]) == 2)
	game.demo_screens.set_view(sonarr["uid"], 0)
	if OS.get_environment("KF_SHOTS") != "":
		game.hud.open_screen(sonarr["uid"])
		await create_timer(0.3).timeout
		root.get_texture().get_image().save_png(OS.get_environment("KF_SHOTS").path_join("sonarr_dashboard.png"))
	var disks_tab = game.hud._modal.find_children("*", "Button", true, false).filter(func(b): return b.text == "Shared disks")[0]
	disks_tab.pressed.emit()
	var mount_details = game.hud._modal.find_children("*", "Button", true, false).filter(func(b): return b.text == "Mount details")[0]
	mount_details.pressed.emit()
	_check("the dashboard's mount details open the pod's shared disk list", game.hud._modal_kind == "shared_disks" and game.hud._modal_arg == sonarr["uid"])
	game.demo_screens.set_view(sonarr["uid"], 0)
	game.hud.open_liveview()
	await process_frame
	_check("demo dashboard directory works without the desktop companion", game.hud._modal.find_children("*", "Button", true, false).size() == w.machines.size() + 1)
	game.hud.open_vpn()
	await create_timer(0.6).timeout
	var vtext = "\n".join(PackedStringArray(game.hud._modal.find_children("*", "Label", true, false).map(func(l): return l.text)))
	_check("the VPN panel shows both sides", vtext.contains("INSIDE") and vtext.contains(v["exit_ip"]))
	_check("the VPN list includes qBittorrent and detects no unprotected downloaders", vtext.contains("qbittorrent") and vtext.contains("No unprotected downloaders detected"))
	_check("the shared VPN lists all three app pods", members.all(func(p): return vtext.contains(p["name"])))
	var inspect_app = game.hud._modal.find_children("*", "OptionButton", true, false)[0]
	_check("each shared app can be opened from its VPN", inspect_app.item_count == 4)
	inspect_app.item_selected.emit(1)
	_check("inspecting a VPN app opens its pod", game.hud._modal_kind == "pod" and game.hud._modal_arg in members.map(func(p): return p["uid"]))
	game.hud.open_vpn()
	for uid in [shared["uid"], gw["uid"]]:
		var pick_route = game.hud._modal.find_children("*", "CheckBox", true, false).filter(func(c): return c.get_meta("vpn_uid", "") == uid)[0]
		pick_route.button_pressed = true
		var show_selected = game.hud._modal.find_children("*", "Button", true, false).filter(func(b): return b.text == "Show selected VPN routes")[0]
		show_selected.pressed.emit()
		_check("the factory shows only the selected gateways and their app feeds", w.vpn_selection.size() == (1 if uid == shared["uid"] else 2) and
			w._paths.size() == (5 if uid == shared["uid"] else 7) and
			w._paths.all(func(pa): return w.vpn_selection.has(pa["vpn_uid"])))
		game.hud.open_vpn()
	var show_all = game.hud._modal.find_children("*", "Button", true, false).filter(func(b): return b.text == "Show all VPN routes")[0]
	show_all.pressed.emit()
	_check("show all restores all nine gateway pipes", w.vpn_selection.is_empty() and w._paths.filter(func(pa): return pa["color"] == w.VPN_TUNNEL_COL).size() == 9)
	w.pipe_filter = "All"
	w.apply_state(st)
	game.hud.open_vpn()
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
	_check("the network panel names Internet Output as the VPN pipe destination", net_text.contains("Gluetun → Internet Output"))
	var picker = game.hud._modal.find_children("*", "OptionButton", true, false)[0]
	var option = -1
	for i in picker.item_count:
		if picker.get_item_text(i) == "Internet Output":
			option = i
	_check("the network panel can isolate the Internet pipes", option >= 0)
	if option >= 0:
		var vpn_paths: Array = w._paths.filter(func(p): return p.has("vpn_uid") or p["color"] == w.VPN_FEED_COL)
		picker.item_selected.emit(option)
		var routes = func(paths): return paths.map(func(p): return [p.get("vpn_uid"), p["pts"]])
		_check("Internet Output keeps the same gateway routes and hides other pipes", routes.call(w._paths) == routes.call(vpn_paths) and w._internet_output.visible)
		picker.item_selected.emit(0)
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
		var output: Vector3 = w._internet_output.position
		var port: Vector3 = w._vpn_signs[gw["uid"]]["outside"].position
		game.hud.close_modal(false)
		w.pipe_filter = "Internet Output"
		w.apply_state(game.cluster.state)
		game.player.flying = true
		var from = centre + Vector3(2.7, -1.1, 1.7)
		for view in [["internet_output", output + Vector3(30, 22, 32), output + Vector3(0, 6, -3)],
				["internet_public_side", output + Vector3(22, 14, -24), output + Vector3(0, 5, -3)],
				["internet_port", port + Vector3(1.8, 0.5, 5), port], ["vpn_inside", c + Vector3(-3.5, 5, 9), c + Vector3(1.2, 6.5, -0.5)],
				["container_pillars", from, centre]]:
			game.player.teleport(view[1], view[2])
			await create_timer(1.3).timeout
			root.get_texture().get_image().save_png(dir.path_join(view[0] + ".png"))
		w.vpn_selection[shared["uid"]] = true
		w.apply_state(game.cluster.state)
		var target: Vector3 = w.machines[shared["uid"]].global_position
		for member in members:
			target += w.machines[member["uid"]].global_position
		target /= members.size() + 1.0
		game.player.teleport(target + Vector3(14, 40, 30), target + Vector3(0, 12, 0))
		await create_timer(1.3).timeout
		root.get_texture().get_image().save_png(dir.path_join("shared_vpn_routes.png"))
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
