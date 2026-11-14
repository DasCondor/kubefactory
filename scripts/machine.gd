extends Node3D
# One pod = one factory machine. Containers are the tanks bolted to its side.

const K = preload("res://scripts/kutil.gd")
const Tex = preload("res://scripts/tex.gd")
const Sfx = preload("res://scripts/sfx.gd")

const Gfx = preload("res://scripts/gfx.gd")
const Models = preload("res://scripts/models.gd")

static var _m = {}
static var _merged = {}   # workload colour + detail level -> [core mesh, extra-detail mesh or null]

var uid = ""
var pod = {}
var slot = -1
var removing = false

var _fan: Node3D
var _beacon: MeshInstance3D
var _screen: MeshInstance3D
var _label: Label3D
var _sub: Label3D
var _smoke: CPUParticles3D
var _tanks = []
var _alarm: Node3D
var _siren: AudioStreamPlayer3D
var _warn: Label3D
var _health = ""
var _t = 0.0
# library model state
var model_id = ""           # "" = the code-drawn machine
var _tpl = {}
var _body: Node3D = null
var _door: Node3D = null
var _door_body: AnimatableBody3D = null
var _door_want = 0.0
var _door_tween: Tween = null
var _interior: Node3D = null
var _bays = []
var _tank_x = 2.62
var _top = 4.0
var _live = false
var _live_mat: StandardMaterial3D = null
var _name_plate: Label3D = null     # the model's resource-name display
var _list_plate: Label3D = null     # the model's container list display
var _screen_quad: MeshInstance3D = null   # code-drawn machines: where a picture goes, over the screen box
var _status_plate: Label3D = null   # the pod's state, on the LiveView glass while it shows no page

static func _box(key: String, size: Vector3) -> BoxMesh:
	if not _m.has(key):
		var b = BoxMesh.new()
		b.size = size
		_m[key] = b
	return _m[key]

static func _cyl(key: String, r: float, h: float) -> CylinderMesh:
	if not _m.has(key):
		var c = CylinderMesh.new()
		c.top_radius = r
		c.bottom_radius = r
		c.height = h
		c.radial_segments = 16
		_m[key] = c
	return _m[key]

# ---- the fixed parts of a machine, as [mesh, material, position, rotation] rows

# The machine as it has always looked (the Standard preset, and the base of the others).
static func _core_parts() -> Array:
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	var z = Vector3.ZERO
	var parts = [
		[_box("base", Vector3(5.6, 0.4, 5.6)), dark, Vector3(0, 0.2, 0), z],
		[_box("band", Vector3(4.5, 0.45, 4.5)), dark, Vector3(0, 0.95, 0), z],
		[_box("lip", Vector3(4.6, 0.2, 4.6)), Tex.shared("orange"), Vector3(0, 3.45, 0), z],
		[_box("roof", Vector3(2.6, 0.8, 2.6)), dark, Vector3(-0.5, 3.9, 0.3), z],
		[_cyl("chimney", 0.42, 2.4), steel, Vector3(1.35, 4.6, -1.35), z],
		[_cyl("chimney_cap", 0.52, 0.25), dark, Vector3(1.35, 5.75, -1.35), z],
		[_cyl("rotor_ring", 1.15, 0.25), dark, Vector3(-0.85, 2.0, 2.25), Vector3(PI / 2, 0, 0)],
		[_box("screen_frame", Vector3(1.5, 1.1, 0.12)), dark, Vector3(1.2, 2.2, 2.22), z],
		[_cyl("pole", 0.06, 1.3), steel, Vector3(-1.7, 4.2, 1.7), z]]
	if not OS.has_feature("web"):   # the browser build has a tight draw budget (see main.gd)
		# side vents, a feed pipe along the back, hazard kick-plate, a lamp over the screen
		for vz in [-1.2, 0.0, 1.2]:
			parts.append([_box("vent", Vector3(0.08, 0.7, 0.8)), dark, Vector3(-2.22, 2.3, vz), z])
			for vy in [2.1, 2.3, 2.5]:
				parts.append([_box("slit", Vector3(0.1, 0.06, 0.66)), steel, Vector3(-2.24, vy, vz), z])
		parts.append([_cyl("pipe", 0.16, 4.6), steel, Vector3(0, 2.9, -2.36), Vector3(0, 0, PI / 2)])
		for px in [-2.2, 2.2]:
			parts.append([_cyl("pipe_down", 0.16, 2.6), steel, Vector3(px, 1.65, -2.36), z])
		parts.append([_box("kick", Vector3(5.62, 0.14, 0.06)), Tex.shared("hazard"), Vector3(0, 0.33, 2.81), z])
		parts.append([_box("lamp_bar", Vector3(1.6, 0.08, 0.08)), Tex.glow(Color(1.0, 0.85, 0.6), 1.2), Vector3(0.2, 3.3, 2.24), z])
	return parts

