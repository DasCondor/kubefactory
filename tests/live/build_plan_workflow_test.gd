extends SceneTree

const K = preload("res://scripts/kutil.gd")
const Plan = preload("res://scripts/build_plan.gd")
var failures = 0

func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ")+what)
	if not ok:
		failures += 1

func button(node: Node, title: String) -> Button:
	for item in node.find_children("*","Button",true,false):
		if item.text == title:
			return item
	return null

func settle() -> void:
	for i in 12:
		await process_frame

func shot(name: String) -> void:
	var folder = OS.get_environment("KF_SHOTS")
	if folder != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(folder)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(folder.path_join(name+".png"))

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var previous = K.load_settings().duplicate(true)
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec()+20000
	while not game.cluster.state.has("lab") and Time.get_ticks_msec()<deadline:
		await create_timer(0.1).timeout
	var hud = game.hud
	hud.settings.erase("flowchart")
	var original_pods = game.cluster.state["pods"].duplicate(true)
	hud.open_blueprint_graph()
	await settle()
	var planner = hud._modal.find_children("*","TabContainer",true,false)[0].get_parent()
	check(planner.model.data["nodes"].size() == 33 and planner.model.data["edges"].size() == game.cluster.state["links"].size(),"builder copies every media endpoint and actual route")
	planner.tabs.current_tab = 1
	planner.view.fit()
	await settle()
	await shot("builder-media-factory")
	if game.touch != null and game.touch.active:
		check(not hud._mobile_scroll.get_h_scroll_bar().visible,"builder controls fit the phone width")
	planner.model.load_plan({"version":2,"nodes":[],"edges":[]})
	button(hud._modal,"Add workload").pressed.emit()
	var first = planner.active_id
	planner.title_edit.text = "web"
	planner.image_edit.text = "nginx:alpine"
	button(planner,"Apply block").pressed.emit()
	button(planner,"Place").pressed.emit()
	planner.appearance.select(1)
	planner.appearance.item_selected.emit(1)
	planner.coords[0].value = 2
	button(planner,"Place here").pressed.emit()
	var second = planner.active_id
	check(planner.model.data["nodes"].size() == 2 and planner.model.node(second)["cell"] == [2,0,0],"touch-friendly grid controls place a worker")
	button(planner,"Rotate").pressed.emit()
	check(planner.model.node(second)["rotation"] == 1,"rotation updates the shared plan")
	button(planner,"Undo").pressed.emit()
	check(planner.model.node(second)["rotation"] == 0,"undo reverses rotation")
	planner.coords[0].value = 0
	button(planner,"Place here").pressed.emit()
	check(planner.model.data["nodes"].size() == 2 and "occupied" in planner.status.text,"occupied placement is rejected visibly")
	planner.set_route(first,second,"API")
	planner.port_edit.text = "80/tcp"
	button(planner,"Preview route").pressed.emit()
	check(planner.model.data["edges"].is_empty() and not planner.view.preview.is_empty(),"route preview changes no saved edge")
	button(planner,"Confirm route").pressed.emit()
	check(planner.model.data["edges"].size() == 1 and planner.view.blocks.paths.size() == 1,"confirmation connects matching sockets in graph and factory")
	planner.select_block(second)
	button(planner,"Remove selected").pressed.emit()
	check(planner.model.data["nodes"].size() == 1 and planner.model.data["edges"].is_empty(),"removing a selected block removes its route")
	button(planner,"Undo").pressed.emit()
	check(planner.model.data["nodes"].size() == 2 and planner.model.data["edges"].size() == 1,"undo restores the block and its route")
	button(hud._modal,"Save locally").pressed.emit()
	var saved = planner.snapshot()
	check(Plan.migrate(K.load_settings().get("flowchart")) == Plan.migrate(saved) and game.world._build_blocks.blocks.size() == 2,"save persists one plan and draws the same factory blocks")
	button(hud._modal,"Compose preview").pressed.emit()
	await settle()
	check("nginx:alpine" in hud._editor.ed.text and "route-1" in hud._editor.ed.text,"the local plan generates a Compose preview")
	button(hud._modal,"Export YAML").pressed.emit()
	check(hud._configuration_editor.approval.visible,"Compose export requires explicit approval")
	hud._configuration_editor.approval.hide()
	hud.close_modal()
	hud.open_blueprint_graph()
	await settle()
	button(hud._modal,"Plan JSON").pressed.emit()
	await settle()
	check(button(hud._modal,"Open plan JSON") != null and button(hud._modal,"Use this plan") != null,"plan JSON can be opened, edited and imported")
	var text = hud._editor.ed.text
	hud._editor.ed.text = "{invalid"
	button(hud._modal,"Use this plan").pressed.emit()
	check(hud._modal_kind == "editor" and Plan.migrate(K.load_settings().get("flowchart")) == Plan.migrate(saved),"invalid imported plans preserve the saved plan")
	hud._editor.ed.text = text
	button(hud._modal,"Use this plan").pressed.emit()
	await settle()
	check(hud._modal_kind == "planner","valid plan JSON returns to the builder")
	check(game.cluster.state["pods"] == original_pods,"planning and exports do not deploy or mutate workloads")
	hud.close_modal()
	K.save_settings(previous)
	game.queue_free()
	await process_frame
	print("BUILD WORKFLOW PASSED" if failures == 0 else "BUILD WORKFLOW FAILED")
	quit(0 if failures == 0 else 1)
