extends SceneTree

var failures = 0

func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func button(node: Node, title: String) -> Button:
	for b in node.find_children("*", "Button", true, false):
		if b.text == title:
			return b
	return null

func wait_until(condition: Callable) -> bool:
	var deadline = Time.get_ticks_msec() + 12000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	return condition.call()

func settle() -> void:
	for i in 10:
		await process_frame

func _initialize() -> void:
	run.call_deferred()

func shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(dir)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func run() -> void:
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	check(await wait_until(func(): return game.cluster.state.has("lab")), "media demo is ready")
	var hud = game.hud
	var cluster = game.cluster
	cluster.read_only = false
	var grafana = cluster.state["pods"].filter(func(p): return p["wname"] == "grafana")[0]["uid"]
	hud.open_connections("lab:grafana-data")
	await settle()
	button(hud._modal, "Inspect selected").pressed.emit()
	await settle()
	check(hud._modal_kind == "shared_disks" and button(hud._modal, "Browse / edit files") != null, "inspected disk summary offers a file action")
	await shot("grafana-disk-file-action")
	button(hud._modal, "Browse / edit files").pressed.emit()
	check(await wait_until(func(): return hud._store.get("list") != null), "disk summary opens its files")
	check(hud._store["mount"]["volume"] == "grafana-data" and hud._store["mount"]["path"] == "/var/lib/grafana", "Grafana disk inspection opens the exact selected mount")
	button(hud._modal, "demo-settings.yaml").pressed.emit()
	check(await wait_until(func(): return button(hud._modal, "Edit file") != null), "Grafana config can be edited through Inspect selected")
	button(hud._modal, "Edit file").pressed.emit()
	await settle()
	check(hud._modal_kind == "editor" and not hud._editor.read_only, "disk summary reaches the writable config editor")
	await shot("grafana-config-from-board")
	button(hud._modal, "Back to files").pressed.emit()
	check(await wait_until(func(): return hud._store.get("list") != null), "editor returns to Grafana files")
	button(hud._modal, "Back").pressed.emit()
	await settle()
	check(hud._modal_kind == "shared_disks" and hud._disk_volume == "grafana-data", "file browser returns to the same disk summary")
	button(hud._modal, "Back").pressed.emit()
	await settle()
	check(hud._modal_kind == "connections" and hud._connection_graph.selected_uid == "lab:grafana-data", "disk summary returns to the selected board card")
	hud._connection_graph.select_endpoint(grafana)
	button(hud._modal, "Inspect selected").pressed.emit()
	await settle()
	check(hud._modal_kind == "ports" and button(hud._modal, "Config / storage files") != null, "inspected pod offers config and storage access")
	button(hud._modal, "Config / storage files").pressed.emit()
	check(await wait_until(func(): return hud._store.get("list") != null) and hud._store["uid"] == grafana, "pod inspector opens that pod's files")
	hud.open_connections("lab:grafana-data")
	await settle()
	var click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.double_click = true
	hud._connection_graph.cards["lab:grafana-data"].gui_input.emit(click)
	check(await wait_until(func(): return hud._modal_kind == "storage" and hud._store.get("list") != null), "double-clicking a storage card opens its files directly")
	hud.open_connections(grafana)
	await settle()
	hud._connection_graph.cards[grafana].gui_input.emit(click)
	check(await wait_until(func(): return hud._modal_kind == "storage" and hud._store.get("list") != null) and hud._store["uid"] == grafana, "double-clicking a pod card opens its files directly")
	hud.open_connections()
	await settle()
	hud._connection_graph.select_endpoint("lab:radarr-config")
	button(hud._modal, "Config / storage files").pressed.emit()
	check(await wait_until(func(): return hud._store.get("list") != null), "storage card opens its files")
	check(hud._store["mount"]["volume"] == "radarr-config" and hud._store["mount"]["path"] == "/config", "the chosen card opens the matching mount")
	var listing = hud._store["list"].duplicate(true)
	hud.on_data("store:%s:list:stale" % hud._store["uid"], {"ok":true, "data":{"entries":[]}})
	check(hud._store["list"] == listing, "a late response cannot replace the currently selected files")
	await settle()
	if game.touch != null and game.touch.active:
		check(not hud._mobile_scroll.get_h_scroll_bar().visible, "mounted file browser fits the phone width")
	await shot("spider-storage-files")
	button(hud._modal, "demo-settings.yaml").pressed.emit()
	check(await wait_until(func(): return button(hud._modal, "Edit file") != null), "text file offers editing")
	button(hud._modal, "Edit file").pressed.emit()
	await settle()
	var editor = hud._editor
	if game.touch != null and game.touch.active:
		check(not hud._mobile_scroll.get_h_scroll_bar().visible, "mounted text editor fits the phone width")
	var old = editor.ed.text
	editor.ed.text += "\noperator_reviewed: true\n"
	editor.save()
	await settle()
	var approval = editor.find_children("*", "ConfirmationDialog", false, false)[0]
	check(approval.visible and editor.modified(), "save needs explicit approval and retains the edited buffer")
	approval.canceled.emit()
	await settle()
	check(editor.modified() and editor.ed.text != old, "cancel keeps all edits")
	editor.save()
	await settle()
	approval = editor.find_children("*", "ConfirmationDialog", false, false)[0]
	await shot("spider-storage-save-approval")
	approval.confirmed.emit()
	check(await wait_until(func(): return not editor._saving), "save receives a backend result")
	check(not editor.modified() and editor.get_meta("file_hash", "") == editor.ed.text.sha256_text(), "the file is saved and the conflict token updates")
	editor.ed.text += "second_save: true\n"
	editor.save()
	await settle()
	editor.find_children("*", "ConfirmationDialog", false, false)[0].confirmed.emit()
	check(await wait_until(func(): return not editor._saving) and not editor.modified(), "the same editor can save again without a false conflict")
	cluster.read_only = true
	editor.ed.text += "blocked: true\n"
	editor.save()
	await settle()
	editor.find_children("*", "ConfirmationDialog", false, false)[0].confirmed.emit()
	await settle()
	check(not editor._saving and editor.modified(), "a permission change refuses the write without losing edits")
	editor.ed.text = editor._saved_text
	button(hud._modal, "Back to files").pressed.emit()
	check(await wait_until(func(): return hud._store.get("list") != null), "back returns to the same mounted storage")
	button(hud._modal, "demo-settings.yaml").pressed.emit()
	check(await wait_until(func(): return button(hud._modal, "View text") != null), "read-only sessions offer only a text viewer")
	check(Marshalls.base64_to_utf8(hud._store["file"]["data"]["data"]).ends_with("second_save: true\n"), "reopened file contains the approved edits only")
	button(hud._modal, "Back").pressed.emit()
	await settle()
	check(hud._modal_kind == "connections" and hud._connection_graph.selected_uid == "lab:radarr-config", "back restores the selected spiderweb card")
	hud.open_connection_files("lab:outbox")
	await settle()
	check(hud._modal_kind == "storage_access" and hud._modal.find_children("*", "Button", true, false).size() >= 3, "shared storage lists its app access paths")
	hud.close_modal()
	game.queue_free()
	await process_frame
	print("STORAGE WORKFLOW PASSED" if failures == 0 else "STORAGE WORKFLOW FAILED")
	quit(0 if failures == 0 else 1)
