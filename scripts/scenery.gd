extends RefCounted
# The industrial surroundings the Enhanced and Ultra presets add to the yard.
# Purely decorative: no collisions, nothing interactive, nothing the game logic
# knows about. Everything repeated is a MultiMesh (one draw per kind of part).
#
#   detail 1 (Enhanced)  concrete walkways, lit lamp posts, a perimeter fence,
#                        container stacks, storage tanks, pipe racks
#   detail 2 (Ultra)     all of that plus the far skyline (cooling towers with
#                        steam, striped smokestacks, factory halls, pylons), a
#                        gantry crane and low ground haze

const Tex = preload("res://scripts/tex.gd")

# rows of [Transform3D, Color] per kind of part, turned into MultiMeshes at the end
var _sets = {}
var _root: Node3D

static func build(detail: int) -> Node3D:
	var s = new()
	s._root = Node3D.new()
	s._root.name = "Scenery"
	if detail >= 1:
		s._enhanced()
	if detail >= 2:
		s._ultra()
	s._flush(detail)
	return s._root

func _tint(rough: float, metal: float = 0.0, tex: Texture2D = null, tri: float = 0.0, normal: Texture2D = null) -> StandardMaterial3D:
	var m = Tex.mat(Color.WHITE, rough, metal, tex, tri, normal)
	m.vertex_color_use_as_albedo = true
	return m

func _kind(key: String, mesh: PrimitiveMesh, material: Material, shadows: bool = true, lod_end: float = 0.0) -> void:
	if not _sets.has(key):
		mesh.material = material
		_sets[key] = {"mesh": mesh, "rows": [], "shadows": shadows, "lod": lod_end}

func _put(key: String, pos: Vector3, size: Vector3 = Vector3.ONE, col: Color = Color.WHITE, rot: Vector3 = Vector3.ZERO) -> void:
	_sets[key]["rows"].append([Transform3D(Basis.from_euler(rot) * Basis.from_scale(size), pos), col])

func _flush(detail: int) -> void:
	for key in _sets:
		var st = _sets[key]
		if st["rows"].is_empty():
			continue
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = st["mesh"]
		mm.instance_count = st["rows"].size()
		for i in st["rows"].size():
			mm.set_instance_transform(i, st["rows"][i][0])
			mm.set_instance_color(i, st["rows"][i][1])
		var mi = MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if st["shadows"] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if st["lod"] > 0.0:
			mi.visibility_range_end = st["lod"] * (1.0 if detail < 2 else 1.5)
			mi.visibility_range_end_margin = 30.0
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_root.add_child(mi)

func _unit_box() -> BoxMesh:
	return BoxMesh.new()

func _unit_cyl(top: float = 1.0, segs: int = 16) -> CylinderMesh:
	var c = CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = 1.0
	c.height = 1.0
	c.radial_segments = segs
	c.rings = 1
	return c

# ---- Enhanced

