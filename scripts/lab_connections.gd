extends GraphEdit
# The same configured endpoints and edges drive this board and the factory pipes.

const K = preload("res://scripts/kutil.gd")
const Lab = preload("res://scripts/demo_media_lab.gd")
signal endpoint_activated(uid)
var selected_uid = ""
var cards = {}
var routes = []
var _signature = ""
var category = "All"
var layout = {}
var _slots = {}
var colors = Lab.COLORS.merged({"Placement": Color(0.47, 0.50, 0.71), "Configuration": Color(0.48, 0.65, 0.46)})

func configure(config) -> void:
	if config is Dictionary:
		category = str(config.get("category", "All"))
		if category not in ["All", "Reporting", "Storage", "LAN / VLAN", "Internet / VPN"]:
			category = "All"
		layout = config.get("layout", {}).duplicate(true) if config.get("layout_style") == "spider" and config.get("layout", {}) is Dictionary else {}
	_signature = ""

func _ready() -> void:
	zoom_min = 0.08
	zoom = 0.75
	show_grid = false
	show_menu = false
	minimap_enabled = false
	right_disconnects = false
	connection_lines_thickness = 1.5
	var paper = StyleBoxFlat.new()
	paper.bg_color = Color(0.94, 0.95, 0.91)
	add_theme_stylebox_override("panel", paper)

func fit_routes() -> void:
	if cards.is_empty():
		return
	var bounds = Rect2(cards.values()[0].position_offset, cards.values()[0].size)
	for card in cards.values():
		bounds = bounds.merge(Rect2(card.position_offset, card.size))
	zoom = clampf(minf(size.x / (bounds.size.x + 80), size.y / (bounds.size.y + 80)), 0.08, 1.0)
	scroll_offset = bounds.position * zoom - (size - bounds.size * zoom) * 0.5

func arrange_spider(reset: bool = true) -> void:
	if cards.is_empty():
		return
	var ids = cards.keys()
	ids.sort_custom(func(a, b): return cards[a].title < cards[b].title)
	var hub = selected_uid if cards.has(selected_uid) else ids[0]
	if not cards.has(selected_uid):
		for uid in ids:
			if cards[uid].title == "prometheus":
				hub = uid
	var peers = {}
	for uid in ids:
		peers[uid] = []
	for route in routes:
		if peers.has(route["from"]) and peers.has(route["to"]):
			for pair in [[route["from"], route["to"]], [route["to"], route["from"]]]:
				if pair[1] not in peers[pair[0]]:
					peers[pair[0]].append(pair[1])
	var walk = [hub]
	var parents = {hub: ""}
	var children = {}
	var depths = {hub: 0}
	for i in ids.size():
		if i == walk.size():
			# Disconnected islands get space on the board, without inventing an edge.
			var orphan = ids.filter(func(uid): return not parents.has(uid))[0]
			parents[orphan] = hub
			depths[orphan] = 1
			children[hub].append(orphan)
			walk.append(orphan)
		var uid = walk[i]
		children[uid] = []
		peers[uid].sort_custom(func(a, b): return cards[a].title < cards[b].title)
		for peer in peers[uid]:
			if not parents.has(peer):
				parents[peer] = uid
				depths[peer] = depths[uid] + 1
				children[uid].append(peer)
				walk.append(peer)
	var weights = {}
	var reverse_walk = walk.duplicate()
	reverse_walk.reverse()
	for uid in reverse_walk:
		weights[uid] = 1
		for child in children[uid]:
			weights[uid] += weights[child]
	var sectors = {hub: Vector2(-PI, PI)}
	var centers = {}
	for uid in walk:
		var angle: float = (sectors[uid].x + sectors[uid].y) * 0.5
		centers[uid] = Vector2(cos(angle) * depths[uid] * 340, sin(angle) * depths[uid] * 190)
		var start: float = sectors[uid].x
		for child in children[uid]:
			var span: float = (sectors[uid].y - sectors[uid].x) * weights[child] / maxf(1, weights[uid] - 1)
			sectors[child] = Vector2(start, start + span)
			start += span
	for uid in ids:
		if not reset and layout.has(cards[uid].title):
			centers[uid] = cards[uid].position_offset + cards[uid].get_combined_minimum_size() * 0.5
	for pass_index in 30:
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var a = ids[i]
				var b = ids[j]
				var delta: Vector2 = centers[b] - centers[a]
				var overlap: Vector2 = (cards[a].get_combined_minimum_size() + cards[b].get_combined_minimum_size()) * 0.5 + Vector2(35, 22) - delta.abs()
				if overlap.x <= 0 or overlap.y <= 0:
					continue
				var push = Vector2((1 if delta.x >= 0 else -1) * (overlap.x + 1), 0) if overlap.x < overlap.y else Vector2(0, (1 if delta.y >= 0 else -1) * (overlap.y + 1))
				if a != hub and (reset or not layout.has(cards[a].title)):
					centers[a] -= push * 0.5
				if b != hub and (reset or not layout.has(cards[b].title)):
					centers[b] += push * 0.5
	for uid in ids:
		if reset or not layout.has(cards[uid].title):
			cards[uid].position_offset = centers[uid] - cards[uid].get_combined_minimum_size() * 0.5

