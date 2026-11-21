extends SceneTree
# Godot --path . -s tests/live/docker_media_lab_test.gd -- --demo=docker-media-gatherer

const K = preload("res://scripts/kutil.gd")
var failures = 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures += 1

func _wait_until(condition: Callable, seconds: float = 12.0) -> bool:
	var ends = Time.get_ticks_msec() + int(1000.0 * seconds)
	while not condition.call() and Time.get_ticks_msec() < ends:
		await create_timer(0.15).timeout
	return condition.call()

func _button(view: Node, title: String) -> Button:
	for button in view.find_children("*", "Button", true, false):
		if button.text == title:
			return button
	return null

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var attached = await _wait_until(func(): return game.cluster.state.has("lab") and not game.world.lab_fixtures.is_empty(), 30.0)
	_check(attached, "media lab launches by demo ID")
	if not attached:
		quit(1)
		return
	var cluster = game.cluster
	var world = game.world
	var hud = game.hud
	hud.settings["board_view"] = "flat"      # these checks are about the flat board
	var st: Dictionary = cluster.state
	# media-lab.json decides the layout; --expect-hosts=1 or =2 overrides it
	var expected_hosts = load("res://scripts/demo_media_lab.gd").configured_host_count()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expect-hosts="):
			expected_hosts = int(arg.trim_prefix("--expect-hosts="))
	hud.settings.erase("storage_warn_pct")
	hud._update_lab_warning(st)
	_check(st["nodes"].size() == expected_hosts and st["pods"].size() == 15, "configured hosts and every container are present")
	var inlet: Node3D = world.lab_fixtures["lan"]
	var cabinet: MeshInstance3D = inlet.get_node("GatewayBody")
	var rim: MeshInstance3D = inlet.get_node("GatewayRim")
	var cabinet_bounds: AABB = cabinet.transform * cabinet.mesh.get_aabb()
	var rim_bounds: AABB = rim.transform * rim.mesh.get_aabb()
	_check(cabinet_bounds.end.y <= rim_bounds.position.y + 0.0001, "gateway trim and cabinet have no overlapping side faces")
	_check(inlet.get_meta("label").billboard == BaseMaterial3D.BILLBOARD_DISABLED,
		"gateway title stays on its front panel")
	var plex_uid = st["pods"].filter(func(pod): return pod["wname"] == "plex")[0]["uid"]
	var inlet_route = world._paths.filter(func(path): return path.get("link") == ["lab:lan", plex_uid, "LAN"])
	var socket: MeshInstance3D = inlet.get_node("GatewayPort0/RoofSocket")
	var socket_top: Vector3 = world.to_local(socket.to_global(Vector3.UP * socket.mesh.height * 0.5))
	_check(inlet_route.size() == 1 and inlet_route[0]["pts"][0].distance_to(socket_top) < 0.001,
		"Plex ingress pipe starts at its numbered socket")
	game.player.teleport(inlet.global_position + Vector3(0, 0, 4.0), inlet.global_position + Vector3(0, 0.65, 0.71))
	hud.close_modal()
	await physics_frame
	await physics_frame
	game._interact()
	_check(hud._modal_kind == "connections" and hud._connection_graph.selected_uid == "lab:lan", "inspecting the inlet opens the unified visual board")
	hud.close_modal()
	game.player.teleport(inlet.global_position + Vector3(-0.60, 0, 3.5), inlet.global_position + Vector3(-0.60, 1.95, 0.80))
	await physics_frame
	await physics_frame
	game._interact()
	_check(hud._modal_kind == "connections" and hud._connection_graph.selected_uid == plex_uid, "inspecting a socket selects its device on the whiteboard")
	_button(hud._modal, "Inspect selected").pressed.emit()
	_check(hud._modal_kind == "ports" and hud._modal_arg == plex_uid, "the selected visual port opens its listener details")
	var trace_device = _button(hud._modal, "Trace device route")
	_check(trace_device != null, "device port details include the outbound route")
	if trace_device != null:
		trace_device.pressed.emit()
		_check(world.lab_trace.has([plex_uid, "lab:www", "HTTPS"]), "device trace reaches the WWW outlet")
	hud.close_modal()
	hud.open_connections()
	var graph = hud._connection_graph
	var grafana_uid = st["pods"].filter(func(pod): return pod["wname"] == "grafana")[0]["uid"]
	var prometheus_uid = st["pods"].filter(func(pod): return pod["wname"] == "prometheus")[0]["uid"]
	_check(graph.cards.size() == st["pods"].size() + st["lab"]["fixtures"].size() - 1
		and graph.get_connection_list().size() == st["links"].size(), "whiteboard includes every app, volume, boundary and configured link")
	_check(graph.get_connection_list().any(func(edge): return edge["from_node"] == graph.cards[grafana_uid].name and edge["to_node"] == graph.cards[prometheus_uid].name),
		"Grafana has a visible direct connection to Prometheus")
	_check(graph.get_connection_list().any(func(edge): return edge["from_node"] == graph.cards[grafana_uid].name and edge["to_node"] == graph.cards["lab:grafana-data"].name),
		"Grafana has a visible connection to its own persistent data")
	graph.cards[grafana_uid].position_offset = Vector2(680, 430)
	graph.cards[grafana_uid].position_offset_changed.emit()
	var saved_layout = graph.layout.duplicate(true)
	graph.configure({"layout_style": "spider", "layout": saved_layout, "category": "Storage"})
	graph.refresh(st)
	_check(graph.routes.all(func(link): return link["kind"] in ["Mounts", "Files"])
		and graph.cards[grafana_uid].position_offset == Vector2(680, 430), "whiteboard configuration preserves layout and filters real routes")
	var drag = InputEventScreenDrag.new()
	drag.relative = Vector2(20, -30)
	await process_frame
	graph.zoom = 1.0
	await process_frame
	var horizontal = graph.find_children("*", "HScrollBar", true, false)[0]
	var vertical = graph.find_children("*", "VScrollBar", true, false)[0]
	graph.scroll_offset = Vector2((horizontal.min_value + horizontal.max_value - horizontal.page) * 0.5,
		(vertical.min_value + vertical.max_value - vertical.page) * 0.5)
	var before_pan: Vector2 = graph.scroll_offset
	graph._gui_input(drag)
	_check(graph.scroll_offset == before_pan - drag.relative, "touch dragging pans the whiteboard")
	var previous_config = hud.settings.get("lab_whiteboard", {}).duplicate(true)
	_button(hud._modal, "Save whiteboard").pressed.emit()
	_check(K.load_settings().get("lab_whiteboard", {}).get("layout", {}).get("grafana") == [680.0, 430.0]
		and is_instance_valid(world._lab_board), "saving the flat whiteboard persists its layout; the board table stays in the world (it keeps the 3D board's own layout)")
	hud.settings["lab_whiteboard"] = previous_config
	K.save_settings(hud.settings)
	world._lab_board.get_meta("graph").configure(previous_config)
	world._update_lab_board(st)
	graph.selected_uid = "lab:grafana-data"
	_button(hud._modal, "Inspect selected").pressed.emit()
	_check(hud._modal_kind == "shared_disks" and hud._disk_volume == "grafana-data", "whiteboard volume card opens its actual shared-disk details")
	hud.close_modal()
	for id in st["lab"]["fixture_hosts"]:
		var fixture: Node3D = world.lab_fixtures[id]
		var platform: Node3D = world.platforms[st["lab"]["fixture_hosts"][id]]
		_check(fixture.position.z > platform.position.z - platform.depth and is_equal_approx(fixture.position.y, world.Platform.HEIGHT),
			id + " is seated on its host platform")
	var library: Node3D = world.lab_fixtures["library"]
	var sync_base: Node3D = world.lab_fixtures["sync-switch"]
	_check(sync_base.position.z + 0.70 < world.platforms["media-host"].position.z,
		"the sync pedestal base is fully supported by the platform")
	_check(library.has_node("StorageContainer") and library.has_node("StoragePort0"),
		"library has a storage container with a connected roof fitting")
	var nameplate: Label3D = library.get_meta("label")
	var text_size = ThemeDB.fallback_font.get_multiline_string_size(nameplate.text, HORIZONTAL_ALIGNMENT_LEFT, -1, nameplate.font_size) * nameplate.pixel_size
	_check(nameplate.billboard == BaseMaterial3D.BILLBOARD_DISABLED and text_size.x <= 1.95 and text_size.y <= 0.21,
		"volume name fits its front plate · " + str(text_size))
	var container: Node3D = library.get_node("StorageContainer")
	var bounds: AABB = container.mesh.get_aabb() if container is MeshInstance3D else container.get_meta("bounds")
	var shell: AABB = container.transform * bounds
	_check(nameplate.position.z <= shell.end.z + 0.01, "nameplate sits on the container")
	_check(is_equal_approx(float(library.get_meta("pipe_y")) - 0.20, shell.end.y), "roof fitting reaches the roof")
	game.player.teleport(library.global_position + Vector3(0, 0, 3.4), library.global_position + Vector3(0, 1.0, 0.9))
	hud.close_modal()
	await physics_frame
	await physics_frame
	_check(game.player.hit.get("meta", {}).get("id") == "library", "mini storage container can be targeted from the aisle")
	game._interact()
	_check(hud._modal_kind == "shared_disks" and hud._disk_volume == "library", "inspecting the container opens its actual volume details")
	hud.close_modal()
	_check(world._paths.size() == st["links"].size() and world._paths.size() > 40, "every configured connection has a 3D pipe")
	var storage_paths = world._paths.filter(func(path): return path.get("kind") == "Mounts")
	var other_paths = world._paths.filter(func(path): return path.get("kind") != "Mounts")
	_check(storage_paths.all(func(path): return other_paths.all(func(other): return path["pts"][1].y < other["pts"][1].y)),
		"data-container lines use the lowest visible pipe lanes")
	var output_host: Node3D = world.platforms["gathering-node"] if expected_hosts == 2 else world.platforms["media-host"]
	_check(world.lab_fixtures["lan"].position.x < world.platforms["media-host"].position.x and
		world.lab_fixtures["www"].position.x > output_host.position.x,
		"LAN ingress and WWW egress are on opposite sides")
	for app in ["sonarr", "radarr", "jackett", "downloader"]:
		var outbound = st["links"].filter(func(link): return link["from_name"] == app and link["kind"] in ["VPN", "HTTPS"])
		_check(outbound.size() == 1 and outbound[0]["to_name"] == "gluetun", app + " has only VPN egress")
	var outbox = K.shared_disks(st).filter(func(disk): return disk["label"].ends_with(" · outbox"))
	_check(outbox.size() == 1 and outbox[0]["mounts"].size() == 2, "downloader and Syncthing share one outbox")
	_check(hud._lab_warning.visible and "library 90.0%" in hud._lab_warning.text, "default storage warning appears above 87 percent")
	hud.settings["storage_warn_pct"] = 90
	hud._update_lab_warning(st)
	_check(not hud._lab_warning.visible, "storage warning is hidden at the configured threshold")
	hud.settings["storage_warn_pct"] = 87
	hud.open_demos()
	_check(hud._demo_cards.get_child_count() == 6, "normal demo picker exposes both Docker labs")
	hud.open_media_lab()
	_check(_button(hud._modal, "Trace connections") != null and _button(hud._modal, "Visit the sync lever") != null,
		"lab menu exposes the route tracer and the lever shortcut")
	var shots = OS.get_environment("KF_SHOTS")
	if shots != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(shots)
		game.player.flying = true
		hud.close_modal()
		world.lab_trace.clear()
		world.apply_state(st)
		var board_position: Vector3 = world._lab_board.global_position
		game.player.teleport(board_position + Vector3(0, 4.3, 17), board_position + Vector3(0, 6.6, 0))
		await create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-whiteboard.png"))
		hud.open_connections()
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-visual-ports.png"))
		hud.close_modal()
		game.player.teleport(inlet.global_position + Vector3(2.5, 0.2, 4.3), inlet.global_position + Vector3(0, 1.75, 0))
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-inlet.png"))
		hud.open_ports(plex_uid, hud.open_media_lab)
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-port-routes.png"))
		hud.close_modal()
		game.player.flying = true
		game.player.teleport(library.global_position + Vector3(2.6, 0, 3.1), library.global_position + Vector3(0, 0.90, 0))
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-storage.png"))
		var lever: Node3D = world.lab_fixtures["sync-switch"]
		game.player.teleport(lever.global_position + Vector3(2.0, 1.4, 3.5), lever.global_position + Vector3(0, 1.2, 0.2))
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-lever.png"))
		hud.open_media_lab()
		_button(hud._modal, "View the factory").pressed.emit()
		await create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-world.png"))
		hud.open_media_lab()
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("media-lab-controls.png"))
	if game.touch != null and game.touch.active:
		for dialog in [hud.open_media_lab, hud.open_connections, hud.open_network, hud.open_ports, hud.open_shared_disks,
			func(): hud.open_ports(plex_uid, hud.open_media_lab),
			func(): hud.open_ports("", hud.open_media_lab, "inbound"),
			func(): hud.open_ports("", hud.open_media_lab, "outbound")]:
			dialog.call()
			for frame in 8:
				await process_frame
			var scroll = hud._mobile_scroll
			_check(not scroll.get_h_scroll_bar().visible and root.get_visible_rect().encloses(scroll.get_global_rect()),
				"media lab phone dialog fits the viewport · %s within %s" % [scroll.get_global_rect(), root.get_visible_rect()])
	hud.open_network()
	var trace = _button(hud._modal, "Trace grafana → prometheus")
	_check(trace != null, "dashboard reads Prometheus directly")
	if trace != null:
		trace.pressed.emit()
		_check(world.lab_trace.size() == 3 and world.lab_trace[2] == "Metrics" and world._paths.size() == st["links"].size(),
			"tracing highlights a link with the rest of the pipes visible")
	hud.open_media_lab()
	var visit = _button(hud._modal, "Visit the sync lever")
	if visit != null:
		visit.pressed.emit()
		await physics_frame
		await physics_frame
	_check(game.player.hit.get("meta", {}).get("id") == "sync-switch", "lever shortcut puts the actual switch within reach")
	cluster.read_only = true
	game._interact()
	_check(hud._modal_kind == "media_lab" and not cluster.state["lab"]["paused"], "read-only users can inspect the lever")
	hud.close_modal()
	cluster.read_only = false
	var policy: Dictionary = cluster.local_policy.duplicate(true)
	cluster.local_policy = {"contexts": [{"match": "docker-media", "max_tier": 1}]}
	cluster.act({"op": "lab_sync", "paused": true})
	_check(not cluster.state["lab"]["paused"] and not hud._lab_allowed("lab_sync"), "tool policy prevents unauthorized lever use")
	cluster.local_policy = policy
	game._interact()
	_check(await _wait_until(func(): return cluster.state["lab"]["paused"]), "interacting with the lever pauses sync")
	var count = cluster.state["lab"]["recent_count"]
	await create_timer(4.5).timeout
	_check(cluster.state["lab"]["recent_count"] == count, "a paused sync does not transfer files")
	var lever: Node3D = world.lab_fixtures["sync-switch"]
	_check(lever.get_meta("arm").rotation.x < -0.50 and "PAUSED" in lever.get_meta("label").text,
		"paused sync shows the handle at its paused stop and the correct status")
	game._interact()
	_check(await _wait_until(func(): return not cluster.state["lab"]["paused"]), "interacting again resumes sync")
	_check(await _wait_until(func(): return cluster.state["lab"]["recent_count"] > count), "resuming sync copies a sample file")
	_check(lever.get_meta("arm").rotation.x > 0.50 and not "PAUSED" in lever.get_meta("label").text,
		"resumed sync moves the handle to its running stop")
	cluster.act({"op": "lab_import"})
	_check(await _wait_until(func(): return cluster.state["lab"]["last_import"] > 0), "received file can be imported into the library")
	var plex_files = cluster.backend.run_action({"op": "file_list", "name": "plex", "ns": "media-host", "root": "/media", "path": ""})
	_check(plex_files["ok"] and plex_files["data"]["entries"].any(func(entry): return entry["name"] == "Sample 001.mkv"),
		"the imported file shows up in the Plex storage browser")
	cluster.act({"op": "lab_access", "access": "VLAN 30"})
	_check(await _wait_until(func(): return K.port_rows(cluster.state).any(func(row): return row["name"] == "plex" and "VLAN 30" in row["scope"])),
		"VLAN setting updates the port view")
	cluster.act({"op": "restart", "ns": "media-host", "kind": "Compose", "name": "plex"})
	_check(await _wait_until(func(): return K.port_rows(cluster.state).any(func(row): return row["name"] == "plex" and row["health"] == "bad")),
		"restarting a published container reports an offline port")
	cluster.act({"op": "lab_discord"})
	_check(await _wait_until(func(): return cluster.state["lab"]["last_alert"] > 0), "Discord test action animates a simulated alert")
	cluster.act({"op": "lab_discord", "enabled": false})
	_check(await _wait_until(func(): return not world.lab_fixtures.has("discord")), "optional Discord pipe and endpoint can be removed")
	var gateway = cluster.state["pods"].filter(func(pod): return pod["wname"] == "gluetun")[0]
	cluster.act({"op": "restart", "ns": gateway["ns"], "kind": gateway["wkind"], "name": gateway["wname"]})
	_check(await _wait_until(func(): return cluster.state["lab"]["egress"].filter(
		func(route): return route["via"] == "gluetun" and not route["ready"]).size() == 4),
		"a failed VPN blocks every protected outbound route")
	game.queue_free()
	await process_frame
	await process_frame
	print("DOCKER MEDIA LAB PASSED" if failures == 0 else "%d MEDIA LAB CHECKS FAILED" % failures)
	quit(0 if failures == 0 else 1)
