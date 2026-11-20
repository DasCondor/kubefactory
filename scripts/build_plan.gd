extends RefCounted
# One local draft drives graph cards, factory blocks and configuration previews.

signal changed
const ROLES = ["app", "worker", "storage", "gateway", "reporting", "generic"]
const KINDS = ["API", "Metrics", "Files", "VPN", "Mounts", "LAN", "HTTPS", "Alerts"]
const COLORS = {"API": Color(0.30, 0.65, 1), "Metrics": Color(0.15, 0.85, 0.8), "Files": Color(1, 0.52, 0.2),
	"VPN": Color(0.76, 0.52, 0.98), "Mounts": Color(0.95, 0.73, 0.3), "LAN": Color(0.5, 0.9, 0.3), "HTTPS": Color(0.65, 0.6, 0.98), "Alerts": Color(0.96, 0.4, 0.8)}
var data = {"version": 2, "nodes": [], "edges": []}
var history = []
var error = ""

static func role_of(title: String) -> String:
	var text = title.to_lower()
	if ["storage", "library", "inbox", "outbox", "-data", "-config"].any(func(s): return text.contains(s)):
		return "storage"
	if ["vpn", "gluetun", "gateway", "www", "lan"].any(func(s): return text.contains(s)):
		return "gateway"
	if ["grafana", "prometheus", "exporter", "metrics", "tautulli", "blackbox"].any(func(s): return text.contains(s)):
		return "reporting"
	if ["sonarr", "radarr", "jackett", "prowlarr", "download", "sync", "worker", "import"].any(func(s): return text.contains(s)):
		return "worker"
	return "app"

static func sockets(node: Dictionary) -> Array:
	return ["Files", "Mounts"] if node.get("appearance") == "storage" else KINDS

static func migrate(saved: Dictionary) -> Dictionary:
	if saved.has("version"):
		# A plan read back from JSON has floats for whole numbers; keep them ints so a
		# reloaded plan compares, hashes and places exactly like the one that was saved.
		var plan = saved.duplicate(true)
		if plan["version"] is float and plan["version"] == roundf(plan["version"]):
			plan["version"] = int(plan["version"])
		for node in plan.get("nodes", []) if plan.get("nodes") is Array else []:
			if not node is Dictionary:
				continue
			if node.get("cell") is Array:
				node["cell"] = node["cell"].map(func(v): return int(v) if v is float and v == roundf(v) else v)
			for key in ["rotation", "vlan"]:
				if node.get(key) is float and node[key] == roundf(node[key]):
					node[key] = int(node[key])
		return plan
	var out = {"version": 2, "nodes": [], "edges": []}
	if not saved.get("nodes") is Array or not saved.get("edges", []) is Array:
		return {}
	var occupied = []
	for i in saved["nodes"].size():
		var old = saved["nodes"][i]
		if not old is Dictionary:
			return {}
		var cell = [roundi(float(old.get("x", 0)) / 245) * 2, 0, roundi(float(old.get("y", 0)) / 260) * 2]
		while cell in occupied:
			cell[0] += 1
		occupied.append(cell.duplicate())
		var title = str(old.get("title", "Workload %d" % (i + 1)))
		if title.strip_edges() == "":
			title = "Workload %d" % (i + 1)
		out["nodes"].append({"id": "b%d" % (i + 1), "title": title, "cell": cell, "rotation": 0, "appearance": role_of(title),
			"vlan": old.get("vlan", 0), "x": old.get("x", 0), "y": old.get("y", 0), "image": "", "observed_uid": "", "resource_type": "volume" if role_of(title) == "storage" else "workload"})
	for edge in saved.get("edges", []):
		if not edge is Array or edge.size() != 3 or not str(edge[0]).is_valid_int() or not str(edge[1]).is_valid_int():
			return {}
		var a = int(edge[0])
		var b = int(edge[1])
		var k = int(edge[2])
		if a < 0 or b < 0 or a >= out["nodes"].size() or b >= out["nodes"].size() or k < 0 or k >= 4:
			return {}
		out["edges"].append(route("b%d" % (a + 1), "b%d" % (b + 1), KINDS[k]))
	return out

static func route(a: String, b: String, kind: String, port: String = "") -> Dictionary:
	return {"from": a, "to": b, "kind": kind, "from_socket": kind + "-out", "to_socket": kind + "-in", "port": port, "mount_path": "", "read_only": false}

