extends Node3D
# Turns cluster state into the factory: platforms (nodes), machines (pods),
# service depots and the conveyor belts that link services to their pods.

signal event(msg, kind)

const K = preload("res://scripts/kutil.gd")
const Tex = preload("res://scripts/tex.gd")
const Platform = preload("res://scripts/platform.gd")
const Machine = preload("res://scripts/machine.gd")
const Gfx = preload("res://scripts/gfx.gd")
const Controls = preload("res://scripts/controls.gd")
const Scenery = preload("res://scripts/scenery.gd")
const Models = preload("res://scripts/models.gd")
const Topology = preload("res://scripts/demo_topology.gd")
const MediaLab = preload("res://scripts/demo_media_lab.gd")
const Pipes = preload("res://scripts/pipes.gd")
const LabConnections = preload("res://scripts/lab_connections.gd")
const PlanBlocks = preload("res://scripts/plan_blocks.gd")
const BuildPlan = preload("res://scripts/build_plan.gd")

const FRONT_Z = -46.0
const YARD_Z = -22.0
const GAP = 14.0
const PER_ROW = 6

const GROUND_SHADER = """
shader_type spatial;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D bump_tex : hint_normal, repeat_enable, filter_linear_mipmap;
// set from script: the engine's colour conversion is right on both renderers,
// a hand-rolled gamma decode here is not (it double-darkens on OpenGL)
uniform vec3 grass_dark : source_color;
uniform vec3 grass_light : source_color;
uniform vec3 dirt_dark : source_color;
uniform vec3 dirt_light : source_color;
varying vec2 wp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float broad = texture(noise_tex, wp * 0.0037).r;
	float mid = texture(noise_tex, wp * 0.031).r;
	float fine = texture(noise_tex, wp * 0.23).r;
	float grain = texture(noise_tex, wp * 1.9).r;
	// the yard: a rounded box around the build area, its edge broken up by noise
	vec2 d = abs(wp - vec2(0.0, -150.0)) - vec2(235.0, 185.0);
	float sd = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
	sd += (mid - 0.5) * 44.0 + (fine - 0.5) * 12.0;
	float yard = 1.0 - smoothstep(-7.0, 7.0, sd);
	vec3 grass = mix(grass_dark, grass_light, broad * 0.55 + mid * 0.45);
	grass *= 0.75 + 0.5 * fine + 0.4 * (grain - 0.5);
	vec3 dirt = mix(dirt_dark, dirt_light, broad * 0.35 + mid * 0.35 + fine * 0.3);
	dirt *= 0.7 + 0.6 * grain;
	ALBEDO = mix(grass, dirt, yard);
	ROUGHNESS = 0.95;
	NORMAL_MAP = texture(bump_tex, wp * 0.45).rgb;
	NORMAL_MAP_DEPTH = mix(0.5, 0.9, yard);
}
"""

var ns_filter = ""
var show_belts = true

var platforms = {}
var machines = {}
var lab_fixtures = {}
var lab_trace = []
var _lab_storage_mesh: ArrayMesh
var _lab_board: Node3D
var _build_blocks: Node3D
var _depots = {}
var _depot_sig = ""
var _belt_sig = ""
var _paths = []
var _belt_mm: MultiMeshInstance3D
var _item_mm: MultiMeshInstance3D
var _item_spacing = 4.0
var _pipes: Node3D = null       # the library's pipe kit, when the library is in use
var _pipe_mode = false          # belts drawn as pipes (flow collars ride them) or as code-drawn tracks
var _item_ring: Mesh
var pipe_filter = "All"
var vpn_selection = {}  # gateway UIDs to trace; empty shows every gateway
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
var _bob: Node3D
var _bob_body: Node3D
var _bob_head: Node3D
var _bob_wrench: Node3D
var _bob_label: Label3D
var _bob_tag: Label3D
var _bob_say_t = 0.0      # seconds until his next remark
var _bob_near = false
var _bob_jobs = 0
var _gauge: Node3D
var _krew_tags = {}       # worker id -> its Label3D
var _krew_lamps = {}      # worker id -> its status lamp
var _select: Node3D
var _select_mat: StandardMaterial3D
var _select_size = Vector3.ZERO
var _first = true
var _source = ""
var _t = 0.0
var _scenery: Node3D = null

func _ready() -> void:
	_build_ground()
	_build_hub()
	_build_log_station()
	_build_npc()
	_build_bob()
	_build_gauge()
	_build_krew_stations()
	var saved = K.load_settings()
	Machine.look = "blocks" if saved.get("workload_look", "machines") == "blocks" else "machines"
	Machine.role_overrides = saved.get("role_overrides", {}) if saved.get("role_overrides") is Dictionary else {}
	if saved.get("show_build_plan",false) and saved.get("flowchart") is Dictionary:
		show_build_plan(BuildPlan.migrate(saved["flowchart"]))
	_belt_mm = _make_mm(Vector3.ONE, Tex.mat(Color.WHITE, 0.6, 0.4))
	_item_mm = _make_mm(Vector3(0.5, 0.5, 0.5), Tex.mat(Color.WHITE, 0.5, 0.1))
	# on pipes, what flows is a glowing collar sliding along the tube
	var ring = CylinderMesh.new()
	ring.top_radius = 0.125
	ring.bottom_radius = 0.125
	ring.height = 0.12
	ring.radial_segments = 16
	ring.rings = 1
	var rm = StandardMaterial3D.new()       # unshaded: the Service's colour at full strength, like a lit band
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.vertex_color_use_as_albedo = true
	ring.material = rm
	_item_ring = ring
	_build_hologram()
	# Selection outline: 12 thin glowing edges fitted around the target
	_select = Node3D.new()
	_select_mat = Tex.glow(Tex.ORANGE, 2.0)
	_select_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var unit = BoxMesh.new()
	for i in 24:      # corner brackets: a short stub at each end of each of the 12 edges
		var e = MeshInstance3D.new()
		e.mesh = unit
		e.material_override = _select_mat
		e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_select.add_child(e)
	_select.visible = false
	add_child(_select)
	_rebuild_scenery()
	if not Gfx.lite():
		# big flat boards hide what is behind them from the renderer
		for o in [[Vector3(9.0, 5.0, 0.3), Vector3(0, 4.6, 0)], [Vector3(7.2, 4.0, 4.0), Vector3(18.0, 2.3, -0.5)]]:
			var occ = OccluderInstance3D.new()
			var bo = BoxOccluder3D.new()
			bo.size = o[0]
			occ.occluder = bo
			occ.position = o[1]
			add_child(occ)

# The preset's decorative layer (see scenery.gd): nothing on Standard.
func _rebuild_scenery() -> void:
	if _scenery != null:
		_scenery.queue_free()
		_scenery = null
	if Gfx.detail() > 0:
		_scenery = Scenery.build(Gfx.detail())
		add_child(_scenery)

# The graphics preset changed: restyle the shared materials, swap the scenery
# layer, and rebuild platforms and machines at the new detail level. The
# cluster state, the selection and every panel are untouched.
func rebuild_graphics(st: Dictionary) -> void:
	Tex.apply_detail()
	_rebuild_scenery()
	for m in machines.values():
		m.queue_free()
	machines.clear()
	for pf in platforms.values():
		pf.queue_free()
	platforms.clear()
	_belt_sig = ""
	if _pipes != null:              # the kit's tier follows the preset
		_pipes.queue_free()
		_pipes = null
	_first = true
	if not st.is_empty() and st.has("nodes"):
		apply_state(st)

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
	# One ground plane: grass that wears down into the packed-gravel factory yard
	# under the build area, with a ragged noise-broken edge instead of a hard seam.
	var noise = FastNoiseLite.new()
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var ni = noise.get_seamless_image(256, 256)
	ni.convert(Image.FORMAT_RGBA8)
	ni.generate_mipmaps()
	var nt = ImageTexture.create_from_image(ni)
	var bump = FastNoiseLite.new()
	bump.seed = 3
	bump.frequency = 0.06
	bump.fractal_octaves = 4
	var bt = Tex.normal_from(bump.get_seamless_image(256, 256), 5.0)
	var gsh = Shader.new()
	gsh.code = GROUND_SHADER
	var gm = ShaderMaterial.new()
	gm.shader = gsh
	gm.set_shader_parameter("noise_tex", nt)
	gm.set_shader_parameter("bump_tex", bt)
	gm.set_shader_parameter("grass_dark", Color(0.17, 0.31, 0.11))
	gm.set_shader_parameter("grass_light", Color(0.41, 0.54, 0.21))
	gm.set_shader_parameter("dirt_dark", Color(0.27, 0.245, 0.21))
	gm.set_shader_parameter("dirt_light", Color(0.47, 0.43, 0.36))
	var mi = MeshInstance3D.new()
	var pm = PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	mi.mesh = pm
	mi.material_override = gm
	add_child(mi)
	# Scenery: a mixed wood of conifers and broadleaf trees, boulders, distant hills
	var rng = RandomNumberGenerator.new()
	rng.seed = 77
	var spots = []
	while spots.size() < 420:
		var p = Vector3(rng.randf_range(-700, 700), 0, rng.randf_range(-800, 420))
		if absf(p.x) < 270 and p.z > -370 and p.z < 70:
			continue
		spots.append(p)
	var trunk = CylinderMesh.new()   # unit meshes, sized per instance
	trunk.top_radius = 0.25
	trunk.bottom_radius = 0.42
	trunk.height = 1.0
	trunk.radial_segments = 7
	trunk.rings = 1
	trunk.material = _tint_mat(0.9)
	var cone = CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 7
	cone.rings = 1
	cone.material = _tint_mat(0.9)
	var blob = SphereMesh.new()
	blob.radius = 1.0
	blob.height = 2.0
	blob.radial_segments = 8
	blob.rings = 5
	blob.material = _tint_mat(0.9)
	var rock = SphereMesh.new()
	rock.radius = 1.0
	rock.height = 2.0
	rock.radial_segments = 6
	rock.rings = 3
	rock.material = _tint_mat(0.95)
	var sets = {"trunk": [trunk, [], []], "cone": [cone, [], []], "blob": [blob, [], []], "rock": [rock, [], []]}
	for i in 300:
		var p = spots[i]
		var s = rng.randf_range(0.7, 1.7)
		var rot = Basis(Vector3.UP, rng.randf() * TAU)
		var bark = Color(0.3, 0.2, 0.12).lerp(Color(0.42, 0.33, 0.24), rng.randf())
		if rng.randf() < 0.55:
			var green = Color(0.09, 0.25, 0.13).lerp(Color(0.2, 0.4, 0.19), rng.randf())
			_place(sets["trunk"], rot, Vector3(s, 2.6 * s, s), p + Vector3(0, 1.3 * s, 0), bark)
			var tiers = [[2.5, 3.4, 1.7], [1.95, 3.0, 3.5], [1.35, 2.8, 5.2]]   # radius, height, base
			for k in 3:
				var t = tiers[k]
				_place(sets["cone"], rot, Vector3(t[0], t[1], t[0]) * s, p + Vector3(0, (t[2] + t[1] / 2.0) * s, 0), green.lightened(0.07 * k))
		else:
			var green = Color(0.16, 0.36, 0.13).lerp(Color(0.36, 0.5, 0.17), rng.randf())
			_place(sets["trunk"], rot, Vector3(s * 1.2, 4.4 * s, s * 1.2), p + Vector3(0, 2.2 * s, 0), bark)
			_place(sets["blob"], rot, Vector3(2.7, 2.3, 2.7) * s, p + Vector3(0, 6.0 * s, 0), green)
			for k in 2:
				var a = rng.randf() * TAU
				var r = rng.randf_range(1.5, 2.0)
				var off = Vector3(cos(a) * 1.6, rng.randf_range(-1.0, 1.3), sin(a) * 1.6)
				_place(sets["blob"], rot, Vector3(r, r * 0.85, r) * s, p + (Vector3(0, 6.0, 0) + off) * s, green.lightened(0.1 * k - 0.04))
	for i in 120:
		var s = rng.randf_range(1.2, 3.4)
		var rot = Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3)))
		var size = Vector3(s, s * rng.randf_range(0.45, 0.8), s * rng.randf_range(0.7, 1.2))
		_place(sets["rock"], rot, size, spots[300 + i] + Vector3(0, size.y * 0.25, 0), Color(0.36, 0.36, 0.38).lerp(Color(0.52, 0.5, 0.47), rng.randf()))
	for st in sets.values():
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = st[0]
		mm.instance_count = st[1].size()
		for i in st[1].size():
			mm.set_instance_transform(i, st[1][i])
			mm.set_instance_color(i, st[2][i])
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
		hill.material_override = Tex.mat(Color(0.17, 0.3, 0.19).lerp(Color(0.27, 0.38, 0.2), rng.randf()), 1.0)
		hill.position = Vector3(cos(a), 0, sin(a)) * rng.randf_range(1300, 1700) + Vector3(0, -30, -150)
		add_child(hill)

