extends Node3D
# The connection board in 3D: every container (and, in the media lab, every
# volume and outside destination) as a block shaped by its role, and every
# declared connection as an arcing pipe in its kind's colour with an arrow
# toward the target and a dot flowing along it while it carries traffic.
# Used in the board panel (board_view.gd puts it in its own viewport with a
# camera) and, scaled down, on the board table in the world.

const K = preload("res://scripts/kutil.gd")
const Lab = preload("res://scripts/demo_media_lab.gd")
const Machine = preload("res://scripts/machine.gd")

const RING = 14.0          # distance between rings of the spider layout
const MIN_GAP = 9.5       # blocks are 4.2 wide; leave room for the name
const TOP = 4.4            # pipes leave and enter the blocks' roofs
const CATEGORIES = ["All", "Reporting", "Storage", "LAN / VLAN", "Internet / VPN"]
const CATEGORY_KINDS = {"Reporting": ["Metrics", "Mounts"], "Storage": ["Mounts", "Files"],
	"LAN / VLAN": ["LAN", "API"], "Internet / VPN": ["HTTPS", "VPN", "Alerts"]}

class Card extends Node3D:
	var uid = ""
	var title = ""
	var subtitle = ""
	var role = ""
	var key = ""             # its key in the saved layout: the title, "#2"... for replicas

var category = "All"
var selected_uid = ""
var layout = {}            # card key -> [x, z]
var cards = {}             # uid -> Card
var routes = []            # the links on the board after the category filter
var labels_visible = true  # the small table in the world hides the ports line
var _signature = ""
var _pipes: Node3D = null
var _flows = []            # [points, phase, speed] for the dots
var _dots: MultiMeshInstance3D = null
var _ring: MeshInstance3D = null
var _t = 0.0
static var _mats = {}

func configure(config) -> void:
	if config is Dictionary:
		category = str(config.get("category", "All"))
		if category not in CATEGORIES:
			category = "All"
		var saved = config.get("layout", {})
		layout = saved.duplicate(true) if saved is Dictionary else {}

static func _mat(color: Color, glow: float = 0.0) -> StandardMaterial3D:
	var key = color.to_html() + str(glow)
	if not _mats.has(key):
		var m = StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.55
		if glow > 0.0:
			m.emission_enabled = true
			m.emission = color
			m.emission_energy_multiplier = glow
		_mats[key] = m
	return _mats[key]

static func role_of_fixture(id: String) -> String:
	if Lab.DISKS.has(id):
		return "storage"
	return "gateway" if id in ["lan", "www"] else "generic"

# Rebuild when what the board shows changed. Returns true when it did.
func refresh(state: Dictionary) -> bool:
	var links: Array = state.get("links", [])
	var kinds: Array = CATEGORY_KINDS.get(category, [])
	if not kinds.is_empty():
		links = links.filter(func(link): return link["kind"] in kinds)
	var endpoints = []
	var bindings = K.port_rows(state)
	for pod in state.get("pods", []):
		if category != "All" and not links.any(func(link): return pod["uid"] in [link["from"], link["to"]]):
			continue
		var ports = bindings.filter(func(row): return pod["uid"] in row["pods"])
		var sub = str(ports[0]["port"]).replace("→", ">") if not ports.is_empty() else "no listener"
		if not pod.get("ready", true):
			sub += " · OFFLINE"
		var title = str(pod["wname"]) if str(pod.get("wname", "")) != "" else str(pod["name"])
		endpoints.append([pod["uid"], title, sub, Machine.role_for(pod)])
	for id in state.get("lab", {}).get("fixtures", {}):
		if id == "sync-switch":
			continue
		if category != "All" and not links.any(func(link): return "lab:" + id in [link["from"], link["to"]]):
			continue
		var sub = "volume" if Lab.DISKS.has(id) else ("inbound" if id == "lan" else "outside")
		endpoints.append(["lab:" + id, str(state["lab"]["fixtures"][id]), sub, role_of_fixture(id)])
	var signature = category + JSON.stringify(endpoints) + JSON.stringify(links.map(func(l): return [l["from"], l["to"], l["kind"], l.get("ready", true), l.get("flow", false)]))
	if signature == _signature:
		return false
	_signature = signature
	routes = links.filter(func(link): return endpoints.any(func(e): return e[0] == link["from"]) and endpoints.any(func(e): return e[0] == link["to"]))
	for c in cards.values():
		remove_child(c)
		c.queue_free()
	cards.clear()
	var used = {}
	for e in endpoints:
		var card = Card.new()
		card.uid = e[0]
		card.title = e[1]
		card.subtitle = e[2]
		card.role = e[3]
		var key: String = e[1]
		var n = 2
		while used.has(key):
			key = "%s #%d" % [e[1], n]
			n += 1
		used[key] = true
		card.key = key
		_build_card(card)
		add_child(card)
		cards[card.uid] = card
	_arrange(false)
	_draw_links()
	return true

