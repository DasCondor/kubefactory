extends VBoxContainer

const Topology = preload("res://scripts/demo_topology.gd")

var graph = GraphEdit.new()
var status = Label.new()
var seq = 0

func _ready() -> void:
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.custom_minimum_size.y = 415
	graph.connection_request.connect(func(a, ap, b, bp):
		if a != b and ap == bp:
			graph.connect_node(a, ap, b, bp))
	graph.disconnection_request.connect(graph.disconnect_node)
	graph.right_disconnects = true
	graph.delete_nodes_request.connect(_remove)
	add_child(graph)
	add_child(status)

func _remove(nodes: Array) -> void:
	for link in graph.get_connection_list():
		if link["from_node"] in nodes or link["to_node"] in nodes:
			graph.disconnect_node(link["from_node"], link["from_port"], link["to_node"], link["to_port"])
	for id in nodes:
		var node = graph.get_node_or_null(NodePath(str(id)))
		if node != null:
			graph.remove_child(node)
			node.queue_free()

func _add(title: String, vlan: int, at: Vector2) -> GraphNode:
	var node = GraphNode.new()
	seq += 1
	node.name = "Workload%d" % seq
	node.title = title
	node.position_offset = at
	var title_edit = LineEdit.new()
	title_edit.text = title
	title_edit.placeholder_text = "Workload name"
	title_edit.custom_minimum_size.x = 175
	title_edit.text_changed.connect(func(value): node.title = value)
	node.add_child(title_edit)
	for kind in Topology.COLORS:
		var label = Label.new()
		label.text = kind
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		node.add_child(label)
		node.set_slot(node.get_child_count() - 1, true, node.get_child_count(), Topology.COLORS[kind],
			true, node.get_child_count(), Topology.COLORS[kind])
	var tag = SpinBox.new()
	tag.name = "VLAN"
	tag.min_value = 0
	tag.max_value = 4094
	tag.value = vlan
	tag.prefix = "VLAN"
	tag.tooltip_text = "802.1Q tag (1–4094). Use 0 for unassigned."
	node.add_child(tag)
	graph.add_child(node)
	return node

func add_workload() -> void:
	_add("New workload", 0, (graph.scroll_offset + graph.size * 0.3) / graph.zoom)

func remove_selected() -> void:
	var ids = []
	for node in graph.get_children():
		if node is GraphNode and node.selected:
			ids.append(node.name)
	_remove(ids)

func _reset() -> void:
	graph.clear_connections()
	for node in graph.get_children():
		if node is GraphNode:
			graph.remove_child(node)
			node.queue_free()
	graph.scroll_offset = Vector2.ZERO

func load_preset(media: bool) -> void:
	_reset()
	var nodes = {}
	for row in Topology.preset(media):
		for id in [row[0], row[1]]:
			if not nodes.has(id):
				var index = nodes.size()
				nodes[id] = _add(id, int(Topology.SEGMENTS.get(id.get_slice("/", 0), 0)),
					Vector2(40 + (index % 4) * 245, 40 + floori(index / 4.0) * 260))
		var port = Topology.COLORS.keys().find(row[2])
		graph.connect_node(nodes[row[0]].name, port, nodes[row[1]].name, port)
	status.text = "Drag cards or connect matching ports. Use the minimap to navigate."

func snapshot() -> Dictionary:
	var nodes = []
	var ids = {}
	for node in graph.get_children():
		if node is GraphNode:
			ids[node.name] = nodes.size()
			nodes.append({"title": node.title, "vlan": int(node.get_node("VLAN").value), "x": node.position_offset.x, "y": node.position_offset.y})
	var edges = []
	for link in graph.get_connection_list():
		edges.append([ids[link["from_node"]], ids[link["to_node"]], link["from_port"]])
	return {"nodes": nodes, "edges": edges}

func restore(saved: Dictionary) -> void:
	_reset()
	var nodes = []
	for node in saved.get("nodes", []):
		nodes.append(_add(str(node["title"]), int(node["vlan"]), Vector2(node["x"], node["y"])))
	for edge in saved.get("edges", []):
		if edge[0] >= 0 and edge[0] < nodes.size() and edge[1] >= 0 and edge[1] < nodes.size() and edge[2] in [0, 1, 2, 3]:
			graph.connect_node(nodes[int(edge[0])].name, int(edge[2]), nodes[int(edge[1])].name, int(edge[2]))
	status.text = "Saved flowchart loaded."