func _tint_mat(rough: float) -> StandardMaterial3D:
	var m = Tex.mat(Color.WHITE, rough)
	m.vertex_color_use_as_albedo = true
	return m

func _place(st: Array, rot: Basis, size: Vector3, pos: Vector3, col: Color) -> void:
	st[1].append(Transform3D(rot * Basis.from_scale(size), pos))
	st[2].append(col)

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
	K.fit_label(title, 8.5, 0.85)
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

# A Krew member from the model library, standing in `body`. Returns the node the
# hand-built figure goes under: `body` itself when there is no model (the web
# build, or a copy without assets), otherwise a hidden holder, so the parts the
# idle animation moves still exist.
func _krew(id: String, body: Node3D, height: float) -> Node3D:
	var m = Models.instance(id)
	if m == null:
		return body
	var b: AABB = m.get_meta("bounds")
	var s = height / maxf(b.size.y, 0.01)
	m.scale = Vector3.ONE * s
	m.position = Vector3(-b.get_center().x * s, -b.position.y * s, -b.get_center().z * s)
	body.add_child(m)
	var holder = Node3D.new()
	holder.visible = false
	body.add_child(holder)
	return holder
# Gauge's resource desk keeps observation separate from infrastructure actions.
func _build_gauge() -> void:
	_gauge = Node3D.new()
	_gauge.position = Vector3(24, 0, 9)
	add_child(_gauge)
	var dark = Tex.shared("dark")
	var cyan = Tex.mat(Color(0.16, 0.75, 0.8), 0.5, 0.2)
	_box(Vector3(5.4, 0.2, 3.0), dark, Vector3(1.8, 0.1, -0.5), _gauge)
	_box(Vector3(3.3, 2.0, 0.15), Tex.shared("board"), Vector3(2.8, 2.2, -1.2), _gauge)
	for x in [1.35, 4.25]:
		_box(Vector3(0.14, 2.8, 0.14), Tex.shared("steel"), Vector3(x, 1.4, -1.2), _gauge)
	var label = Label3D.new()
	label.text = "GAUGE\nRESOURCE DESK"
	label.font_size = 44
	label.modulate = Color(0.4, 0.95, 1.0)
	label.position = Vector3(2.8, 2.2, -1.1)
	K.fit_label(label, 3.0, 1.5)
	_gauge.add_child(label)
	_solid(Vector3(3.6, 2.8, 0.4), Vector3(2.8, 1.4, -1.2), {"type": "gauge"}, _gauge)
	_solid(Vector3(1.4, 2.6, 1.4), Vector3(0, 1.3, 0), {"type": "gauge"}, _gauge)
	var figure = Node3D.new()
	_gauge.add_child(figure)
	var fallback = _krew("gauge", figure, 2.6)
	_box(Vector3(0.9, 1.2, 0.6), cyan, Vector3(0, 1.25, 0), fallback)
	_box(Vector3(0.68, 0.58, 0.55), Tex.shared("steel"), Vector3(0, 2.1, 0), fallback)
	_box(Vector3(0.52, 0.2, 0.05), Tex.glow(Color(0.3, 0.95, 1.0), 1.5), Vector3(0, 2.1, 0.3), fallback)
	for x in [-0.28, 0.28]:
		_box(Vector3(0.25, 0.65, 0.3), dark, Vector3(x, 0.33, 0), fallback)
	var tag = Label3D.new()
	tag.text = "GAUGE\n[E] resource desk"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.pixel_size = 0.0055
	tag.outline_size = 10
	tag.modulate = Color(0.6, 0.95, 1.0)
	tag.position = Vector3(0, 3.4, 0)
	tag.visibility_range_end = 60.0
	_gauge.add_child(tag)

# Sentinel, Scout and Scrappy: each at a small station with a status lamp.
const KREW_STATIONS = [
	["sentinel", "SENTINEL", "security", Color(0.36, 0.6, 1.0), Vector3(32.5, 0, 9)],
	["scout", "SCOUT", "network", Color(0.4, 0.9, 0.5), Vector3(37.5, 0, 9)],
	["scrappy", "SCRAPPY", "cleanup", Color(1.0, 0.85, 0.25), Vector3(42.5, 0, 9)],
	["archie", "ARCHIE", "storage", Color(0.7, 0.5, 1.0), Vector3(32.5, 0, 15)],
	["forge", "FORGE", "build", Color(1.0, 0.55, 0.2), Vector3(37.5, 0, 15)],
	["blueprint", "BLUEPRINT", "architect", Color(0.84, 0.8, 1.0), Vector3(42.5, 0, 15)],
]

func _build_krew_stations() -> void:
	for s in KREW_STATIONS:
		var root = Node3D.new()
		root.position = s[4]
		add_child(root)
		var accent = Tex.mat(s[3], 0.5, 0.2)
		_box(Vector3(3.2, 0.2, 2.6), Tex.shared("dark"), Vector3(0, 0.1, 0), root)
		_box(Vector3(3.2, 0.06, 0.12), accent, Vector3(0, 0.23, 1.25), root)
		_box(Vector3(0.12, 2.4, 0.12), Tex.shared("steel"), Vector3(1.3, 1.2, -1.0), root)
		var lamp = MeshInstance3D.new()
		var lm = SphereMesh.new()
		lm.radius = 0.2
		lm.height = 0.4
		lamp.mesh = lm
		lamp.material_override = Tex.status_glow("ok")
		lamp.position = Vector3(1.3, 2.55, -1.0)
		root.add_child(lamp)
		_krew_lamps[s[0]] = lamp
		_solid(Vector3(1.6, 2.6, 1.6), Vector3(0, 1.3, 0), {"type": "krew", "worker": s[0]}, root)
		var figure = Node3D.new()
		root.add_child(figure)
		_drawn_krew(s[0], _krew(s[0], figure, 2.3), accent, s[3])
		var tag = Label3D.new()
		tag.text = "%s  ·  %s\n[E] findings" % [s[1], s[2]]
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.font_size = 40
		tag.pixel_size = 0.0055
		tag.outline_size = 10
		tag.modulate = s[3].lightened(0.35)
		tag.position = Vector3(0, 3.1, 0)
		tag.visibility_range_end = 60.0
		root.add_child(tag)
		_krew_tags[s[0]] = tag

# Foreman's operations desk at the end of the Krew's row. The figure follows the
# chosen AI provider (section 09A): each provider has its own model, and rules
# only is the original orange supervisor.
var _foreman: Node3D = null
var _foreman_fig: Node3D = null
var _foreman_tag: Label3D = null
var _foreman_model = ""

func _build_foreman() -> void:
	_foreman = Node3D.new()
	_foreman.position = Vector3(48.5, 0, 9)
	add_child(_foreman)
	var gold = Tex.mat(Color(1.0, 0.68, 0.15), 0.5, 0.2)
	_box(Vector3(4.6, 0.2, 3.2), Tex.shared("dark"), Vector3(0.6, 0.1, 0), _foreman)
	_box(Vector3(4.6, 0.06, 0.12), gold, Vector3(0.6, 0.23, 1.55), _foreman)
	_box(Vector3(2.4, 1.5, 0.12), Tex.shared("board"), Vector3(1.6, 1.9, -1.3), _foreman)
	for x in [0.5, 2.7]:
		_box(Vector3(0.12, 2.6, 0.12), Tex.shared("steel"), Vector3(x, 1.3, -1.3), _foreman)
	var board = Label3D.new()
	board.text = "FOREMAN\nOPERATIONS"
	board.font_size = 40
	board.modulate = Color(1.0, 0.75, 0.3)
	board.position = Vector3(1.6, 1.9, -1.22)
	K.fit_label(board, 2.2, 1.2)
	_foreman.add_child(board)
	_solid(Vector3(1.6, 2.6, 1.6), Vector3(0, 1.3, 0), {"type": "foreman"}, _foreman)
	_solid(Vector3(2.6, 2.6, 0.4), Vector3(1.6, 1.3, -1.3), {"type": "foreman"}, _foreman)
	_foreman_tag = Label3D.new()
	_foreman_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_foreman_tag.font_size = 40
	_foreman_tag.pixel_size = 0.0055
	_foreman_tag.outline_size = 10
	_foreman_tag.position = Vector3(0, 3.2, 0)
	_foreman_tag.visibility_range_end = 60.0
	_foreman.add_child(_foreman_tag)

func set_foreman(id: Dictionary) -> void:
	if _foreman == null:
		_build_foreman()
	_foreman_tag.text = "FOREMAN  ·  %s\n[E] incidents" % str(id["label"]).to_lower()
	_foreman_tag.modulate = id["color"].lightened(0.3)
	if _foreman_model == id["model"]:
		return
	_foreman_model = id["model"]
	if _foreman_fig != null:
		_foreman_fig.queue_free()
	_foreman_fig = Node3D.new()
	_foreman.add_child(_foreman_fig)
	var fallback = _krew(id["model"], _foreman_fig, 2.5)
	# the code-drawn supervisor: hardhat and tablet, in the provider's colour
	var body = Tex.mat(id["color"], 0.5, 0.2)
	for x in [-0.22, 0.22]:
		_box(Vector3(0.24, 0.62, 0.3), Tex.shared("dark"), Vector3(x, 0.31, 0), fallback)
	_box(Vector3(0.86, 0.9, 0.56), body, Vector3(0, 1.07, 0), fallback)
	_box(Vector3(0.64, 0.5, 0.5), Tex.shared("steel"), Vector3(0, 1.8, 0), fallback)
	_box(Vector3(0.46, 0.15, 0.05), Tex.glow(id["color"].lightened(0.3), 1.6), Vector3(0, 1.82, 0.26), fallback)
	var hat = Tex.mat(Color(1.0, 0.75, 0.1), 0.5, 0.1)
	_box(Vector3(0.84, 0.08, 0.74), hat, Vector3(0, 2.09, 0.04), fallback)
	_box(Vector3(0.6, 0.24, 0.52), hat, Vector3(0, 2.24, 0), fallback)
	for x in [-0.56, 0.56]:
		_box(Vector3(0.2, 0.7, 0.24), body, Vector3(x, 1.05, 0.05), fallback)
	# the tablet, held by its lower edge in the right hand: flush with the front of the
	# forearm, its bottom at the hand
	_box(Vector3(0.4, 0.3, 0.04), Tex.shared("dark"), Vector3(0.56, 0.84, 0.19), fallback)
	_box(Vector3(0.34, 0.24, 0.02), Tex.glow(Color(0.5, 0.85, 1.0), 1.2), Vector3(0.56, 0.85, 0.215), fallback)
