extends Node3D
# The first-person tool in your hand: one distinct model per tool, held by a
# gloved arm, with look sway, walk bob, sprint carry, landing dip, swap and
# recoil / charge animation. Lives on the camera.
#
# Everything is built at roughly real size and then shrunk and held close
# (inside the player's collision radius) so it never pokes through a wall.

const Tex = preload("res://scripts/tex.gd")
const Models = preload("res://scripts/models.gd")
const K = preload("res://scripts/kutil.gd")

# The library's handheld tools (desktop renderer). They are modelled aiming +Z
# with their display facing -Z, so the whole tool is turned half round in the
# hand: it aims where you look and its display faces you, the right way round.
const LIB_IDS = ["scanner", "datapad", "build_gun", "wrench", "dismantler", "demolisher"]
const LIB_SCALE = 0.52        # library tools are about a metre tall; the hand-built ones a third of that
const LIB_POSES = [   # resting [position, rotation] per tool, in camera space
	[Vector3(0.155, -0.118, -0.300), Vector3(0.05, 0.24, 0.0)],     # scanner
	[Vector3(0.060, -0.150, -0.300), Vector3(-0.20, 0.14, 0.02)],   # datapad
	[Vector3(0.155, -0.118, -0.300), Vector3(0.05, 0.24, 0.0)],     # build gun
	[Vector3(0.170, -0.130, -0.300), Vector3(-0.45, 0.30, 0.35)],   # wrench
	[Vector3(0.155, -0.118, -0.300), Vector3(0.05, 0.24, 0.0)],     # dismantler
	[Vector3(0.155, -0.118, -0.300), Vector3(0.05, 0.24, 0.0)],     # demolisher
]
const SCALE = 0.3
const POSES = [   # resting [position, rotation] per tool, in camera space
	[Vector3(0.190, -0.120, -0.270), Vector3(0.03, 0.16, 0.0)],     # scanner
	[Vector3(0.135, -0.105, -0.250), Vector3(0.30, 0.20, 0.04)],    # datapad
	[Vector3(0.195, -0.124, -0.270), Vector3(0.03, 0.16, 0.0)],     # build gun
	[Vector3(0.190, -0.165, -0.260), Vector3(-0.75, 0.25, 0.30)],   # wrench
	[Vector3(0.195, -0.124, -0.265), Vector3(0.03, 0.16, 0.0)],     # dismantler
	[Vector3(0.200, -0.130, -0.265), Vector3(0.03, 0.16, 0.0)],     # demolisher
]

var player: CharacterBody3D
var charge = 0.0          # 0..1 while a hold action winds up

var _index = -1
var _color = Color.WHITE
var _next = null          # [index, color] waiting for the current tool to drop
var _raise = 0.0          # 0 = stowed below the screen, 1 = in hand
var _pivot: Node3D
var _model: Node3D = null
var _spin: Node3D = null
var _spin_axis = Vector3.RIGHT
var _spin_speed = 0.0
var _glows = []           # [material, base energy]
var _t = 0.0
var _bob = 0.0
var _kick = 0.0
var _dip = 0.0
var _air = 0.0
var _carry = 0.0
var _sway = Vector2.ZERO
var _last_yaw = 0.0
var _last_pitch = 0.0
var _was_floor = true
var _fall = 0.0
var _lib = false          # the tool in hand is a library model
var _readout: Label3D = null
var _readout_text = ""

func _ready() -> void:
	_pivot = Node3D.new()
	add_child(_pivot)

func set_tool(index: int, color: Color) -> void:
	if index == _index and color == _color and _next == null:
		return
	if _model == null:
		_build(index, color)
	else:
		_next = [index, color]

# What the tool's own display shows: real state from the game (tool, target,
# what the trigger would do), never a stand-in.
func set_readout(text: String) -> void:
	if text == _readout_text:
		return
	_readout_text = text
	_fit_readout()

func _fit_readout() -> void:
	if _readout == null:
		return
	_readout.text = _readout_text
	var sz: Vector2 = _readout.get_meta("size")
	K.fit_label(_readout, sz.x * 0.9, sz.y * 0.84, 0.0016)