static func problem(plan) -> String:
	if not plan is Dictionary or plan.get("version") != 2 or not plan.get("nodes") is Array or not plan.get("edges") is Array:
		return "This is not a supported version 2 build plan."
	if plan["nodes"].size() > 128 or plan["edges"].size() > 512:
		return "A local plan supports up to 128 blocks and 512 routes."
	var ids = {}
	var cells = []
	var identifier = RegEx.new()
	identifier.compile("^[A-Za-z0-9_-]+$")
	var image_name = RegEx.new()
	image_name.compile("^[A-Za-z0-9][A-Za-z0-9./:@_-]*$")
	for node in plan["nodes"]:
		if not node is Dictionary or not node.get("id") is String or node["id"] == "" or node["id"].length() > 80 or ids.has(node["id"]):
			return "Every block needs a unique ID."
		if identifier.search(node["id"]) == null or node.get("resource_type", "workload") not in ["workload", "volume", "boundary"]:
			return "Block IDs use letters, numbers, dashes or underscores, and need a valid resource type."
		if not node.get("title") is String or node["title"].strip_edges() == "" or node["title"].length() > 128:
			return "Every block needs a name of 1–128 characters."
		if node.get("appearance") not in ROLES or not node.get("cell") is Array or node["cell"].size() != 3:
			return "Choose a block appearance and a three-coordinate grid cell."
		for value in node["cell"] + [node.get("rotation"), node.get("vlan")]:
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) != floorf(float(value)):
				return "Grid coordinates, rotation and VLAN must be whole numbers."
		var cell: Array = node["cell"]
		if absf(cell[0]) > 128 or cell[1] < 0 or cell[1] > 32 or absf(cell[2]) > 128 or node["rotation"] < 0 or node["rotation"] > 3 or node["vlan"] < 0 or node["vlan"] > 4094:
			return "The grid, rotation or VLAN is outside its supported range."
		if cell in cells:
			return "That grid cell is occupied."
		for key in ["x", "y"]:
			if typeof(node.get(key)) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(node[key])) or absf(float(node[key])) > 100000:
				return "Graph positions must be finite coordinates."
		if not node.get("image", "") is String or str(node.get("image", "")).length() > 256 or not node.get("observed_uid", "") is String:
			return "Image and observed workload ID must be text."
		if node.get("image", "") != "" and image_name.search(node["image"]) == null:
			return "Use a container image name, without shell commands or variable substitutions."
		if not node.get("bindings", []) is Array or node.get("bindings", []).size() > 64:
			return "A block can hold up to 64 port bindings."
		for binding in node.get("bindings", []):
			if not binding is Dictionary or not binding.get("target", "") is String or not binding.get("ip", "") is String or not binding.get("published", "") is String:
				return "Port bindings must contain text target, address and published port fields."
		cells.append(cell)
		ids[node["id"]] = node
	var seen = []
	var gateways = {}
	for edge in plan["edges"]:
		if not edge is Dictionary or not ids.has(edge.get("from")) or not ids.has(edge.get("to")) or edge["from"] == edge["to"]:
			return "A route must join two different existing blocks."
		var kind = edge.get("kind")
		if kind not in KINDS or kind not in sockets(ids[edge["from"]]) or kind not in sockets(ids[edge["to"]]):
			return "Those socket types are incompatible. Storage accepts only mounts or files."
		if edge.get("from_socket") != kind + "-out" or edge.get("to_socket") != kind + "-in":
			return "Connect an output socket to a matching input socket."
		var key = [edge["from"], edge["to"], kind]
		if key in seen:
			return "That route already exists."
		seen.append(key)
		if kind == "VPN" and ids[edge["to"]].get("resource_type","workload") == "workload":
			if gateways.has(edge["from"]) and gateways[edge["from"]] != edge["to"]:
				return "A workload can use one shared VPN namespace at a time."
			gateways[edge["from"]] = edge["to"]
		if not edge.get("port", "") is String or not edge.get("mount_path", "") is String or not edge.get("read_only", false) is bool:
			return "Route port, mount path or access has an invalid type."
		if edge.get("port", "").length() > 256 or edge.get("mount_path", "").length() > 512:
			return "Route details are too long."
		var path: String = edge.get("mount_path", "")
		if path != "" and (not path.begins_with("/") or ".." in path.split("/") or path.contains(char(0))):
			return "A mount needs an absolute path without parent-directory traversal."
	for id in gateways:
		if gateways.has(gateways[id]):
			return "VPN namespace chains or cycles are not supported. Use a direct gateway."
	return ""

func load_plan(saved: Dictionary) -> bool:
	var next = migrate(saved)
	error = problem(next)
	if error != "":
		return false
	data = next
	history.clear()
	changed.emit()
	return true