func _cyl(radius: float, height: float, material: Material, pos: Vector3, parent: Node3D, rot = Vector3.ZERO) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var c = CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = 16
	mi.mesh = c
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

# The code-drawn figures for the browser build and the Compatibility renderer,
# each shaped like its library model: Sentinel a guard robot with a shield,
# Scout a four-rotor drone, Scrappy a tracked sweeper with a roller brush.
func _drawn_krew(id: String, p: Node3D, accent: Material, colour: Color) -> void:
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	var eyes = Tex.glow(colour.lightened(0.3), 1.6)
	match id:
		"sentinel":
			for x in [-0.22, 0.22]:
				_box(Vector3(0.24, 0.62, 0.3), dark, Vector3(x, 0.31, 0), p)
			_box(Vector3(0.84, 0.86, 0.56), accent, Vector3(0, 1.05, 0), p)
			_box(Vector3(0.36, 0.3, 0.06), steel, Vector3(0, 1.12, 0.29), p)
			_box(Vector3(0.66, 0.52, 0.52), steel, Vector3(0, 1.78, 0), p)
			_box(Vector3(0.48, 0.18, 0.05), eyes, Vector3(0, 1.8, 0.27), p)
			_cyl(0.035, 0.3, steel, Vector3(0.2, 2.18, 0), p)
			for x in [-0.55, 0.55]:
				_box(Vector3(0.2, 0.66, 0.24), accent, Vector3(x, 1.0, 0), p)
			# the shield on the left arm
			_box(Vector3(0.12, 0.66, 0.54), steel, Vector3(-0.72, 0.95, 0.12), p)
			_box(Vector3(0.04, 0.3, 0.2), eyes, Vector3(-0.79, 0.98, 0.12), p)
		"scout":
			_cyl(0.05, 0.62, steel, Vector3(0, 0.31, 0), p)
			_box(Vector3(0.9, 0.5, 0.7), accent, Vector3(0, 0.95, 0), p)
			_box(Vector3(0.5, 0.26, 0.05), steel, Vector3(0, 1.0, 0.36), p)
			_box(Vector3(0.36, 0.1, 0.04), eyes, Vector3(0, 1.0, 0.39), p)
			_cyl(0.16, 0.2, steel, Vector3(0, 0.62, 0.2), p, Vector3(PI / 2, 0, 0))
			for x in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					var at = Vector3(x * 0.78, 1.12, z * 0.62)
					_box(Vector3(absf(at.x) * 1.1, 0.08, 0.1), dark, Vector3(at.x * 0.5, 1.08, at.z), p)
					_cyl(0.07, 0.18, steel, at, p)
					_cyl(0.36, 0.04, accent, at + Vector3(0, 0.1, 0), p)
			_cyl(0.025, 0.34, steel, Vector3(0, 1.36, 0), p)
		"scrappy":
			# built along +x, turned so the brush faces the yard like the model
			var turn = Node3D.new()
			turn.rotation.y = -PI / 2
			p.add_child(turn)
			p = turn
			for z in [-0.42, 0.42]:
				_box(Vector3(1.3, 0.34, 0.26), dark, Vector3(-0.1, 0.17, z), p)
				for x in [-0.6, -0.1, 0.4]:
					_cyl(0.13, 0.28, steel, Vector3(x, 0.17, z), p, Vector3(PI / 2, 0, 0))
			_box(Vector3(1.05, 0.62, 0.8), accent, Vector3(-0.15, 0.68, 0), p)
			_box(Vector3(0.5, 0.42, 0.55), accent, Vector3(-0.35, 1.18, 0), p)
			# its face looks forward, toward the brush
			_box(Vector3(0.06, 0.34, 0.46), steel, Vector3(0.4, 1.12, 0), p)
			_box(Vector3(0.04, 0.12, 0.32), eyes, Vector3(0.44, 1.14, 0), p)
			_cyl(0.32, 0.9, Tex.mat(colour.darkened(0.15), 0.8, 0.0), Vector3(0.78, 0.32, 0), p, Vector3(PI / 2, 0, 0))
		"archie":
			# a storage unit: a cabinet of drive bays on short legs, a face on top
			for x in [-0.35, 0.35]:
				_box(Vector3(0.18, 0.3, 0.5), dark, Vector3(x, 0.15, 0), p)
			_box(Vector3(1.0, 1.2, 0.7), accent, Vector3(0, 0.9, 0), p)
			for y in [0.55, 0.85, 1.15]:
				_box(Vector3(0.8, 0.18, 0.04), steel, Vector3(0, y, 0.36), p)
				_box(Vector3(0.08, 0.06, 0.03), eyes, Vector3(0.3, y, 0.39), p)
			_box(Vector3(0.62, 0.42, 0.5), steel, Vector3(0, 1.72, 0), p)
			_box(Vector3(0.44, 0.14, 0.05), eyes, Vector3(0, 1.74, 0.26), p)
		"forge":
			# a fabrication arm on a heavy base
			_cyl(0.5, 0.36, dark, Vector3(0, 0.18, 0), p)
			_box(Vector3(0.7, 0.5, 0.6), accent, Vector3(0, 0.6, 0), p)
			_box(Vector3(0.5, 0.36, 0.46), steel, Vector3(0, 1.04, 0), p)
			_box(Vector3(0.36, 0.12, 0.05), eyes, Vector3(0, 1.06, 0.24), p)
			var arm = _box(Vector3(0.18, 0.9, 0.18), accent, Vector3(0.42, 1.45, 0.1), p)
			arm.rotation.z = -0.6
			var fore = _box(Vector3(0.14, 0.6, 0.14), steel, Vector3(0.82, 1.78, 0.1), p)
			fore.rotation.z = 0.9
			_box(Vector3(0.2, 0.2, 0.2), Tex.glow(Color(1.0, 0.6, 0.2), 2.0), Vector3(1.06, 1.6, 0.1), p)
		"blueprint":
			# a slim architect robot holding up a blueprint board
			for x in [-0.18, 0.18]:
				_box(Vector3(0.2, 0.66, 0.26), dark, Vector3(x, 0.33, 0), p)
			_box(Vector3(0.7, 0.86, 0.46), accent, Vector3(0, 1.08, 0), p)
			_box(Vector3(0.56, 0.48, 0.46), steel, Vector3(0, 1.8, 0), p)
			_box(Vector3(0.42, 0.14, 0.05), eyes, Vector3(0, 1.82, 0.24), p)
			# the board, held up in front of the chest by both hands at its sides
			_box(Vector3(0.8, 0.56, 0.05), Tex.glow(Color(0.3, 0.45, 1.0), 1.2), Vector3(0.0, 1.05, 0.36), p)
			for y in [0.92, 1.05, 1.18]:
				_box(Vector3(0.62, 0.02, 0.02), Tex.glow(Color(0.9, 0.95, 1.0), 1.6), Vector3(0, y, 0.395), p)
			for x in [-1.0, 1.0]:
				_box(Vector3(0.14, 0.5, 0.16), accent, Vector3(x * 0.44, 1.22, 0.02), p)       # upper arm
				_box(Vector3(0.12, 0.12, 0.34), steel, Vector3(x * 0.44, 1.0, 0.18), p)        # forearm, reaching forward
				_box(Vector3(0.1, 0.16, 0.12), dark, Vector3(x * 0.41, 1.0, 0.36), p)          # hand on the board's edge

# What a station shows: the worker's state, and its lamp in the colour of its worst finding.
func set_krew_status(id: String, text: String, worst: String) -> void:
	if _krew_tags.has(id):
		var name = _krew_tags[id].text.get_slice("\n", 0)
		_krew_tags[id].text = "%s\n%s" % [name, text]
	if _krew_lamps.has(id):
		_krew_lamps[id].material_override = Tex.status_glow({"high": "bad", "medium": "warn", "low": "warn"}.get(worst, "ok"))

# Key hints on signs and tags ("[E] findings") follow the player's bindings.
# The text as written is kept, so a later rebinding translates from the original.
func refresh_hints(n: Node = self) -> void:
	for c in n.get_children():
		if c is Label3D:
			if not c.has_meta("kf_shown") or c.get_meta("kf_shown") != c.text:
				c.set_meta("kf_raw", c.text)     # set by the game since: that is the original now
			var shown = Controls.hint(str(c.get_meta("kf_raw")))
			c.text = shown
			c.set_meta("kf_shown", shown)
		if c.get_child_count() > 0:
			refresh_hints(c)

func set_gauge_visible(enabled: bool) -> void:
	_gauge.visible = enabled
	_gauge.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED

# Porter, the Portainer dock worker beside the shipping containers.
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
	# the sign stands over the container stack, clear of Porter and his name tag
	for sx in [1.2, 5.0]:
		_box(Vector3(0.14, 3.9, 0.14), steel, base + Vector3(sx, 1.95, -1.95))
	_box(Vector3(4.2, 1.0, 0.1), Tex.shared("board"), base + Vector3(3.1, 3.4, -1.95))
	var dock_sign = Label3D.new()
	dock_sign.text = "PORTAINER DOCK"
	dock_sign.font_size = 44
	dock_sign.modulate = Color(0.075, 0.745, 0.976)
	dock_sign.position = base + Vector3(3.1, 3.4, -1.89)
	K.fit_label(dock_sign, 3.8, 0.75)
	add_child(dock_sign)
	# the robot
	_npc = Node3D.new()
	_npc.position = base
	add_child(_npc)
	_solid(Vector3(1.4, 2.6, 1.4), Vector3(0, 1.3, 0), {"type": "npc"}, _npc)
	_npc_body = Node3D.new()
	_npc.add_child(_npc_body)
	var pfig = _krew("porter", _npc_body, 2.7)
	for lx in [-0.22, 0.22]:
		_box(Vector3(0.24, 0.8, 0.28), dark, Vector3(lx, 0.4, 0), pfig)
		_box(Vector3(0.3, 0.14, 0.42), steel, Vector3(lx, 0.07, 0.06), pfig)
	_box(Vector3(0.9, 0.95, 0.55), blue, Vector3(0, 1.3, 0), pfig)
	_box(Vector3(0.5, 0.3, 0.04), Tex.shared("hazard"), Vector3(0, 1.15, 0.29), pfig)
	for ax in [-0.58, 0.58]:
		_box(Vector3(0.2, 0.8, 0.22), blue, Vector3(ax, 1.3, 0), pfig)
		_box(Vector3(0.22, 0.2, 0.24), steel, Vector3(ax, 0.82, 0), pfig)
	_box(Vector3(0.62, 0.5, 0.52), steel, Vector3(0, 2.05, 0), pfig)
	_box(Vector3(0.5, 0.16, 0.04), Tex.glow(Color(0.3, 0.95, 1.0), 2.0), Vector3(0, 2.1, 0.27), pfig)
	var hat = MeshInstance3D.new()
	var hm = CylinderMesh.new()
	hm.top_radius = 0.3
	hm.bottom_radius = 0.4
	hm.height = 0.24
	hat.mesh = hm
	hat.material_override = yellow
	hat.position = Vector3(0, 2.42, 0)
	pfig.add_child(hat)
	_box(Vector3(0.9, 0.05, 0.95), yellow, Vector3(0, 2.31, 0.08), pfig)
	# crane on his back: mast, jib, cable and hook
	_box(Vector3(0.14, 2.3, 0.14), yellow, Vector3(0, 2.0, -0.36), pfig)
	_box(Vector3(0.12, 0.12, 1.5), yellow, Vector3(0, 3.1, 0.3), pfig)
	_npc_hook = Node3D.new()
	_npc_hook.position = Vector3(0, 3.05, 0.95)
	pfig.add_child(_npc_hook)
	_box(Vector3(0.03, 0.6, 0.03), dark, Vector3(0, -0.3, 0), _npc_hook)
	_box(Vector3(0.34, 0.22, 0.22), Tex.body(Color(0.95, 0.45, 0.2)), Vector3(0, -0.7, 0), _npc_hook)
	var tag = Label3D.new()
	tag.text = "PORTER\n[E] talk"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.pixel_size = 0.0055
	tag.outline_size = 10
	tag.modulate = Color(0.6, 0.92, 1.0)
	tag.position = Vector3(0, 3.75, 0)
	tag.visibility_range_end = 60.0
	_npc.add_child(tag)