# The library model for this tool, held by the same gloved arm. False if the
# library is not there (browser build, missing files): the hand-built tool is used.
func _build_library(index: int, color: Color) -> bool:
	if not Models.available():
		return false
	var id = LIB_IDS[index]
	var scene = Models._load_scene(id, Models.tier())
	if scene == null:
		return false
	var parts = []
	Models._collect(scene, Transform3D.IDENTITY, parts)
	scene.free()
	var anchors: Dictionary = Models.entry(id).get("variants", {}).get(Models.tier(), {}).get("anchors", {})
	var grip = Models._v3(anchors.get("Grip", [0, 0.3, 0]))
	var holder = Node3D.new()
	holder.rotation.y = PI
	holder.scale = Vector3.ONE * LIB_SCALE
	_model.add_child(holder)
	# the grip sits where the hand is; everything else follows from it
	var hand = Vector3(0, -0.15, 0.07) if index != 1 else Vector3(0.16, -0.06, 0.02)
	holder.position = hand - (holder.transform.basis * grip)
	var solid = []
	var lit = []
	for p in parts:
		var nm = str(p[0]).get_slice(".", 0)
		if nm.begins_with("Lens_") or nm.begins_with("Emitter_") or nm.begins_with("RamTip_") or nm.begins_with("Button_"):
			lit.append(p)
		else:
			solid.append(p)
	for group in [solid, lit]:
		if group.is_empty():
			continue
		var mi = MeshInstance3D.new()
		mi.mesh = Models._merge(group)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if group == lit:
			mi.material_override = _glow(color, 2.2)
		holder.add_child(mi)
	var sc = anchors.get("LiveViewSurface")
	if typeof(sc) == TYPE_DICTIONARY:
		_readout = Label3D.new()
		_readout.font_size = 40
		_readout.outline_size = 0
		_readout.modulate = color.lightened(0.55)
		_readout.no_depth_test = false
		_readout.position = Models._v3(sc["position"]) + Models._v3(sc["normal"]) * 0.004
		_readout.rotation.y = PI          # the glass faces -Z in the model
		_readout.set_meta("size", Vector2(sc["size"][0], sc["size"][1]))
		holder.add_child(_readout)
		_fit_readout()
	# the glove closes round the library grip, which is thicker than the hand-built ones
	var keep = _model
	var arm = Node3D.new()
	arm.scale = Vector3.ONE * 1.5
	arm.position = hand + (Vector3(0, -0.01, 0.0) if index != 1 else Vector3(0.02, -0.05, 0.03))
	keep.add_child(arm)
	_model = arm
	_arm(Vector3.ZERO, Vector3(0.5, 0.25, 0.0) if index != 1 else Vector3(0.75, 0.1, 0.0))
	_model = keep
	_lib = true
	return true

func kick(strength: float = 1.0) -> void:
	_kick = maxf(_kick, strength)

# ---- construction ------------------------------------------------------

func _part(mesh: Mesh, material: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else _model).add_child(mi)
	return mi

