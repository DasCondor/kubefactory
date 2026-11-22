extends SubViewportContainer
# The connection board in a panel: the board scene (board_scene.gd, style "iso")
# in its own world, drawn as an isometric diagram on grid paper, or from straight
# above as a 2D diagram. The camera is orthographic, so tiles keep their size
# wherever they are. Mouse: drag empty paper to pan, wheel to zoom, click to
# select, double-click to open files, drag a block to move it. Touch: drag to
# pan (or move the selected block), pinch to zoom, tap selects, double-tap opens.
# Callout pills on the selected block's routes say what each one carries.
# It offers the same calls as the flat board, so the panel's buttons work on both.

signal endpoint_activated(uid: String)
signal endpoint_selected(uid: String)

const BoardScene = preload("res://scripts/board_scene.gd")
const ISO_PITCH = 35.264      # true isometric: the camera looks down atan(1/sqrt(2))
const ISO_YAW = 45.0

var scene: Node3D
var viewport: SubViewport
var camera: Camera3D
var view = "iso"              # "iso" or "2d"
var target = Vector3.ZERO
var ortho = 80.0              # what the camera shows, top to bottom, in board units
var _fit_ortho = 80.0
var _touches = {}             # index -> position
var _press_at = Vector2.ZERO
var _press_card = ""
var _dragging = ""            # what a drag is doing: "pan", "move"
var _last_tap = -1000
var _last_tap_uid = ""
var _pinch = 0.0
var _overlay: Control
var _pills = []               # [world position, Control]
var _pill_sig = ""
var _framed = true            # still showing "Fit board": refit when the panel changes size

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
	get: return _fit_ortho / maxf(ortho, 0.01)
	set(value):
		_framed = false
		ortho = clampf(_fit_ortho / maxf(value, 0.05), 8.0, 900.0)
		_place_camera()

func _init(mode: String = "iso") -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.handle_input_locally = false
	add_child(viewport)
	var env = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = BoardScene.PAPER
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.62
	env.environment = e
	viewport.add_child(env)
	# light from the upper left: bright roofs, two side faces in two shades
	var sun = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-62), deg_to_rad(-20), 0)
	sun.light_energy = 0.75
	viewport.add_child(sun)
	viewport.add_child(_paper())
	scene = BoardScene.new()
	scene.style = "iso"
	viewport.add_child(scene)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 1000.0
	viewport.add_child(camera)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(_overlay)
	set_view(mode)
	# a phone lays the panel out after it opens; keep the fit until the player moves the view
	resized.connect(func():
		if _framed and size.x > 0 and size.y > 0:
			fit_routes())

# Grid paper: a light floor with fine lines every 2 units and stronger ones
# every 10; from the isometric camera the squares read as diamonds.
func _paper() -> MeshInstance3D:
	var floor_mesh = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(1600, 1600)
	floor_mesh.mesh = plane
	var sh = Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded;