# Bob, the pod fixer: an old hand in a flat cap who keeps a repair stand across
# the yard from Porter. His board lists what is broken; talk to him for the
# diagnosis and the fix for each job.
func _build_bob() -> void:
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	var wood = Tex.mat(Color(0.5, 0.36, 0.22), 0.85)
	var wood_dark = Tex.mat(Color(0.33, 0.23, 0.15), 0.9)
	var cream = Tex.mat(Color(0.93, 0.89, 0.78), 0.8)
	var base = Vector3(-10.5, 0, 9.0)
	var c = base + Vector3(-3.5, 0, -1.5)    # centre of the stall; Bob stands out in front of it
	# the stall: pallet floor, four posts, a striped awning, pegboard back wall
	_box(Vector3(6.0, 0.2, 4.0), dark, c + Vector3(0, 0.1, 0))
	for px in [-2.3, 2.3]:
		_box(Vector3(0.16, 3.9, 0.16), wood_dark, c + Vector3(px, 1.95, -1.15))
		_box(Vector3(0.16, 3.4, 0.16), wood_dark, c + Vector3(px, 1.7, 1.25))
	for i in 6:
		var slat = _box(Vector3(0.8, 0.1, 2.9), Tex.shared("orange") if i % 2 == 0 else cream, c + Vector3(-2.0 + i * 0.8, 3.72, 0.05))
		slat.rotation.x = 0.17
	_box(Vector3(4.8, 0.3, 0.08), Tex.shared("orange"), c + Vector3(0, 3.33, 1.5))
	_box(Vector3(4.2, 2.1, 0.1), Tex.shared("board"), c + Vector3(0, 2.35, -1.15))
	_bob_label = Label3D.new()
	_bob_label.font_size = 52
	_bob_label.position = c + Vector3(0, 2.35, -1.09)
	_bob_label.text = "FIX LIST"
	add_child(_bob_label)
	_box(Vector3(3.6, 0.7, 0.1), Tex.shared("board"), c + Vector3(0, 4.45, 1.3))
	for px in [-1.6, 1.6]:
		_box(Vector3(0.08, 0.75, 0.08), wood_dark, c + Vector3(px, 3.85, 1.3))
	var stand_sign = Label3D.new()
	stand_sign.text = "BOB'S REPAIRS"
	stand_sign.font_size = 44
	stand_sign.modulate = Color(1.0, 0.82, 0.5)
	stand_sign.position = c + Vector3(0, 4.45, 1.36)
	K.fit_label(stand_sign, 3.3, 0.55)
	add_child(stand_sign)
	# the workbench and what is on it: toolbox, vice, a gear, a little broken machine
	_box(Vector3(3.8, 0.14, 1.2), wood, c + Vector3(0, 1.0, 0.25))
	_box(Vector3(3.6, 0.08, 1.0), wood_dark, c + Vector3(0, 0.4, 0.25))
	for px in [-1.75, 1.75]:
		for pz in [-0.25, 0.75]:
			_box(Vector3(0.14, 0.95, 0.14), wood_dark, c + Vector3(px, 0.5, pz))
	_box(Vector3(0.75, 0.34, 0.36), Tex.mat(Color(0.75, 0.16, 0.13), 0.5, 0.3), c + Vector3(-1.2, 1.24, 0.2))
	_box(Vector3(0.5, 0.05, 0.06), steel, c + Vector3(-1.2, 1.47, 0.2))
	_box(Vector3(0.3, 0.26, 0.4), dark, c + Vector3(1.45, 1.2, 0.5))
	_box(Vector3(0.34, 0.1, 0.12), steel, c + Vector3(1.45, 1.38, 0.62))
	var gear = MeshInstance3D.new()
	var gm = CylinderMesh.new()
	gm.top_radius = 0.26
	gm.bottom_radius = 0.26
	gm.height = 0.08
	gm.radial_segments = 10
	gear.mesh = gm
	gear.material_override = steel
	gear.position = c + Vector3(-0.3, 1.11, 0.55)
	add_child(gear)
	_box(Vector3(0.55, 0.45, 0.55), Tex.body(Color(0.85, 0.75, 0.2)), c + Vector3(0.5, 1.3, 0.15))
	_box(Vector3(0.58, 0.07, 0.58), dark, c + Vector3(0.5, 1.1, 0.15))
	_box(Vector3(0.12, 0.12, 0.12), Tex.status_glow("bad"), c + Vector3(0.68, 1.6, 0.0))
	# tools hung on the pegboard edge
	for i in 3:
		var tool = _box(Vector3(0.07, 0.6 - i * 0.1, 0.04), steel, c + Vector3(-2.02 + i * 0.001, 1.1 + i * 0.02, -0.6 + i * 0.3))
		tool.rotation.x = 0.1
	_solid(Vector3(4.6, 2.6, 2.6), c + Vector3(0, 1.3, 0.05), {"type": "bob"})
	# Bob himself, a little stooped, cane in one hand and a wrench in the other
	var skin = Tex.mat(Color(0.89, 0.72, 0.6), 0.8)
	var white = Tex.mat(Color(0.93, 0.93, 0.9), 0.9)
	var green = Tex.mat(Color(0.34, 0.44, 0.3), 0.85)
	var brown = Tex.mat(Color(0.3, 0.23, 0.19), 0.85)
	var tweed = Tex.mat(Color(0.45, 0.42, 0.38), 0.95)
	_bob = Node3D.new()
	_bob.position = base
	add_child(_bob)
	_solid(Vector3(1.4, 2.6, 1.4), Vector3(0, 1.3, 0), {"type": "bob"}, _bob)
	_bob_body = Node3D.new()
	_bob.add_child(_bob_body)
	var bfig = _krew("bob", _bob_body, 2.3)
	for lx in [-0.2, 0.2]:
		_box(Vector3(0.26, 0.12, 0.42), dark, Vector3(lx, 0.06, 0.06), bfig)
		_box(Vector3(0.24, 0.8, 0.26), brown, Vector3(lx, 0.5, 0), bfig)
	var torso = Node3D.new()
	torso.position = Vector3(0, 0.9, 0)
	torso.rotation.x = 0.17
	bfig.add_child(torso)
	_box(Vector3(0.86, 0.86, 0.5), green, Vector3(0, 0.45, 0), torso)
	_box(Vector3(0.52, 0.72, 0.04), Tex.mat(Color(0.42, 0.29, 0.18), 0.8), Vector3(0, 0.4, 0.27), torso)   # leather apron
	_box(Vector3(0.2, 0.1, 0.05), steel, Vector3(0.1, 0.34, 0.3), torso)                                   # pocket spanner
	for ax in [-0.54, 0.54]:
		_box(Vector3(0.2, 0.76, 0.22), green, Vector3(ax, 0.46, 0.03), torso)
		_box(Vector3(0.18, 0.16, 0.2), skin, Vector3(ax, 0.02, 0.05), torso)
	_bob_head = Node3D.new()
	_bob_head.position = Vector3(0, 0.9, 0.04)
	torso.add_child(_bob_head)
	_box(Vector3(0.5, 0.5, 0.48), skin, Vector3(0, 0.26, 0), _bob_head)
	for hx in [-0.265, 0.265]:
		_box(Vector3(0.05, 0.26, 0.36), white, Vector3(hx, 0.27, -0.04), _bob_head)
	_box(Vector3(0.5, 0.34, 0.05), white, Vector3(0, 0.3, -0.25), _bob_head)
	_box(Vector3(0.58, 0.1, 0.58), tweed, Vector3(0, 0.55, 0.0), _bob_head)
	_box(Vector3(0.52, 0.05, 0.22), tweed, Vector3(0, 0.51, 0.36), _bob_head)
	for gx in [-0.12, 0.12]:
		_box(Vector3(0.17, 0.13, 0.03), dark, Vector3(gx, 0.31, 0.25), _bob_head)
		_box(Vector3(0.13, 0.09, 0.03), Tex.glow(Color(0.75, 0.92, 1.0), 0.9), Vector3(gx, 0.31, 0.262), _bob_head)
		_box(Vector3(0.16, 0.035, 0.04), white, Vector3(gx, 0.41, 0.25), _bob_head)   # eyebrows
	_box(Vector3(0.08, 0.1, 0.09), Tex.mat(Color(0.82, 0.62, 0.52), 0.8), Vector3(0, 0.22, 0.27), _bob_head)
	_box(Vector3(0.32, 0.08, 0.06), white, Vector3(0, 0.14, 0.26), _bob_head)
	_box(Vector3(0.36, 0.13, 0.07), white, Vector3(0, 0.04, 0.24), _bob_head)
	# cane, planted beside him, its handle in his hand
	_box(Vector3(0.05, 0.9, 0.05), wood_dark, Vector3(0.56, 0.45, 0.1), bfig)
	_box(Vector3(0.05, 0.05, 0.16), wood_dark, Vector3(0.56, 0.9, 0.04), bfig)
	# wrench in the other hand
	_bob_wrench = Node3D.new()
	_bob_wrench.position = Vector3(-0.54, 0.02, 0.06)     # in the fist; it hangs from there
	torso.add_child(_bob_wrench)
	_box(Vector3(0.05, 0.5, 0.03), steel, Vector3(0, 0.2, 0), _bob_wrench)
	_box(Vector3(0.16, 0.1, 0.035), steel, Vector3(0, 0.48, 0), _bob_wrench)
	_box(Vector3(0.05, 0.08, 0.04), dark, Vector3(0, 0.53, 0), _bob_wrench)
	var tag = Label3D.new()
	tag.text = "BOB\n[E] fix list"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.pixel_size = 0.0055
	tag.outline_size = 10
	tag.modulate = Color(1.0, 0.86, 0.6)
	tag.position = Vector3(0, 2.75, 0)
	tag.visibility_range_end = 60.0
	tag.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM   # so a spoken line grows upward, off his cap
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.width = 560.0
	_bob.add_child(tag)
	_bob_tag = tag