# What the Enhanced (lod 1) and Ultra (lod 2) presets bolt on. Nothing here
# replaces a core part: it is all added on top of the classic machine.
static func _detail_parts(lod: int) -> Array:
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	var z = Vector3.ZERO
	var parts = []
	# a steel frame on the body's corners, bolted to the base
	for cx in [-2.22, 2.22]:
		for cz in [-2.22, 2.22]:
			parts.append([_box("corner", Vector3(0.14, 3.0, 0.14)), steel, Vector3(cx, 1.9, cz), z])
			parts.append([_box("foot", Vector3(0.34, 0.1, 0.34)), steel, Vector3(cx * 1.14, 0.45, cz * 1.14), z])
	# roof: a cooling unit with a grille, and a cable tray along the front
	parts.append([_box("ac", Vector3(1.0, 0.5, 1.2)), dark, Vector3(1.45, 3.8, 0.95), z])
	for g in 4:
		parts.append([_box("ac_slat", Vector3(0.84, 0.04, 0.12)), steel, Vector3(1.45, 4.07, 0.55 + g * 0.27), z])
	parts.append([_box("tray", Vector3(4.4, 0.07, 0.1)), dark, Vector3(0, 3.08, 2.25), z])
	# a service ladder up the back, a warning plate and a step under the screen
	for lx in [-1.62, -1.12]:
		parts.append([_box("rail", Vector3(0.05, 3.3, 0.05)), steel, Vector3(lx, 1.95, -2.27), z])
	for r in 7:
		parts.append([_box("rung", Vector3(0.5, 0.04, 0.04)), steel, Vector3(-1.37, 0.7 + r * 0.42, -2.27), z])
	parts.append([_box("plate", Vector3(0.7, 0.34, 0.03)), Tex.shared("hazard"), Vector3(1.2, 1.38, 2.215), z])
	parts.append([_box("step", Vector3(1.9, 0.08, 0.5)), steel, Vector3(1.2, 0.44, 2.55), z])
	# rivet rows across the body, front and back
	for ry in [1.3, 3.2]:
		for i in 9:
			for rz in [-2.215, 2.215]:
				parts.append([_box("rivet", Vector3(0.07, 0.07, 0.03)), steel, Vector3(-2.0 + i * 0.5, ry, rz), z])
	if lod >= 2:
		# gauges, a second pipe run and a mast (the lit base strip is added per workload colour)
		var face = Tex.glow(Color(0.9, 0.95, 1.0), 0.5)
		for gx in [-0.5, 0.0, 0.5]:
			parts.append([_cyl("gauge", 0.13, 0.06), dark, Vector3(1.2 + gx, 1.75, -2.24), Vector3(PI / 2, 0, 0)])
			parts.append([_cyl("gauge_face", 0.1, 0.07), face, Vector3(1.2 + gx, 1.75, -2.25), Vector3(PI / 2, 0, 0)])
		parts.append([_cyl("pipe_thin", 0.09, 4.5), steel, Vector3(-2.33, 1.25, 0), Vector3(PI / 2, 0, 0)])
		for pz in [-2.0, 0.0, 2.0]:
			parts.append([_box("clamp", Vector3(0.24, 0.24, 0.08)), dark, Vector3(-2.33, 1.25, pz), z])
		parts.append([_cyl("mast", 0.025, 1.6), steel, Vector3(-1.2, 5.1, -0.4), z])
		parts.append([_box("mast_tip", Vector3(0.08, 0.08, 0.08)), Tex.glow(Color(1.0, 0.3, 0.25), 2.0), Vector3(-1.2, 5.92, -0.4), z])
		for hx in [-1.5, -0.9]:
			parts.append([_box("hinge", Vector3(0.1, 0.5, 0.06)), steel, Vector3(hx, 2.2, -2.23), z])
	return parts

