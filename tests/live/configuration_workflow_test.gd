extends SceneTree

var failures = 0

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _button(node: Node, title: String) -> Button:
	for button in node.find_children("*", "Button", true, false):
		if button.text == title:
			return button
	return null

func _initialize() -> void:
	_run.call_deferred()

func _settle() -> void:
	for i in 10:
		await process_frame

func _shot(name: String) -> void:
	var folder = OS.get_environment("KF_SHOTS")
	if folder != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(folder)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(folder.path_join(name + ".png"))

func _run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 30000
	while (not game.cluster.state.has("lab") or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	_check(game.cluster.state.has("lab"), "demo is ready for the setup workflow")
	if not game.cluster.state.has("lab"):
		quit(1)
		return
	var hud = game.hud
	hud.settings["board_view"] = "flat"      # these checks are about the flat board
	var count = game.cluster.state["pods"].size()
	hud.open_connections()
	await _settle()
	var graph = hud._connection_graph
	_check(graph.cards.size() == 33, "overview includes every media lab endpoint")
	_check(graph.cards.values().all(func(card): return graph.get_global_rect().encloses(card.get_global_rect())), "the opening map frames every card")
	await _shot("spider-whiteboard")
	hud._talk["app"] = "wordpress"
	hud.open_talk("app")
	var preview = _button(hud._modal, "Preview this setup")
	_check(preview != null, "Porter offers preview before deployment")
	if preview != null:
		preview.pressed.emit()
	await _settle()
	_check(hud._modal_kind == "porter_preview" and game.cluster.state["pods"].size() == count, "Porter preview shows additions without deploying them")
	_check(hud._porter_proposal["state"]["board"].any(func(card): return card[3] == "planned" and "mysql-data" in card[1]), "proposal includes its data volume")
	await _shot("porter-proposal")
	_button(hud._modal, "Review / edit YAML").pressed.emit()
	await _settle()
	var panel = hud._configuration_editor
	_check(hud._modal_kind == "editor" and "WORDPRESS_DB_HOST" in panel.editor.ed.text, "proposal opens its complete editable setup YAML")
	panel.editor.ed.text += "\n# operator-reviewed\n"
	_button(hud._modal, "Export YAML").pressed.emit()
	await _settle()
	_check(panel.approval.visible and panel._snapshot.ends_with("# operator-reviewed\n"), "edited setup requires explicit approval before export")
	await _shot("porter-export-approval")
	panel.approval.hide()
	panel.editor._saved_text = panel.editor.ed.text
	hud.close_modal()
	hud.open_map_yaml()
	await _settle()
	_check(hud._configuration_editor.editor.ed.text.contains('"kind": "Deployment"'), "the current map can also generate YAML")
	if game.touch != null and game.touch.active:
		_check(not hud._mobile_scroll.get_h_scroll_bar().visible, "YAML controls fit the phone width")
	_check(game.cluster.state["pods"].size() == count, "review and canceled export leave the cluster unchanged")
	hud._configuration_editor.editor._saved_text = hud._configuration_editor.editor.ed.text
	hud.close_modal()
	game.queue_free()
	await process_frame
	print("CONFIGURATION WORKFLOW PASSED" if failures == 0 else "CONFIGURATION WORKFLOW FAILED")
	quit(0 if failures == 0 else 1)