# Where to stand to look at a node's sign, as [pos, look_at].
func node_spot(node_name: String) -> Variant:
	var pf = platforms.get(node_name)
	if pf == null:
		return null
	return [pf.position + Vector3(0, 0.3, 16), pf.position + Vector3(0, 8.0, 1.2)]

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
	K.fit_label(title, 6.0, 0.6)
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
	K.fit_label(_uplink_label, 6.0, 0.28)
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
	K.fit_label(_uplink_label, 6.0, 0.28)
	var uc = K.health_color("ok" if ok else "bad")
	_uplink_mat.albedo_color = Color(uc.r, uc.g, uc.b, 0.25 if ok else 0.3)

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
		# thin brackets at the eight corners rather than a full cage, so the
		# highlight frames the thing without drawing lines across it
		var t = 0.035
		var i = 0
		for axis in 3:
			var b = (axis + 1) % 3
			var c = (axis + 2) % 3
			var stub = minf(0.7, size[axis] * 0.2)
			for sb in [-0.5, 0.5]:
				for sc in [-0.5, 0.5]:
					for end in [-1.0, 1.0]:
						var e = _select.get_child(i)
						var sv = Vector3(t, t, t)
						sv[axis] = stub
						var pv = Vector3.ZERO
						pv[axis] = end * (size[axis] - stub) * 0.5
						pv[b] = size[b] * sb
						pv[c] = size[c] * sc
						e.scale = sv
						e.position = pv
						i += 1

func show_build_plan(plan: Dictionary) -> bool:
	if BuildPlan.problem(plan) != "":
		return false
	if not is_instance_valid(_build_blocks):
		_build_blocks = PlanBlocks.new()
		_build_blocks.position = Vector3(110,0.3,80)
		add_child(_build_blocks)
	_build_blocks.redraw(plan)
	var title = Label3D.new()
	title.text = "LOCAL BUILD PLAN · no deployment\n[E] inspect a block to keep editing"
	title.position = Vector3(_build_blocks.bounds.get_center().x,9,_build_blocks.bounds.position.z-8)
	title.font_size = 54
	title.pixel_size = 0.035
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_build_blocks.add_child(title)
	return true

func _node_rank(n: Dictionary) -> String:
	return ("0" if str(n["roles"]).contains("control-plane") or str(n["roles"]).contains("master") else "1") + n["name"]

func apply_state(st: Dictionary) -> void:
	var quiet = _first or (st["source"] + "|" + st["context"]) != _source
	if quiet:
		vpn_selection.clear()
		lab_trace.clear()
		if pipe_filter == "Internet Output" or st.has("lab") or _source.begins_with("simulation|docker-media"):
			pipe_filter = "All"
		if st.has("lab"):
			show_belts = true
	_first = false
	_source = st["source"] + "|" + st["context"]
	var nodes = st["nodes"].duplicate()
	if st.has("lab"):
		nodes.sort_custom(func(a, b): return a["name"] > b["name"])
	else:
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
			var rows: int = pf.used_rows()
			if st.has("lab"):
				var count = st["lab"]["fixture_hosts"].values().count(row[j])
				var cabinet_rows = ceili(count / 2.0)
				rows = maxi(rows, ceili((cabinet_rows * 6.0 - 2.0) / Platform.PITCH))
			pf.set_rows(rows)
			pf.position = Vector3((j - (row.size() - 1) / 2.0) * (Platform.WIDTH + GAP), 0, row_z)
			max_depth = maxf(max_depth, pf.depth)
		row_z -= max_depth + 34.0
		i += PER_ROW
	if sun != null and OS.has_feature("web"):
		# shortcut: the browser build drops sun shadows on big factories to stay under
		# WebGL's ~4096 elements per frame; merge machine parts into one mesh to lift it
		sun.shadow_enabled = machines.size() < 45
	_update_lab_fixtures(st.get("lab", {}))
	_update_services(st, pods)
	_update_lab_board(st)
	_update_hub(st)

func _update_lab_board(st: Dictionary) -> void:
	if not st.has("lab"):
		if is_instance_valid(_lab_board):
			_lab_board.queue_free()
			_lab_board = null
		return
	if not is_instance_valid(_lab_board):
		_lab_board = Node3D.new()
		_lab_board.position = Vector3(-34, 0, FRONT_Z + 16)
		add_child(_lab_board)
		_box(Vector3(18.5, 12.2, 0.35), Tex.shared("board"), Vector3(0, 6.6, 0), _lab_board)
		for y in [0.4, 12.8]:
			_box(Vector3(18.8, 0.18, 0.45), Tex.shared("orange"), Vector3(0, y, 0), _lab_board)
		for x in [-7.5, 7.5]:
			_box(Vector3(0.4, 0.5, 1.8), Tex.shared("steel"), Vector3(x, 0.25, 0), _lab_board)
		_solid(Vector3(18.8, 12.8, 0.45), Vector3(0, 6.4, 0),
			{"type": "lab_fixture", "id": "connections", "name": "ALL CONNECTIONS · apps, ports and storage"}, _lab_board)
		var title = Label3D.new()
		title.text = "CONNECTION WHITEBOARD · [E] configure"
		title.position = Vector3(0, 12.4, 0.20)
		title.outline_size = 0
		title.font_size = 48
		K.fit_label(title, 17.8, 0.45)
		_lab_board.add_child(title)
		var viewport = SubViewport.new()
		viewport.size = Vector2i(2048, 1536)
		viewport.disable_3d = true
		_lab_board.add_child(viewport)
		var graph = LabConnections.new()
		viewport.add_child(graph)
		graph.configure(K.load_settings().get("lab_whiteboard", {}))
		graph.size = Vector2(viewport.size)
		var face = MeshInstance3D.new()
		var quad = QuadMesh.new()
		quad.size = Vector2(18.0, 11.3)
		face.mesh = quad
		var material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_texture = viewport.get_texture()
		face.material_override = material
		face.position = Vector3(0, 6.35, 0.20)
		_lab_board.add_child(face)
		_lab_board.set_meta("graph", graph)
		_lab_board.set_meta("viewport", viewport)
	var graph = _lab_board.get_meta("graph")
	if graph.refresh(st):
		graph.fit_routes.call_deferred()
		_lab_board.get_meta("viewport").render_target_update_mode = SubViewport.UPDATE_ONCE

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
	# Bob's job board: the top of his fix list, worst first
	var jobs = K.issues(st)
	_bob_jobs = jobs.size()
	if jobs.is_empty():
		_bob_label.text = "FIX LIST\n\nnothing on the bench\nevery machine is humming"
		_bob_label.modulate = K.health_color("ok")
	else:
		var rows = ["FIX LIST  (%d)" % jobs.size(), ""]
		for j in jobs.slice(0, 5):
			rows.append("%s  %s" % [str(j["name"]).left(20), j["status"]])
		if jobs.size() > 5:
			rows.append("+ %d more" % (jobs.size() - 5))
		rows.append("[E] ask Bob")
		_bob_label.text = "\n".join(PackedStringArray(rows))
		_bob_label.modulate = Color(1.0, 0.82, 0.5)
	K.fit_label(_bob_label, 3.9, 1.85)
	_hub_label.text = "%s  ·  %s\n\nNODES  %d / %d ready\nPODS   %d running  ·  %d pending  ·  %d failing\nWORKLOADS  %d   ·   SERVICES  %d\n\n[E]  open the cluster codex" % [
		str(st.get("provider", st["source"])).to_upper() if str(st.get("provider", "")) != "" else str(st["source"]).to_upper(), st["context"], ready, st["nodes"].size(),
		c["ok"], c["warn"], c["bad"], st["workloads"].size(), st["services"].size()]
	if st.has("lab"):
		_hub_label.text = "DOCKER MEDIA LAB  ·  SIMULATED\n\n%d %s  ·  %d containers running\n\n[E]  routes, ports, storage and controls" % [
			st["nodes"].size(), "host" if st["nodes"].size() == 1 else "hosts", c["ok"]]
	K.fit_label(_hub_label, 8.4, 3.5)
	K.fit_label(_log_label, 6.0, 1.7)

func _build_lab_storage(parent: Node3D) -> Dictionary:
	var surface = {"pos": Vector3(0, 1.22, 0.902), "size": Vector2(1.94, 0.15)}
	var model = Models.instance("shipping_container")
	if model != null:
		var bounds: AABB = model.get_meta("bounds")
		var dimensions = Vector3(2.28, 1.25, 1.70)
		model.scale = dimensions / bounds.size
		model.position = Vector3(0, 0.18 + dimensions.y * 0.5, 0) - bounds.get_center() * model.scale
		var template = Models.template("shipping_container")
		if template.has("name_surface"):
			var panel: Dictionary = template["name_surface"]
			var panel_size: Vector2 = panel["size"] * Vector2(model.scale.x, model.scale.y)
			panel_size.y = maxf(panel_size.y, 0.12)
			surface = {"pos": model.transform * panel["pos"], "size": panel_size}
			_box(Vector3(panel_size.x, panel_size.y, 0.008), Tex.shared("board"), surface["pos"] - Vector3(0, 0, 0.005), parent)
		if template.has("roof_bounds"):
			parent.set_meta("pipe_y", model.position.y + template["roof_bounds"].end.y * model.scale.y + 0.20)
	else:
		if _lab_storage_mesh == null:
			var paint = Tex.body(Color(0.22, 0.48, 0.72))
			var frame = Tex.shared("dark")
			var steel = Tex.shared("steel")
			var parts = [
				Models._box(Vector3(2.20, 1.16, 1.62), Vector3(0, 0.77, 0), paint),
				Models._box(Vector3(2.40, 0.10, 1.82), Vector3(0, 1.38, 0), frame),
				Models._box(Vector3(2.40, 0.10, 1.82), Vector3(0, 0.24, 0), frame),
				Models._box(Vector3(2.08, 0.19, 0.018), Vector3(0, 1.22, 0.889), Tex.shared("board"))]
			for x in [-1.10, 1.10]:
				for z in [-0.82, 0.82]:
					parts.append(Models._box(Vector3(0.12, 1.16, 0.12), Vector3(x, 0.80, z), frame))
					for y in [0.24, 1.34]:
						parts.append(Models._box(Vector3(0.20, 0.18, 0.20), Vector3(x, y, z), steel))
				for i in 7:
					parts.append(Models._box(Vector3(0.07, 0.92, 0.06), Vector3(x, 0.80, -0.66 + i * 0.22), paint))
			for side in [-1.0, 1.0]:
				parts.append(Models._box(Vector3(1.01, 1.04, 0.06), Vector3(side * 0.54, 0.78, 0.85), paint))
				parts.append(Models._box(Vector3(0.045, 0.83, 0.045), Vector3(side * 0.28, 0.70, 0.91), steel))
				parts.append(Models._box(Vector3(0.16, 0.055, 0.07), Vector3(side * 0.32, 0.59, 0.94), frame))
				parts.append(Models._box(Vector3(0.34, 0.11, 0.04), Vector3(side * 0.62, 0.34, 0.90), frame))
				for y in [0.48, 0.98]:
					parts.append(Models._box(Vector3(0.14, 0.10, 0.10), Vector3(side * 1.0, y, 0.87), steel))
			_lab_storage_mesh = Models._merge(parts)
		model = MeshInstance3D.new()
		model.mesh = _lab_storage_mesh
	model.name = "StorageContainer"
	parent.add_child(model)
	return surface

