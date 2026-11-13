extends Node3D
# Turns cluster state into the factory: platforms (nodes), machines (pods),
# service depots and the conveyor belts that link services to their pods.

signal event(msg, kind)

const K = preload("res://scripts/kutil.gd")
const Tex = preload("res://scripts/tex.gd")
const Platform = preload("res://scripts/platform.gd")
const Machine = preload("res://scripts/machine.gd")

const FRONT_Z = -46.0
const YARD_Z = -22.0
const GAP = 14.0
const PER_ROW = 6

var ns_filter = ""
var show_belts = true

var platforms = {}
var machines = {}
var _depots = {}
var _depot_sig = ""
var _belt_sig = ""
var _paths = []
var _belt_mm: MultiMeshInstance3D
var _item_mm: MultiMeshInstance3D
var _item_spacing = 4.0
var _hub_label: Label3D
var _hologram: Node3D
var _log_label: Label3D
var _uplink_label: Label3D
var _uplink_mat: StandardMaterial3D
var _gates = []
var player = null
var sun: DirectionalLight3D = null
var _npc: Node3D
var _avatars = {}   # peer id -> {node, target, label, body}
var _npc_body: Node3D
var _npc_hook: Node3D
var _select: Node3D
var _select_mat: StandardMaterial3D
var _select_size = Vector3.ZERO
var _first = true
var _source = ""
var _t = 0.0

func _ready() -> void:
	_build_ground()
	_build_hub()
	_build_log_station()
	_build_npc()
	_belt_mm = _make_mm(Vector3.ONE, Tex.mat(Color.WHITE, 0.6, 0.4))
	_item_mm = _make_mm(Vector3(0.5, 0.5, 0.5), Tex.mat(Color.WHITE, 0.5, 0.1))
	_build_hologram()
	# Selection outline: 12 thin glowing edges fitted around the target
	_select = Node3D.new()
	_select_mat = Tex.glow(Tex.ORANGE, 2.0)
	_select_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var unit = BoxMesh.new()
	for i in 12:
		var e = MeshInstance3D.new()
		e.mesh = unit
		e.material_override = _select_mat
		e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_select.add_child(e)
	_select.visible = false
	add_child(_select)

func _make_mm(size: Vector3, material: StandardMaterial3D) -> MultiMeshInstance3D:
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var b = BoxMesh.new()
	b.size = size
	material.vertex_color_use_as_albedo = true
	b.material = material
	mm.mesh = b
	var mi = MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.custom_aabb = AABB(Vector3(-2000, -10, -2000), Vector3(4000, 200, 4000))
	add_child(mi)
	return mi

func _build_ground() -> void:
	var ground = StaticBody3D.new()
	var cs = CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	ground.add_child(cs)
	add_child(ground)
	var noise = FastNoiseLite.new()
	noise.frequency = 0.02
	var nt = NoiseTexture2D.new()
	nt.noise = noise
	nt.seamless = true
	nt.width = 256
	nt.height = 256
	var grad = Gradient.new()
	grad.set_color(0, Color(0.20, 0.36, 0.14))
	grad.set_color(1, Color(0.42, 0.55, 0.22))
	nt.color_ramp = grad
	var gm = Tex.mat(Color.WHITE, 0.95, 0.0, nt, 0.02)
	var mi = MeshInstance3D.new()
	var pm = PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	mi.mesh = pm
	mi.material_override = gm
	add_child(mi)
	# Factory yard: a compacted dirt apron under the whole build area
	var apron = MeshInstance3D.new()
	var am = PlaneMesh.new()
	am.size = Vector2(520, 420)
	apron.mesh = am
	var an = FastNoiseLite.new()
	an.frequency = 0.035
	an.fractal_octaves = 4
	var at = NoiseTexture2D.new()
	at.noise = an
	at.seamless = true
	at.width = 512
	at.height = 512
	var ag = Gradient.new()
	ag.set_color(0, Color(0.27, 0.25, 0.22))
	ag.set_color(1, Color(0.47, 0.43, 0.36))
	at.color_ramp = ag
	apron.material_override = Tex.mat(Color.WHITE, 0.95, 0.0, at, 0.03)
	apron.position = Vector3(0, 0.02, -150)
	add_child(apron)
	# Scenery: trees, rocks and distant hills
	var rng = RandomNumberGenerator.new()
	rng.seed = 77
	var trunk = CylinderMesh.new()
	trunk.top_radius = 0.25
	trunk.bottom_radius = 0.4
	trunk.height = 5.0
	trunk.material = Tex.mat(Color(0.3, 0.2, 0.12), 0.9)
	var crown = SphereMesh.new()
	crown.radius = 2.6
	crown.height = 5.5
	crown.radial_segments = 8
	crown.rings = 5
	crown.material = Tex.mat(Color(0.16, 0.38, 0.16), 0.9)
	var rock = SphereMesh.new()
	rock.radius = 1.0
	rock.height = 1.4
	rock.radial_segments = 6
	rock.rings = 3
	rock.material = Tex.mat(Color(0.42, 0.42, 0.44), 0.95)
	var spots = []
	while spots.size() < 420:
		var p = Vector3(rng.randf_range(-700, 700), 0, rng.randf_range(-800, 420))
		if absf(p.x) < 270 and p.z > -370 and p.z < 70:
			continue
		spots.append(p)
	for pair in [[trunk, 2.5, 0], [crown, 6.2, 0], [rock, 0.3, 1]]:
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pair[0]
		var n = 300 if pair[2] == 0 else 120
		mm.instance_count = n
		for i in n:
			var p = spots[i] if pair[2] == 0 else spots[300 + i]
			var s = 0.7 + float((i * 37) % 10) / 10.0
			var xf = Transform3D(Basis.from_scale(Vector3(s, s, s) * (1.0 if pair[2] == 0 else 2.2)), p + Vector3(0, pair[1] * s, 0))
			mm.set_instance_transform(i, xf)
		var mmi = MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)
	for i in 14:
		var a = i * TAU / 14.0 + rng.randf() * 0.3
		var hill = MeshInstance3D.new()
		var sm = SphereMesh.new()
		sm.radius = rng.randf_range(220, 420)
		sm.height = rng.randf_range(160, 380)
		sm.radial_segments = 14
		sm.rings = 6
		hill.mesh = sm
		hill.material_override = Tex.mat(Color(0.2, 0.33, 0.2), 1.0)
		hill.position = Vector3(cos(a), 0, sin(a)) * rng.randf_range(1300, 1700) + Vector3(0, -30, -150)
		add_child(hill)

