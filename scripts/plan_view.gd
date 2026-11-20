extends SubViewportContainer

signal selected(id)
signal socket_picked(socket)
signal edited
const Blocks = preload("res://scripts/plan_blocks.gd")
var model
var viewport = SubViewport.new()
var scene = Node3D.new()
var blocks = Blocks.new()
var camera = Camera3D.new()
var ghost = MeshInstance3D.new()
var active_id = ""
var mode = "Select"
var role = "app"
var cell = [0,0,0]
var turn = 0
var preview = {}
var orbit = 0.0

func _ready() -> void:
	stretch = true
	focus_mode = Control.FOCUS_ALL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size.y = 360
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.add_child(scene)
	scene.add_child(blocks)
	scene.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 3000
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.13,0.17,0.21)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.8,0.85,0.95)
	environment.environment.ambient_light_energy = 0.7
	scene.add_child(environment)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50,-35,0)
	sun.light_energy = 1.5
	scene.add_child(sun)
	ghost.mesh = Blocks.box(Vector3(4.3,5.0,4.3))
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(ghost)
	gui_input.connect(_event)
	resized.connect(func(): fit())
	refresh()

func refresh() -> void:
	if model == null or not is_inside_tree():
		return
	blocks.redraw(model.data,active_id,preview)
	update_ghost()

func fit() -> void:
	if size.x < 1 or size.y < 1:
		return
	camera.size = maxf(18, maxf(blocks.bounds.size.z+20,(blocks.bounds.size.x+20)*size.y/size.x)*1.5)
	look()

func look() -> void:
	var target = blocks.bounds.get_center()
	var offset = Basis(Vector3.UP,orbit)*Vector3(0.8,1.3,1.1).normalized()*maxf(80,blocks.bounds.size.length()*2)
	camera.position = target+offset
	camera.look_at(target,Vector3.UP)

func update_ghost() -> void:
	ghost.visible = mode in ["Place","Move"]
	ghost.position = Vector3(cell[0],cell[1],cell[2])*Blocks.STEP+Vector3.UP*2.5
	ghost.rotation.y = turn*PI/2
	var occupied = model.data["nodes"].any(func(n): return n["cell"] == cell and (mode != "Move" or n["id"] != active_id))
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1,0.25,0.2,0.35) if occupied else Color(0.3,1,0.6,0.35)
	ghost.material_override = material

func place() -> void:
	if mode == "Move":
		model.edit(active_id,{"cell":cell.duplicate(), "rotation":turn})
	elif mode == "Place":
		var id = model.add("New " + role,cell,role,"",turn)
		if id != "":
			active_id = id
			selected.emit(id)
	else:
		return
	edited.emit()

func _event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mode in ["Place","Move"]:
		var point = event.position*Vector2(viewport.size)/size
		var pos = Plane(Vector3.UP,cell[1]*Blocks.STEP.y).intersects_ray(camera.project_ray_origin(point),camera.project_ray_normal(point))
		if pos != null:
			cell = [clampi(roundi(pos.x/6),-128,128),cell[1],clampi(roundi(pos.z/6),-128,128)]
			update_ghost()
	if event is InputEventMouseButton and event.pressed:
		grab_focus()
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			camera.size = clampf(camera.size*(0.85 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.15),6,1500)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if mode in ["Place","Move"]:
				place()
			else:
				var point = event.position*Vector2(viewport.size)/size
				var origin = camera.project_ray_origin(point)
				var hit = scene.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin,origin+camera.project_ray_normal(point)*3000))
				var meta = hit.get("collider").get_meta("kf",{}) if hit.has("collider") else {}
				if meta.get("type") == "plan_socket" and mode == "Connect":
					socket_picked.emit(meta)
				elif meta.has("id"):
					active_id = meta["id"]
					selected.emit(active_id)
			accept_event()
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			if mode in ["Place","Move"]:
				turn = (turn+1)%4
				update_ghost()
			else:
				var node = model.node(active_id)
				if node != null:
					model.edit(active_id,{"rotation":(int(node["rotation"])+1)%4})
					edited.emit()
		elif event.keycode == KEY_DELETE:
			model.remove([active_id])
			edited.emit()
		elif event.ctrl_pressed and event.keycode == KEY_Z:
			model.undo()
			edited.emit()
		elif event.keycode in [KEY_ENTER,KEY_SPACE] and mode in ["Place","Move"]:
			place()
		elif event.keycode in [KEY_LEFT,KEY_RIGHT,KEY_UP,KEY_DOWN,KEY_PAGEUP,KEY_PAGEDOWN]:
			var delta = {KEY_LEFT:Vector3i.LEFT,KEY_RIGHT:Vector3i.RIGHT,KEY_UP:Vector3i.FORWARD,KEY_DOWN:Vector3i.BACK,KEY_PAGEUP:Vector3i.UP,KEY_PAGEDOWN:Vector3i.DOWN}[event.keycode]
			var node = model.node(active_id)
			var base = cell if mode in ["Place","Move"] or node == null else node["cell"]
			cell = [base[0]+delta.x,base[1]+delta.y,base[2]+delta.z]
			if mode == "Select" and node != null:
				model.edit(active_id,{"cell":cell.duplicate()})
				edited.emit()
			else:
				update_ghost()
		else:
			return
		accept_event()
