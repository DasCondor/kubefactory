extends SceneTree
# The 3D connection board, in every demo world, through the game's own panel.
#
#   engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/board3d_workflow_test.gd -- --demo=docker-media-gatherer
#
# For the world it was started in: the board opens in 3D with one block per
# container (and lab volume or outside destination) and one pipe per declared
# route; a tap selects, a double tap opens the block's files; dragging a
# selected block moves it, saving keeps that place, and the table in the world
# shows the same layout. Settings are restored at the end.

const K = preload("res://scripts/kutil.gd")
var failures = 0

func check(ok: bool, what: String, got = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if ok else "  got: " + str(got)))
	if not ok:
		failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _touch(view: Control, at: Vector2, pressed: bool) -> void:
	var e = InputEventScreenTouch.new()
	e.index = 0
	e.position = at
	e.pressed = pressed
	view._gui_input(e)

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _run() -> void:
	var previous = K.load_settings().duplicate(true)
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	await create_timer(1.0).timeout
	var hud = game.hud
	var st: Dictionary = game.cluster.state
	hud.close_modal(false)
	hud.settings.erase("board_view")
	hud.open_connections()
	await create_timer(1.0).timeout
	var board = hud._connection_graph
	check(board is SubViewportContainer and board.view == "iso", "the board opens as an isometric diagram by default")
	check(board.camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "the isometric camera is orthographic")
	await _shot("board-iso")
	var fixtures = st.get("lab", {}).get("fixtures", {}).keys().filter(func(id): return id != "sync-switch").size()
	check(board.cards.size() == st["pods"].size() + fixtures, "one block per container and lab endpoint", board.cards.size())
	check(board.connection_list().size() == st["links"].size(), "one pipe per declared route", board.connection_list().size())
	# a tap on a block selects it; a second tap opens its files
	var uid = st["pods"][0]["uid"]
	var spot = board.camera.unproject_position(board.cards[uid].position + Vector3(0, 2.0, 0))
	check(board.pick(spot) == uid, "a block can be picked where it is drawn")
	board.select_endpoint(uid)
	await create_timer(0.3).timeout
	var pills = board._pills.size()
	check(pills > 0 and pills == board.scene.badges().size(), "the selected block's routes get callout pills", pills)
	check(board.cards[uid].position.y > 0.0, "the selected tile rises")
	await _shot("board-iso-selected")
	board.set_view("2d")
	board.fit_routes()
	await create_timer(0.3).timeout
	var spot2 = board.camera.unproject_position(board.cards[uid].position + Vector3(0, 1.3, 0))
	check(board.pick(spot2) == uid, "in 2D a block can be picked where it is drawn")
	var rect = Rect2(Vector2.ZERO, Vector2(board.viewport.size))
	if board.size.x >= 560:
		check(board.cards.values().all(func(c): return rect.has_point(board.camera.unproject_position(c.position))), "fit shows every block in 2D")
	else:
		var tile_px = board.camera.unproject_position(Vector3(3.2, 0, 0)).distance_to(board.camera.unproject_position(Vector3(-3.2, 0, 0)))
		check(tile_px >= 40.0, "on a phone, fit keeps tiles readable", tile_px)
	await _shot("board-2d")
	board.set_view("iso")
	board.fit_routes()
	board.select_endpoint("")
	await create_timer(0.2).timeout
	spot = board.camera.unproject_position(board.cards[uid].position + Vector3(0, 2.0, 0))
	_touch(board, spot, true)
	_touch(board, spot, false)
	check(board.selected_uid == uid, "a tap selects the block")
	_touch(board, spot, true)
	_touch(board, spot, false)
	await create_timer(0.5).timeout
	check(hud._modal_kind != "connections", "a double tap opens the block's files", hud._modal_kind)
	# move a block, save, reopen: it keeps its place, and so does the table in the world
	hud.close_modal(false)
	hud.open_connections(uid)
	await create_timer(0.8).timeout
	board = hud._connection_graph
	var to = board.cards[uid].position + Vector3(30, 0, -20)
	board.scene.move_card(uid, to)
	var key: String = board.cards[uid].key
	# a button on a desktop; on a phone it sits in the "More..." list
	for b in hud._modal.find_children("*", "Button", true, false):
		if b is OptionButton:
			for i in b.item_count:
				if b.get_item_text(i) == "Save whiteboard":
					b.item_selected.emit(i)
		elif b.text == "Save whiteboard":
			b.pressed.emit()
	hud.close_modal(false)
	hud.open_connections()
	await create_timer(0.8).timeout
	board = hud._connection_graph
	check(board.cards[uid].position.distance_to(Vector3(to.x, 0, to.z)) < 0.01, "a moved block keeps its place after saving", board.cards[uid].position)
	var table = game.world._lab_board.get_meta("graph") if is_instance_valid(game.world._lab_board) else null
	check(table != null and table.cards.has(uid) and table.layout.has(key), "the table in the world shows the same board and layout")
	# the flat board is still one button away
	hud.settings["board_view"] = "flat"
	hud.close_modal(false)
	hud.open_connections()
	await create_timer(0.5).timeout
	check(hud._connection_graph is GraphEdit, "the flat board is still available")
	hud.close_modal(false)
	K.save_settings(previous)
	game.queue_free()
	await process_frame
	print("BOARD 3D PASSED" if failures == 0 else "BOARD 3D FAILED")
	quit(0 if failures == 0 else 1)