func _box(size: Vector3, material: Material, pos: Vector3, parent: Node3D = self) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var b = BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = material
	mi.position = pos
	parent.add_child(mi)
	return mi

func _solid(size: Vector3, pos: Vector3, meta, parent: Node3D = self) -> StaticBody3D:
	var sb = StaticBody3D.new()
	var cs = CollisionShape3D.new()
	var sh = BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	sb.position = pos
	if meta != null:
		sb.set_meta("kf", meta)
	parent.add_child(sb)
	return sb

func _build_hub() -> void:
	var dark = Tex.shared("dark")
	var pad = MeshInstance3D.new()
	var c = CylinderMesh.new()
	c.top_radius = 7.0
	c.bottom_radius = 7.4
	c.height = 0.3
	c.radial_segments = 32
	pad.mesh = c
	pad.material_override = Tex.shared("foundation")
	pad.position.y = 0.15
	add_child(pad)
	_box(Vector3(9.0, 5.0, 0.5), Tex.shared("board"), Vector3(0, 4.6, 0))
	_box(Vector3(9.4, 0.3, 0.6), Tex.shared("orange"), Vector3(0, 7.25, 0))
	_box(Vector3(9.4, 0.3, 0.6), Tex.shared("orange"), Vector3(0, 1.95, 0))
	for x in [-4.0, 4.0]:
		_box(Vector3(0.5, 2.0, 0.5), dark, Vector3(x, 1.0, 0))
	_solid(Vector3(9.4, 7.4, 0.6), Vector3(0, 3.7, 0), {"type": "hub"})
	_box(Vector3(3.0, 1.1, 1.2), dark, Vector3(0, 0.85, 1.6))
	var scr = _box(Vector3(2.6, 0.9, 0.08), Tex.glow(Tex.ORANGE, 1.6), Vector3(0, 1.55, 1.7))
	scr.rotation.x = -0.6
	_solid(Vector3(3.0, 2.0, 1.4), Vector3(0, 1.0, 1.6), {"type": "hub"})
	var title = Label3D.new()
	title.text = "THE HUB  //  CLUSTER CONTROL"
	title.font_size = 72
	title.pixel_size = 0.01
	title.modulate = Tex.ORANGE
	title.position = Vector3(0, 6.5, 0.27)
	add_child(title)
	_hub_label = Label3D.new()
	_hub_label.font_size = 40
	_hub_label.pixel_size = 0.01
	_hub_label.position = Vector3(0, 4.05, 0.27)
	_hub_label.text = "Connecting..."
	add_child(_hub_label)
	# antenna
	var mast = MeshInstance3D.new()
	var mc = CylinderMesh.new()
	mc.top_radius = 0.08
	mc.bottom_radius = 0.2
	mc.height = 16.0
	mast.mesh = mc
	mast.material_override = Tex.shared("steel")
	mast.position = Vector3(5.6, 8.0, -1.5)
	add_child(mast)
	var tip = MeshInstance3D.new()
	var ts = SphereMesh.new()
	ts.radius = 0.3
	ts.height = 0.6
	tip.mesh = ts
	tip.material_override = Tex.status_glow("bad")
	tip.position = Vector3(5.6, 16.2, -1.5)
	add_child(tip)