uniform vec4 paper : source_color;
uniform vec4 ink : source_color;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float grid(vec2 p, float step, float w) {
	vec2 g = abs(fract(p / step - 0.5) - 0.5) / fwidth(p / step);
	return 1.0 - min(min(g.x, g.y) / w, 1.0);
}
void fragment() {
	float fine = grid(wp.xz, 2.0, 1.0) * 0.22;
	float bold = grid(wp.xz, 10.0, 1.2) * 0.38;
	ALBEDO = mix(paper.rgb, ink.rgb, max(fine, bold));
}
"""
	var m = ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("paper", BoardScene.PAPER)
	m.set_shader_parameter("ink", Color(0.62, 0.64, 0.66))
	floor_mesh.material_override = m
	floor_mesh.position.y = -0.02
	return floor_mesh

func set_view(mode: String) -> void:
	view = "2d" if mode == "2d" else "iso"
	scene.set_view(view)
	_place_camera()

func configure(config) -> void:
	scene.configure(config)

func refresh(state: Dictionary) -> bool:
	var changed = scene.refresh(state)
	if changed:
		_pill_sig = ""
	return changed

func select_endpoint(uid: String) -> void:
	scene.select_endpoint(uid)

func connection_list() -> Array:
	return scene.connection_list()

func arrange_spider() -> void:
	scene.arrange_spider()

# Frame every block: the flat board's "Fit board". The board's corners are
# measured along the camera's own axes, so it fits in either view and any panel shape.
func fit_routes() -> void:
	if scene.cards.is_empty():
		return
	_place_camera()
	# every tile's corners (with room for its labels) along the camera's axes:
	# the tiles themselves, not the box around them, which the turn would inflate
	var right = camera.global_transform.basis.x
	var up = camera.global_transform.basis.y
	var lo = Vector2(1e9, 1e9)
	var hi = Vector2(-1e9, -1e9)
	var t = BoardScene.TILE * 0.5 + Vector3(1.5, 0, 1.5)
	for c in scene.cards.values():
		for corner in [Vector3(-t.x, -1.5, -t.z), Vector3(t.x, -1.5, -t.z), Vector3(-t.x, -1.5, t.z), Vector3(t.x, -1.5, t.z),
				Vector3(-t.x, BoardScene.TILE.y + 2.0, -t.z), Vector3(t.x, BoardScene.TILE.y + 2.0, t.z), Vector3(-t.x, BoardScene.TILE.y + 2.0, t.z), Vector3(t.x, BoardScene.TILE.y + 2.0, -t.z)]:
			var p: Vector3 = c.position + corner
			var s = Vector2(p.dot(right), p.dot(up))
			lo = lo.min(s)
			hi = hi.max(s)
	var mid = (lo + hi) * 0.5
	# the ground point that lands in the middle of the screen
	var fwd = -camera.global_transform.basis.z
	var centre = right * mid.x + up * mid.y
	target = centre - fwd * (centre.y / fwd.y) if absf(fwd.y) > 0.001 else Vector3(centre.x, 0, centre.z)
	target.y = 0.0
	var aspect = size.x / maxf(size.y, 1.0) if size.y > 0 else 1.6
	_fit_ortho = clampf(maxf(hi.y - lo.y, (hi.x - lo.x) / maxf(aspect, 0.2)) * 1.06, 16.0, 900.0)
	if size.x > 0 and size.x < 560:
		# a phone: never so small a tile is unreadable; the rest is a drag away
		_fit_ortho = minf(_fit_ortho, size.y * BoardScene.TILE.x / 44.0)
	_framed = true
	ortho = _fit_ortho
	_place_camera()

func focus_selected() -> void:
	if scene.cards.has(scene.selected_uid):
		_framed = false
		target = scene.cards[scene.selected_uid].position
		target.y = 0.0
		ortho = clampf(minf(ortho, 50.0), 12.0, 900.0)
		_place_camera()

func _place_camera() -> void:
	if camera == null:
		return
	camera.size = ortho
	if view == "2d":
		camera.rotation = Vector3(-PI / 2.0, 0, 0)
		camera.position = target + Vector3(0, 400, 0)
	else:
		var yaw = deg_to_rad(ISO_YAW)
		var pitch = deg_to_rad(ISO_PITCH)
		var at = target + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * 400.0
		# set outright: this also runs before the camera is in the tree
		camera.transform = Transform3D(Basis.looking_at(target - at, Vector3.UP), at)
	_pill_sig = ""

# The card under a point of the panel: the nearest tile centre on screen, within
# about one tile.
func pick(at: Vector2) -> String:
	var best = ""
	var best_d = 1e9
	var px_per_unit = viewport.size.y / maxf(camera.size, 0.01)
	var reach = maxf(BoardScene.TILE.x * px_per_unit * 0.75, 18.0)
	for uid in scene.cards:
		var c: Vector3 = scene.cards[uid].position + Vector3(0, BoardScene.TILE.y * 0.5, 0)
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
	return from + dir * (-from.y / dir.y)

func _select(uid: String) -> void:
	scene.select_endpoint(uid)
	endpoint_selected.emit(uid)
	_pill_sig = ""

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

# Drag the paper: the point under the finger stays under the finger.
func _pan(from: Vector2, to: Vector2) -> void:
	_framed = false
	target -= _ground(to) - _ground(from)
	target.y = 0.0
	_place_camera()

func _zoom_by(factor: float) -> void:
	_framed = false
	ortho = clampf(ortho * factor, 8.0, 900.0)
	_place_camera()

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
		var before: Vector2 = _touches.get(event.index, event.position - event.relative)
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			var p = _touches.values()
			var span = p[0].distance_to(p[1])
			if _pinch > 0.0 and span > 0.0:
				_zoom_by(_pinch / span)
			_pinch = span
			_pan(event.position - event.relative * 0.5, event.position)    # two fingers: the middle moves half as far
		else:
			if _dragging == "" and event.position.distance_to(_press_at) >= 14.0:
				_dragging = "move" if _press_card != "" and _press_card == scene.selected_uid else "pan"
			if _dragging == "move":
				scene.move_card(_press_card, _ground(event.position))
				_pill_sig = ""
			elif _dragging == "pan":
				_pan(before, event.position)
		accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_by(1.0 / 1.12)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_by(1.12)
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
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT and _dragging in ["", "pan", "move"]:
			if _dragging == "" and event.position.distance_to(_press_at) >= 6.0:
				_dragging = "move" if _press_card != "" else "pan"
				if _dragging == "move":
					_select(_press_card)
			if _dragging == "move":
				scene.move_card(_press_card, _ground(event.position))
				_pill_sig = ""
			elif _dragging == "pan":
				_pan(event.position - event.relative, event.position)
		elif _dragging == "pan":
			_pan(event.position - event.relative, event.position)
		accept_event()

# ----- callout pills over the scene

func _process(_delta: float) -> void:
	var list: Array = scene.badges()
	var sig = str(list.map(func(b): return [b[0], b[1]]))
	if sig != _pill_sig:
		_pill_sig = sig
		for p in _pills:
			p[1].queue_free()
		_pills.clear()
		for b in list:
			_pills.append([b[0], _pill(b[1], b[2])])
	# pills that would cover each other are nudged down until they don't
	var placed = []
	for p in _pills:
		var at = camera.unproject_position(p[0])
		var r = Rect2((at - p[1].size * 0.5).round(), p[1].size)
		for i in 8:
			if not placed.any(func(q): return q.grow(2).intersects(r)):
				break
			r.position.y += r.size.y + 4
		placed.append(r)
		p[1].position = r.position

func _pill(text: String, color: Color) -> Control:
	var pc = PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb = StyleBoxFlat.new()
	sb.bg_color = color.lerp(BoardScene.PAPER, 0.6)
	sb.border_color = BoardScene.INK
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	pc.add_theme_stylebox_override("panel", sb)
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", BoardScene.INK)
	pc.add_child(l)
	_overlay.add_child(pc)
	return pc
