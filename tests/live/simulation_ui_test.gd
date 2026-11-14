extends SceneTree

const Agent = preload("res://scripts/agent.gd")

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
	var ok = game.cluster.backend != null and game.cluster.backend.label == "simulation" and not Agent.running()
	game.hud.open_clusters()
	var button = _find_button(game.hud._modal, "Discover local connections")
	if button == null or button.disabled:
		ok = false
	else:
		button.pressed.emit()
		deadline = Time.get_ticks_msec() + 30000
		while game.cluster.finding_targets and Time.get_ticks_msec() < deadline:
			await create_timer(0.1).timeout
		ok = ok and not game.cluster.finding_targets and game.cluster.backend.label == "simulation"
		ok = ok and game.cluster.targets.any(func(t): return t["source"] == "docker" and t["context"] == "simulation-test")
		ok = ok and game.hud._modal_kind == "clusters"
	game.queue_free()
	await process_frame
	await process_frame
	if ok:
		print("SIMULATION SWITCHER PASSED")
	else:
		printerr("Simulation switcher did not discover the test engine")
	quit(0 if ok else 1)