# Porter, the Portainer dock worker: a little crane-backed robot beside a
# stack of shipping containers. Talk to him to get complete app setups built.
func _build_npc() -> void:
	var blue = Tex.mat(Color(0.075, 0.745, 0.976), 0.5, 0.2)
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	var yellow = Tex.mat(Color(0.98, 0.8, 0.12), 0.5, 0.1)
	var base = Vector3(10.5, 0, 9.0)
	# the dock: pallet, container stack, sign
	_box(Vector3(6.0, 0.2, 4.0), dark, base + Vector3(2.6, 0.1, -0.6))
	var crates = [[Vector3(1.9, 0.2 + 0.5, -1.2), Color(0.075, 0.745, 0.976)], [Vector3(4.0, 0.7, -1.2), Color(0.95, 0.45, 0.2)],
		[Vector3(3.0, 1.7, -1.2), Color(0.3, 0.8, 0.45)], [Vector3(4.3, 0.7, 0.3), Color(0.85, 0.75, 0.2)]]
	for c in crates:
		_box(Vector3(2.0, 1.0, 1.0), Tex.body(c[1]), base + c[0])
		_box(Vector3(2.04, 0.08, 1.04), dark, base + c[0] + Vector3(0, 0.5, 0))
	_solid(Vector3(4.6, 2.4, 2.6), base + Vector3(3.1, 1.2, -0.6), null)
	_box(Vector3(0.14, 3.4, 0.14), steel, base + Vector3(-1.6, 1.7, -1.4))
	_box(Vector3(3.2, 0.9, 0.1), Tex.shared("board"), base + Vector3(-0.1, 3.0, -1.4))
	var dock_sign = Label3D.new()
	dock_sign.text = "PORTAINER DOCK"
	dock_sign.font_size = 44
	dock_sign.pixel_size = 0.01
	dock_sign.modulate = Color(0.075, 0.745, 0.976)
	dock_sign.position = base + Vector3(-0.1, 3.0, -1.34)
	add_child(dock_sign)
	# the robot
	_npc = Node3D.new()
	_npc.position = base
	add_child(_npc)
	_solid(Vector3(1.4, 2.6, 1.4), Vector3(0, 1.3, 0), {"type": "npc"}, _npc)
	_npc_body = Node3D.new()
	_npc.add_child(_npc_body)
	for lx in [-0.22, 0.22]:
		_box(Vector3(0.24, 0.8, 0.28), dark, Vector3(lx, 0.4, 0), _npc_body)
		_box(Vector3(0.3, 0.14, 0.42), steel, Vector3(lx, 0.07, 0.06), _npc_body)
	_box(Vector3(0.9, 0.95, 0.55), blue, Vector3(0, 1.3, 0), _npc_body)
	_box(Vector3(0.5, 0.3, 0.04), Tex.shared("hazard"), Vector3(0, 1.15, 0.29), _npc_body)
	for ax in [-0.58, 0.58]:
		_box(Vector3(0.2, 0.8, 0.22), blue, Vector3(ax, 1.3, 0), _npc_body)
		_box(Vector3(0.22, 0.2, 0.24), steel, Vector3(ax, 0.82, 0), _npc_body)
	_box(Vector3(0.62, 0.5, 0.52), steel, Vector3(0, 2.05, 0), _npc_body)
	_box(Vector3(0.5, 0.16, 0.04), Tex.glow(Color(0.3, 0.95, 1.0), 2.0), Vector3(0, 2.1, 0.27), _npc_body)
	var hat = MeshInstance3D.new()
	var hm = CylinderMesh.new()
	hm.top_radius = 0.3
	hm.bottom_radius = 0.4
	hm.height = 0.24
	hat.mesh = hm
	hat.material_override = yellow
	hat.position = Vector3(0, 2.42, 0)
	_npc_body.add_child(hat)
	_box(Vector3(0.9, 0.05, 0.95), yellow, Vector3(0, 2.31, 0.08), _npc_body)
	# crane on his back: mast, jib, cable and hook
	_box(Vector3(0.14, 2.3, 0.14), yellow, Vector3(0, 2.0, -0.36), _npc_body)
	_box(Vector3(0.12, 0.12, 1.5), yellow, Vector3(0, 3.1, 0.3), _npc_body)
	_npc_hook = Node3D.new()
	_npc_hook.position = Vector3(0, 3.05, 0.95)
	_npc_body.add_child(_npc_hook)
	_box(Vector3(0.03, 0.6, 0.03), dark, Vector3(0, -0.3, 0), _npc_hook)
	_box(Vector3(0.34, 0.22, 0.22), Tex.body(Color(0.95, 0.45, 0.2)), Vector3(0, -0.7, 0), _npc_hook)
	var tag = Label3D.new()
	tag.text = "PORTER\nPortainer dock  ·  [E] talk"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.pixel_size = 0.0075
	tag.outline_size = 10
	tag.modulate = Color(0.6, 0.92, 1.0)
	tag.position = Vector3(0, 3.9, 0)
	tag.visibility_range_end = 60.0
	_npc.add_child(tag)

