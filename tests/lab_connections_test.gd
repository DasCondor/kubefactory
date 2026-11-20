extends SceneTree

const Demo = preload("res://scripts/backend_demo.gd")
const Board = preload("res://scripts/lab_connections.gd")
var failures = 0

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var board = Board.new()
	root.add_child(board)
	board.size = Vector2(1200, 700)
	var state = Demo.new("docker-media-gatherer").fetch()
	board.refresh(state)
	await process_frame
	await process_frame
	board.arrange_spider()
	await process_frame
	var collisions = 0
	for a in board.cards:
		for b in board.cards:
			if a < b and Rect2(board.cards[a].position_offset, board.cards[a].size).intersects(Rect2(board.cards[b].position_offset, board.cards[b].size)):
				collisions += 1
	_check(collisions == 0, "spider cards do not overlap")
	_check(board.get_connection_list().size() == state["links"].size(), "spider map preserves every real connection")
	board.fit_routes()
	await process_frame
	await process_frame
	var frame = board.get_global_rect().grow(-8)
	_check(board.cards.values().all(func(card): return frame.encloses(card.get_global_rect())), "opening overview includes every card without clipping")
	_check(not board.show_menu and not board.minimap_enabled, "map removes the duplicate toolbar and minimap obstruction")
	var grafana = state["pods"].filter(func(p): return p["wname"] == "grafana")[0]["uid"]
	board.select_endpoint(grafana)
	board.focus_selected()
	await process_frame
	_check(board.get_global_rect().encloses(board.cards[grafana].get_global_rect()) and board.zoom >= 0.85, "finding an app centers it at a readable scale")
	var saved = board.layout.duplicate(true)
	board.configure({"layout_style": "spider", "layout": saved, "category": "Storage"})
	board.refresh(state)
	_check(board.cards[grafana].position_offset == Vector2(saved["grafana"][0], saved["grafana"][1]), "saved spider layout survives a category change")
	board.configure({})
	board.refresh(state)
	board.fit_routes()
	await process_frame
	var shots = OS.get_environment("KF_SHOTS")
	if shots != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(shots)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shots.path_join("spider-overview.png"))
	print("LAB CONNECTIONS PASSED" if failures == 0 else "LAB CONNECTIONS FAILED")
	quit(0 if failures == 0 else 1)
