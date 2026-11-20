extends VBoxContainer

signal plan_changed(plan)
signal inspect_observed(uid)
const Plan = preload("res://scripts/build_plan.gd")
const PlanView = preload("res://scripts/plan_view.gd")
const Topology = preload("res://scripts/demo_topology.gd")
var model = Plan.new()
var graph = GraphEdit.new()
var view = PlanView.new()
var status = Label.new()
var tabs = TabContainer.new()
var active_id = ""
var title_edit = LineEdit.new()
var image_edit = LineEdit.new()
var appearance = OptionButton.new()
var vlan = SpinBox.new()
var coords = []
var from_pick = OptionButton.new()
var to_pick = OptionButton.new()
var kind_pick = OptionButton.new()
var port_edit = LineEdit.new()
var mount_edit = LineEdit.new()
var mount_read_only = CheckBox.new()
var selected_edge = {}
var _updating = false

func _button(label: String, cb: Callable) -> Button:
	var b = Button.new()
	b.text = label
	b.pressed.connect(cb)
	return b

func _row() -> HFlowContainer:
	var row = HFlowContainer.new()
	add_child(row)
	return row

func _ready() -> void:
	var modes = _row()
	for mode in ["Select","Place","Move","Connect"]:
		modes.add_child(_button(mode, func():
			view.mode = mode
			view.update_ghost()
			if mode != "Select":
				tabs.current_tab = 1
			status.text = "Click the grid to %s. R rotates; Enter places. Connect: choose an output cube, then a matching input sphere." % mode.to_lower()))
	modes.add_child(_button("Place here", view.place))
	modes.add_child(_button("Rotate", rotate_selected))
	modes.add_child(_button("Undo", func(): model.undo()))
	modes.add_child(_button("Fit view", func(): view.fit(); fit_graph()))
	modes.add_child(_button("Turn view", func(): view.orbit += PI/4; view.look()))
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	graph.name = "Graph"
	graph.custom_minimum_size.y = 360
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.minimap_enabled = false
	graph.zoom_min = 0.08
	graph.connection_request.connect(func(a,ap,b,bp):
		var source = model.node(str(a))
		var dest = model.node(str(b))
		if source != null and dest != null and Plan.sockets(source)[ap] == Plan.sockets(dest)[bp]:
			set_route(str(a),str(b),Plan.sockets(source)[ap])
			preview_route())
	graph.disconnection_request.connect(func(a,ap,b,_bp): model.disconnect_blocks(str(a),str(b),Plan.sockets(model.node(str(a)))[ap]))
	graph.delete_nodes_request.connect(_remove)
	graph.end_node_move.connect(func():
		if _updating:
			return
		var next = snapshot()
		for item in next["nodes"]:
			var card = graph.get_node_or_null(NodePath(item["id"]))
			if card != null:
				if Vector2(item["x"],item["y"]) != card.position_offset:
					item["cell"] = [roundi(card.position_offset.x/120),item["cell"][1],roundi(card.position_offset.y/120)]
					item["x"] = item["cell"][0]*120
					item["y"] = item["cell"][2]*120
		if not model.commit(next):
			_render())
	tabs.add_child(graph)
	view.name = "Factory blocks"
	view.model = model
	view.selected.connect(select_block)
	view.edited.connect(_report)
	view.socket_picked.connect(func(socket):
		if socket["output"]:
			_pick_id(from_pick,socket["id"])
			kind_pick.select(Plan.KINDS.find(socket["kind"]))
		else:
			_pick_id(to_pick,socket["id"])
			if Plan.KINDS[kind_pick.selected] != socket["kind"]:
				status.text = "Choose an input of the same socket type as the output."
				return
			preview_route())
	tabs.add_child(view)
	var fields = _row()
	title_edit.placeholder_text = "Block name"
	title_edit.custom_minimum_size.x = 180
	image_edit.placeholder_text = "Container image (workloads)"
	image_edit.custom_minimum_size.x = 240
	fields.add_child(title_edit)
	fields.add_child(image_edit)
	for role in Plan.ROLES:
		appearance.add_item(role.capitalize())
	appearance.item_selected.connect(func(i): view.role = Plan.ROLES[i])
	fields.add_child(appearance)
	vlan.min_value = 0
	vlan.max_value = 4094
	vlan.prefix = "VLAN "
	fields.add_child(vlan)
	var placement = _row()
	for i in 3:
		var number = SpinBox.new()
		number.min_value = 0 if i == 1 else -128
		number.max_value = 32 if i == 1 else 128
		number.prefix = ["X ","Level ","Z "][i]
		number.custom_minimum_size.x = 105
		coords.append(number)
		placement.add_child(number)
		number.value_changed.connect(func(_v): view.cell = coords.map(func(c): return int(c.value)); view.update_ghost())
	placement.add_child(_button("Apply block", apply_fields))
	placement.add_child(_button("Remove selected", remove_selected))
	placement.add_child(_button("Inspect source", func():
		var item = model.node(active_id)
		if item != null and item.get("observed_uid", "") != "":
			inspect_observed.emit(item["observed_uid"])
		else:
			status.text = "This is a new planned block, with no observed workload."))
	var connections = _row()
	from_pick.tooltip_text = "Source output socket"
	to_pick.tooltip_text = "Destination input socket"
	connections.add_child(from_pick)
	for kind in Plan.KINDS:
		kind_pick.add_item(kind)
	connections.add_child(kind_pick)
	connections.add_child(to_pick)
	port_edit.placeholder_text = "Target port e.g. 3000/tcp"
	port_edit.custom_minimum_size.x = 185
	connections.add_child(port_edit)
	mount_edit.placeholder_text = "Mount path e.g. /media"
	mount_edit.custom_minimum_size.x = 185
	connections.add_child(mount_edit)
	mount_read_only.text = "Read-only mount"
	connections.add_child(mount_read_only)
	connections.add_child(_button("Preview route",preview_route))
	connections.add_child(_button("Confirm route",func():
		if selected_edge.is_empty():
			preview_route()
			return
		var edge = selected_edge.duplicate()
		view.preview.clear()
		selected_edge.clear()
		model.edit_route(edge)
		_report()))
	connections.add_child(_button("Remove route",func():
		if not selected_edge.is_empty():
			model.disconnect_blocks(selected_edge["from"],selected_edge["to"],selected_edge["kind"])
			selected_edge.clear()
			view.preview.clear()
			view.refresh()))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)
	model.changed.connect(_render)
	_render()

