extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _find_button(node: Node, title: String) -> Button:
	if node is Button and node.text == title:
		return node
	for child in node.get_children():
		var found = _find_button(child, title)
		if found != null:
			return found
	return null

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 20000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	if game.cluster.backend == null:
		printerr("Simulation did not load")
		quit(1)
		return
	game.hud.close_modal(false)
	game.cluster.read_only = true
	game.player.flying = true
	var pos: Vector3 = game.world._gauge.global_position
	game.player.teleport(pos + Vector3(0.0, 0.0, 5.0), pos + Vector3(0, 1.3, 0))
	await create_timer(0.6).timeout
	var ok = game.player.hit.get("meta", {}).get("type", "") == "gauge"
	game.world.set_gauge_visible(false)
	await create_timer(0.2).timeout
	ok = ok and game.player.hit.get("meta", {}).get("type", "") != "gauge"
	game.world.set_gauge_visible(true)
	await create_timer(0.2).timeout
	ok = ok and game.player.hit.get("meta", {}).get("type", "") == "gauge"
	var station = OS.get_environment("KF_GAUGE_STATION")
	if station != "":
		root.get_texture().get_image().save_png(station)
	game._interact()
	ok = ok and game.hud._modal_kind == "gauge"
	var cpu_heading = _find_button(game.hud._modal, "CPU REQUEST")
	if cpu_heading == null:
		ok = false
	else:
		cpu_heading.pressed.emit()
		ok = ok and game.hud._table_state("gauge-nodes")["col"] == "cpu_requested"
	game.hud._gauge_sync_head(10000)
	ok = ok and _find_button(game.hud._gauge_head, "NODE").disabled
	game.hud._gauge_sync_head(9999)
	ok = ok and not _find_button(game.hud._gauge_head, "NODE").disabled
	game.hud._table_state("gauge-nodes")["filter"] = "never-a-node-012345"
	game.hud._fill_gauge(true)
	ok = ok and game.hud._gauge_rows.get_child_count() == 0
	game.hud._table_state("gauge-nodes")["filter"] = ""
	game.hud._fill_gauge(true)
	for i in game.hud._gauge_pick.item_count:
		var uid = str(game.hud._gauge_pick.get_item_metadata(i))
		var pod = game.K.find_pod(game.cluster.state, uid)
		if pod != null and pod["status"] == "Running":
			game.hud._gauge_pick.select(i)
			break
	var before = game.cluster.state["pods"].size()
	game.hud._gauge_request()
	deadline = Time.get_ticks_msec() + 10000
	while game.hud._gauge_readout.text.begins_with("Reading") and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	ok = ok and game.hud._gauge_readout.text.contains("SIMULATED") and game.cluster.state["pods"].size() == before
	await create_timer(0.5).timeout
	var screenshot = OS.get_environment("KF_GAUGE_SCREEN")
	if screenshot != "":
		root.get_texture().get_image().save_png(screenshot)
	print("Gauge readout: ", game.hud._gauge_readout.text.replace("\n", " | "))
	if game.touch_on():
		var panel = game.hud._modal.get_child(1)
		print("Gauge touch layout: viewport=", root.get_visible_rect().size, " window=", root.size, " unit=", game.hud.touch_u, " panel=", panel.size)
		var outer = game.hud._gauge_scroll
		ok = ok and outer != null and outer.get_v_scroll_bar().max_value > outer.get_v_scroll_bar().page
		outer.scroll_vertical = int(outer.get_v_scroll_bar().max_value)
		await create_timer(0.2).timeout
		var table_shot = OS.get_environment("KF_GAUGE_TABLE_SCREEN")
		if table_shot != "":
			root.get_texture().get_image().save_png(table_shot)
	var old_key = game.hud._gauge["key"]
	game.hud.on_data(old_key, {"ok": false, "msg": "metrics unavailable"})
	ok = ok and game.hud._gauge_readout.text.contains("Unavailable: metrics unavailable")
	game.hud.open_gauge()
	game.hud.on_data(old_key, {"ok": true, "data": {"cpu_cores": 999}})
	ok = ok and game.hud._gauge_readout.text.begins_with("Choose a workload")
	game.queue_free()
	await process_frame
	await process_frame
	if ok:
		print("GAUGE UI PASSED")
	else:
		printerr("Gauge UI interaction failed")
	quit(0 if ok else 1)