# Other players on this cluster, drawn as small robots in their tool's tier colour.
func set_peers(peers: Array, tool_names: Array) -> void:
	var seen = {}
	for p in peers:
		seen[p["id"]] = true
		var parts = str(p["pos"]).split(",")
		if parts.size() < 4:
			continue
		var target = Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
		var tool = clampi(p["tool"], 0, tool_names.size() - 1)
		var col = K.tier_color([1, 1, 2, 3, 4, 5][clampi(tool, 0, 5)])
		if not _avatars.has(p["id"]):
			var n = Node3D.new()
			n.position = target
			add_child(n)
			var body = _box(Vector3(0.8, 0.95, 0.5), Tex.mat(col, 0.5, 0.2), Vector3(0, 1.25, 0), n)
			for lx in [-0.2, 0.2]:
				_box(Vector3(0.24, 0.8, 0.28), Tex.shared("dark"), Vector3(lx, 0.4, 0), n)
			_box(Vector3(0.56, 0.46, 0.5), Tex.shared("steel"), Vector3(0, 1.98, 0), n)
			_box(Vector3(0.44, 0.14, 0.04), Tex.glow(Color(1.0, 0.9, 0.5), 2.0), Vector3(0, 2.02, -0.26), n)
			_box(Vector3(0.12, 0.12, 0.7), Tex.shared("dark"), Vector3(0.5, 1.35, -0.35), n)
			var tag = Label3D.new()
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.font_size = 44
			tag.pixel_size = 0.0075
			tag.outline_size = 10
			tag.no_depth_test = true
			tag.position = Vector3(0, 2.9, 0)
			n.add_child(tag)
			_avatars[p["id"]] = {"node": n, "label": tag, "body": body, "target": target, "yaw": 0.0}
		var a = _avatars[p["id"]]
		a["target"] = target
		a["yaw"] = parts[3].to_float()
		a["body"].material_override = Tex.mat(col, 0.5, 0.2)
		a["label"].text = "%s\n%s%s" % [p["user"], tool_names[tool], ("  ·  " + str(p["doing"]).left(40)) if str(p["doing"]) != "" else ""]
		a["label"].modulate = col.lightened(0.4)
	for id in _avatars.keys():
		if not seen.has(id):
			_avatars[id]["node"].queue_free()
			_avatars.erase(id)

func _build_log_station() -> void:
	var c = Vector3(18.0, 0, -0.5)
	_box(Vector3(8.0, 0.3, 5.0), Tex.shared("dark"), c + Vector3(0, 0.15, 0))
	_box(Vector3(7.2, 4.0, 4.0), Tex.body(Color(0.45, 0.48, 0.52)), c + Vector3(0, 2.3, 0))
	_box(Vector3(7.5, 0.25, 4.3), Tex.shared("orange"), c + Vector3(0, 4.4, 0))
	_box(Vector3(6.4, 3.0, 0.12), Tex.shared("board"), c + Vector3(0, 2.3, 2.04))
	_solid(Vector3(7.4, 4.6, 4.2), c + Vector3(0, 2.3, 0), {"type": "logs"})
	var dish = MeshInstance3D.new()
	var dm = CylinderMesh.new()
	dm.top_radius = 1.3
	dm.bottom_radius = 0.2
	dm.height = 0.6
	dish.mesh = dm
	dish.material_override = Tex.shared("steel")
	dish.position = c + Vector3(2.2, 5.2, -0.5)
	dish.rotation = Vector3(0.5, 0, -0.4)
	add_child(dish)
	var title = Label3D.new()
	title.text = "LOGGING STATION"
	title.font_size = 48
	title.pixel_size = 0.01
	title.modulate = Tex.ORANGE
	title.position = c + Vector3(0, 3.4, 2.12)
	add_child(title)
	# the station's wireless uplink: a light column from the dish, green when
	# the selected log provider answers and red when there is no signal
	_uplink_mat = Tex.ghost(Color(0.3, 1.0, 0.5, 0.25))
	var beam = MeshInstance3D.new()
	var bm = CylinderMesh.new()
	bm.top_radius = 0.05
	bm.bottom_radius = 0.22
	bm.height = 70.0
	bm.radial_segments = 8
	beam.mesh = bm
	beam.material_override = _uplink_mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position = c + Vector3(2.2, 40.5, -0.5)
	add_child(beam)
	_uplink_label = Label3D.new()
	_uplink_label.font_size = 26
	_uplink_label.pixel_size = 0.01
	_uplink_label.position = c + Vector3(0, 0.95, 2.12)
	_uplink_label.text = "UPLINK  Kubernetes API  ·  STANDBY"
	_uplink_label.modulate = Color(0.7, 0.75, 0.8)
	add_child(_uplink_label)
	_log_label = Label3D.new()
	_log_label.font_size = 24
	_log_label.pixel_size = 0.01
	_log_label.position = c + Vector3(0, 2.2, 2.12)
	_log_label.text = "[E] logs, events and audit trail"
	add_child(_log_label)