func _pick_id(pick: OptionButton, id: String) -> void:
	for i in pick.item_count:
		if pick.get_item_metadata(i) == id:
			pick.select(i)
			return

func select_block(id: String) -> void:
	active_id = id
	view.active_id = id
	var node = model.node(id)
	if node == null:
		return
	title_edit.text = node["title"]
	image_edit.text = node.get("image","")
	appearance.select(Plan.ROLES.find(node["appearance"]))
	view.role = node["appearance"]
	vlan.value = node["vlan"]
	for i in 3:
		coords[i].set_value_no_signal(node["cell"][i])
	view.cell = node["cell"].duplicate()
	view.turn = int(node["rotation"])
	view.refresh()

func _render() -> void:
	_updating = true
	graph.clear_connections()
	for child in graph.get_children():
		if child is GraphNode:
			graph.remove_child(child)
			child.queue_free()
	var source = from_pick.get_item_metadata(from_pick.selected) if from_pick.selected >= 0 else ""
	var dest = to_pick.get_item_metadata(to_pick.selected) if to_pick.selected >= 0 else ""
	from_pick.clear()
	to_pick.clear()
	for item in model.data["nodes"]:
		var card = GraphNode.new()
		card.name = item["id"]
		card.title = item["title"]
		card.position_offset = Vector2(item["x"],item["y"])
		card.custom_minimum_size.x = 200
		for kind in Plan.sockets(item):
			var label = Label.new()
			label.text = kind + "   IN → OUT"
			card.add_child(label)
			card.set_slot(card.get_child_count()-1,true,Plan.KINDS.find(kind),Plan.COLORS[kind],true,Plan.KINDS.find(kind),Plan.COLORS[kind])
		card.gui_input.connect(func(event):
			if event is InputEventMouseButton and event.pressed:
				select_block(item["id"]))
		graph.add_child(card)
		for pick in [from_pick,to_pick]:
			pick.fit_to_longest_item = false
			pick.custom_minimum_size.x = 150
			pick.add_item(item["title"])
			pick.set_item_metadata(pick.item_count-1,item["id"])
	for edge in model.data["edges"]:
		graph.connect_node(edge["from"],Plan.sockets(model.node(edge["from"])).find(edge["kind"]),edge["to"],Plan.sockets(model.node(edge["to"])).find(edge["kind"]))
	_pick_id(from_pick,str(source))
	_pick_id(to_pick,str(dest))
	view.refresh()
	if model.node(active_id) != null:
		select_block(active_id)
	_report()
	plan_changed.emit(snapshot())
	_updating = false