func _enhanced() -> void:
	var steel_c = Color(0.55, 0.57, 0.6)
	var dark_c = Color(0.13, 0.14, 0.16)
	_kind("slab", _unit_box(), _tint(0.92, 0.0, Tex.foundation(), 0.125, Tex._cache["foundation_n"]), false)
	_kind("steel", _unit_box(), _tint(0.45, 0.75))
	_kind("steel_small", _unit_box(), _tint(0.45, 0.75), false, 260.0)
	_kind("pole", _unit_cyl(0.6, 8), _tint(0.45, 0.75))
	_kind("pipe", _unit_cyl(1.0, 10), _tint(0.4, 0.6))
	_kind("crate", _unit_box(), _tint(0.6, 0.3, Tex.panel(), 0.25, Tex._cache["panel_n"]))
	_kind("tank", _unit_cyl(1.0, 20), _tint(0.5, 0.5, Tex.panel(), 0.12, Tex._cache["panel_n"]))
	_kind("lamp", _unit_box(), Tex.glow(Color(1.0, 0.86, 0.62), 2.4), false)

	# concrete walkways: spawn to the platforms, and along the depot row
	# (worn, darker than the platform slabs, so the yard still reads as a gravel yard)
	var worn = Color(0.5, 0.48, 0.45)
	_put("slab", Vector3(0, 0.03, -12), Vector3(5.0, 0.06, 68.0), worn)
	_put("slab", Vector3(0, 0.03, -22), Vector3(96.0, 0.06, 3.6), worn)
	_put("slab", Vector3(0, 0.03, 12.5), Vector3(40.0, 0.06, 3.2), worn)

	# lamp posts along them, each with a warm light
	for p in [Vector3(-9, 0, 15), Vector3(9, 0, 15), Vector3(-9, 0, -10), Vector3(9, 0, -10), Vector3(-9, 0, -34), Vector3(9, 0, -34), Vector3(-40, 0, 12), Vector3(40, 0, 12)]:
		var inward = -signf(p.x)
		_put("pole", p + Vector3(0, 3.5, 0), Vector3(0.14, 7.0, 0.14), dark_c)
		_put("steel_small", p + Vector3(inward * 0.7, 6.9, 0), Vector3(1.6, 0.1, 0.12), dark_c)
		_put("steel_small", p + Vector3(inward * 1.35, 6.82, 0), Vector3(0.7, 0.14, 0.34), dark_c)
		_put("lamp", p + Vector3(inward * 1.35, 6.73, 0), Vector3(0.56, 0.05, 0.26))
		var l = OmniLight3D.new()
		l.position = p + Vector3(inward * 1.35, 6.4, 0)
		l.light_color = Color(1.0, 0.84, 0.6)
		l.light_energy = 2.2
		l.omni_range = 15.0
		l.omni_attenuation = 1.4
		l.distance_fade_enabled = true
		l.distance_fade_begin = 90.0
		l.distance_fade_length = 30.0
		_root.add_child(l)

	# perimeter fence round the yard: posts, two rails, and mesh panels as a thin band
	var x0 = 212.0
	var z_front = 46.0
	var z_back = -326.0
	var zl = z_front - z_back
	for i in int(2.0 * x0 / 8.0) + 1:
		var x = -x0 + i * 8.0
		if absf(x) > 12.0:     # the front gate
			_put("steel_small", Vector3(x, 1.3, z_front), Vector3(0.12, 2.6, 0.12), steel_c)
		_put("steel_small", Vector3(x, 1.3, z_back), Vector3(0.12, 2.6, 0.12), steel_c)
	for i in int(zl / 8.0) + 1:
		for sx in [-x0, x0]:
			_put("steel_small", Vector3(sx, 1.3, z_front - i * 8.0), Vector3(0.12, 2.6, 0.12), steel_c)
	for h in [0.5, 2.5]:
		for sx in [-1.0, 1.0]:
			_put("steel", Vector3(sx * x0, h, (z_front + z_back) / 2.0), Vector3(0.06, 0.08, zl), steel_c)
			_put("steel", Vector3(sx * (x0 + 12.0) / 2.0, h, z_front), Vector3(x0 - 12.0, 0.08, 0.06), steel_c)
		_put("steel", Vector3(0, h, z_back), Vector3(2.0 * x0, 0.08, 0.06), steel_c)
	for gx in [-12.0, 12.0]:   # gate posts in hazard yellow
		_put("steel", Vector3(gx, 1.8, z_front), Vector3(0.4, 3.6, 0.4), Color(0.96, 0.74, 0.1))

	# container stacks either side of the entrance
	var rng = RandomNumberGenerator.new()
	rng.seed = 404
	var paints = [Color(0.075, 0.6, 0.85), Color(0.85, 0.42, 0.18), Color(0.3, 0.68, 0.4), Color(0.8, 0.7, 0.2), Color(0.62, 0.2, 0.2), Color(0.45, 0.48, 0.52)]
	for side in [-1.0, 1.0]:
		for cx in 3:
			for cz in 2:
				for cy in (2 if (cx + cz) % 2 == 0 else 1):
					var at = Vector3(side * (52.0 + cx * 6.6), 1.3 + cy * 2.62, 26.0 + cz * 3.0)
					_put("crate", at, Vector3(6.1, 2.6, 2.45), paints[rng.randi() % paints.size()])
					_put("steel_small", at + Vector3(0, 1.31, 0), Vector3(6.14, 0.06, 2.49), dark_c)

	# storage tanks with a band, a dome and a ladder
	for i in 3:
		var at = Vector3(92.0 + i * 13.0, 0, 26.0)
		_put("tank", at + Vector3(0, 4.5, 0), Vector3(5.0, 9.0, 5.0), Color(0.82, 0.84, 0.86))
		_put("tank", at + Vector3(0, 6.3, 0), Vector3(5.06, 0.7, 5.06), Tex.ORANGE)
		_put("pole", at + Vector3(0, 9.6, 0), Vector3(5.0, 1.2, 5.0), Color(0.7, 0.72, 0.75))
		_put("steel_small", at + Vector3(0, 4.6, 5.08), Vector3(0.5, 9.2, 0.06), steel_c)

	# pipe racks along the front fence: H-frames carrying three lines
	for side in [-1.0, 1.0]:
		for i in 12:
			var x = side * (34.0 + i * 13.5)
			for fz in [38.6, 41.4]:
				_put("steel", Vector3(x, 2.6, fz), Vector3(0.22, 5.2, 0.22), dark_c)
			_put("steel", Vector3(x, 4.6, 40.0), Vector3(0.2, 0.2, 3.2), dark_c)
		var mid = side * (34.0 + 5.5 * 13.5)
		var lines = [[39.0, 0.32, steel_c], [40.0, 0.24, Tex.ORANGE.darkened(0.1)], [41.0, 0.32, Color(0.25, 0.42, 0.55)]]
		for ln in lines:
			_put("pipe", Vector3(mid, 4.7 + ln[1], ln[0]), Vector3(ln[1], 12.0 * 13.5, ln[1]), ln[2], Vector3(0, 0, PI / 2))

