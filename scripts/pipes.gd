extends Node3D
# The service belts drawn with the model library's pipe kit (assets/network):
# pipe_straight for every run, the junction block of conduit_elbow at every
# corner, and pipe_valve on the drop into each machine. Used wherever the
# library is (desktop, and the browser's High preset); the browser's Standard
# preset keeps the belts drawn in code (world.gd).
#
# The kit is V2 geometry: the library marks it "legacy geometry, visual rebuild
# pending". It is placed on purpose, by the operator's choice, and named as such
# in docs/KNOWN_LIMITATIONS.md.
#
# Each piece is split in two multimeshes: the tube and junction body take the
# Service's colour (as the belts always have), the flanges, couplers, brackets,
# valve wheel and caps keep the library's own materials.

const Models = preload("res://scripts/models.gd")

const CROSS = 3.2            # the kit's tube is 0.13 m across; a belt is a few times that
const PIECE = 6.0            # one straight piece per this many metres of run
const AXIS_Y = 0.185         # the tube's centre height in the model, above its feet

var _sets = {}               # name -> [tinted MultiMesh, plain MultiMesh]
var _ok = false

# Splits one library model into the parts to tint and the parts to keep, by
# the part's name (Conduit_*, Junction_* are the body).
static func _split(id: String, only: Array = [], skip: Array = []) -> Array:
	var scene = Models._load_scene(id, Models.tier())
	if scene == null:
		return []
	var parts = []
	Models._collect(scene, Transform3D.IDENTITY, parts)
	scene.free()
	var body = []
	var rest = []
	for p in parts:
		var nm = str(p[0]).get_slice(".", 0)
		if not only.is_empty() and not only.any(func(pre): return nm.begins_with(pre)):
			continue
		if skip.any(func(pre): return nm.begins_with(pre)):
			continue
		if nm.begins_with("Conduit_") or nm.begins_with("Junction_"):
			body.append(p)
		else:
			rest.append(p)
	return [Models._merge(body), Models._merge(rest)]

func _ready() -> void:
	var tint = StandardMaterial3D.new()
	tint.vertex_color_use_as_albedo = true
	tint.roughness = 0.45
	tint.metallic = 0.25
	# a vertical run has no floor to stand on: the same pipe without its support brackets
	for spec in [["pipe", "pipe_straight", [], []], ["riser", "pipe_straight", [], ["SupportBracket_"]],
			["joint", "conduit_elbow", ["Junction_", "JunctionCap_"], []], ["valve", "pipe_valve", [], []]]:
		var meshes = _split(spec[1], spec[2], spec[3])
		if meshes.is_empty() or meshes[0] == null:
			return                     # the kit is not there: the caller keeps its code-drawn belts
		var pair = []
		for i in 2:
			var mm = MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = i == 0
			var mesh: ArrayMesh = meshes[i]
			if mesh == null:
				pair.append(null)
				continue
			if i == 0:
				mesh = mesh.duplicate()
				for s in mesh.get_surface_count():
					mesh.surface_set_material(s, tint)
			mm.mesh = mesh
			var mi = MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.custom_aabb = AABB(Vector3(-2000, -10, -2000), Vector3(4000, 200, 4000))
			add_child(mi)
			pair.append(mm)
		_sets[spec[0]] = pair
	_ok = true

func ready_to_use() -> bool:
	return _ok

# A piece laid from a to b: the model's Z runs along the segment, its tube's
# centre line on the segment, its feet below a horizontal run.
static func _lay(a: Vector3, b: Vector3, along_len: float, cross: float) -> Transform3D:
	var d = b - a
	var dir = d.normalized()
	var rot: Basis
	if absf(dir.y) > 0.5:
		rot = Basis(Vector3.RIGHT, -PI / 2.0 if dir.y > 0 else PI / 2.0)    # Z up (or down)
	else:
		rot = Basis(Vector3.UP, atan2(dir.x, dir.z))                        # Z along the run
	var basis = rot * Basis.from_scale(Vector3(cross, cross, d.length() / along_len))
	var mid = (a + b) * 0.5
	return Transform3D(basis, mid - basis * Vector3(0, AXIS_Y, 0))

# segs: [[a, b, color, is_drop]]   joints: [[pos, color]]
func build(segs: Array, joints: Array) -> void:
	if not _ok:
		return
	var lists = {"pipe": [], "riser": [], "joint": [], "valve": []}
	for sg in segs:
		var a: Vector3 = sg[0]
		var b: Vector3 = sg[1]
		var len = a.distance_to(b)
		if len < 0.05:
			continue
		if sg[3]:
			# the valve keeps its proportions at the machine's end of the drop
			# (b); plain pipe fills the rest above it
			var lv = minf(2.28 * CROSS, len)                            # the valve model is 2.28 m end to end
			var v0 = b.lerp(a, lv / len)
			lists["valve"].append([_lay(v0, b, 2.28, CROSS), sg[2]])
			if len - lv <= 0.3:
				continue
			b = v0
			len = a.distance_to(b)
		var n = maxi(1, int(round(len / PIECE)))
		var kind = "riser" if absf(b.y - a.y) > 0.5 * len else "pipe"
		for i in n:
			lists[kind].append([_lay(a.lerp(b, float(i) / n), a.lerp(b, float(i + 1) / n), 3.0, CROSS), sg[2]])
	for j in joints:
		var s = CROSS * 1.15
		lists["joint"].append([Transform3D(Basis.from_scale(Vector3(s, s, s)), j[0] - Vector3(0, 0.18 * s, 0)), j[1]])
	for k in lists:
		var pair = _sets[k]
		var items: Array = lists[k]
		for i in 2:
			var mm: MultiMesh = pair[i]
			if mm == null:
				continue
			mm.instance_count = items.size()
			for n in items.size():
				mm.set_instance_transform(n, items[n][0])
				if i == 0:
					mm.set_instance_color(n, items[n][1])

func count() -> int:
	var c = 0
	for k in _sets:
		if _sets[k][0] != null:
			c += _sets[k][0].instance_count
	return c