func _b(size: Vector3, material: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var m = BoxMesh.new()
	m.size = size
	return _part(m, material, pos, rot, parent)

# A cylinder whose axis points along -Z (forward); `front` / `back` are its radii.
func _c(front: float, back: float, length: float, material: Material, pos: Vector3, parent: Node3D = null, axis_rot: Vector3 = Vector3(-PI / 2, 0, 0)) -> MeshInstance3D:
	var m = CylinderMesh.new()
	m.top_radius = front
	m.bottom_radius = back
	m.height = length
	m.radial_segments = 12
	m.rings = 1
	return _part(m, material, pos, axis_rot, parent)

func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var m = Tex.glow(color, energy)
	_glows.append([m, energy])
	return m

# Gloved fist on a grip at `at`, with the forearm running back off-screen.
func _arm(at: Vector3, arm_rot: Vector3 = Vector3(0.5, 0.25, 0.0)) -> void:
	var glove = Tex.mat(Color(0.15, 0.16, 0.19), 0.85)
	var pad = Tex.mat(Color(0.3, 0.31, 0.34), 0.7)
	_b(Vector3(0.078, 0.1, 0.1), glove, at)
	_b(Vector3(0.082, 0.03, 0.045), pad, at + Vector3(0, 0.04, -0.05))    # knuckles
	_b(Vector3(0.03, 0.035, 0.075), glove, at + Vector3(-0.048, 0.055, -0.015))   # thumb
	var arm = Node3D.new()
	arm.position = at + Vector3(0, -0.035, 0.03)
	arm.rotation = arm_rot
	_model.add_child(arm)
	_b(Vector3(0.072, 0.072, 0.12), glove, Vector3(0, 0, 0.05), Vector3.ZERO, arm)
	_b(Vector3(0.102, 0.102, 0.035), Tex.shared("dark"), Vector3(0, 0, 0.12), Vector3.ZERO, arm)
	_b(Vector3(0.094, 0.094, 0.56), Tex.shared("orange"), Vector3(0, 0, 0.41), Vector3.ZERO, arm)
	_b(Vector3(0.098, 0.03, 0.2), pad, Vector3(0, 0.035, 0.3), Vector3.ZERO, arm)       # forearm plate

# Shared pistol frame: receiver, grip, trigger guard, lit top rail. Returns the paint.
func _frame(color: Color, width: float, height: float, length: float) -> StandardMaterial3D:
	var dark = Tex.shared("dark")
	var paint = Tex.mat(color.darkened(0.25), 0.45, 0.35)
	_b(Vector3(width, height, length), paint, Vector3.ZERO)
	_b(Vector3(width + 0.006, height * 0.3, length * 0.7), dark, Vector3(0, -height * 0.38, -length * 0.08))
	_b(Vector3(width * 0.55, 0.16, 0.075), dark, Vector3(0, -height * 0.5 - 0.06, length * 0.27), Vector3(0.22, 0, 0))
	_b(Vector3(0.012, 0.012, 0.09), dark, Vector3(0, -height * 0.5 - 0.055, length * 0.1))
	_b(Vector3(width + 0.004, 0.02, length * 0.72), _glow(color, 1.6), Vector3(0, height * 0.5 - 0.022, 0.0))
	_b(Vector3(width * 0.5, 0.02, length * 0.5), dark, Vector3(0, height * 0.5 + 0.008, 0.02))
	_arm(Vector3(0, -height * 0.5 - 0.075, length * 0.27 + 0.012))
	return paint

func _build(index: int, color: Color) -> void:
	if _model != null:
		_model.queue_free()
	_glows.clear()
	_spin = null
	_index = index
	_color = color
	_model = Node3D.new()
	_model.scale = Vector3.ONE * SCALE
	_pivot.add_child(_model)
	_readout = null
	_lib = false
	if _build_library(index, color):
		return
	var dark = Tex.shared("dark")
	var steel = Tex.shared("steel")
	match index:
		0:   # scanner: a sensor dish up front and a little readout facing you
			_frame(color, 0.085, 0.11, 0.28)
			_c(0.095, 0.03, 0.11, steel, Vector3(0, 0.0, -0.195))
			_c(0.1, 0.1, 0.012, dark, Vector3(0, 0.0, -0.252))
			_c(0.03, 0.03, 0.03, _glow(color, 2.4), Vector3(0, 0.0, -0.245))
			_spin = Node3D.new()
			_spin.position = Vector3(0, 0, -0.262)
			_spin_axis = Vector3.BACK
			_model.add_child(_spin)
			for i in 3:
				_b(Vector3(0.012, 0.085, 0.006), steel, Vector3.ZERO, Vector3(0, 0, i * PI / 3.0), _spin)
			_b(Vector3(0.012, 0.05, 0.03), dark, Vector3(0, 0.075, 0.105))
			_b(Vector3(0.09, 0.062, 0.012), dark, Vector3(0, 0.105, 0.115), Vector3(-0.55, 0, 0))
			_b(Vector3(0.078, 0.05, 0.006), _glow(color, 1.3), Vector3(0, 0.107, 0.122), Vector3(-0.55, 0, 0))
			_b(Vector3(0.007, 0.13, 0.007), steel, Vector3(0.036, 0.115, 0.05))
			_b(Vector3(0.014, 0.014, 0.014), _glow(Color(1.0, 0.3, 0.25), 2.0), Vector3(0.036, 0.185, 0.05))
		1:   # datapad: a rugged tablet with a lit, text-filled screen
			var off = Tex.shared("off")
			_b(Vector3(0.37, 0.25, 0.024), dark, Vector3.ZERO)
			_b(Vector3(0.39, 0.035, 0.034), steel, Vector3(0, -0.125, 0))
			_b(Vector3(0.39, 0.035, 0.034), steel, Vector3(0, 0.125, 0))
			for x in [-0.185, 0.185]:
				_b(Vector3(0.03, 0.08, 0.04), Tex.shared("orange"), Vector3(x, 0.1, 0))
				_b(Vector3(0.03, 0.08, 0.04), Tex.shared("orange"), Vector3(x, -0.1, 0))
			_b(Vector3(0.315, 0.19, 0.006), _glow(color.darkened(0.55), 0.7), Vector3(0, 0.0, 0.013))
			_b(Vector3(0.3, 0.022, 0.004), _glow(color, 1.8), Vector3(0, 0.075, 0.017))
			var rng = RandomNumberGenerator.new()
			rng.seed = 5
			for row in 6:
				var w = rng.randf_range(0.1, 0.27)
				_b(Vector3(w, 0.009, 0.004), _glow(color.lightened(0.5), 1.2) if row % 3 != 2 else off,
					Vector3(-0.145 + w / 2.0, 0.045 - row * 0.021, 0.017))
			_b(Vector3(0.05, 0.05, 0.004), _glow(Tex.ORANGE, 1.6), Vector3(0.115, -0.055, 0.017))
			# thumb over the bezel, fingers behind
			var glove = Tex.mat(Color(0.15, 0.16, 0.19), 0.85)
			_b(Vector3(0.075, 0.035, 0.035), glove, Vector3(0.175, -0.035, 0.03), Vector3(0, 0, 0.5))
			_b(Vector3(0.09, 0.11, 0.05), glove, Vector3(0.205, -0.05, -0.03))
			var arm = Node3D.new()
			arm.position = Vector3(0.215, -0.08, -0.01)
			arm.rotation = Vector3(-0.2, 0.5, 0.0)
			_model.add_child(arm)
			_b(Vector3(0.072, 0.072, 0.12), glove, Vector3(0, 0, 0.05), Vector3.ZERO, arm)
			_b(Vector3(0.102, 0.102, 0.035), dark, Vector3(0, 0, 0.12), Vector3.ZERO, arm)
			_b(Vector3(0.094, 0.094, 0.56), Tex.shared("orange"), Vector3(0, 0, 0.41), Vector3.ZERO, arm)
		2:   # build gun: twin prongs around a spinning fabricator core, feed tank on the side
			_frame(color, 0.11, 0.135, 0.32)
			for x in [-0.04, 0.04]:
				_b(Vector3(0.024, 0.03, 0.22), steel, Vector3(x, 0.01, -0.26))
				_b(Vector3(0.03, 0.04, 0.03), dark, Vector3(x, 0.01, -0.365))
			_spin = Node3D.new()
			_spin.position = Vector3(0, 0.01, -0.25)
			_spin_axis = Vector3.BACK
			_model.add_child(_spin)
			_b(Vector3(0.042, 0.042, 0.11), _glow(color, 2.6), Vector3.ZERO, Vector3.ZERO, _spin)
			_b(Vector3(0.05, 0.012, 0.03), steel, Vector3(0, 0, -0.03), Vector3.ZERO, _spin)
			_c(0.042, 0.042, 0.19, steel, Vector3(-0.092, 0.005, 0.0))
			_c(0.046, 0.046, 0.03, _glow(color, 1.4), Vector3(-0.092, 0.005, -0.03))
			_c(0.012, 0.012, 0.1, dark, Vector3(-0.092, 0.005, -0.14))
			_b(Vector3(0.114, 0.03, 0.05), Tex.shared("hazard"), Vector3(0, -0.02, -0.132))
		3:   # wrench: an honest big spanner, tier band on the shaft
			_b(Vector3(0.044, 0.46, 0.024), steel, Vector3(0, 0.13, 0))
			_b(Vector3(0.046, 0.15, 0.032), dark, Vector3(0, -0.04, 0))
			_b(Vector3(0.042, 0.028, 0.026), _glow(color, 1.8), Vector3(0, 0.08, 0))
			_b(Vector3(0.042, 0.012, 0.026), _glow(color, 1.8), Vector3(0, 0.115, 0))
			_b(Vector3(0.12, 0.075, 0.026), steel, Vector3(0, 0.385, 0))
			_b(Vector3(0.034, 0.085, 0.026), steel, Vector3(-0.043, 0.455, 0), Vector3(0, 0, 0.12))
			_b(Vector3(0.034, 0.085, 0.026), steel, Vector3(0.043, 0.455, 0), Vector3(0, 0, -0.12))
			_b(Vector3(0.05, 0.016, 0.03), dark, Vector3(0, 0.335, 0))
			var glove = Tex.mat(Color(0.15, 0.16, 0.19), 0.85)
			_b(Vector3(0.075, 0.1, 0.085), glove, Vector3(0, -0.04, 0.012))
			_b(Vector3(0.03, 0.04, 0.07), glove, Vector3(-0.04, 0.02, 0.0))
			var arm = Node3D.new()
			arm.position = Vector3(0.0, -0.075, 0.03)
			arm.rotation = Vector3(1.25, 0.1, 0.0)
			_model.add_child(arm)
			_b(Vector3(0.072, 0.072, 0.12), glove, Vector3(0, 0, 0.05), Vector3.ZERO, arm)
			_b(Vector3(0.102, 0.102, 0.035), dark, Vector3(0, 0, 0.12), Vector3.ZERO, arm)
			_b(Vector3(0.094, 0.094, 0.56), Tex.shared("orange"), Vector3(0, 0, 0.41), Vector3.ZERO, arm)
		4:   # dismantler: a saw blade on an arm, under a guard
			_frame(color, 0.1, 0.13, 0.34)
			_b(Vector3(0.03, 0.045, 0.24), steel, Vector3(0.028, 0.0, -0.27))
			_b(Vector3(0.05, 0.02, 0.2), dark, Vector3(0, 0.125, -0.37))
			_b(Vector3(0.05, 0.11, 0.02), dark, Vector3(0, 0.075, -0.265))
			_spin = Node3D.new()
			_spin.position = Vector3(0, 0.0, -0.385)
			_spin_axis = Vector3.RIGHT
			_model.add_child(_spin)
			_c(0.1, 0.1, 0.01, steel, Vector3.ZERO, _spin, Vector3(0, 0, PI / 2))
			_c(0.03, 0.03, 0.03, _glow(color, 2.4), Vector3.ZERO, _spin, Vector3(0, 0, PI / 2))
			for i in 8:
				var a = i * TAU / 8.0
				_b(Vector3(0.011, 0.03, 0.03), steel, Vector3(0, cos(a) * 0.105, sin(a) * 0.105), Vector3(a + 0.6, 0, 0), _spin)
			_b(Vector3(0.104, 0.03, 0.05), Tex.shared("hazard"), Vector3(0, -0.02, -0.14))
		5:   # demolisher: heavy twin barrels, carry handle, hazard banding, side vents
			_frame(color, 0.14, 0.16, 0.38)
			for x in [-0.038, 0.038]:
				_c(0.034, 0.034, 0.27, steel, Vector3(x, 0.012, -0.32))
				_c(0.042, 0.042, 0.035, dark, Vector3(x, 0.012, -0.445))
				_c(0.02, 0.02, 0.012, _glow(color, 3.0), Vector3(x, 0.012, -0.46))
			_b(Vector3(0.12, 0.05, 0.04), dark, Vector3(0, 0.012, -0.24))
			_b(Vector3(0.146, 0.05, 0.07), Tex.shared("hazard"), Vector3(0, 0.03, -0.15))
			for x in [-0.072, 0.072]:
				for k in 3:
					_b(Vector3(0.008, 0.07, 0.03), _glow(color, 1.8), Vector3(x, 0.0, -0.02 + k * 0.05))
			for z in [-0.09, 0.09]:
				_b(Vector3(0.018, 0.05, 0.018), dark, Vector3(0, 0.105, z))
			_b(Vector3(0.022, 0.022, 0.22), steel, Vector3(0, 0.135, 0))
			_c(0.05, 0.05, 0.1, dark, Vector3(0, 0.02, 0.235))
			_c(0.03, 0.03, 0.02, steel, Vector3(0, 0.02, 0.29))

# ---- animation ---------------------------------------------------------

func _process(delta: float) -> void:
	if _model == null or player == null or delta <= 0.0:
		return
	_t += delta
	# swap: drop the old tool, bring up the new one
	if _next != null:
		_raise = move_toward(_raise, 0.0, delta / 0.11)
		if _raise <= 0.0:
			_build(_next[0], _next[1])
			_next = null
	else:
		_raise = move_toward(_raise, 1.0, delta / 0.22)
	var stow = 1.0 - ease(_raise, 0.4)

	# look sway: the tool trails a little behind the view as you turn
	var yaw = player.rotation.y
	var pitch = player.camera.rotation.x
	var turn = Vector2(wrapf(yaw - _last_yaw, -PI, PI), pitch - _last_pitch) / delta
	_last_yaw = yaw
	_last_pitch = pitch
	var want = Vector2(clampf(turn.x * 0.006, -0.035, 0.035), clampf(turn.y * 0.006, -0.03, 0.03))
	_sway = _sway.lerp(want, clampf(delta * 9.0, 0.0, 1.0))

	# movement: stride bob on the ground, drift in the air, a dip on landing
	var hv = Vector2(player.velocity.x, player.velocity.z).length()
	var grounded = player.is_on_floor() and not player.flying
	var amp = 0.0
	if grounded:
		_bob += delta * hv * 1.45
		amp = clampf(hv / 7.0, 0.0, 1.5) * 0.0042
		if not _was_floor:
			_dip = clampf(_fall * 0.0022, 0.0, 0.03)
	else:
		_fall = maxf(-player.velocity.y, 0.0)
	_was_floor = grounded
	_dip = lerpf(_dip, 0.0, clampf(delta * 9.0, 0.0, 1.0))
	_air = lerpf(_air, 0.0 if grounded else clampf(player.velocity.y * 0.0016, -0.014, 0.014), clampf(delta * 6.0, 0.0, 1.0))
	var running = (grounded and hv > 10.0) or (player.flying and hv > 26.0)
	_carry = lerpf(_carry, 1.0 if running and charge <= 0.0 else 0.0, clampf(delta * 7.0, 0.0, 1.0))
	_kick = lerpf(_kick, 0.0, clampf(delta * 11.0, 0.0, 1.0))

	var home = LIB_POSES[_index] if _lib else POSES[_index]
	var pos: Vector3 = home[0]
	var rot: Vector3 = home[1]
	pos += Vector3(sin(_bob) * amp, sin(_bob * 2.0) * amp * 0.7 + sin(_t * 1.6) * 0.0012, 0.0)
	pos += Vector3(_sway.x * 0.35, -_sway.y * 0.3 - _air - _dip - stow * 0.17, 0.0)
	pos += Vector3(-0.022, -0.02, 0.012) * _carry
	pos += Vector3(0, 0.004, 0.028) * _kick
	rot += Vector3(-_sway.y * 0.9 - stow * 0.7 - _dip * 4.0, -_sway.x * 1.1, -_sway.x * 0.8 + sin(_bob) * amp * 5.0)
	rot += Vector3(-0.16, 0.5, 0.1) * _carry
	rot += Vector3(0.16, 0, 0) * _kick
	if charge > 0.0:
		# winding up: the tool strains and rattles harder as the action nears
		var shake = charge * charge * 0.0022
		pos += Vector3(sin(_t * 71.0), sin(_t * 83.0 + 1.3), sin(_t * 59.0 + 0.7)) * shake
		pos += Vector3(0, 0.006, -0.012) * charge
		if _index == 3:
			rot.z += sin(_t * 10.0) * 0.22 * charge   # cranking the wrench
	_pivot.position = pos
	_pivot.rotation = rot

	for g in _glows:
		g[0].emission_energy_multiplier = g[1] * (1.0 + 2.2 * charge + 1.5 * _kick)
	if _spin != null:
		_spin_speed = lerpf(_spin_speed, 1.5 + 34.0 * charge + 14.0 * _kick, clampf(delta * 5.0, 0.0, 1.0))
		_spin.rotate_object_local(_spin_axis, -_spin_speed * delta)