func set_uplink(provider_name: String, ok: bool) -> void:
	_uplink_label.text = "UPLINK  %s  ·  %s" % [provider_name, "LINKED" if ok else "NO SIGNAL"]
	_uplink_label.modulate = K.health_color("ok" if ok else "bad")
	_uplink_mat.albedo_color = Color(0.3, 1.0, 0.5, 0.25) if ok else Color(1.0, 0.2, 0.15, 0.3)

# One pylon per reachable cluster (kubeconfig contexts, Docker, simulations).
func set_targets(targets: Array, source: String, context: String) -> void:
	for g in _gates:
		g.queue_free()
	_gates.clear()
	if targets.is_empty():
		return
	var head = Label3D.new()
	head.text = "CLUSTER GATES"
	head.font_size = 64
	head.pixel_size = 0.01
	head.modulate = Tex.ORANGE
	head.outline_size = 10
	head.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	head.position = Vector3(-13.0 - (mini(targets.size(), 9) - 1) * 2.75, 9.2, 1.0)
	add_child(head)
	_gates.append(head)
	for i in mini(targets.size(), 9):
		var t = targets[i]
		var active = t["source"] == source and t["context"] == context
		var col = K.provider_color(t["provider"])
		var g = Node3D.new()
		g.position = Vector3(-13.0 - i * 5.5, 0, 1.0)
		add_child(g)
		_gates.append(g)
		_box(Vector3(2.6, 0.4, 2.6), Tex.shared("dark"), Vector3(0, 0.2, 0), g)
		_box(Vector3(1.5, 4.4, 1.5), Tex.body(col), Vector3(0, 2.6, 0), g)
		_box(Vector3(1.8, 0.35, 1.8), Tex.status_glow("ok") if active else Tex.shared("dark"), Vector3(0, 4.95, 0), g)
		_box(Vector3(1.0, 0.7, 0.1), Tex.glow(col, 1.4), Vector3(0, 2.2, 0.78), g)
		_solid(Vector3(2.6, 5.2, 2.6), Vector3(0, 2.6, 0), {"type": "cluster", "index": i}, g)
		var l = Label3D.new()
		var nm = str(t["context"])
		if nm.length() > 26:
			nm = nm.left(12) + "…" + nm.right(13)
		l.text = "%s\n%s\n%s" % [t["provider"], nm, "● ACTIVE" if active else ""]
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 44
		l.pixel_size = 0.01
		l.outline_size = 10
		l.modulate = col.lightened(0.45)
		l.position = Vector3(0, 6.6 + (i % 2) * 1.7, 0)
		l.visibility_range_end = 90.0
		g.add_child(l)

func _build_hologram() -> void:
	_hologram = Node3D.new()
	var m = Tex.ghost(Color(0.3, 0.75, 1.0, 0.3))
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_box(Vector3(5.6, 0.4, 5.6), m, Vector3(0, 0.2, 0), _hologram)
	_box(Vector3(4.4, 3.0, 4.4), m, Vector3(0, 1.9, 0), _hologram)
	_box(Vector3(2.6, 0.8, 2.6), m, Vector3(-0.5, 3.9, 0.3), _hologram)
	_box(Vector3(0.8, 2.4, 0.8), m, Vector3(1.35, 4.6, -1.35), _hologram)
	_hologram.visible = false
	add_child(_hologram)