# Bake a list of parts into one ArrayMesh with a surface per material.
static func _merge(parts: Array) -> ArrayMesh:
	var by_mat = {}
	for p in parts:
		if not by_mat.has(p[1]):
			by_mat[p[1]] = SurfaceTool.new()
		by_mat[p[1]].append_from(p[0], 0, Transform3D(Basis.from_euler(p[3]), p[2]))
	var mesh = ArrayMesh.new()
	for mat in by_mat:
		by_mat[mat].commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh

func _add(mesh: Mesh, material: Material, pos: Vector3, parent: Node3D = self) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	parent.add_child(mi)
	return mi

func setup(p: Dictionary) -> void:
	uid = p["uid"]
	var sb = StaticBody3D.new()
	sb.set_meta("kf", {"type": "pod", "uid": uid})
	var cs = CollisionShape3D.new()
	var sh = BoxShape3D.new()
	sh.size = Vector3(5.4, 4.4, 5.4)
	cs.shape = sh
	cs.position.y = 2.2
	sb.add_child(cs)
	add_child(sb)

	var wkey = p["ns"] + "/" + p["wname"]
	var col = K.hue_color(wkey, 0.5, 0.9) if p["wname"] != "" else Color(0.75, 0.76, 0.78)
	# On the desktop the machine is a model from the library, chosen by what the
	# pod is; the browser build (and any missing model) keeps the code-drawn one.
	if not _build_model(p, col):
		_build_classic(col)
	_finish_setup(p)

# ---- a machine from the model library

const MODEL_SCALE = 1.9      # library machines are ~2 m cabinets; the factory's slots are built for ~4 m
const DOOR_OPEN = deg_to_rad(105.0)