func commit(next: Dictionary) -> bool:
	error = problem(next)
	if error != "":
		return false
	if next == data:
		return true
	history.append(data.duplicate(true))
	if history.size() > 64:
		history.pop_front()
	data = next
	changed.emit()
	return true

func undo() -> bool:
	if history.is_empty():
		return false
	data = history.pop_back()
	error = ""
	changed.emit()
	return true

func node(id: String):
	for item in data["nodes"]:
		if item["id"] == id:
			return item
	return null

func add(title: String, cell: Array, appearance: String = "generic", image: String = "", rotation: int = 0) -> String:
	var next = data.duplicate(true)
	var id = "b1"
	var seq = 1
	while node(id) != null:
		seq += 1
		id = "b%d" % seq
	next["nodes"].append({"id": id, "title": title, "cell": cell.duplicate(), "rotation": rotation, "appearance": appearance, "image": image,
		"observed_uid": "", "resource_type": "volume" if appearance == "storage" else "workload", "vlan": 0, "x": cell[0] * 120.0, "y": cell[2] * 120.0})
	return id if commit(next) else ""

func edit(id: String, fields: Dictionary) -> bool:
	var next = data.duplicate(true)
	for item in next["nodes"]:
		if item["id"] == id:
			item.merge(fields, true)
			if fields.has("cell"):
				item["x"] = fields["cell"][0]*120.0
				item["y"] = fields["cell"][2]*120.0
			return commit(next)
	error = "Select an existing block first."
	return false

func remove(ids: Array) -> bool:
	var next = data.duplicate(true)
	next["nodes"] = next["nodes"].filter(func(n): return n["id"] not in ids)
	next["edges"] = next["edges"].filter(func(e): return e["from"] not in ids and e["to"] not in ids)
	return commit(next)

func connect_blocks(a: String, b: String, kind: String, port: String = "") -> bool:
	var next = data.duplicate(true)
	next["edges"].append(route(a, b, kind, port))
	return commit(next)

func disconnect_blocks(a: String, b: String, kind: String) -> bool:
	var next = data.duplicate(true)
	next["edges"] = next["edges"].filter(func(e): return [e["from"], e["to"], e["kind"]] != [a, b, kind])
	return commit(next)

func edit_route(edge: Dictionary) -> bool:
	var next = data.duplicate(true)
	for i in next["edges"].size():
		var existing = next["edges"][i]
		if [existing["from"],existing["to"],existing["kind"]] == [edge["from"],edge["to"],edge["kind"]]:
			next["edges"][i] = edge.duplicate(true)
			return commit(next)
	next["edges"].append(edge.duplicate(true))
	return commit(next)

func from_state(state: Dictionary) -> bool:
	var next = {"version": 2, "nodes": [], "edges": []}
	var ids = {}
	var items = []
	for pod in state.get("pods", []):
		items.append([pod["uid"], pod.get("wname", pod["name"]), pod["containers"][0]["image"] if not pod.get("containers", []).is_empty() else ""])
	for id in state.get("lab", {}).get("fixtures", {}):
		if id != "sync-switch":
			items.append(["lab:" + id, id, ""])
	for i in items.size():
		var id = "b%d" % (i + 1)
		ids[items[i][0]] = id
		var role = "storage" if items[i][0].begins_with("lab:") and not items[i][1] in ["lan", "www", "discord"] else role_of(items[i][1])
		var source = state.get("pods", []).filter(func(p): return p["uid"] == items[i][0])
		next["nodes"].append({"id": id, "title": items[i][1], "cell": [(i % 6) * 2, 0, floori(i / 6.0) * 2], "rotation": 0,
			"appearance": role, "image": items[i][2], "observed_uid": items[i][0], "bindings": source[0].get("docker_ports", []).duplicate(true) if not source.is_empty() else [],
			"resource_type": ("volume" if role == "storage" else "boundary") if items[i][0].begins_with("lab:") else "workload", "vlan": 0, "x": (i % 6) * 240, "y": floori(i / 6.0) * 250})
	for link in state.get("links", []):
		if ids.has(link["from"]) and ids.has(link["to"]) and link["kind"] in KINDS:
			var edge = route(ids[link["from"]], ids[link["to"]], link["kind"], str(link.get("port", "")))
			if link["kind"] == "Mounts":
				for p in state.get("pods", []):
					if p["uid"] == link["from"]:
						for mount in p.get("store", {}).get("shared_mounts", []):
							if "lab:" + str(mount["name"]) == link["to"]:
								edge["mount_path"] = mount["path"]
								edge["read_only"] = mount.get("read_only", false)
			if edge not in next["edges"]:
				next["edges"].append(edge)
	return commit(next)
