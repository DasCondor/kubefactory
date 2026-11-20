extends Node3D

const Plan = preload("res://scripts/build_plan.gd")
const Tex = preload("res://scripts/tex.gd")
const Machine = preload("res://scripts/machine.gd")
const STEP = Vector3(6, 6, 6)
static var meshes = {}
var blocks = {}
var paths = []
var bounds = AABB(Vector3(-6, 0, -6), Vector3(12, 5, 12))

static func box(size: Vector3) -> BoxMesh:
	var mesh = BoxMesh.new()
	mesh.size = size
	return mesh

static func role_mesh(role: String) -> ArrayMesh:
	if meshes.has(role):
		return meshes[role]
	var steel = Tex.shared("steel")
	var dark = Tex.shared("dark")
	var body = Tex.mat({"app":Color(0.36,0.68,0.72), "worker":Color(0.83,0.59,0.33), "storage":Color(0.37,0.52,0.72),
		"gateway":Color(0.65,0.67,0.32), "reporting":Color(0.67,0.45,0.72)}.get(role, Color(0.6,0.64,0.66)))
	var parts = [[box(Vector3(4.2,0.25,4.2)), dark, Vector3(0,0.125,0), Vector3.ZERO],
		[box(Vector3(3.9,3.6,3.9)), body, Vector3(0,2.05,0), Vector3.ZERO]]
	match role:
		"app":
			parts.append([box(Vector3(3.4,2.7,0.12)), dark, Vector3(0,2.15,2.0), Vector3.ZERO])
			for y in [1.3,1.9,2.5]:
				parts.append([box(Vector3(2.5,0.12,0.14)), steel, Vector3(-0.1,y,2.1), Vector3.ZERO])
		"worker":
			for y in [0.9,1.5,2.1,2.7,3.3]:
				parts.append([box(Vector3(3.1,0.22,0.15)), dark, Vector3(0,y,2.0), Vector3.ZERO])
			parts.append([box(Vector3(1.7,0.6,1.7)), steel, Vector3(0,4.0,0), Vector3.ZERO])
		"storage":
			for y in [1.0,2.0,3.0]:
				parts.append([box(Vector3(3.5,0.72,0.25)), dark, Vector3(0,y,2.0), Vector3.ZERO])
				parts.append([box(Vector3(0.25,0.25,0.3)), steel, Vector3(-1.3,y,2.18), Vector3.ZERO])
		"gateway":
			for side in [-1,1]:
				for angle in [-PI/4,PI/4]:
					parts.append([box(Vector3(1.0,0.2,0.18)), steel, Vector3(side*0.95,2.2+sin(angle)*0.5,2.1), Vector3(0,0,angle*side)])
			parts.append([box(Vector3(3.2,0.4,0.6)), dark, Vector3(0,3.9,0), Vector3.ZERO])
		"reporting":
			var dial = CylinderMesh.new()
			dial.top_radius = 1.1
			dial.bottom_radius = 1.1
			dial.height = 0.18
			parts.append([dial, dark, Vector3(0,2.1,2.0), Vector3(PI/2,0,0)])
			parts.append([box(Vector3(0.13,1.5,0.2)), steel, Vector3(0.2,2.5,2.15), Vector3(0,0,-0.4)])
			parts.append([box(Vector3(0.16,1.3,0.16)), steel, Vector3(1.2,4.3,0), Vector3.ZERO])
	meshes[role] = Machine._merge(parts)
	return meshes[role]

static func socket_position(node: Dictionary, kind: String, output: bool) -> Vector3:
	var index = Plan.KINDS.find(kind)
	var local = Vector3(2.35 if output else -2.35, 1.1 + floori(index/4.0)*1.1, (index%4-1.5)*0.8)
	return Vector3(node["cell"][0],node["cell"][1],node["cell"][2]) * STEP + Basis(Vector3.UP,int(node["rotation"])*PI/2) * local