func _build_model(p: Dictionary, col: Color) -> bool:
	if not Models.available():
		return false
	var id = Models.machine_for(p)
	var tpl = Models.template(id)
	if tpl.is_empty() or tpl.get("core") == null:
		return false
	model_id = id
	_tpl = tpl
	_body = Node3D.new()
	_body.scale = Vector3.ONE * MODEL_SCALE
	add_child(_body)
	var core = MeshInstance3D.new()
	core.mesh = tpl["core"]
	_body.add_child(core)
	if tpl.get("accent") != null:
		# the armour takes the workload's colour, as machine bodies always have
		var am = MeshInstance3D.new()
		am.mesh = tpl["accent"]
		am.material_override = Tex.accent(col)
		_body.add_child(am)
	_beacon = MeshInstance3D.new()
	if tpl.get("lamp") != null:
		_beacon.mesh = tpl["lamp"]
	_beacon.material_override = Tex.status_glow("warn")
	_body.add_child(_beacon)
	# the service door, on its own pivot along the hinge line
	var screen_parent: Node3D = _body
	var screen_off = Vector3.ZERO
	if tpl.has("door"):
		var d = tpl["door"]
		_door = Node3D.new()
		_door.position = d["hinge"]
		_body.add_child(_door)
		var dm = MeshInstance3D.new()
		dm.mesh = tpl["door_mesh"]
		_door.add_child(dm)
		# the accent-coloured panels of the leaf keep the workload colour too
		for s in dm.mesh.get_surface_count():
			var m = dm.mesh.surface_get_material(s)
			if m != null and tpl.get("accent") != null and m == tpl["accent"].surface_get_material(0):
				dm.set_surface_override_material(s, Tex.accent(col))
		# collision proxy for the leaf: moves with the pivot, so an open door is solid where it now is
		var body = AnimatableBody3D.new()
		body.sync_to_physics = false
		var cs = CollisionShape3D.new()
		var sh = BoxShape3D.new()
		var a: AABB = d["aabb"]
		sh.size = Vector3(a.size.x, a.size.y, maxf(a.size.z, 0.06))
		cs.shape = sh
		cs.position = a.get_center() - d["hinge"]
		body.add_child(cs)
		body.set_meta("kf", {"type": "pod", "uid": uid})
		_door.add_child(body)
		_door_body = body
		_interior = Node3D.new()
		_interior.visible = false      # nothing inside is drawn while the door is shut
		_body.add_child(_interior)
		_build_interior(tpl["cavity"], d["side"])
		if tpl.has("screen") and tpl["screen"].get("on_door", false):
			screen_parent = _door
			screen_off = -d["hinge"]
	# the LiveView surface: its own quad over the model's glass
	if tpl.has("screen"):
		var sc = tpl["screen"]
		var q = QuadMesh.new()
		q.size = sc["size"]
		_screen = MeshInstance3D.new()
		_screen.mesh = q
		_screen.position = sc["pos"] + screen_off
		_screen.visible = false     # the glass stays neutral until a real page is on it: health never tints it
		_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_screen.name = "LiveViewSurface"
		screen_parent.add_child(_screen)
	else:
		_screen = MeshInstance3D.new()
		_body.add_child(_screen)
	# the model's other displays carry real data: this pod's name, its containers
	_name_plate = _plate(tpl.get("name_surface"), Color(0.86, 0.95, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	_list_plate = _plate(tpl.get("list_surface"), Color(0.8, 0.92, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	# (the type plate is lettered in the model itself)
	# the pod's state as one small line on the LiveView glass while no page is shown
	_status_plate = _plate(tpl.get("screen"), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_fan = Node3D.new()
	add_child(_fan)
	var b: AABB = tpl["bounds"]
	_tank_x = b.end.x * MODEL_SCALE + 0.5
	_top = b.end.y * MODEL_SCALE
	return true

# A text display lying on one of the model's glass surfaces (null if it has none).
func _plate(surface, col: Color, align: int) -> Label3D:
	if surface == null:
		return null
	var l = Label3D.new()
	l.font_size = 40
	l.modulate = col
	l.outline_size = 0
	l.horizontal_alignment = align
	l.position = surface["pos"]
	l.set_meta("size", surface["size"])
	l.visibility_range_end = 45.0
	_body.add_child(l)
	return l

func _plate_text(l: Label3D, text: String) -> void:
	if l == null or l.text == text:
		return
	l.text = text
	var sz: Vector2 = l.get_meta("size")
	K.fit_label(l, sz.x * 0.92, sz.y * 0.8, 0.0022)

# Shelves and storage bays behind the door. The bays stay empty until the pod's
# real volume mounts are known (set_modules), so nothing inside is invented.
func _build_interior(cav: AABB, side: int) -> void:
	var steel = Tex.shared("steel")
	var dark = Tex.shared("dark")
	_bays.clear()
	# as many columns as the bay is wide, rows as it is tall (modules about 0.4 m wide, 0.22 m high)
	var cols = clampi(int(round(cav.size.x / 0.42)), 2, 5)
	var rows = clampi(int(round(cav.size.y / 0.24)), 1, 4)
	var cw = cav.size.x / cols
	var rh = cav.size.y / rows
	for r in rows:
		# a shelf under each row, set back from the opening
		_add(_box("m_shelf_%d_%d" % [int(cav.size.x * 100), int(cav.size.z * 100)], Vector3(cav.size.x, 0.02, cav.size.z * 0.9)), steel,
			Vector3(cav.get_center().x, cav.position.y + r * rh + 0.01, cav.get_center().z), _interior)
		for c in cols:
			var at = Vector3(cav.position.x + (c + 0.5) * cw, cav.position.y + r * rh + rh * 0.5 + 0.01, cav.get_center().z - side * cav.size.z * 0.08)
			_bays.append({"at": at, "size": Vector3(cw * 0.82, rh * 0.74, cav.size.z * 0.62), "node": null})
	# a dim work light at the top of the bay, only lit while the door is open
	_add(_box("m_bay_light", Vector3(cav.size.x * 0.6, 0.012, 0.03)), Tex.glow(Color(1.0, 0.93, 0.8), 1.4),
		Vector3(cav.get_center().x, cav.end.y - 0.03, cav.get_center().z + side * cav.size.z * 0.3), _interior)
	_add(_box("m_bay_back_%d" % int(cav.size.x * 100), Vector3(cav.size.x * 0.96, cav.size.y * 0.96, 0.01)), dark,
		Vector3(cav.get_center().x, cav.get_center().y, cav.get_center().z - side * (cav.size.z / 2.0 - 0.012)), _interior)

# One storage module per real volume mount: [{path, type, claim, readable, read_only}]
func set_modules(mounts: Array) -> void:
	if _interior == null:
		return
	for bay in _bays:
		if bay["node"] != null:
			bay["node"].queue_free()
			bay["node"] = null
	var colors = {"pvc": Color(0.72, 0.5, 1.0), "configmap": Color(0.3, 0.85, 1.0), "secret": Color(1.0, 0.35, 0.3), "projected": Color(1.0, 0.35, 0.3),
		"emptydir": Color(0.75, 0.78, 0.8), "hostpath": Color(1.0, 0.75, 0.2), "bind": Color(1.0, 0.75, 0.2), "volume": Color(0.72, 0.5, 1.0)}
	for i in mini(mounts.size(), _bays.size()):
		var bay = _bays[i]
		var m = mounts[i]
		var n = Node3D.new()
		n.position = bay["at"]
		_interior.add_child(n)
		var sz: Vector3 = bay["size"]
		_add(_box("m_mod_%d_%d_%d" % [int(sz.x * 100), int(sz.y * 100), int(sz.z * 100)], sz), Tex.shared("dark"), Vector3.ZERO, n)
		var side = float(_tpl["door"]["side"])
		var face = side * (sz.z / 2.0 + 0.004)
		_add(_box("m_mod_strip_%d" % int(sz.x * 100), Vector3(sz.x * 0.86, 0.02, 0.008)), Tex.glow(colors.get(str(m.get("type", "")), Color(0.8, 0.8, 0.8)), 1.6), Vector3(0, sz.y * 0.32, face), n)
		_add(_box("m_mod_handle_%d" % int(sz.x * 100), Vector3(sz.x * 0.3, 0.025, 0.03)), Tex.shared("steel"), Vector3(0, -sz.y * 0.2, face + side * 0.012), n)
		var l = Label3D.new()
		l.text = "%s\n%s" % [str(m.get("path", "")), str(m.get("claim", "")) if str(m.get("claim", "")) != "" else str(m.get("type", ""))]
		l.font_size = 20
		l.pixel_size = 0.0011
		l.position = Vector3(0, 0.02, face + side * 0.004)
		l.rotation.y = 0.0 if side > 0 else PI
		l.modulate = Color(0.85, 0.88, 0.92)
		l.width = sz.x * 0.86 / 0.0011
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		n.add_child(l)
		bay["node"] = n

# Where to stand to look into the open door, as [position, look-at].
func door_view() -> Array:
	if _door == null:
		return []
	var d = _tpl["door"]
	var g = _body.global_transform
	var centre = g * d["aabb"].get_center()
	var out = (g.basis * d["out"]).normalized()
	var along = (g.basis * d["along"]).normalized()
	var screen_right = (-out).cross(Vector3.UP).normalized()
	# stand on the side the leaf does not swing to, close enough to stay clear of the
	# next row, and look past the opening so it sits left of the storage panel
	return [centre + out * (2.4 + d["width"] * MODEL_SCALE * 0.6) + along * 0.9 + Vector3(0, -centre.y + 0.25, 0), centre + screen_right * 2.3]

func has_door() -> bool:
	return _door != null

func door_open() -> bool:
	return _door_want > 0.0

# Open or shut the service door. It swings out on its hinge up to its stop, and
# no further than whoever is standing in its path: `blocker` is a world position
# (the player) the leaf must not sweep through.
func set_door(open: bool, blocker = null) -> float:
	if _door == null:
		return 0.0
	var limit = DOOR_OPEN
	if open and blocker != null:
		var d = _tpl["door"]
		var local = _door.get_parent().to_local(blocker) - d["hinge"]     # model units, relative to the hinge
		var dist = Vector2(local.x, local.z).length()
		var reach = float(d["width"]) + 0.45 / MODEL_SCALE
		if dist < reach and absf(local.y) < 1.4:
			# angle of the blocker round the hinge, measured the way the leaf swings
			var ang = atan2(local.dot(d["out"]), local.dot(d["along"]))
			if ang > 0.0:
				limit = clampf(ang - asin(clampf((0.5 / MODEL_SCALE) / maxf(dist, 0.3), 0.0, 1.0)), 0.0, DOOR_OPEN)
	_door_want = limit if open else 0.0
	if open:
		_interior.visible = true
	if _door_tween != null:
		_door_tween.kill()
	_door_tween = create_tween()
	_door_tween.tween_property(_door, "rotation:y", _door_want, 0.55 if open else 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if not open:
		_door_tween.tween_callback(func(): _interior.visible = false)
	return _door_want

# Show a live texture on the machine's screen (LiveView), or go back to the status colour.
func set_screen_texture(tex: Texture2D) -> void:
	if _screen == null or _screen.mesh == null:
		return
	if model_id == "":
		if _screen_quad == null:
			if tex == null:
				return
			var q = QuadMesh.new()
			q.size = Vector2(1.26, 0.86)
			_screen_quad = MeshInstance3D.new()
			_screen_quad.mesh = q
			_screen_quad.position = _screen.position + Vector3(0, 0, 0.034)
			_screen_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_screen.get_parent().add_child(_screen_quad)
		_screen_quad.visible = tex != null
		if tex != null:
			if _live_mat == null:
				_live_mat = StandardMaterial3D.new()
				_live_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_live_mat.albedo_texture = tex
			_screen_quad.material_override = _live_mat
		return
	if tex == null:
		_live = false
		if model_id != "":
			_screen.visible = false
			if _status_plate != null:
				_status_plate.visible = true
		else:
			_screen.material_override = Tex.status_glow(_health if _health != "" else "warn")
		return
	if not _live or _live_mat == null:
		_live_mat = StandardMaterial3D.new()
		_live_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_live_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_live_mat.albedo_texture = tex
	_screen.material_override = _live_mat
	_screen.visible = true
	if _status_plate != null:
		_status_plate.visible = false
	_live = true

# Where the screen is in the world and how big, for aiming at it: {pos, right, up, size}
func screen_rect() -> Dictionary:
	if _screen == null or not (_screen.mesh is QuadMesh):
		return {}
	var g = _screen.global_transform
	return {"pos": g.origin, "right": g.basis.x.normalized(), "up": g.basis.y.normalized(),
		"size": _screen.mesh.size * g.basis.get_scale().x, "normal": g.basis.z.normalized()}

# ---- the code-drawn machine (the browser build, and the fallback)

func _build_classic(col: Color) -> void:
	# Everything on a machine that never moves is merged into one mesh (a surface
	# per material) and shared by every machine of the same workload, so a machine
	# costs a handful of draws instead of dozens. The extra detail of the Enhanced
	# and Ultra presets is a second merged mesh that drops out at a distance.
	# Only the body carries the workload's colour, so everything else is one mesh
	# shared by every machine in the world: the renderer draws all of them as
	# instances of it.
	var lod = Gfx.detail()
	var key = "%d:%s" % [lod, OS.has_feature("web")]
	if not _merged.has(key):
		_merged[key] = [_merge(_core_parts()), _merge(_detail_parts(lod)) if lod > 0 else null]
	var core = MeshInstance3D.new()
	core.mesh = _merged[key][0]
	add_child(core)
	_add(_box("body", Vector3(4.4, 3.0, 4.4)), Tex.body(col), Vector3(0, 1.9, 0))
	if _merged[key][1] != null:
		var extra = MeshInstance3D.new()
		extra.mesh = _merged[key][1]
		extra.visibility_range_end = 130.0
		extra.visibility_range_end_margin = 20.0
		extra.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		extra.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(extra)
	if lod >= 2:
		# a lit strip round the base in the workload's colour
		var skey = "strip:" + col.to_html(false)
		if not _merged.has(skey):
			var strip = Tex.glow(col.lightened(0.15), 1.1)
			var rows = []
			for s in [-1.0, 1.0]:
				rows.append([_box("strip_x", Vector3(5.5, 0.05, 0.05)), strip, Vector3(0, 0.43, 2.79 * s), Vector3.ZERO])
				rows.append([_box("strip_z", Vector3(0.05, 0.05, 5.5)), strip, Vector3(2.79 * s, 0.43, 0), Vector3.ZERO])
			_merged[skey] = _merge(rows)
		var sm = MeshInstance3D.new()
		sm.mesh = _merged[skey]
		sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sm.visibility_range_end = 220.0
		add_child(sm)
	if Gfx.occlusion():
		# the solid body hides whatever stands behind it from the renderer
		var occ = OccluderInstance3D.new()
		if not _m.has("occluder"):
			var bo = BoxOccluder3D.new()
			bo.size = Vector3(4.3, 3.2, 4.3)
			_m["occluder"] = bo
		occ.occluder = _m["occluder"]
		occ.position = Vector3(0, 1.8, 0)
		add_child(occ)

	# Front face (+Z): spinning rotor and a status screen (these change, so they stay separate)
	_fan = Node3D.new()
	_fan.position = Vector3(-0.85, 2.0, 2.42)
	add_child(_fan)
	for i in 3:
		var blade = _add(_box("blade", Vector3(1.9, 0.26, 0.08)), Tex.shared("steel"), Vector3.ZERO, _fan)
		blade.rotation.z = i * PI / 3.0
	_screen = _add(_box("screen", Vector3(1.3, 0.9, 0.06)), Tex.status_glow("warn"), Vector3(1.2, 2.2, 2.29))
	if not _m.has("bulb"):
		var s = SphereMesh.new()
		s.radius = 0.3
		s.height = 0.6
		_m["bulb"] = s
	_beacon = _add(_m["bulb"], Tex.status_glow("warn"), Vector3(-1.7, 4.95, 1.7))

func _finish_setup(p: Dictionary) -> void:
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 44
	_label.pixel_size = 0.0075
	_label.outline_size = 10
	_label.position = Vector3(0, 7.1, 0)
	_label.visibility_range_end = 90.0
	add_child(_label)
	_sub = Label3D.new()
	_sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sub.font_size = 34
	_sub.pixel_size = 0.0075
	_sub.outline_size = 8
	_sub.position = Vector3(0, 6.55, 0)
	_sub.visibility_range_end = 60.0
	add_child(_sub)

	_smoke = CPUParticles3D.new()
	_smoke.position = Vector3(1.35, 5.9, -1.35)
	_smoke.amount = 10
	_smoke.lifetime = 2.6
	_smoke.direction = Vector3.UP
	_smoke.spread = 10.0
	_smoke.gravity = Vector3(0.5, 0.3, 0)
	_smoke.initial_velocity_min = 1.0
	_smoke.initial_velocity_max = 1.7
	_smoke.scale_amount_min = 0.6
	_smoke.scale_amount_max = 1.3
	if not _m.has("puff"):
		var s = SphereMesh.new()
		s.radius = 0.4
		s.height = 0.8
		s.radial_segments = 8
		s.rings = 4
		var pm = Tex.ghost(Color.WHITE)
		pm.vertex_color_use_as_albedo = true
		s.material = pm
		_m["puff"] = s
		var g = Gradient.new()
		g.set_color(0, Color(0.85, 0.87, 0.9, 0.5))
		g.set_color(1, Color(0.85, 0.87, 0.9, 0.0))
		_m["ramp"] = g
	_smoke.mesh = _m["puff"]
	_smoke.color_ramp = _m["ramp"]
	_smoke.emitting = false
	add_child(_smoke)
	if model_id != "":
		# library machines have no chimney: their exhaust is the rear vents
		_smoke.position = Vector3(0.0, _top * 0.72, -_tpl["bounds"].size.z * MODEL_SCALE * 0.5 - 0.3)
		_smoke.amount = 6
		_smoke.scale_amount_min = 0.3
		_smoke.scale_amount_max = 0.7
		_smoke.gravity = Vector3(0.2, 0.5, -0.6)
		_label.position.y = _top + 2.0
		_sub.position.y = _top + 1.45

	# Alarm: a red light column + warning sign, visible from across the factory.
	if not _m.has("beam"):
		var bm = Tex.ghost(Color(1.0, 0.12, 0.08, 0.22))
		bm.emission_enabled = true
		bm.emission = Color(1.0, 0.1, 0.05)
		bm.emission_energy_multiplier = 2.0
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_m["beam_mat"] = bm
		var cm = CylinderMesh.new()
		cm.top_radius = 0.5
		cm.bottom_radius = 0.9
		cm.height = 60.0
		cm.radial_segments = 12
		cm.cap_top = false
		cm.cap_bottom = false
		_m["beam"] = cm
	_alarm = Node3D.new()
	_alarm.visible = false
	add_child(_alarm)
	_add(_m["beam"], _m["beam_mat"], Vector3(0, 36.0, 0), _alarm).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lamp = OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.15, 0.08)
	lamp.light_energy = 4.0
	lamp.omni_range = 16.0
	lamp.position = Vector3(0, 6.0, 0)
	_alarm.add_child(lamp)
	Sfx.build_streams()
	_siren = AudioStreamPlayer3D.new()
	_siren.stream = Sfx.streams["alarm"]
	_siren.volume_db = -14.0
	_siren.unit_size = 5.0
	_siren.max_distance = 60.0
	_siren.position = Vector3(0, 5.0, 0)
	add_child(_siren)
	_warn = Label3D.new()
	_warn.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_warn.font_size = 64
	_warn.pixel_size = 0.01
	_warn.outline_size = 14
	_warn.modulate = Color(1.0, 0.3, 0.22)
	_warn.position = Vector3(0, 8.3, 0)
	_warn.visibility_range_end = 220.0
	_alarm.add_child(_warn)

	update(p)
	# "Build" animation: rise out of the foundation.
	scale = Vector3(1, 0.02, 1)
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector3.ONE, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func update(p: Dictionary) -> void:
	pod = p
	_label.text = p["name"]
	var line = p["status"]
	if p["restarts"] > 0:
		line += "  ·  %d restarts" % p["restarts"]
	_sub.text = line
	var h = p["health"]
	_sub.modulate = K.health_color(h)
	if h != _health:
		_health = h
		if not _live and model_id == "":
			_screen.material_override = Tex.status_glow(h)
		_beacon.material_override = Tex.status_glow(h)
		_smoke.emitting = h == "ok"
		_alarm.visible = h == "bad"
		if h == "bad" and not _siren.playing:
			_siren.play(randf())
		elif h != "bad" and _siren.playing:
			_siren.stop()
	_warn.text = "!  " + p["status"]
	var conts = p["containers"]
	_plate_text(_name_plate, str(p["name"]))
	if _status_plate != null:
		_plate_text(_status_plate, str(p["status"]))
		_status_plate.pixel_size = minf(_status_plate.pixel_size, 0.0014)
		_status_plate.modulate = K.health_color(h)
	if _list_plate != null:
		var rows = PackedStringArray()
		for i in mini(conts.size(), 6):
			var c = conts[i]
			rows.append("%s   %s" % [str(c["name"]), str(c["state"]) if str(c.get("reason", "")) == "" else str(c["reason"])])
		if conts.size() > 6:
			rows.append("+ %d more" % (conts.size() - 6))
		_plate_text(_list_plate, "\n".join(rows))
	# Container tanks along the +X side
	var want = mini(conts.size(), 4)
	while _tanks.size() < want:
		var i = _tanks.size()
		var z = -1.5 + i * 1.05
		_add(_cyl("tank", 0.42, 2.2), Tex.shared("steel"), Vector3(_tank_x, 1.5, z))
		var ring = _add(_cyl("tank_ring", 0.46, 0.22), Tex.status_glow("warn"), Vector3(_tank_x, 2.3, z))
		_tanks.append(ring)
	for i in want:
		var c = conts[i]
		var ch = "ok" if c["state"] == "running" and c["ready"] else ("warn" if c["state"] != "terminated" else ("done" if c["reason"] == "Completed" else "bad"))
		if h == "bad":
			ch = "bad"
		_tanks[i].material_override = Tex.status_glow(ch)

func dismantle() -> void:
	if removing:
		return
	removing = true
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector3(0.9, 0.01, 0.9), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)

func _process(delta: float) -> void:
	_t += delta
	if _health == "ok":
		_fan.rotation.z -= delta * 5.0
	elif _health == "bad":
		_beacon.visible = fmod(_t, 0.5) < 0.28
		_alarm.scale.x = 1.0 + 0.25 * sin(_t * 6.0)
		_alarm.scale.z = _alarm.scale.x
	elif _health == "warn":
		_beacon.visible = fmod(_t, 1.2) < 0.7
		_fan.rotation.z -= delta * 0.8
	if _health == "ok" or _health == "done":
		_beacon.visible = true
