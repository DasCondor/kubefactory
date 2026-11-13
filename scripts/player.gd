extends CharacterBody3D
const ViewModel = preload("res://scripts/viewmodel.gd")
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
var view: Node3D
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
	view = ViewModel.new()
	view.player = self
	camera.add_child(view)
	floor_snap_length = 0.4

# The tool in your hand (see viewmodel.gd), recoloured per tool tier.
func set_tool(index: int, color: Color) -> void:
	view.set_tool(index, color)

# A jolt through the tool: `strength` 1 for a finished action, less for a click.
func tool_kick(strength: float = 1.0) -> void:
	view.kick(strength)

# 0..1 while a hold action is winding up.
func tool_charge(f: float) -> void:
	view.charge = f

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