func _build_lab_lever(parent: Node3D) -> void:
	var steel = Tex.shared("steel")
	var dark = Tex.shared("dark")
	var paint = Tex.body(Color(0.22, 0.48, 0.72))
	_box(Vector3(1.24, 0.12, 1.08), dark, Vector3(0, 0.22, 0), parent)
	_box(Vector3(0.90, 0.96, 0.75), paint, Vector3(0, 0.73, 0), parent)
	_box(Vector3(1.24, 0.16, 1.04), dark, Vector3(0, 1.23, 0.16), parent)
	_box(Vector3(0.78, 0.30, 0.04), Tex.shared("board"), Vector3(0, 0.80, 0.40), parent)
	for x in [-0.31, 0.31]:
		_box(Vector3(0.16, 0.28, 0.40), steel, Vector3(x, 1.38, 0.24), parent)
		for z in [-0.40, 0.40]:
			_cyl(0.065, 0.06, steel, Vector3(x * 1.6, 0.31, z), parent)
	_cyl(0.13, 0.90, steel, Vector3(0, 1.44, 0.25), parent, Vector3(0, 0, PI * 0.5))
	_box(Vector3(0.28, 0.05, 0.14), Tex.body(Color(0.31, 0.77, 0.50)), Vector3(0, 1.34, 0.65), parent)
	_box(Vector3(0.28, 0.05, 0.14), Tex.body(Color(1.0, 0.61, 0.20)), Vector3(0, 1.34, -0.26), parent)
	var arm = Node3D.new()
	arm.name = "SyncLever"
	arm.position = Vector3(0, 1.44, 0.25)
	parent.add_child(arm)
	_cyl(0.065, 0.64, steel, Vector3(0, 0.32, 0), arm)
	_cyl(0.14, 0.78, Tex.body(Tex.ORANGE), Vector3(0, 0.68, 0), arm, Vector3(0, 0, PI * 0.5))
	for x in [-0.40, 0.40]:
		_cyl(0.15, 0.07, dark, Vector3(x, 0.68, 0), arm, Vector3(0, 0, PI * 0.5))
	parent.set_meta("arm", arm)
	var lamp = _cyl(0.07, 0.04, Tex.status_glow("ok"), Vector3(0, 1.05, 0.40), parent, Vector3(PI * 0.5, 0, 0))
	parent.set_meta("lamp", lamp)

func _build_lab_gateway(parent: Node3D, height: float, color: Color, count: int) -> void:
	var body = _box(Vector3(2.15, height - 0.26, 1.42), Tex.mat(Color(0.08, 0.11, 0.13), 0.85, 0.1),
		Vector3(0, 0.18 + (height - 0.26) * 0.5, 0), parent)
	body.name = "GatewayBody"
	var rim = _box(Vector3(2.19, 0.08, 1.46), Tex.mat(color, 0.75, 0.1), Vector3(0, height - 0.04, 0), parent)
	rim.name = "GatewayRim"
	_box(Vector3(1.94, 0.62, 0.016), Tex.shared("board"), Vector3(0, 2.60, 0.718), parent)
	parent.set_meta("port_count", count)
	var gold = Tex.mat(Color(0.85, 0.67, 0.27), 0.6, 0.3)
	for i in count:
		var y = 1.95 - i * 0.60
		var jack = Node3D.new()
		jack.name = "GatewayPort%d" % i
		parent.add_child(jack)
		_box(Vector3(0.46, 0.30, 0.05), Tex.shared("steel"), Vector3(-0.60, y, 0.745), jack)
		_box(Vector3(0.31, 0.17, 0.03), Tex.shared("off"), Vector3(-0.60, y, 0.78), jack)
		for contact in 5:
			_box(Vector3(0.018, 0.08, 0.012), gold, Vector3(-0.70 + contact * 0.05, y - 0.015, 0.799), jack)
		var lamp = _cyl(0.045, 0.025, Tex.status_glow("warn"), Vector3(-0.93, y, 0.735), jack, Vector3(PI * 0.5, 0, 0))
		jack.set_meta("lamp", lamp)
		var label = Label3D.new()
		label.position = Vector3(0.32, y, 0.735)
		label.font_size = 36
		label.outline_size = 0
		label.visibility_range_end = 45.0
		jack.add_child(label)
		jack.set_meta("label", label)
		var collider = _solid(Vector3(0.52, 0.36, 0.08), Vector3(-0.60, y, 0.77), {}, jack)
		collider.name = "PortCollider"
		var x = (i - (count - 1) * 0.5) * 0.64
		var point = Vector3(x, height + 0.20, -0.46)
		var socket = _cyl(0.15, 0.20, Tex.shared("steel"), point - Vector3.UP * 0.10, jack)
		socket.name = "RoofSocket"
		_cyl(0.19, 0.06, Tex.shared("dark"), Vector3(0, -0.06, 0), socket)
		jack.set_meta("pipe_port", point)