# ---- Ultra

func _ultra() -> void:
	var concrete = Color(0.62, 0.62, 0.6)
	var dark_c = Color(0.13, 0.14, 0.16)
	_kind("concrete", _unit_cyl(0.72, 24), _tint(0.9, 0.0, Tex.foundation(), 0.02, Tex._cache["foundation_n"]))
	_kind("concrete_top", _unit_cyl(1.12, 24), _tint(0.9, 0.0, Tex.foundation(), 0.02, Tex._cache["foundation_n"]))
	_kind("stack", _unit_cyl(0.62, 14), _tint(0.85))
	_kind("hall", _unit_box(), _tint(0.7, 0.3, Tex.panel(), 0.05, Tex._cache["panel_n"]))
	_kind("window", _unit_box(), Tex.glow(Color(1.0, 0.8, 0.5), 1.6), false)
	_kind("beacon", _unit_box(), Tex.glow(Color(1.0, 0.2, 0.15), 3.0), false)
	_kind("lattice", _unit_box(), _tint(0.5, 0.7))
	_kind("crane", _unit_box(), _tint(0.5, 0.2))

	# cooling towers, each breathing steam
	for t in [Vector3(-190, 0, -470), Vector3(-105, 0, -505), Vector3(175, 0, -485)]:
		_put("concrete", t + Vector3(0, 24, 0), Vector3(34.0, 48.0, 34.0), concrete)
		_put("concrete_top", t + Vector3(0, 60, 0), Vector3(24.5, 24.0, 24.5), concrete.darkened(0.05))
		_root.add_child(_steam(t + Vector3(0, 74, 0), 22.0, 26, 14.0))

	# striped smokestacks with a warning light
	for s in [Vector3(40, 0, -455), Vector3(72, 0, -462), Vector3(-270, 0, -430), Vector3(255, 0, -440)]:
		_put("stack", s + Vector3(0, 45, 0), Vector3(3.4, 90.0, 3.4), Color(0.78, 0.78, 0.76))
		for b in 3:
			_put("stack", s + Vector3(0, 66 + b * 9.0, 0), Vector3(2.75 - b * 0.16, 4.5, 2.75 - b * 0.16), Color(0.78, 0.16, 0.12))
		_put("beacon", s + Vector3(0, 90.6, 0), Vector3(1.2, 1.2, 1.2))
		_root.add_child(_steam(s + Vector3(0, 93, 0), 3.0, 14, 9.0))

	# factory halls with saw-tooth roofs and lit window bands
	for hrow in [[Vector3(-20, 0, -445), 150.0], [Vector3(120, 0, -520), 110.0], [Vector3(-240, 0, -500), 90.0]]:
		var c: Vector3 = hrow[0]
		var w: float = hrow[1]
		_put("hall", c + Vector3(0, 11, 0), Vector3(w, 22.0, 46.0), Color(0.42, 0.45, 0.5))
		_put("window", c + Vector3(0, 15, 23.05), Vector3(w * 0.9, 2.2, 0.1))
		_put("window", c + Vector3(0, 6, 23.05), Vector3(w * 0.9, 1.2, 0.1))
		for k in int(w / 15.0):
			_put("hall", c + Vector3(-w / 2.0 + 7.5 + k * 15.0, 24.5, 0), Vector3(10.6, 7.5, 46.0), Color(0.3, 0.32, 0.36), Vector3(0, 0, 0.6))

	# power pylons down the right-hand side, with their lines
	var prev = null
	for i in 5:
		var p = Vector3(262, 0, 10 - i * 85.0)
		for lx in [-1.0, 1.0]:
			for lz in [-1.0, 1.0]:
				_put("lattice", p + Vector3(lx * 2.0, 15, lz * 2.0), Vector3(0.35, 30.5, 0.35), dark_c, Vector3(lz * 0.09, 0, -lx * 0.09))
		_put("lattice", p + Vector3(0, 30.5, 0), Vector3(0.5, 9.0, 0.5), dark_c)
		for ay in [24.0, 29.0, 33.5]:
			_put("lattice", p + Vector3(0, ay, 0), Vector3(15.0 - (ay - 24.0) * 0.6, 0.3, 0.3), dark_c)
		if prev != null:
			for wx in [-7.0, 7.0]:
				_put("lattice", (p + prev) / 2.0 + Vector3(wx, 23.4, 0), Vector3(0.06, 0.06, 85.0), dark_c)
		prev = p

	# a gantry crane standing over the left-hand container stack
	var yellow = Color(0.96, 0.74, 0.1)
	var g = Vector3(-58.6, 0, 27.5)
	for gx in [-11.0, 11.0]:
		for gz in [-4.2, 4.2]:
			_put("crane", g + Vector3(gx, 6.5, gz), Vector3(0.5, 13.0, 0.5), yellow)
		_put("crane", g + Vector3(gx, 12.6, 0), Vector3(0.6, 0.8, 9.4), yellow)
	_put("crane", g + Vector3(0, 13.3, 0), Vector3(24.0, 1.0, 1.4), yellow)
	_put("crane", g + Vector3(3.0, 12.3, 0), Vector3(1.8, 1.0, 1.8), dark_c)
	_put("crane", g + Vector3(3.0, 9.6, 0), Vector3(0.06, 4.6, 0.06), dark_c)

	# low haze over the yard that catches the lamp light
	var fog = FogVolume.new()
	fog.size = Vector3(430, 5, 380)
	fog.position = Vector3(0, 2.0, -140)
	var fm = FogMaterial.new()
	fm.density = 0.0035
	fm.albedo = Color(0.92, 0.94, 1.0)
	fm.height_falloff = 0.4
	fog.material = fm
	_root.add_child(fog)

func _steam(at: Vector3, radius: float, amount: int, life: float) -> CPUParticles3D:
	var p = CPUParticles3D.new()
	p.position = at
	p.amount = amount
	p.lifetime = life
	p.preprocess = life
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = radius * 0.6
	p.direction = Vector3.UP
	p.spread = 12.0
	p.gravity = Vector3(2.2, 1.2, 0.6)
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 6.0
	p.scale_amount_min = radius * 0.5
	p.scale_amount_max = radius * 0.9
	var s = SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = 10
	s.rings = 5
	var m = Tex.ghost(Color.WHITE)
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_BACK
	s.material = m
	p.mesh = s
	var grad = Gradient.new()
	grad.set_color(0, Color(0.95, 0.96, 0.98, 0.0))
	grad.add_point(0.15, Color(0.95, 0.96, 0.98, 0.34))
	grad.set_color(grad.get_point_count() - 1, Color(0.92, 0.94, 0.97, 0.0))
	p.color_ramp = grad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-80, -10, -80), Vector3(200, 140, 160))
	return p