func _report() -> void:
	status.text = model.error if model.error != "" else "%d blocks · %d directed routes · local draft only. Save locally to keep changes; no containers are deployed." % [model.data["nodes"].size(),model.data["edges"].size()]

func apply_fields() -> void:
	model.edit(active_id,{"title":title_edit.text,"image":image_edit.text,"appearance":Plan.ROLES[appearance.selected],"vlan":int(vlan.value),"cell":coords.map(func(c): return int(c.value))})
	_report()

func rotate_selected() -> void:
	var node = model.node(active_id)
	if node != null:
		model.edit(active_id,{"rotation":(int(node["rotation"])+1)%4})
		_report()

func set_route(a: String,b: String,kind: String) -> void:
	_pick_id(from_pick,a)
	_pick_id(to_pick,b)
	kind_pick.select(Plan.KINDS.find(kind))
	for edge in model.data["edges"]:
		if [edge["from"],edge["to"],edge["kind"]] == [a,b,kind]:
			port_edit.text = edge.get("port","")
			mount_edit.text = edge.get("mount_path","")
			mount_read_only.button_pressed = edge.get("read_only",false)
			return
	port_edit.text = ""
	mount_edit.text = ""
	mount_read_only.button_pressed = false

func preview_route() -> void:
	if from_pick.selected < 0 or to_pick.selected < 0:
		status.text = "Add two blocks, then choose source and destination sockets."
		return
	selected_edge = Plan.route(from_pick.get_item_metadata(from_pick.selected),to_pick.get_item_metadata(to_pick.selected),Plan.KINDS[kind_pick.selected],port_edit.text)
	selected_edge["mount_path"] = mount_edit.text
	selected_edge["read_only"] = mount_read_only.button_pressed
	var next = snapshot()
	next["edges"] = next["edges"].filter(func(e): return [e["from"],e["to"],e["kind"]] != [selected_edge["from"],selected_edge["to"],selected_edge["kind"]])
	next["edges"].append(selected_edge)
	var problem = Plan.problem(next)
	if problem != "":
		status.text = problem
		selected_edge.clear()
		view.preview.clear()
	else:
		view.preview = selected_edge.duplicate()
		status.text = "Preview: %s → %s · %s %s. Confirm route to keep it, or remove the selected route." % [model.node(selected_edge["from"])["title"],model.node(selected_edge["to"])["title"],selected_edge["kind"],selected_edge["port"]]
	view.refresh()

func add_workload() -> void:
	var cell = [0,0,0]
	while model.data["nodes"].any(func(n): return n["cell"] == cell):
		cell[0] += 2
	var id = model.add("New workload",cell)
	if id != "":
		select_block(id)
	view.fit()

func _remove(ids: Array) -> void:
	model.remove(ids.map(func(id): return str(id)))

func remove_selected() -> void:
	var ids = []
	for child in graph.get_children():
		if child is GraphNode and child.selected:
			ids.append(str(child.name))
	if ids.is_empty() and active_id != "":
		ids.append(active_id)
	model.remove(ids)

func load_preset(media: bool) -> void:
	var legacy = {"nodes":[],"edges":[]}
	var ids = {}
	for row in Topology.preset(media):
		for id in [row[0],row[1]]:
			if not ids.has(id):
				var index = ids.size()
				ids[id] = index
				legacy["nodes"].append({"title":id,"vlan":int(Topology.SEGMENTS.get(id.get_slice("/",0),0)),"x":40+(index%4)*245,"y":40+floori(index/4.0)*260})
		legacy["edges"].append([ids[row[0]],ids[row[1]],Plan.KINDS.find(row[2])])
	model.commit(Plan.migrate(legacy))
	view.fit.call_deferred()
	fit_graph.call_deferred()

func snapshot() -> Dictionary:
	return model.data.duplicate(true)

func restore(saved: Dictionary) -> void:
	if not model.load_plan(saved):
		_report()
	view.fit.call_deferred()
	fit_graph.call_deferred()

func fit_graph() -> void:
	var cards = graph.get_children().filter(func(c): return c is GraphNode)
	if cards.is_empty():
		return
	var bounds = Rect2(cards[0].position_offset,cards[0].get_combined_minimum_size())
	for card in cards:
		bounds = bounds.merge(Rect2(card.position_offset,card.get_combined_minimum_size()))
	graph.zoom = clampf(minf(graph.size.x/(bounds.size.x+80),graph.size.y/(bounds.size.y+80)),0.08,1.0)
	graph.scroll_offset = bounds.position*graph.zoom-(graph.size-bounds.size*graph.zoom)*0.5