func redraw(plan: Dictionary, selected: String = "", preview: Dictionary = {}) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	blocks.clear()
	paths.clear()
	bounds = AABB(Vector3(-6,0,-6),Vector3(12,5,12))
	var by_id = {}
	for item in plan["nodes"]:
		by_id[item["id"]] = item
		var block = Node3D.new()
		block.position = Vector3(item["cell"][0],item["cell"][1],item["cell"][2]) * STEP
		block.rotation.y = int(item["rotation"]) * PI/2
		add_child(block)
		blocks[item["id"]] = block
		bounds = bounds.merge(AABB(block.position-Vector3(3,0,3),Vector3(6,6,6)))
		var visual = MeshInstance3D.new()
		visual.mesh = role_mesh(item["appearance"])
		block.add_child(visual)
		var body = StaticBody3D.new()
		body.set_meta("kf", {"type":"plan_block", "id":item["id"], "name":item["title"], "observed_uid":item.get("observed_uid","")})
		var shape = CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		shape.shape.size = Vector3(4.2,5.0,4.2)
		shape.position.y = 2.5
		body.add_child(shape)
		block.add_child(body)
		var title = Label3D.new()
		title.text = item["title"] + "\n" + str(item["appearance"]).to_upper()
		title.font_size = 40
		title.pixel_size = 0.012
		title.position = Vector3(0,5.4,0)
		title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		block.add_child(title)
		if item["id"] == selected:
			var rim = MeshInstance3D.new()
			rim.mesh = box(Vector3(4.5,0.08,4.5))
			rim.position.y = 0.30
			rim.material_override = Tex.glow(Color(1,0.6,0.2),1)
			block.add_child(rim)
		for kind in Plan.sockets(item):
			for output in [false,true]:
				var port = StaticBody3D.new()
				port.position = block.to_local(to_global(socket_position(item,kind,output)))
				port.set_meta("kf", {"type":"plan_socket", "id":item["id"], "kind":kind, "output":output})
				var mesh = MeshInstance3D.new()
				mesh.mesh = box(Vector3(0.38,0.38,0.38)) if output else SphereMesh.new()
				if not output:
					mesh.mesh.radius = 0.22
					mesh.mesh.height = 0.44
				mesh.material_override = Tex.mat(Plan.COLORS[kind])
				port.add_child(mesh)
				var hit = CollisionShape3D.new()
				hit.shape = SphereShape3D.new()
				hit.shape.radius = 0.35
				port.add_child(hit)
				block.add_child(port)
	var route_meshes = {}
	var edges = plan["edges"].duplicate(true)
	if not preview.is_empty():
		edges.append(preview)
	for i in edges.size():
		var edge = edges[i]
		if not by_id.has(edge["from"]) or not by_id.has(edge["to"]):
			continue
		var a = by_id[edge["from"]]
		var b = by_id[edge["to"]]
		var start = socket_position(a,edge["kind"],true)
		var end = socket_position(b,edge["kind"],false)
		var height = bounds.end.y + 1.0 + i*0.22
		var points = [start, start+Basis(Vector3.UP,int(a["rotation"])*PI/2)*Vector3.RIGHT*0.8]
		points.append(Vector3(points[-1].x,height,points[-1].z))
		var drop = end+Basis(Vector3.UP,int(b["rotation"])*PI/2)*Vector3.LEFT*0.8
		points.append(Vector3(drop.x,height,points[-1].z))
		points.append(Vector3(drop.x,height,drop.z))
		points.append(drop)
		points.append(end)
		paths.append({"edge":edge, "points":points})
		var key: String = edge["kind"]
		if edge == preview:
			key = "Preview"
		if not route_meshes.has(key):
			route_meshes[key] = []
		for j in range(1,points.size()):
			var delta: Vector3 = points[j]-points[j-1]
			if delta.length() > 0.001:
				route_meshes[key].append(Transform3D(Basis(Quaternion(Vector3.UP,delta.normalized())).scaled(Vector3(0.15,delta.length(),0.15)),(points[j]+points[j-1])*0.5))
	for kind in route_meshes:
		var pipe = CylinderMesh.new()
		pipe.top_radius = 0.5
		pipe.bottom_radius = 0.5
		pipe.height = 1.0
		pipe.radial_segments = 8
		pipe.material = Tex.mat(Color.WHITE if kind == "Preview" else Plan.COLORS[kind])
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pipe
		mm.instance_count = route_meshes[kind].size()
		for i in mm.instance_count:
			mm.set_instance_transform(i,route_meshes[kind][i])
		var view = MultiMeshInstance3D.new()
		view.multimesh = mm
		add_child(view)
	var floor_mesh = MeshInstance3D.new()
	floor_mesh.mesh = box(Vector3(bounds.size.x+12,0.15,bounds.size.z+12))
	floor_mesh.position = Vector3(bounds.get_center().x,-0.12,bounds.get_center().z)
	floor_mesh.material_override = Tex.mat(Color(0.22,0.26,0.28))
	add_child(floor_mesh)
	# Grid lines sit above the floor rather than sharing its surface.
	for axis in [0,2]:
		for value in range(int(bounds.position[axis])-6,int(bounds.end[axis])+7,6):
			var line = MeshInstance3D.new()
			line.mesh = box(Vector3(0.035,0.025,bounds.size.z+12) if axis == 0 else Vector3(bounds.size.x+12,0.025,0.035))
			line.position = Vector3(value,0.0,bounds.get_center().z) if axis == 0 else Vector3(bounds.get_center().x,0.0,value)
			line.material_override = Tex.shared("steel")
			add_child(line)
