extends CharacterBody3D
const Tex = preload("res://scripts/tex.gd")
# First-person pioneer: walk / sprint / jump, double-tap Space for the hoverpack.

const WALK = 7.0
const SPRINT = 13.0
const FLY = 16.0
const FLY_FAST = 40.0
const JUMP = 6.5
const GRAVITY = 19.0
const REACH = 70.0

signal stepped()

var enabled = true
var sensitivity = 1.0
var _stride = 0.0
var flying = false
var camera: Camera3D
var hit = {}

var _pitch = 0.0
var _tool: Node3D = null
var _tool_home = Vector3.ZERO
var _bob = 0.0
var _last_space = -10.0

func _ready() -> void:
	var cs = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	camera = Camera3D.new()
	camera.position.y = 1.65
	camera.fov = 80.0
	camera.far = 3000.0
	add_child(camera)
	camera.make_current()
	floor_snap_length = 0.4

# The tool in your hand: a small viewmodel recoloured per tool tier.
func set_tool(index: int, color: Color) -> void:
	if _tool != null:
		_tool.queue_free()
	_tool = Node3D.new()
	_tool.position = Vector3(0.34, -0.3, -0.62)
	_tool.rotation = Vector3(0.05, 0.12, 0.0)
	camera.add_child(_tool)
	var dark = Tex.shared("dark")
	var glow = Tex.glow(color, 1.6)
	var parts = []
	if index == 1:
		# datapad: a slab with a lit screen
		_tool.position = Vector3(0.3, -0.26, -0.55)
		_tool.rotation = Vector3(0.55, 0.25, 0.05)
		parts = [[Vector3(0.36, 0.24, 0.025), dark, Vector3.ZERO], [Vector3(0.31, 0.19, 0.01), glow, Vector3(0, 0, 0.016)]]
	else:
		var len = 0.34 + index * 0.05
		parts = [[Vector3(0.1, 0.13, len), dark, Vector3.ZERO],
			[Vector3(0.06, 0.16, 0.1), dark, Vector3(0, -0.12, len * 0.3)],
			[Vector3(0.105, 0.035, len * 0.8), glow, Vector3(0, 0.03, 0)],
			[Vector3(0.05 + index * 0.012, 0.05 + index * 0.012, 0.16), Tex.shared("steel"), Vector3(0, 0.0, -len * 0.5 - 0.06)],
			[Vector3(0.03, 0.03, 0.02), glow, Vector3(0, 0, -len * 0.5 - 0.15)]]
	for p in parts:
		var mi = MeshInstance3D.new()
		var b = BoxMesh.new()
		b.size = p[0]
		mi.mesh = b
		mi.material_override = p[1]
		mi.position = p[2]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_tool.add_child(mi)
	_tool.scale = Vector3.ONE * 0.62
	_tool.position += Vector3(0.06, -0.04, 0.0)
	_tool_home = _tool.position
	_tool.position.y -= 0.25
	create_tween().tween_property(_tool, "position:y", _tool_home.y, 0.18)

func teleport(pos: Vector3, look_at_point = null) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	if look_at_point != null:
		var d = look_at_point - (pos + Vector3(0, 1.65, 0))
		rotation.y = atan2(-d.x, -d.z)
		_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.5, 1.5)
		camera.rotation.x = _pitch

func _unhandled_input(ev: InputEvent) -> void:
	if not enabled or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if ev is InputEventMouseMotion:
		rotation.y -= ev.relative.x * 0.0022 * sensitivity
		_pitch = clampf(_pitch - ev.relative.y * 0.0022 * sensitivity, -1.5, 1.5)
		camera.rotation.x = _pitch
	elif ev.is_action_pressed("jump"):
		var now = Time.get_ticks_msec() / 1000.0
		if now - _last_space < 0.3:
			flying = not flying
			velocity.y = 0.0
		_last_space = now

func _physics_process(delta: float) -> void:
	var dir = Vector3.ZERO
	var up = 0.0
	var fast = false
	if enabled:
		var v = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		dir = (transform.basis * Vector3(v.x, 0, v.y)).normalized() if v.length() > 0.01 else Vector3.ZERO
		fast = Input.is_action_pressed("sprint")
		up = (1.0 if Input.is_action_pressed("jump") else 0.0) - (1.0 if Input.is_action_pressed("descend") else 0.0)
	if flying:
		var sp = FLY_FAST if fast else FLY
		velocity = velocity.lerp(dir * sp + Vector3.UP * up * sp * 0.7, clampf(delta * 8.0, 0.0, 1.0))
		if is_on_floor() and up < 0.0:
			flying = false
	else:
		var sp = SPRINT if fast else WALK
		var accel = 12.0 if is_on_floor() else 3.0
		var hv = Vector3(velocity.x, 0, velocity.z).lerp(dir * sp, clampf(delta * accel, 0.0, 1.0))
		velocity.x = hv.x
		velocity.z = hv.z
		if is_on_floor():
			if up > 0.0:
				velocity.y = JUMP
		else:
			velocity.y -= GRAVITY * delta
	move_and_slide()
	if is_on_floor() and not flying:
		_stride += delta * Vector2(velocity.x, velocity.z).length()
		if _stride > 2.4:
			_stride = 0.0
			stepped.emit()
	if _tool != null and is_on_floor():
		_bob += delta * Vector2(velocity.x, velocity.z).length() * 1.4
		_tool.position.x = _tool_home.x + sin(_bob) * 0.008
		_tool.rotation.z = sin(_bob * 0.5) * 0.02
	# What is under the crosshair?
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * REACH
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var r = get_world_3d().direct_space_state.intersect_ray(q)
	if r.is_empty():
		hit = {}
	else:
		var meta = r["collider"].get_meta("kf", {})
		hit = {"collider": r["collider"], "pos": r["position"], "meta": meta,
			"dist": from.distance_to(r["position"])}