func _build_card(card: Card) -> void:
	var body = MeshInstance3D.new()
	body.mesh = load("res://scripts/plan_blocks.gd").role_mesh(card.role)
	card.add_child(body)
	var name_tag = Label3D.new()
	name_tag.text = card.title
	name_tag.font_size = 72
	name_tag.pixel_size = 0.03
	name_tag.outline_size = 14
	name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_tag.position = Vector3(0, 6.6, 0)
	name_tag.name = "Name"
	card.add_child(name_tag)
	var sub = Label3D.new()
	sub.text = card.subtitle
	sub.font_size = 48
	sub.pixel_size = 0.026
	sub.outline_size = 10
	sub.modulate = Color(0.78, 0.84, 0.88)
	sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sub.position = Vector3(0, 5.3, 0)
	sub.name = "Sub"
	sub.visible = labels_visible
	card.add_child(sub)

# The spider layout of the flat board, on the floor: the hub (Prometheus where
# there is one, else the busiest card) in the middle, each ring further out.
func arrange_spider() -> void:
	layout.clear()
	_arrange(true)
	_draw_links()

func _arrange(reset: bool) -> void:
	if cards.is_empty():
		return
	var ids = cards.keys()
	ids.sort_custom(func(a, b): return cards[a].title < cards[b].title)
	var peers = {}
	for uid in ids:
		peers[uid] = []
	for r in routes:
		if peers.has(r["from"]) and peers.has(r["to"]):
			if r["to"] not in peers[r["from"]]:
				peers[r["from"]].append(r["to"])
			if r["from"] not in peers[r["to"]]:
				peers[r["to"]].append(r["from"])
	var hub = ids[0]
	for uid in ids:
		if peers[uid].size() > peers[hub].size():
			hub = uid
	for uid in ids:
		if cards[uid].title == "prometheus":
			hub = uid
	var walk = [hub]
	var depth = {hub: 0}
	var children = {}
	for i in ids.size():
		if i == walk.size():
			var orphan = ids.filter(func(u): return not depth.has(u))[0]
			depth[orphan] = 1
			children[hub].append(orphan)
			walk.append(orphan)
		var uid = walk[i]
		children[uid] = []
		for p in peers[uid]:
			if not depth.has(p):
				depth[p] = depth[uid] + 1
				children[uid].append(p)
				walk.append(p)
	var weight = {}
	var back = walk.duplicate()
	back.reverse()
	for uid in back:
		weight[uid] = 1
		for c in children[uid]:
			weight[uid] += weight[c]
	var sector = {hub: Vector2(-PI, PI)}
	var pos = {}
	for uid in walk:
		var a = (sector[uid].x + sector[uid].y) * 0.5
		pos[uid] = Vector2(cos(a), sin(a)) * depth[uid] * RING
		var start = sector[uid].x
		for c in children[uid]:
			var span = (sector[uid].y - sector[uid].x) * weight[c] / maxf(1.0, weight[uid] - 1)
			sector[c] = Vector2(start, start + span)
			start += span
	var fixed = {hub: true}
	for uid in ids:
		var saved = layout.get(cards[uid].key)
		if not reset and saved is Array and saved.size() == 2:
			pos[uid] = Vector2(float(saved[0]), float(saved[1]))
			fixed[uid] = true
	for pass_index in 80:
		var moved = false
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var a = ids[i]
				var b = ids[j]
				var d: Vector2 = pos[b] - pos[a]
				if d.length() < 0.01:
					d = Vector2(1, 0.4)
				var gap = MIN_GAP - d.length()
				if gap <= 0:
					continue
				var push = d.normalized() * (gap + 0.1)
				var move_a = not fixed.has(a)
				var move_b = not fixed.has(b)
				if move_a:
					pos[a] -= push * (0.5 if move_b else 1.0)
				if move_b:
					pos[b] += push * (0.5 if move_a else 1.0)
				moved = moved or move_a or move_b
		if not moved:
			break
	for uid in ids:
		cards[uid].position = Vector3(pos[uid].x, 0, pos[uid].y)