func show_hologram(pos: Vector3) -> void:
	_hologram.visible = true
	_hologram.position = Vector3(snappedf(pos.x, 4.0), Platform.HEIGHT, snappedf(pos.z, 4.0))

func hide_hologram() -> void:
	_hologram.visible = false

# Highlight whatever the player is aiming at (collider must own a BoxShape3D).
func select(collider, col: Color = Color(0.98, 0.584, 0.286)) -> void:
	if collider == null or not is_instance_valid(collider) or collider.get_child_count() == 0:
		_select.visible = false
		return
	var cs = collider.get_child(0)
	if not (cs is CollisionShape3D) or not (cs.shape is BoxShape3D):
		_select.visible = false
		return
	_select.visible = true
	_select.global_position = cs.global_position
	_select.global_rotation = cs.global_rotation
	_select_mat.albedo_color = col
	_select_mat.emission = col
	var size = cs.shape.size + Vector3.ONE * 0.2
	if size != _select_size:
		_select_size = size
		var t = 0.07
		var i = 0
		for axis in 3:
			var b = (axis + 1) % 3
			var c = (axis + 2) % 3
			for sb in [-0.5, 0.5]:
				for sc in [-0.5, 0.5]:
					var e = _select.get_child(i)
					var sv = Vector3(t, t, t)
					sv[axis] = size[axis] + t
					var pv = Vector3.ZERO
					pv[b] = size[b] * sb
					pv[c] = size[c] * sc
					e.scale = sv
					e.position = pv
					i += 1

func _node_rank(n: Dictionary) -> String:
	return ("0" if str(n["roles"]).contains("control-plane") or str(n["roles"]).contains("master") else "1") + n["name"]

func apply_state(st: Dictionary) -> void:
	var quiet = _first or (st["source"] + "|" + st["context"]) != _source
	_first = false
	_source = st["source"] + "|" + st["context"]
	var nodes = st["nodes"].duplicate()
	nodes.sort_custom(func(a, b): return _node_rank(a) < _node_rank(b))
	var pods = []
	var need_yard = false
	for p in st["pods"]:
		if ns_filter != "" and p["ns"] != ns_filter:
			continue
		pods.append(p)
		if p["node"] == "":
			need_yard = true
	# --- platforms
	var order = []
	var info = {}
	for n in nodes:
		order.append(n["name"])
		info[n["name"]] = n
	if need_yard:
		order.append("")
		info[""] = null
	for nm in platforms.keys():
		if not order.has(nm):
			for m in machines.values():
				if m.get_parent() == platforms[nm]:
					machines.erase(m.uid)
			platforms[nm].queue_free()
			platforms.erase(nm)
			if not quiet and nm != "":
				event.emit("Node %s left the cluster" % nm, "bad")
	for nm in order:
		if not platforms.has(nm):
			var pf = Platform.new()
			add_child(pf)
			pf.setup(nm if nm != "" else "UNSCHEDULED")
			pf.node_name = nm
			platforms[nm] = pf
			if not quiet and nm != "":
				event.emit("Node %s joined the cluster" % nm, "ok")
		platforms[nm].update(info[nm])
	# --- machines
	var seen = {}
	for p in pods:
		seen[p["uid"]] = true
		var pf = platforms.get(p["node"])
		if pf == null:
			continue
		var m = machines.get(p["uid"])
		if m != null and m.get_parent() != pf:
			m.get_parent().free_slot(m.slot)
			m.queue_free()
			machines.erase(p["uid"])
			m = null
		if m == null:
			m = Machine.new()
			pf.add_child(m)
			m.slot = pf.take_slot(p["uid"])
			m.position = pf.slot_pos(m.slot)
			m.setup(p)
			machines[p["uid"]] = m
			if not quiet:
				event.emit("Built %s" % p["name"], "info")
		else:
			var was = m.pod["health"]
			m.update(p)
			if not quiet and was != "bad" and p["health"] == "bad":
				event.emit("%s: %s" % [p["name"], p["status"]], "bad")
	for id in machines.keys():
		if not seen.has(id):
			var m = machines[id]
			m.get_parent().free_slot(m.slot)
			if not quiet:
				event.emit("Dismantled %s" % m.pod["name"], "warn")
			m.dismantle()
			machines.erase(id)
	# --- layout
	var row_z = FRONT_Z
	var i = 0
	while i < order.size():
		var row = order.slice(i, i + PER_ROW)
		var max_depth = 0.0
		for j in row.size():
			var pf = platforms[row[j]]
			pf.set_rows(pf.used_rows())
			pf.position = Vector3((j - (row.size() - 1) / 2.0) * (Platform.WIDTH + GAP), 0, row_z)
			max_depth = maxf(max_depth, pf.depth)
		row_z -= max_depth + 34.0
		i += PER_ROW
	if sun != null and OS.has_feature("web"):
		# shortcut: the browser build drops sun shadows on big factories to stay under
		# WebGL's ~4096 elements per frame; merge machine parts into one mesh to lift it
		sun.shadow_enabled = machines.size() < 45
	_update_services(st, pods)
	_update_hub(st)

