extends Node3D
# One cluster node = one foundation platform with a gantry sign and a terminal.

const K = preload("res://scripts/kutil.gd")
const Tex = preload("res://scripts/tex.gd")
const Gfx = preload("res://scripts/gfx.gd")

const PITCH = 8.0
const COLS = 4
const WIDTH = COLS * PITCH + 8.0
const HEIGHT = 1.0

var node_name = ""
var rows = 0
var slots = []
var depth = 0.0

var _slab: Node3D = null
var _title: Label3D
var _sub: Label3D
var _status: Label3D
var _bars = {}
var _trim: MeshInstance3D

func _mesh(size: Vector3, material: Material, pos: Vector3, parent: Node3D = self) -> MeshInstance3D:
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

func _text(txt: String, size: int, pos: Vector3, color: Color = Color.WHITE) -> Label3D:
	var l = Label3D.new()
	l.text = txt
	l.font_size = size
	l.pixel_size = 0.01
	l.outline_size = 0
	l.modulate = color
	l.position = pos
	add_child(l)
	return l

func setup(nm: String) -> void:
	node_name = nm
	var meta = {"type": "node", "name": nm}
	# Gantry sign over the entrance ramp
	var steel = Tex.shared("dark")
	for x in [-9.0, 9.0]:
		_mesh(Vector3(0.6, 11.0, 0.6), steel, Vector3(x, 5.5, 1.2))
		_solid(Vector3(0.6, 11.0, 0.6), Vector3(x, 5.5, 1.2), null)
	_mesh(Vector3(19.0, 5.2, 0.4), Tex.shared("board"), Vector3(0, 8.4, 1.2))
	_trim = _mesh(Vector3(19.4, 0.3, 0.5), Tex.shared("orange"), Vector3(0, 11.15, 1.2))
	_mesh(Vector3(19.4, 0.3, 0.5), Tex.shared("orange"), Vector3(0, 5.65, 1.2))
	_solid(Vector3(19.0, 5.2, 0.4), Vector3(0, 8.4, 1.2), meta)
	_title = _text(nm, 120, Vector3(0, 10.0, 1.42), Tex.ORANGE)
	K.fit_label(_title, 18.0, 1.3)
	_sub = _text("", 56, Vector3(0, 8.95, 1.42), Color(0.75, 0.78, 0.8))
	_status = _text("", 64, Vector3(0, 8.2, 1.42))
	var y = 7.3
	for key in ["CPU", "MEM"]:
		_text(key, 48, Vector3(-8.2, y, 1.42), Color(0.75, 0.78, 0.8)).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_mesh(Vector3(10.0, 0.42, 0.06), Tex.shared("off"), Vector3(-0.6, y, 1.42))
		var fill = _mesh(Vector3(10.0, 0.42, 0.08), Tex.status_glow("ok"), Vector3(-0.6, y, 1.44))
		var val = _text("", 44, Vector3(8.6, y, 1.42))
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_bars[key] = [fill, val]
		y -= 0.75
	# Entrance ramp + node terminal
	var ramp = _solid(Vector3(8.0, 0.3, 4.2), Vector3(0, 0.36, 2.0), null)
	ramp.rotation.x = atan2(HEIGHT, 4.0)
	var rm = _mesh(Vector3(8.0, 0.3, 4.2), Tex.shared("hazard"), Vector3.ZERO, ramp)
	rm.position = Vector3.ZERO
	_mesh(Vector3(1.4, 1.3, 0.9), steel, Vector3(6.2, 0.65, 3.0))
	var scr = _mesh(Vector3(1.2, 0.8, 0.08), Tex.glow(Tex.ORANGE, 1.6), Vector3(6.2, 1.55, 3.0))
	scr.rotation.x = -0.5
	_solid(Vector3(1.6, 2.2, 1.2), Vector3(6.2, 1.1, 3.0), meta)
	var hint = _text("NODE TERMINAL", 28, Vector3(6.2, 2.25, 3.0), Tex.ORANGE)
	hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hint.visibility_range_end = 25.0
	set_rows(2)

func set_rows(r: int) -> void:
	if r == rows:
		return
	rows = r
	depth = rows * PITCH + 4.0
	if _slab != null:
		_slab.queue_free()
	_slab = Node3D.new()
	add_child(_slab)
	var c = Vector3(0, HEIGHT / 2.0, -depth / 2.0)
	_mesh(Vector3(WIDTH, HEIGHT, depth), Tex.shared("foundation"), c, _slab)
	_mesh(Vector3(WIDTH + 0.5, 0.45, depth + 0.5), Tex.shared("dark"), Vector3(0, 0.225, -depth / 2.0), _slab)
	_mesh(Vector3(WIDTH, 0.04, 0.5), Tex.shared("orange"), Vector3(0, HEIGHT + 0.02, -0.3), _slab)
	_solid(Vector3(WIDTH, HEIGHT, depth), c, {"type": "platform", "node": node_name}, _slab)
	if Gfx.occlusion():
		# the slab hides the ground and anything low behind it from the renderer
		var occ = OccluderInstance3D.new()
		var bo = BoxOccluder3D.new()
		bo.size = Vector3(WIDTH, HEIGHT, depth)
		occ.occluder = bo
		occ.position = c
		_slab.add_child(occ)
	if Gfx.detail() >= 1:
		_dress(_slab, Gfx.detail())