func select_endpoint(uid: String) -> void:
	selected_uid = uid
	for id in cards:
		cards[id].selected = id == uid
		for kind in _slots[id]:
			var related = uid == "" or routes.any(func(route): return route["kind"] == kind and id in [route["from"], route["to"]] and uid in [route["from"], route["to"]])
			var color: Color = colors[kind].darkened(0.18)
			color.a = 0.95 if related else 0.18
			cards[id].set_slot_color_left(_slots[id][kind], color)
			cards[id].set_slot_color_right(_slots[id][kind], color)

func focus_selected() -> void:
	if cards.has(selected_uid):
		zoom = maxf(zoom, 0.85)
		scroll_offset = (cards[selected_uid].position_offset + cards[selected_uid].size * 0.5) * zoom - size * 0.5

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		scroll_offset -= event.relative
		accept_event()

func refresh(state: Dictionary) -> bool:
	var links: Array = state.get("links", [])
	var kinds: Array = {"Reporting": ["Metrics", "Mounts"], "Storage": ["Mounts", "Files"],
		"LAN / VLAN": ["LAN", "API"], "Internet / VPN": ["HTTPS", "VPN", "Alerts"]}.get(category, [])
	if not kinds.is_empty():
		links = links.filter(func(link): return link["kind"] in kinds)
	var signature = category + str(state.get("lab", {}).get("access")) + str(state.get("board", []))
	for pod in ([] if state.has("board") else state["pods"]):
		if category != "All" and not links.any(func(link): return pod["uid"] in [link["from"], link["to"]]):
			continue
		signature += str([pod["uid"], pod["health"], pod.get("docker_ports")])
	for link in links:
		signature += str([link["from"], link["to"], link["kind"], link["ready"], link.get("port"), link["what"]])
	if signature == _signature:
		return false
	_signature = signature
	clear_connections()
	for node in cards.values():
		remove_child(node)
		node.queue_free()
	cards.clear()
	_slots.clear()
	routes = links.duplicate(true)
	var endpoints = []
	var bindings = K.port_rows(state)
	for pod in state["pods"]:
		if category != "All" and not links.any(func(link): return pod["uid"] in [link["from"], link["to"]]):
			continue
		var app: String = pod["wname"]
		var ports = bindings.filter(func(row): return pod["uid"] in row["pods"])
		var subtitle = "No listener"
		if not ports.is_empty():
			subtitle = "%s\n%s | %s" % [ports[0]["port"].replace("→", ">"), ports[0]["scope"], "running" if pod["ready"] else "OFFLINE"]
		endpoints.append([pod["uid"], app, subtitle, Vector2.ZERO])
	for id in ({} if state.has("board") else state.get("lab", {}).get("fixtures", {})):
		if id == "sync-switch":
			continue
		if category != "All" and not links.any(func(link): return "lab:" + id in [link["from"], link["to"]]):
			continue
		var subtitle: String
		if Lab.DISKS.has(id):
			subtitle = "Shared volume" if Lab.DISKS[id][2].size() > 1 else "Persistent volume"
			for mount in Lab.DISKS[id][2]:
				subtitle += "\n%s %s" % [mount[1], "RO" if mount[2] else "RW"]
		else:
			subtitle = state["lab"]["access"] if id == "lan" else "External destination"
			var destinations = []
			for link in links:
				if "lab:" + id in [link["from"], link["to"]] and link.get("port", "") not in destinations:
					destinations.append(link.get("port", ""))
			subtitle += "\n" + ", ".join(destinations)
		endpoints.append(["lab:" + id, state["lab"]["fixtures"][id], subtitle, Vector2.ZERO])
	if state.has("board"):
		endpoints = state["board"].map(func(entry): return [entry[0], entry[1], entry[2], Vector2.ZERO, entry[3]])
	var ports = {}
	for endpoint in endpoints:
		var uid: String = endpoint[0]
		var node = GraphNode.new()
		node.name = "Endpoint%d" % cards.size()
		node.title = endpoint[1]
		node.position_offset = endpoint[3]
		var saved = layout.get(endpoint[1])
		if saved is Array and saved.size() == 2 and (saved[0] is float or saved[0] is int) and (saved[1] is float or saved[1] is int):
			node.position_offset = Vector2(clampf(saved[0], -5000, 5000), clampf(saved[1], -5000, 5000))
		node.position_offset_changed.connect(func(): layout[endpoint[1]] = [node.position_offset.x, node.position_offset.y])
		node.custom_minimum_size.x = 200
		var ink = StyleBoxFlat.new()
		ink.bg_color = Color(0.99, 0.99, 0.97)
		if endpoint.size() > 4 and endpoint[4] == "planned":
			ink.bg_color = Color(0.84, 0.98, 0.86)
		ink.border_color = Lab.COLORS["Mounts"] if uid.begins_with("lab:") and Lab.DISKS.has(uid.trim_prefix("lab:")) else Color(0.25, 0.39, 0.45)
		ink.set_border_width_all(2)
		ink.set_content_margin_all(5)
		ink.set_corner_radius_all(9)
		node.add_theme_stylebox_override("panel", ink)
		var titlebar = ink.duplicate()
		titlebar.bg_color = Color(0.84, 0.88, 0.86)
		node.add_theme_stylebox_override("titlebar", titlebar)
		var selected_panel = ink.duplicate()
		selected_panel.border_color = Color(0.94, 0.45, 0.14)
		selected_panel.set_border_width_all(3)
		node.add_theme_stylebox_override("panel_selected", selected_panel)
		node.add_theme_color_override("title_color", Color(0.10, 0.16, 0.19))
		var description = Label.new()
		description.text = str(endpoint[2]).get_slice("\n", 0)
		if not uid.begins_with("lab:") and K.find_pod(state, uid) != null:
			var pod = K.find_pod(state, uid)
			var bindings_for_pod: Array = pod.get("docker_ports", [])
			if not bindings_for_pod.is_empty():
				description.text = bindings_for_pod[0]["target"] + (" | OFFLINE" if not pod["ready"] else "")
		description.add_theme_font_size_override("font_size", 13)
		description.add_theme_color_override("font_color", Color(0.16, 0.21, 0.23))
		node.add_child(description)
		var incoming = 0
		var outgoing = 0
		ports[uid] = {}
		_slots[uid] = {}
		for kind in colors:
			var inputs = links.any(func(link): return link["to"] == uid and link["kind"] == kind)
			var outputs = links.any(func(link): return link["from"] == uid and link["kind"] == kind)
			if not inputs and not outputs:
				continue
			var label = Label.new()
			label.text = "Storage mount" if kind == "Mounts" else ("File transfer" if kind == "Files" else kind)
			label.add_theme_font_size_override("font_size", 10)
			label.add_theme_color_override("font_color", Color(0.16, 0.21, 0.23))
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			node.add_child(label)
			node.set_slot(node.get_child_count() - 1, inputs, 0, colors[kind], outputs, 0, colors[kind])
			_slots[uid][kind] = node.get_child_count() - 1
			ports[uid][kind] = [incoming, outgoing]
			if inputs:
				incoming += 1
			if outputs:
				outgoing += 1
		node.tooltip_text = endpoint[1] + "\n" + endpoint[2]
		node.gui_input.connect(func(event):
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				select_endpoint(uid)
				if event.double_click:
					endpoint_activated.emit(uid))
		add_child(node)
		for title in node.get_titlebar_hbox().find_children("*", "Label", true, false):
			title.add_theme_color_override("font_color", Color(0.10, 0.16, 0.19))
			title.add_theme_font_size_override("font_size", 26)
		cards[uid] = node
		node.selected = uid == selected_uid
	for link in links:
		if cards.has(link["from"]) and cards.has(link["to"]):
			connect_node(cards[link["from"]].name, ports[link["from"]][link["kind"]][1],
				cards[link["to"]].name, ports[link["to"]][link["kind"]][0])
	arrange_spider(false)
	select_endpoint(selected_uid)
	return true
