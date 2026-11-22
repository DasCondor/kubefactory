extends SubViewportContainer
# The 3D connection board in a panel: the board scene in its own world, with a
# camera that orbits it. Mouse: drag to turn, right or middle drag to pan,
# wheel to zoom, click to select, double-click to open files, drag a block to
# move it. Touch: one finger turns (or moves the block it started on), two
# fingers pinch to zoom and move together to pan, tap selects, double-tap opens.
# It offers the same calls as the flat board, so the panel's buttons work on both.

signal endpoint_activated(uid: String)
signal endpoint_selected(uid: String)

const BoardScene = preload("res://scripts/board_scene.gd")

var scene: Node3D
var viewport: SubViewport
var camera: Camera3D
var target = Vector3.ZERO
var yaw = deg_to_rad(-30.0)
var pitch = deg_to_rad(48.0)
var distance = 120.0
var _fit_distance = 120.0
var _touches = {}           # index -> position
var _press_at = Vector2.ZERO
var _press_card = ""
var _dragging = ""          # what a drag is doing: "turn", "pan", "move"
var _last_tap = -1000
var _last_tap_uid = ""
var _pinch = 0.0

var category:
	get: return scene.category
	set(value): scene.category = value
var selected_uid:
	get: return scene.selected_uid
	set(value): scene.selected_uid = value
var layout:
	get: return scene.layout
	set(value): scene.layout = value
var cards:
	get: return scene.cards
var routes:
	get: return scene.routes
var zoom:
	get: return _fit_distance / maxf(distance, 0.01)
	set(value):
		distance = clampf(_fit_distance / maxf(value, 0.05), 12.0, 900.0)
		_place_camera()

func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.handle_input_locally = false
	add_child(viewport)
	var env = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.11, 0.13, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.66, 0.72)
	e.ambient_light_energy = 0.75
	env.environment = e
	viewport.add_child(env)
	var sun = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	sun.light_energy = 1.1
	viewport.add_child(sun)
	var floor_mesh = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(900, 900)
	floor_mesh.mesh = plane
	var fm = StandardMaterial3D.new()
	fm.albedo_color = Color(0.16, 0.19, 0.22)
	floor_mesh.material_override = fm
	floor_mesh.position.y = -0.05
	viewport.add_child(floor_mesh)
	scene = BoardScene.new()
	viewport.add_child(scene)
	camera = Camera3D.new()
	camera.fov = 50.0
	camera.far = 2000.0
	viewport.add_child(camera)
	_place_camera()

func configure(config) -> void:
	scene.configure(config)

func refresh(state: Dictionary) -> bool:
	return scene.refresh(state)

func select_endpoint(uid: String) -> void:
	scene.select_endpoint(uid)

func connection_list() -> Array:
	return scene.connection_list()

func arrange_spider() -> void:
	scene.arrange_spider()

# Frame every block: the flat board's "Fit board".
func fit_routes() -> void:
	var box: AABB = scene.card_bounds()
	target = box.get_center()
	target.y = 0.0
	var span = maxf(box.size.x, box.size.z)
	var aspect = size.x / maxf(size.y, 1.0) if size.y > 0 else 1.6
	# a portrait panel needs more distance to fit the board's width
	_fit_distance = clampf(span * (0.62 if aspect >= 1.0 else 0.72 / maxf(aspect, 0.3)) + 16.0, 30.0, 900.0)
	distance = _fit_distance
	_place_camera()

func focus_selected() -> void:
	if scene.cards.has(scene.selected_uid):
		target = scene.cards[scene.selected_uid].position
		distance = clampf(minf(distance, 60.0), 20.0, 900.0)
		_place_camera()

func _place_camera() -> void:
	pitch = clampf(pitch, deg_to_rad(12.0), deg_to_rad(85.0))
	var offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	camera.position = target + offset
	camera.look_at(target, Vector3.UP)

# The card under a point of the panel: the nearest block centre on screen,
# within a radius that grows as the board gets closer.
func pick(at: Vector2) -> String:
	var best = ""
	var best_d = 1e9
	var reach = clampf(2600.0 / maxf(distance, 1.0), 18.0, 140.0)
	for uid in scene.cards:
		var c: Vector3 = scene.cards[uid].position + Vector3(0, 2.0, 0)
		if camera.is_position_behind(c):
			continue
		var d = camera.unproject_position(c).distance_to(at)
		if d < reach and d < best_d:
			best = uid
			best_d = d
	return best

func _ground(at: Vector2) -> Vector3:
	var from = camera.project_ray_origin(at)
	var dir = camera.project_ray_normal(at)
	if absf(dir.y) < 0.0001:
		return target
	var t = -from.y / dir.y
	return from + dir * t

func _select(uid: String) -> void:
	scene.select_endpoint(uid)
	endpoint_selected.emit(uid)

func _tap(at: Vector2) -> void:
	var uid = pick(at)
	var now = Time.get_ticks_msec()
	if uid != "" and uid == _last_tap_uid and now - _last_tap < 420:
		endpoint_activated.emit(uid)
		_last_tap = -1000
		return
	_last_tap = now
	_last_tap_uid = uid
	_select(uid)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_press_at = event.position
				_press_card = pick(event.position)
				_dragging = ""
			elif _touches.size() == 2:
				var p = _touches.values()
				_pinch = p[0].distance_to(p[1])
				_dragging = "pan"
		else:
			_touches.erase(event.index)
			if _touches.is_empty():
				if _dragging == "" and event.position.distance_to(_press_at) < 14.0:
					_tap(event.position)
				_dragging = ""
		accept_event()
		return
	if event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			var p = _touches.values()
			var span = p[0].distance_to(p[1])
			if _pinch > 0.0 and span > 0.0:
				distance = clampf(distance * _pinch / span, 12.0, 900.0)
			_pinch = span
			_pan(event.relative * 0.5)
		else:
			if _dragging == "" and event.position.distance_to(_press_at) >= 14.0:
				_dragging = "move" if _press_card != "" and _press_card == scene.selected_uid else "turn"
			if _dragging == "move":
				scene.move_card(_press_card, _ground(event.position))
			elif _dragging == "turn":
				_turn(event.relative)
		accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = clampf(distance / 1.12, 12.0, 900.0)
			_place_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = clampf(distance * 1.12, 12.0, 900.0)
			_place_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_at = event.position
				_press_card = pick(event.position)
				_dragging = ""
				if event.double_click and _press_card != "":
					endpoint_activated.emit(_press_card)
					_dragging = "done"
			else:
				if _dragging == "":
					_select(pick(event.position))
				_dragging = ""
		elif event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dragging = "pan" if event.pressed else ""
		accept_event()
		return
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT and _dragging in ["", "turn", "move"]:
			if _dragging == "" and event.position.distance_to(_press_at) >= 6.0:
				_dragging = "move" if _press_card != "" else "turn"
				if _dragging == "move":
					_select(_press_card)
			if _dragging == "move":
				scene.move_card(_press_card, _ground(event.position))
			elif _dragging == "turn":
				_turn(event.relative)
		elif _dragging == "pan":
			_pan(event.relative)
		accept_event()

func _turn(relative: Vector2) -> void:
	yaw -= relative.x * 0.008
	pitch += relative.y * 0.006
	_place_camera()

func _pan(relative: Vector2) -> void:
	var right = camera.global_transform.basis.x
	var forward = Vector3(-sin(yaw), 0, -cos(yaw))
	var k = distance * 0.0016
	target += (-right * relative.x + forward * relative.y) * k
	_place_camera()