func _update_lab_fixtures(lab: Dictionary) -> void:
	var fixtures: Dictionary = lab.get("fixtures", {})
	for id in lab_fixtures.keys():
		if not fixtures.has(id):
			lab_fixtures[id].queue_free()
			lab_fixtures.erase(id)
	var slots = {MediaLab.MEDIA: 0, MediaLab.GATHER: 0}
	for id in fixtures:
		var mount = MediaLab.DISKS.has(id)
		var control = id == "sync-switch"
		var gateway = not mount and not control
		var gateway_ports: Array = lab.get("gateway_ports", {}).get(id, [])
		var host: String = lab["fixture_hosts"].get(id, MediaLab.MEDIA)
		var base: Vector3 = platforms[host].position
		var tail: Vector3 = platforms.get(MediaLab.GATHER, platforms[MediaLab.MEDIA]).position
		var pos: Vector3
		if mount:
			var index: int = slots[host]
			pos = base + Vector3(17.0 if index % 2 == 0 else -17.0, Platform.HEIGHT, -4.0 - 6.0 * floori(index / 2.0))
			slots[host] += 1
		else:
			match id:
				"lan": pos = base + Vector3(-25, 0, 1)
				"www": pos = tail + Vector3(25, 0, 1)
				"discord": pos = tail + Vector3(25, 0, -8)
				"sync-switch": pos = base + Vector3(12, Platform.HEIGHT, -1.5)
		if gateway and lab_fixtures.has(id) and lab_fixtures[id].get_meta("port_count", -1) != gateway_ports.size():
			lab_fixtures[id].queue_free()
			lab_fixtures.erase(id)
		if not lab_fixtures.has(id):
			var d = Node3D.new()
			add_child(d)
			lab_fixtures[id] = d
			var color: Color = MediaLab.COLORS["Mounts" if mount else ("Files" if control else {"lan": "LAN", "www": "VPN", "discord": "Alerts"}[id])]
			var height = 1.63 if mount else (1.45 if control else 3.1)
			d.set_meta("pipe_y", height)
			_box(Vector3(1.65, 0.18, 1.40) if control else Vector3(2.45, 0.18, 2.15), Tex.shared("steel"), Vector3(0, 0.09, 0), d)
			var storage_surface = {}
			if mount:
				storage_surface = _build_lab_storage(d)
			elif control:
				_build_lab_lever(d)
			else:
				_build_lab_gateway(d, height, color, gateway_ports.size())
			_solid(Vector3(2.45 if mount else (1.65 if control else 2.25), height + (0.85 if control else 0.0), 2.05 if mount else (1.76 if control else 1.46)), Vector3(0, height * 0.5 + (0.42 if control else 0.0), 0),
				{"type": "lab_fixture", "id": id, "name": fixtures[id]}, d)
			var label = Label3D.new()
			label.text = fixtures[id]
			label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
			label.font_size = 48
			label.pixel_size = 0.014
			label.modulate = color.lightened(0.25)
			label.position = storage_surface["pos"] if mount else (Vector3(0, 0.80, 0.425) if control else Vector3(0, 2.60, 0.742))
			label.visibility_range_end = 45.0
			label.outline_size = 0
			if mount:
				var panel_size: Vector2 = storage_surface["size"]
				K.fit_label(label, panel_size.x, panel_size.y)
			elif gateway:
				K.fit_label(label, 1.84, 0.54)
			d.add_child(label)
			d.set_meta("label", label)
		var fixture: Node3D = lab_fixtures[id]
		fixture.position = pos
		if control:
			var angle = -0.55 if lab["paused"] else 0.55
			var arm: Node3D = fixture.get_meta("arm")
			if not is_equal_approx(arm.rotation.x, angle):
				arm.create_tween().tween_property(arm, "rotation:x", angle, 0.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			var status = "PAUSED" if lab["paused"] else ("COPYING" if lab["transfer"] else "READY")
			var health = "warn" if lab["paused"] else "ok"
			if not lab["sync_ready"]:
				status = "OFFLINE"
				health = "bad"
			fixture.get_meta("label").text = "SYNC\n" + status
			fixture.get_meta("label").modulate = K.health_color(health).lightened(0.25)
			fixture.get_meta("lamp").material_override = Tex.status_glow(health)
			K.fit_label(fixture.get_meta("label"), 0.70, 0.24)
		elif id == "lan":
			fixture.get_meta("label").text = "LAN / VLAN IN\n" + str(lab["access"])
			K.fit_label(fixture.get_meta("label"), 1.84, 0.54)
		if gateway:
			var mapping = {}
			for i in gateway_ports.size():
				var port: Dictionary = gateway_ports[i]
				var jack = fixture.get_node("GatewayPort%d" % i)
				var health = "bad" if not port["ready"] else ("ok" if port["reachable"] else "warn")
				var status = "OFFLINE" if not port["ready"] else ("LOCAL" if not port["reachable"] else ("OPEN" if id == "lan" else "OUT"))
				jack.get_meta("label").text = "%d · %s\n%s · %s" % [i + 1, str(port["port"]).to_upper(), port["app"], status]
				jack.get_meta("label").modulate = K.health_color(health).lightened(0.2)
				K.fit_label(jack.get_meta("label"), 1.20, 0.44)
				jack.get_meta("lamp").material_override = Tex.status_glow(health)
				jack.get_node("PortCollider").set_meta("kf", {"type": "lab_fixture", "id": id, "uid": port["uid"],
					"name": "%s · %s" % [port["app"], port["port"]], "port": port["port"]})
				if port["uid"] != "":
					mapping[port["uid"]] = jack.get_meta("pipe_port")
			fixture.set_meta("gateway_ports", mapping)

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
			var external = s["type"] in ["LoadBalancer", "NodePort"]
			for x in ([-0.94, 0.94] if external else [0.0]):
				_box(Vector3(0.85, 2.56, 0.85), Tex.body(col), Vector3(x, 1.58, 0), d)
			_box(Vector3(3.2, 0.25, 3.2), Tex.shared("dark"), Vector3(0, 3.0, 0), d)
			_box(Vector3(2.4, 1.3, 0.1), Tex.shared("board"), Vector3(0, 1.8, 1.52), d)
			_solid(Vector3(3.6, 3.2, 3.6), Vector3(0, 1.6, 0), {"type": "service", "ns": s["ns"], "name": s["name"],
				"pillars": "Two pillars · externally exposed Service (" + s["type"] + ")" if external else "One pillar · in-cluster Service (" + s["type"] + ")"}, d)
			var l = Label3D.new()
			l.text = "%s\n%s\n%s" % [s["name"], s["type"], s["ports"]]
			l.font_size = 30
			l.pixel_size = 0.008
			l.line_spacing = -4
			l.position = Vector3(0, 1.8, 1.59)
			K.fit_label(l, 2.2, 1.12, 0.008)
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
	var bsig = pipe_filter if show_belts else "off"
	var lab = st.has("lab")
	var infrastructure = not lab and show_belts and pipe_filter in ["All", "Services and VPN"]
	var show_egress = not lab and (infrastructure or (show_belts and pipe_filter == "Internet Output"))
	var exits = _update_vpn_signs([] if lab else pods, show_egress)
	if show_belts:
		for i in svcs.size():
			if not infrastructure:
				break
			var s = svcs[i]
			var d = _depots[s["ns"] + "/" + s["name"]]
			# Stay in front of the platforms until the route reaches the target's aisle.
			var h = 12.0 + i * 0.7
			var lz = (YARD_Z + FRONT_Z) * 0.5
			var col = K.hue_color("svc:" + s["ns"] + "/" + s["name"], 0.6, 0.85)
			for p in pods:
				if p["ns"] != s["ns"] or not K.selects(s["selector"], p["labels"]):
					continue
				var m = machines.get(p["uid"])
				if m == null:
					continue
				var mp = _machine_port(m, Vector2(-0.7 + (i % 3) * 0.37, 0.93))
				var aisle = _pipe_aisle(m)
				var sx = d.position.x
				var pts = [Vector3(sx, 3.1, YARD_Z), Vector3(sx, h, YARD_Z), Vector3(sx, h, lz),
					Vector3(aisle.x, h, lz), Vector3(aisle.x, h, mp.z), Vector3(mp.x, h, mp.z), mp]
				paths.append({"pts": pts, "color": col, "service": i})
				bsig += str(pts)
		# VPN feeds stay inside the factory. Each tunnel runs to its own port outside it.
		# A shared VPN collects its clients at one riser before entering the gateway.
		#  - a sidecar (Kubernetes, the demo): the VPN is a unit on the pod's roof,
		#    piped straight into the machine it carries
		#  - an image with the VPN built in: only the tunnel
		var lane_index = 0
		var vpn_inputs = {}
		for p in pods:
			var gw = machines.get(str(p.get("net", {}).get("via", "")))
			var m = machines.get(p["uid"])
			if gw != null and m != null and gw != m and not gw.pod.get("net", {}).get("vpn", {}).is_empty():
				var height = 12.0 + (svcs.size() + lane_index) * 0.7
				lane_index += 1
				if show_egress and _vpn_route_visible(gw.uid):
					var tap = _pipe_aisle(gw) + Vector3.RIGHT * 1.1
					tap.y = height
					var pts = _aisle_route(m, gw, _vpn_anchor(m), tap, height, true)
					pts.pop_back()  # the approach already ends at the tap at this height
					var active: bool = p["ready"] and gw.pod["ready"]
					paths.append({"pts": pts, "color": VPN_FEED_COL, "valve": false, "vpn_uid": gw.uid,
						"vpn_join": "branch", "flow": active})
					vpn_inputs[gw.uid] = [tap, active or vpn_inputs.get(gw.uid, [tap, false])[1]]
					bsig += "feed" + str(pts) + str(active)
			if not show_egress or not _vpn_route_visible(p["uid"]):
				continue
			if exits.has(p["uid"]):
				var v: Dictionary = p["net"]["vpn"]
				var tunnel: Array = exits[p["uid"]]
				if str(v.get("sidecar", "")) != "":
					var port = _machine_port(m, Vector2(-0.29, -0.65))
					var inlet = to_local(m.to_global(m.pipe_port(VPN_ROOF_OFFSET) + Vector3(-VPN_UNIT_WIDTH * 0.5, 0.48, 0)))
					paths.append({"pts": [port, Vector3(port.x, inlet.y, port.z), Vector3(port.x, inlet.y, inlet.z), inlet],
						"color": VPN_FEED_COL, "valve": false, "vpn_uid": p["uid"], "flow": p["ready"]})
					bsig += "side" + str(inlet) + str(p["ready"])
				paths.append({"pts": tunnel, "color": VPN_TUNNEL_COL, "valve": false, "vpn_uid": p["uid"], "flow": p["ready"]})
				bsig += "tunnel" + str(tunnel) + str(p["ready"])
		for uid in vpn_inputs:
			var top: Vector3 = vpn_inputs[uid][0]
			var inlet = _machine_port(machines[uid], Vector2(-0.72, -0.35))
			var low = maxf(7.2, inlet.y + 0.7)
			var pts = [top, Vector3(top.x, low, top.z), Vector3(top.x, low, inlet.z),
				Vector3(inlet.x, low, inlet.z), inlet]
			paths.append({"pts": pts, "color": VPN_FEED_COL, "valve": false, "vpn_uid": uid,
				"vpn_join": "riser", "flow": vpn_inputs[uid][1]})
			bsig += "riser" + str(pts) + str(vpn_inputs[uid][1])
		var shown = {}
		for p in pods:
			shown[p["uid"]] = true
		var endpoints = machines.duplicate() if lab else machines
		if lab:
			for id in lab_fixtures:
				endpoints["lab:" + id] = lab_fixtures[id]
				shown["lab:" + id] = true
		var ports = {}
		var links: Array = st.get("links", []).duplicate()
		if lab:
			# Mounts take the lowest lanes so their drops stay legible beside storage.
			links.sort_custom(func(a, b): return a["kind"] == "Mounts" and b["kind"] != "Mounts")
		for link in links:
			if not shown.has(link["from"]) or not shown.has(link["to"]):
				continue
			var from = endpoints.get(link["from"])
			var to = endpoints.get(link["to"])
			if from == null or to == null:
				continue
			var a = _app_pipe_port(from, ports, link["to"])
			var b = _app_pipe_port(to, ports, link["from"])
			var height = (6.8 + lane_index * 0.33) if lab else (12.0 + (svcs.size() + lane_index) * 0.7)
			lane_index += 1
			# Reserve the same ports and height even when this kind is hidden.
			if pipe_filter != "All" and pipe_filter != link["kind"]:
				continue
			var pts = _aisle_route(from, to, a, b, height)
			var color: Color = (MediaLab.COLORS if lab else Topology.COLORS)[link["kind"]]
			var traced = [link["from"], link["to"], link["kind"]] == lab_trace or lab_trace.has([link["from"], link["to"], link["kind"]])
			var flow: bool = link.get("flow", link["ready"])
			if lab and not traced:
				if not lab_trace.is_empty():
					color = color.darkened(0.35)
					flow = false
				elif not link["ready"]:
					color = color.darkened(0.42)
			paths.append({"pts": pts, "color": color, "valve": false, "flow": flow, "kind": link["kind"],
				"link": [link["from"], link["to"], link["kind"]]})
			bsig += str(pts) + str(color) + str(flow) + str([link["from"], link["to"], link["kind"]])
	if bsig != _belt_sig:
		_belt_sig = bsig
		_rebuild_belts(paths)
# ---- VPN gateways and the Internet Output station
#
# INSIDE, by the gateway: its addresses on your network and what goes through
# it. OUTSIDE, beside its dedicated port: the pod and the public exit address.
const VPN_UNIT_H = 1.0       # the sidecar's unit on the pod's roof
const VPN_UNIT_WIDTH = 0.92
const VPN_ROOF_OFFSET = Vector2(0.51, -0.37)
const INTERNET_FIRST_PORT_Y = 8.2
const INTERNET_PORT_PITCH = 1.18
const VPN_FEED_COL = Color(0.62, 0.42, 0.95)
const VPN_TUNNEL_COL = Color(0.95, 0.72, 0.22)
var _vpn_signs = {}      # VPN uid -> {inside, outside, unit, sig}
var _internet_output: Node3D
var _internet_output_sig = []

func _vpn_route_visible(uid: String) -> bool:
	return pipe_filter != "Internet Output" or vpn_selection.is_empty() or vpn_selection.has(uid)

# where a VPN line leaves a machine: the top, clear of the Service drops
func _machine_port(m: Node3D, offset: Vector2) -> Vector3:
	return to_local(m.to_global(m.pipe_port(offset)))

func _pipe_aisle(m: Node3D) -> Vector3:
	return to_local(m.global_position) + Vector3(-Platform.PITCH / 2.0, 0, Platform.PITCH / 2.0)

func _aisle_route(from: Node3D, to: Node3D, a: Vector3, b: Vector3, height: float, from_right: bool = false) -> Array:
	var a_lane = _pipe_aisle(from)
	if from_right:
		a_lane.x += Platform.PITCH  # the left side of the roof holds the app pipes
	var b_lane = _pipe_aisle(to)
	var pts = [a, Vector3(a.x, height, a.z), Vector3(a_lane.x, height, a.z)]
	if not is_equal_approx(a_lane.x, b_lane.x):
		pts.append(Vector3(a_lane.x, height, a_lane.z))
		pts.append(Vector3(b_lane.x, height, a_lane.z))
	pts.append_array([Vector3(b_lane.x, height, b.z), Vector3(b.x, height, b.z), b])
	return pts

func _app_pipe_port(m: Node3D, ports: Dictionary, peer: String = "") -> Vector3:
	var id = m.get_instance_id()
	var index = int(ports.get(id, 0))
	ports[id] = index + 1
	var gateway_port = m.get_meta("gateway_ports", {}).get(peer)
	if gateway_port != null:
		return to_local(m.to_global(gateway_port))
	if m.has_meta("pipe_y"):
		var offset = Vector3(-0.79 + 0.32 * (index % 6), m.get_meta("pipe_y"), -0.46 + 0.36 * floori(index / 6.0))
		var socket_name = "StoragePort%d" % index
		if m.has_node("StorageContainer") and not m.has_node(socket_name):
			var socket = _cyl(0.15, 0.20, Tex.shared("steel"), offset - Vector3.UP * 0.10, m)
			socket.name = socket_name
			_cyl(0.19, 0.06, Tex.shared("dark"), Vector3(0, -0.06, 0), socket)
		return to_local(m.to_global(offset))
	# Leave the forward strip of the roof for Service drops and their fittings.
	return _machine_port(m, Vector2(-0.92 + 0.38 * floori(index / 6.0), -0.87 + 0.27 * (index % 6)))

func _vpn_anchor(m: Node3D) -> Vector3:
	return _machine_port(m, VPN_ROOF_OFFSET)

# A sidecar VPN, drawn as what it is: its own small unit on the pod's roof.
func _vpn_unit(m: Node3D, v: Dictionary) -> Node3D:
	var u = Node3D.new()
	u.position = m.pipe_port(VPN_ROOF_OFFSET)
	m.add_child(u)
	_box(Vector3(1.02, 0.10, 1.02), Tex.shared("steel"), Vector3(0, 0.05, 0), u)
	_box(Vector3(VPN_UNIT_WIDTH, VPN_UNIT_H - 0.10, VPN_UNIT_WIDTH), Tex.shared("dark"), Vector3(0, (VPN_UNIT_H + 0.10) * 0.5, 0), u)
	_box(Vector3(VPN_UNIT_WIDTH + 0.04, 0.08, VPN_UNIT_WIDTH + 0.04), Tex.glow(VPN_TUNNEL_COL, 1.2), Vector3(0, VPN_UNIT_H * 0.79, 0), u)
	var l = Label3D.new()
	l.text = "VPN\n%s" % str(v.get("sidecar", ""))
	l.font_size = 36
	l.pixel_size = 0.006
	l.outline_size = 6
	l.modulate = VPN_TUNNEL_COL.lightened(0.3)
	l.position = Vector3(0, VPN_UNIT_H * 0.4, VPN_UNIT_WIDTH * 0.5 + 0.012)
	K.fit_label(l, VPN_UNIT_WIDTH * 0.88, 0.48, 0.006)
	u.add_child(l)
	return u

func _vpn_sign(col: Color, distance: float) -> Label3D:
	var l = Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 44
	l.pixel_size = 0.005
	l.outline_size = 9
	l.outline_modulate = Color(0.02, 0.02, 0.04, 0.95)
	l.modulate = col
	l.visibility_range_begin = 1.6
	l.visibility_range_end = distance
	add_child(l)
	return l

func _update_vpn_signs(pods: Array, shown: bool) -> Dictionary:
	var gateways = pods.filter(func(p): return machines.has(p["uid"]) and not p.get("net", {}).get("vpn", {}).is_empty())
	gateways.sort_custom(func(a, b): return a["uid"] < b["uid"])
	var edge = FRONT_Z
	for platform in platforms.values():
		edge = minf(edge, platform.position.z - platform.depth)
	edge -= 10.0
	var lanes = {}
	var routes = {}
	for p in gateways:
		var uid = p["uid"]
		var m = machines[uid]
		var s = _vpn_signs.get(uid)
		if s == null:
			s = {"inside": _vpn_sign(VPN_FEED_COL.lightened(0.35), 22.0),
				"outside": _vpn_sign(VPN_TUNNEL_COL.lightened(0.35), 34.0), "unit": null, "sig": ""}
			s["outside"].billboard = BaseMaterial3D.BILLBOARD_DISABLED
			s["outside"].double_sided = false
			_vpn_signs[uid] = s
		var b = _vpn_anchor(m)
		var side = str(p["net"]["vpn"].get("sidecar", "")) != ""
		var unit = s["unit"]
		if is_instance_valid(unit) and (not side or unit.get_parent() != m):
			unit.queue_free()
			unit = null
		if side:
			if not is_instance_valid(unit):
				unit = _vpn_unit(m, p["net"]["vpn"])
			b = to_local(unit.to_global(Vector3.UP * VPN_UNIT_H))
		s["unit"] = unit if is_instance_valid(unit) else null
		s["inside"].position = b + Vector3(0, 2.0, 0)
		s["inside"].visible = _vpn_route_visible(uid)
		# Leave the roof on the right and run along the aisle below the main trunks.
		var x = to_local(m.global_position).x + Platform.PITCH * 0.5
		var slot = int(lanes.get(x, 0))
		lanes[x] = slot + 1
		var y = INTERNET_FIRST_PORT_Y + slot * INTERNET_PORT_PITCH
		var port = Vector3(x, y, edge)
		routes[uid] = [b, Vector3(b.x, y, b.z), Vector3(x, y, b.z), port]
		s["outside"].position = port + Vector3(0, 0.61, 0.33)
		s["outside"].visible = shown and _vpn_route_visible(uid)
		var inside = K.vpn_inside_text(p)
		var vpn: Dictionary = p["net"]["vpn"]
		var exit_ip = str(vpn.get("exit_ip", ""))
		var outside = "%s/%s\n%s%s" % [p["ns"], p["name"], "Exit IP unknown" if exit_ip.is_empty() else exit_ip,
			" · SIMULATED" if vpn.get("exit_note", "") == "SIMULATED" else ""]
		if inside + outside != s["sig"]:
			s["sig"] = inside + outside
			s["inside"].text = inside
			K.fit_label(s["inside"], 2.9, 0.85, 0.004)
			s["outside"].text = outside
			K.fit_label(s["outside"], 4.5, 0.70)
	for uid in _vpn_signs.keys():
		if not routes.has(uid):
			_vpn_signs[uid]["inside"].queue_free()
			_vpn_signs[uid]["outside"].queue_free()
			if is_instance_valid(_vpn_signs[uid]["unit"]):
				_vpn_signs[uid]["unit"].queue_free()
			_vpn_signs.erase(uid)
	_update_internet_output(edge, lanes, shown)
	return routes

func _update_internet_output(edge: float, lanes: Dictionary, shown: bool) -> void:
	var sig = [] if lanes.is_empty() else [edge, lanes]
	if sig != _internet_output_sig:
		_internet_output_sig = sig
		if is_instance_valid(_internet_output):
			_internet_output.queue_free()
			_internet_output = null
		if not lanes.is_empty():
			var xs = lanes.keys()
			xs.sort()
			var width: float = xs.back() - xs.front()
			var center: float = (xs.front() + xs.back()) * 0.5
			var top = INTERNET_FIRST_PORT_Y + (lanes.values().max() - 1) * INTERNET_PORT_PITCH
			var rack = Node3D.new()
			rack.name = "InternetOutput"
			rack.position = Vector3(center, 0, edge)
			add_child(rack)
			_internet_output = rack
			_box(Vector3(width + 4.6, 0.30, 3.8), Tex.shared("foundation"), Vector3(0, 0.15, -1.15), rack)
			_box(Vector3(width + 4.6, 2.8, 0.35), Tex.shared("dark"), Vector3(0, 1.4, -1.85), rack)
			var steel = Tex.shared("steel")
			var gold = Tex.body(VPN_TUNNEL_COL)
			for x in xs:
				var local_x: float = x - center
				var h: float = INTERNET_FIRST_PORT_Y + (lanes[x] - 1) * INTERNET_PORT_PITCH + 0.92
				_box(Vector3(1.3, h, 2.5), Tex.shared("dark"), Vector3(local_x, h * 0.5, -1.25), rack)
				for slot in lanes[x]:
					var y = INTERNET_FIRST_PORT_Y + slot * INTERNET_PORT_PITCH
					_cyl(0.32, 0.32, steel, Vector3(local_x, y, 0.04), rack, Vector3(PI * 0.5, 0, 0))
					_cyl(0.21, 0.09, gold, Vector3(local_x, y, 0.19), rack, Vector3(PI * 0.5, 0, 0))
			# One shared output leaves the ports' collector on the public side of the rack.
			if width > 0.01:
				_cyl(0.37, width, gold, Vector3(0, 1.25, -2.5), rack, Vector3(0, 0, PI * 0.5))
			_cyl(0.37, 5.6, gold, Vector3(0, 1.25, -5.3), rack, Vector3(PI * 0.5, 0, 0)).name = "PublicInternetPipe"
			_box(Vector3(3.6, top + 0.6, 2.2), Tex.shared("dark"), Vector3(0, (top + 0.6) * 0.5, -8.6), rack)
			_box(Vector3(4.0, 0.18, 2.6), gold, Vector3(0, top + 0.65, -8.6), rack)
			for face in [["FactoryInputs", "FACTORY SIDE\nVPN INPUTS", 0.55, 0.0],
					["PublicOutput", "PUBLIC SIDE\nWWW OUTPUT", -9.78, PI]]:
				var title = _vpn_sign(VPN_TUNNEL_COL.lightened(0.4), 180.0)
				title.reparent(rack, false)
				title.name = face[0]
				title.text = face[1]
				title.billboard = BaseMaterial3D.BILLBOARD_DISABLED
				title.double_sided = false
				title.rotation.y = face[3]
				title.font_size = 64
				title.pixel_size = 0.021
				title.position = Vector3(0, top + 1.8, face[2])
	if is_instance_valid(_internet_output):
		_internet_output.visible = shown

func _rebuild_belts(paths: Array) -> void:
	_paths = paths
	var segs = {}
	var joints = {}
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
			var is_drop = i == pts.size() - 1 and path.get("valve", true)
			var key = str(a) + str(b)
			if path.has("service") and not is_drop:
				# Branches from the same starting point share one piece of trunk.
				key = "%s:%s:%s" % [path["service"], a, (b - a).normalized()]
			if not segs.has(key) or a.distance_squared_to(b) > a.distance_squared_to(segs[key][1]):
				segs[key] = [a, b, path["color"], is_drop]
			if i < pts.size() - 1 or path.get("vpn_join") == "branch":
				joints[str(b)] = [b, path["color"]]                      # a corner
		path["cum"] = cum
		total += cum[cum.size() - 1]
	# the library's pipe kit where the library is in use; otherwise the code-drawn tracks
	if Models.available() and _pipes == null:
		_pipes = Pipes.new()
		add_child(_pipes)
	_pipe_mode = _pipes != null and _pipes.ready_to_use()
	_belt_mm.visible = not _pipe_mode
	_item_mm.multimesh.mesh = _item_ring
	if _pipe_mode:
		_pipes.build(segs.values().map(func(sg): return [sg[0], sg[1], sg[2].darkened(0.1), sg[3]]), joints.values())
	var mm = _belt_mm.multimesh
	if not _pipe_mode and not (mm.mesh is CylinderMesh):
		var tube = CylinderMesh.new()
		tube.top_radius = 0.081
		tube.bottom_radius = 0.081
		tube.height = 1.0
		tube.radial_segments = 8
		tube.material = mm.mesh.material
		mm.mesh = tube
	mm.instance_count = 0 if _pipe_mode else segs.size()
	var i = 0
	for sg in ([] if _pipe_mode else segs.values()):
		var a: Vector3 = sg[0]
		var b: Vector3 = sg[1]
		var delta = b - a
		var basis = Basis(Quaternion(Vector3.UP, delta.normalized())) * Basis.from_scale(Vector3(1, delta.length() + 0.12, 1))
		mm.set_instance_transform(i, Transform3D(basis, (a + b) / 2.0))
		mm.set_instance_color(i, sg[2].darkened(0.55))
		i += 1
	_item_spacing = maxf(4.0, total / 2500.0)
	var count = 0
	for path in paths:
		path["first"] = count
		path["n"] = int(path["cum"][path["cum"].size() - 1] / _item_spacing) if path.get("flow", true) else 0
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
	# Bob: slow breathing, a nod now and then, the wrench ticking in his hand
	_bob_body.position.y = sin(_t * 1.2) * 0.015
	_bob_head.rotation.x = 0.06 + sin(_t * 0.7) * 0.05
	_bob_wrench.rotation.z = PI + sin(_t * 2.1) * 0.08    # hanging down, swinging a little
	_bob_wrench.rotation.x = -0.17                          # upright, against his stoop
	if player != null:
		var bd = player.global_position - _bob.global_position
		var bwant = atan2(bd.x, bd.z) if bd.length() < 30.0 else 0.0
		_bob.rotation.y = lerp_angle(_bob.rotation.y, bwant, clampf(delta * 2.5, 0.0, 1.0))
		# walk up to him and he has something to say: a fresh zinger every few seconds
		var near = bd.length() < 9.0
		_bob_say_t -= delta
		if near and (not _bob_near or _bob_say_t <= 0.0):
			_bob_tag.text = "\"%s\"\n\nBOB  ·  [E] fix list" % K.bob_line(_bob_jobs > 0)
			_bob_say_t = 7.0
		elif not near and _bob_near:
			_bob_tag.text = "BOB\n[E] fix list"
		_bob_near = near
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
			var pos = pts[seg - 1].lerp(pts[seg], clampf(f, 0.0, 1.0))
			var basis = Basis.IDENTITY
			var d: Vector3 = pts[seg] - pts[seg - 1]
			if d.length_squared() > 0.0001:
				basis = Basis(Quaternion(Vector3.UP, d.normalized()))
			if path.get("kind") == "Files":
				basis *= Basis.from_scale(Vector3(1.35, 1.8, 1.35))
			mm.set_instance_transform(path["first"] + k, Transform3D(basis, pos))

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