func _update_hub(st: Dictionary) -> void:
	var ready = 0
	for n in st["nodes"]:
		if n["ready"]:
			ready += 1
	var c = {"ok": 0, "warn": 0, "bad": 0, "done": 0}
	for p in st["pods"]:
		c[p["health"]] += 1
	var bad = []
	for p in st["pods"]:
		if p["health"] == "bad" and bad.size() < 5:
			bad.append("%s  -  %s" % [p["name"].left(34), p["status"]])
	if bad.is_empty():
		_log_label.text = "ALL SYSTEMS NOMINAL\n\n[E] logs, events and audit trail"
	else:
		_log_label.text = "ACTIVE ALERTS\n" + "\n".join(PackedStringArray(bad)) + "\n[E] open"
	_log_label.modulate = K.health_color("ok") if bad.is_empty() else Color(1.0, 0.45, 0.38)
	_hub_label.text = "%s  ·  %s\n\nNODES  %d / %d ready\nPODS   %d running  ·  %d pending  ·  %d failing\nWORKLOADS  %d   ·   SERVICES  %d\n\n[E]  open the cluster codex" % [
		str(st.get("provider", st["source"])).to_upper() if str(st.get("provider", "")) != "" else str(st["source"]).to_upper(), st["context"], ready, st["nodes"].size(),
		c["ok"], c["warn"], c["bad"], st["workloads"].size(), st["services"].size()]

func _update_services(st: Dictionary, pods: Array) -> void:
	var svcs = []
	for s in st["services"]:
		if ns_filter == "" or s["ns"] == ns_filter:
			svcs.append(s)
	svcs.sort_custom(func(a, b): return a["ns"] + "/" + a["name"] < b["ns"] + "/" + b["name"])
	var sig = ""
	for s in svcs:
		sig += s["ns"] + "/" + s["name"] + "|" + s["type"] + "|" + s["ports"] + ";"
	if sig != _depot_sig:
		_depot_sig = sig
		for d in _depots.values():
			d.queue_free()
		_depots.clear()
		for i in svcs.size():
			var s = svcs[i]
			var d = Node3D.new()
			d.position = Vector3((i - (svcs.size() - 1) / 2.0) * 7.5, 0, YARD_Z)
			add_child(d)
			var col = K.hue_color("svc:" + s["ns"] + "/" + s["name"], 0.6, 0.85)
			_box(Vector3(3.6, 0.3, 3.6), Tex.shared("dark"), Vector3(0, 0.15, 0), d)
			_box(Vector3(3.0, 2.6, 3.0), Tex.body(col), Vector3(0, 1.6, 0), d)
			_box(Vector3(3.2, 0.25, 3.2), Tex.shared("dark"), Vector3(0, 3.0, 0), d)
			_box(Vector3(2.4, 1.3, 0.1), Tex.shared("board"), Vector3(0, 1.8, 1.52), d)
			_solid(Vector3(3.6, 3.2, 3.6), Vector3(0, 1.6, 0), {"type": "service", "ns": s["ns"], "name": s["name"]}, d)
			var l = Label3D.new()
			l.text = "%s\n%s\n%s" % [s["name"], s["type"], s["ports"]]
			l.font_size = 30
			l.pixel_size = 0.008
			l.line_spacing = -4
			l.position = Vector3(0, 1.8, 1.59)
			d.add_child(l)
			var tag = Label3D.new()
			tag.text = s["ns"] + " / " + s["name"]
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.font_size = 36
			tag.pixel_size = 0.0075
			tag.outline_size = 8
			tag.modulate = col.lightened(0.4)
			tag.position = Vector3(0, 4.0, 0)
			tag.visibility_range_end = 70.0
			d.add_child(tag)
			_depots[s["ns"] + "/" + s["name"]] = d
	# Belt routes: depot -> lift -> trunk -> drop onto every selected machine
	var paths = []
	var bsig = "" if show_belts else "off"
	if show_belts:
		for i in svcs.size():
			var s = svcs[i]
			var d = _depots[s["ns"] + "/" + s["name"]]
			var h = 12.0 + (i % 6) * 0.75
			var lz = YARD_Z - 3.0 - (i % 6) * 1.0
			var col = K.hue_color("svc:" + s["ns"] + "/" + s["name"], 0.6, 0.85)
			for p in pods:
				if p["ns"] != s["ns"] or not K.selects(s["selector"], p["labels"]):
					continue
				var m = machines.get(p["uid"])
				if m == null:
					continue
				var mp = m.get_parent().position + m.position + Vector3(-0.5, 0, 0.3)
				var sx = d.position.x
				var pts = [Vector3(sx, 3.1, YARD_Z), Vector3(sx, h, YARD_Z), Vector3(sx, h, lz),
					Vector3(mp.x, h, lz), Vector3(mp.x, h, mp.z), Vector3(mp.x, mp.y + 4.3, mp.z)]
				paths.append({"pts": pts, "color": col})
				bsig += str(pts[0]) + str(pts[4]) + str(h)
	if bsig != _belt_sig:
		_belt_sig = bsig
		_rebuild_belts(paths)