# Enhanced: safety railings round three sides and floor markings. Ultra adds lit
# edge strips and two floodlights on the gantry. Decorative only (no collision).
func _dress(parent: Node3D, lod: int) -> void:
	var steel = Tex.shared("steel")
	var hw = WIDTH / 2.0 - 0.15
	var posts = []
	var n_side = int(depth / 4.0) + 1
	for i in n_side:
		for sx in [-hw, hw]:
			posts.append(Vector3(sx, HEIGHT + 0.55, -0.4 - i * (depth - 0.8) / maxf(n_side - 1, 1)))
	var n_back = int(WIDTH / 4.0) + 1
	for i in n_back:
		posts.append(Vector3(-hw + i * (2.0 * hw) / (n_back - 1), HEIGHT + 0.55, -depth + 0.15))
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var pm = BoxMesh.new()
	pm.size = Vector3(0.08, 1.1, 0.08)
	pm.material = steel
	mm.mesh = pm
	mm.instance_count = posts.size()
	for i in posts.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, posts[i]))
	var mi = MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.visibility_range_end = 170.0
	mi.visibility_range_end_margin = 20.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(mi)
	for h in [0.55, 1.08]:
		for sx in [-hw, hw]:
			_mesh(Vector3(0.05, 0.05, depth - 0.6), steel, Vector3(sx, HEIGHT + h, -depth / 2.0 - 0.1), parent)
		_mesh(Vector3(2.0 * hw, 0.05, 0.05), steel, Vector3(0, HEIGHT + h, -depth + 0.15), parent)
	# painted lane lines between the machine rows
	for r in range(1, rows):
		_mesh(Vector3(WIDTH - 3.0, 0.02, 0.14), Tex.mat(Color(0.93, 0.89, 0.78), 0.8), Vector3(0, HEIGHT + 0.012, -r * PITCH - 2.0), parent)
	if lod >= 2:
		var strip = Tex.glow(Tex.ORANGE, 1.4)
		for sx in [-WIDTH / 2.0, WIDTH / 2.0]:
			_mesh(Vector3(0.06, 0.06, depth), strip, Vector3(sx * 1.003, HEIGHT - 0.12, -depth / 2.0), parent)
		_mesh(Vector3(WIDTH, 0.06, 0.06), strip, Vector3(0, HEIGHT - 0.12, -depth - 0.03), parent)
		for sx in [-7.5, 7.5]:
			_mesh(Vector3(0.9, 0.3, 0.5), Tex.shared("dark"), Vector3(sx, 5.45, 0.75), parent)
			_mesh(Vector3(0.7, 0.06, 0.34), Tex.glow(Color(1.0, 0.92, 0.75), 3.0), Vector3(sx, 5.29, 0.72), parent)
			var sp = SpotLight3D.new()
			sp.position = Vector3(sx, 5.2, 0.6)
			sp.rotation = Vector3(deg_to_rad(-62.0), 0, 0)
			sp.light_color = Color(1.0, 0.9, 0.72)
			sp.light_energy = 3.0
			sp.spot_range = 26.0
			sp.spot_angle = 48.0
			sp.distance_fade_enabled = true
			sp.distance_fade_begin = 110.0
			sp.distance_fade_length = 30.0
			parent.add_child(sp)

func slot_pos(i: int) -> Vector3:
	var col = i % COLS
	var row = int(i / float(COLS))
	return Vector3((col - (COLS - 1) / 2.0) * PITCH, HEIGHT, -(row + 0.5) * PITCH - 2.0)

func take_slot(id: String) -> int:
	for i in slots.size():
		if slots[i] == null:
			slots[i] = id
			return i
	slots.append(id)
	return slots.size() - 1

func free_slot(i: int) -> void:
	if i >= 0 and i < slots.size():
		slots[i] = null

func used_rows() -> int:
	var last = -1
	for i in slots.size():
		if slots[i] != null:
			last = i
	return maxi(2, int(ceil((last + 1) / float(COLS))))

func update(n) -> void:
	if n == null:
		_title.text = "UNSCHEDULED"
		_sub.text = "pods waiting for a node"
		_status.text = "PENDING YARD"
		K.fit_label(_title, 18.0, 1.3)
		_status.modulate = K.health_color("warn")
		for key in _bars:
			_bars[key][0].visible = false
			_bars[key][1].text = "-"
		return
	var bits = [n["roles"], n["version"]]
	for k in ["itype", "zone"]:
		if str(n.get(k, "")) != "":
			bits.append(str(n[k]))
	_sub.text = "   ·   ".join(PackedStringArray(bits))
	K.fit_label(_sub, 18.0, 0.7)
	var h = "ok"
	var txt = "READY"
	if not n["ready"]:
		h = "bad"
		txt = "NOT READY"
	elif n["cordoned"]:
		h = "warn"
		txt = "CORDONED  ·  scheduling disabled"
	_status.text = txt
	_status.modulate = K.health_color(h)
	K.fit_label(_status, 18.0, 0.8)
	_trim.material_override = Tex.shared("orange") if h == "ok" else Tex.status_glow(h)
	_set_bar("CPU", n["cpu_req"], n["cpu"], "%.1f / %.0f cores" % [n["cpu_req"], n["cpu"]])
	_set_bar("MEM", n["mem_req"], n["mem"], "%s / %s" % [K.fmt_mem(n["mem_req"]), K.fmt_mem(n["mem"])])

func _set_bar(key: String, used: float, total: float, txt: String) -> void:
	var f = clampf(used / total, 0.0, 1.0) if total > 0.0 else 0.0
	var fill: MeshInstance3D = _bars[key][0]
	fill.visible = f > 0.001
	fill.scale.x = maxf(f, 0.001)
	fill.position.x = -0.6 - 5.0 + 5.0 * f
	fill.material_override = Tex.status_glow("ok" if f < 0.75 else ("warn" if f < 0.92 else "bad"))
	_bars[key][1].text = txt
	K.fit_label(_bars[key][1], 3.9, 0.5)   # the gap between the bar's end and the sign's edge