# A card moved by the player: it keeps that place in the saved layout.
func move_card(uid: String, at: Vector3) -> void:
	if not cards.has(uid):
		return
	cards[uid].position = Vector3(at.x, 0, at.z)
	layout[cards[uid].key] = [at.x, at.z]
	_draw_links()

func card_bounds() -> AABB:
	var box = AABB()
	var first = true
	for c in cards.values():
		var b = AABB(c.position - Vector3(3, 0, 3), Vector3(6, 8, 6))
		box = b if first else box.merge(b)
		first = false
	return box if not first else AABB(Vector3(-10, 0, -10), Vector3(20, 8, 20))

func select_endpoint(uid: String) -> void:
	selected_uid = uid if cards.has(uid) else ""
	_draw_links()

func related(uid: String) -> Array:
	var out = []
	for r in routes:
		if uid in [r["from"], r["to"]]:
			out.append(r["from"] if r["to"] == uid else r["to"])
	return out

func connection_list() -> Array:
	return routes.map(func(r): return {"from_node": r["from"], "to_node": r["to"], "kind": r["kind"]})

# The pipes: a quadratic arc from roof to roof, side by side when two cards
# share several, an arrow cone toward the target, dimmed when a card is
# selected and they are not its own.
func _draw_links() -> void:
	if _pipes != null:
		remove_child(_pipes)
		_pipes.queue_free()
	_pipes = Node3D.new()
	add_child(_pipes)
	_flows.clear()
	var tubes = {}
	var cones = {}
	var pair_count = {}
	for r in routes:
		var pk = [r["from"], r["to"]] if r["from"] < r["to"] else [r["to"], r["from"]]
		pair_count[str(pk)] = pair_count.get(str(pk), 0) + 1
	var pair_seen = {}
	var near = related(selected_uid) if selected_uid != "" else []
	for r in routes:
		if not cards.has(r["from"]) or not cards.has(r["to"]):
			continue
		var pk = [r["from"], r["to"]] if r["from"] < r["to"] else [r["to"], r["from"]]
		var index = pair_seen.get(str(pk), 0)
		pair_seen[str(pk)] = index + 1
		var a: Vector3 = cards[r["from"]].position + Vector3(0, TOP, 0)
		var b: Vector3 = cards[r["to"]].position + Vector3(0, TOP, 0)
		var flat = Vector3(b.x - a.x, 0, b.z - a.z)
		var side = flat.cross(Vector3.UP).normalized() if flat.length() > 0.01 else Vector3.RIGHT
		var shift = side * (index - (pair_count[str(pk)] - 1) * 0.5) * 0.9
		var mid = (a + b) * 0.5 + shift + Vector3(0, 2.5 + flat.length() * 0.22, 0)
		var pts = []
		for i in 13:
			var t = i / 12.0
			pts.append(a.lerp(mid, t).lerp(mid.lerp(b, t), t))
		var mine = selected_uid == "" or selected_uid in [r["from"], r["to"]]
		var color: Color = Lab.COLORS.get(r["kind"], Color(0.7, 0.7, 0.7))
		if not r.get("ready", true):
			color = color.darkened(0.55)
		if not mine:
			color = color.lerp(Color(0.35, 0.37, 0.4), 0.75)
		var key = color.to_html() + ("g" if mine and selected_uid != "" else "")
		if not tubes.has(key):
			tubes[key] = [color, []]
			cones[key] = [color, []]
		var radius = 0.32 if mine and selected_uid != "" else 0.22
		for i in range(1, pts.size()):
			var d: Vector3 = pts[i] - pts[i - 1]
			tubes[key][1].append(Transform3D(Basis(Quaternion(Vector3.UP, d.normalized())) * Basis.from_scale(Vector3(radius, d.length(), radius)), (pts[i] + pts[i - 1]) * 0.5))
		var tip: Vector3 = pts[8]
		var dir: Vector3 = (pts[9] - pts[7]).normalized()
		cones[key][1].append(Transform3D(Basis(Quaternion(Vector3.UP, dir)) * Basis.from_scale(Vector3.ONE * (1.5 if radius > 0.25 else 1.15)), tip))
		if mine and r.get("ready", true) and r.get("flow", true):
			_flows.append([pts, randf(), 0.35 + randf() * 0.15, color])
	for key in tubes:
		_multimesh(_cyl(1.0, 1.0), _mat(tubes[key][0], 0.35 if key.ends_with("g") else 0.0), tubes[key][1])
		_multimesh(_cyl(0.0, 0.9), _mat(cones[key][0], 0.35 if key.ends_with("g") else 0.0), cones[key][1])
	# the selected card's ring, and the flowing dots
	if selected_uid != "" and cards.has(selected_uid):
		var ring = MeshInstance3D.new()
		var cm = CylinderMesh.new()
		cm.top_radius = 3.6
		cm.bottom_radius = 3.6
		cm.height = 0.12
		ring.mesh = cm
		ring.material_override = _mat(Color(1.0, 0.55, 0.15), 1.6)
		ring.position = cards[selected_uid].position + Vector3(0, 0.08, 0)
		_pipes.add_child(ring)
	var dot = SphereMesh.new()
	dot.radius = 0.42
	dot.height = 0.84
	dot.radial_segments = 10
	dot.rings = 5
	var dm = StandardMaterial3D.new()
	dm.vertex_color_use_as_albedo = true
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot.material = dm
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = dot
	mm.instance_count = _flows.size()
	_dots = MultiMeshInstance3D.new()
	_dots.multimesh = mm
	_dots.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pipes.add_child(_dots)
	for i in _flows.size():
		mm.set_instance_color(i, _flows[i][3].lightened(0.35))
	_move_dots()

static func _cyl(top: float, bottom: float) -> CylinderMesh:
	var c = CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = 1.0
	c.radial_segments = 8
	c.rings = 1
	return c

func _multimesh(mesh: Mesh, material: Material, transforms: Array) -> void:
	if transforms.is_empty():
		return
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var view = MultiMeshInstance3D.new()
	view.multimesh = mm
	view.material_override = material
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pipes.add_child(view)

func _move_dots() -> void:
	if _dots == null or not is_instance_valid(_dots):
		return
	var mm = _dots.multimesh
	for i in _flows.size():
		var f = _flows[i]
		var t = fmod(f[1] + _t * f[2], 1.0)
		var pts: Array = f[0]
		var at = t * (pts.size() - 1)
		var k = mini(int(at), pts.size() - 2)
		var p: Vector3 = pts[k].lerp(pts[k + 1], at - k)
		mm.set_instance_transform(i, Transform3D(Basis(), p))

func _process(delta: float) -> void:
	_t += delta
	if not _flows.is_empty():
		_move_dots()