func _rebuild_belts(paths: Array) -> void:
	_paths = paths
	var segs = {}
	var total = 0.0
	for path in paths:
		var pts = path["pts"]
		var cum = [0.0]
		for i in range(1, pts.size()):
			var a = pts[i - 1]
			var b = pts[i]
			cum.append(cum[i - 1] + a.distance_to(b))
			if a.distance_to(b) < 0.01:
				continue
			var key = str(a) + str(b)
			if not segs.has(key):
				segs[key] = [a, b, path["color"]]
		path["cum"] = cum
		total += cum[cum.size() - 1]
	var mm = _belt_mm.multimesh
	mm.instance_count = segs.size()
	var i = 0
	for sg in segs.values():
		var a: Vector3 = sg[0]
		var b: Vector3 = sg[1]
		var d = (b - a).abs()
		var vertical = d.y > 0.01
		var w = 0.45 if vertical else 0.9
		var size = Vector3(maxf(d.x + w, w), maxf(d.y, 0.14), maxf(d.z + w, w))
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(size), (a + b) / 2.0))
		mm.set_instance_color(i, sg[2].darkened(0.55))
		i += 1
	_item_spacing = maxf(4.0, total / 2500.0)
	var count = 0
	for path in paths:
		path["first"] = count
		path["n"] = int(path["cum"][path["cum"].size() - 1] / _item_spacing)
		count += path["n"]
	_item_mm.multimesh.instance_count = count
	for path in paths:
		for k in path["n"]:
			_item_mm.multimesh.set_instance_color(path["first"] + k, path["color"])

func _process(delta: float) -> void:
	_t += delta
	for a in _avatars.values():
		a["node"].position = a["node"].position.lerp(a["target"], clampf(delta * 3.0, 0.0, 1.0))
		a["node"].rotation.y = lerp_angle(a["node"].rotation.y, a["yaw"], clampf(delta * 5.0, 0.0, 1.0))
	# Porter idles: bobs, sways his hook, and turns to face you when you are near
	_npc_body.position.y = sin(_t * 2.0) * 0.03
	_npc_hook.rotation.x = sin(_t * 1.7) * 0.25
	if player != null:
		var d = player.global_position - _npc.global_position
		var want = atan2(d.x, d.z) if d.length() < 30.0 else 0.0
		_npc.rotation.y = lerp_angle(_npc.rotation.y, want, clampf(delta * 4.0, 0.0, 1.0))
	var mm = _item_mm.multimesh
	var off = fmod(_t * 3.0, _item_spacing)
	for path in _paths:
		var pts = path["pts"]
		var cum = path["cum"]
		var seg = 1
		for k in path["n"]:
			var dist = off + k * _item_spacing
			while seg < cum.size() - 1 and cum[seg] < dist:
				seg += 1
			var f = (dist - cum[seg - 1]) / maxf(cum[seg] - cum[seg - 1], 0.001)
			var pos = pts[seg - 1].lerp(pts[seg], clampf(f, 0.0, 1.0)) + Vector3(0, 0.33, 0)
			mm.set_instance_transform(path["first"] + k, Transform3D(Basis.IDENTITY, pos))

# Where to stand (in the aisle beside it) and where to look, as [pos, look_at].
func workload_spot(ns: String, kind: String, wname: String) -> Variant:
	for m in machines.values():
		if m.pod["ns"] == ns and m.pod["wkind"] == kind and m.pod["wname"] == wname:
			return machine_spot(m.uid)
	return null

func machine_spot(uid: String) -> Variant:
	var m = machines.get(uid)
	if m == null:
		return null
	var c = m.get_parent().position + m.position
	return [c + Vector3(4.0, 0.2, 4.0), c + Vector3(0, 2.6, 0)]
