extends RefCounted
# The supplied model library (assets/, 141 IDs x Standard / Enhanced / Ultra).
#
# GLBs are read at run time straight from the assets folder beside the game
# (GLTFDocument), not imported into the project: nothing to pre-build, the
# browser export stays as light as it was (it has no assets folder and keeps
# the code-drawn models), and a missing file simply falls back to those.
#
# A loaded model is turned into a template once and then shared by every
# instance: its fixed parts are merged into one mesh per material, and the
# parts the game needs to drive are kept apart:
#   accent   the armour panels, recoloured with the workload's own colour
#   lamp     the status lamp (the game sets its colour)
#   door     the service door leaf, hung on its own pivot so it can open
#   screen   the LiveView glass: a separate quad the game draws on, with the
#            decorative glyph the model shipped with removed
#
# Only categories built to the Porter V3 standard are used in the world
# (krew, machines). The V2 categories stay in the library, catalogued, until
# they are rebuilt: see docs/MODEL_AUDIT.md.

const K = preload("res://scripts/kutil.gd")
const Gfx = preload("res://scripts/gfx.gd")

const TIERS = ["standard", "enhanced", "ultra"]
# Corrections applied when a model is loaded: verified defects in the supplied
# files, fixed here so the files themselves stay byte-identical to the library.
#   move:  shift every node whose name starts with one of `nodes`
#   posts: steel brackets added to carry what was moved, as [size, centre]
const FIXUPS = {
	# The display was modelled between the two vessel domes and cut into both
	# (frame y 1.92-2.24 against cap tops at y 2.10). It now stands on two posts
	# on top of the housing, clear of the vessels from every side.
	"statefulset": {"nodes": ["LiveView_"], "move": Vector3(0, 0.56, -0.25),
		"posts": [[Vector3(0.05, 0.1, 0.05), Vector3(-0.25, 2.445, 0.62)], [Vector3(0.05, 0.1, 0.05), Vector3(0.25, 2.445, 0.62)]]},
	"database_server": {"nodes": ["LiveView_"], "move": Vector3(0, 0.56, -0.25),
		"posts": [[Vector3(0.05, 0.1, 0.05), Vector3(-0.25, 2.445, 0.62)], [Vector3(0.05, 0.1, 0.05), Vector3(0.25, 2.445, 0.62)]]},
}

static var _catalog = {}
static var _templates = {}
static var _root = ""
static var _checked = false

static func root() -> String:
	if not _checked:
		_checked = true
		var p = K.data_path("assets")
		if not OS.has_feature("web") and FileAccess.file_exists(p.path_join("catalog.json")):
			_root = p
			var d = K.read_json(p.path_join("catalog.json"))
			if typeof(d) == TYPE_DICTIONARY:
				for m in d.get("models", []):
					_catalog[str(m["id"])] = m
	return _root

# The library is used on the desktop renderer; the browser / compatibility
# path keeps the lighter code-drawn models.
static func available() -> bool:
	return root() != "" and not Gfx.lite()

static func entry(id: String) -> Dictionary:
	root()
	return _catalog.get(id, {})

static func ids(category: String = "") -> Array:
	root()
	var r = []
	for id in _catalog:
		if category == "" or _catalog[id].get("category") == category:
			r.append(id)
	r.sort()
	return r

static func tier() -> String:
	return TIERS[Gfx.detail()]

# ---- which machine model stands for which workload

# Chosen from what the pod actually is: its image first (a database is a
# database whatever controller runs it), then its workload kind.
static func machine_for(pod: Dictionary) -> String:
	var images = ""
	for c in pod.get("containers", []):
		images += str(c.get("image", "")).to_lower() + " "
	var name = (str(pod.get("wname", "")) + " " + str(pod.get("name", ""))).to_lower()
	var both = images + name
	var by_image = [
		[["postgres", "mysql", "mariadb", "mongo", "cockroach", "influxdb", "clickhouse", "mssql", "timescale", "catalog-db"], "database_server"],
		[["redis", "memcached", "valkey", "sccache", "dragonfly"], "cache_server"],
		[["kafka", "rabbitmq", "nats", "mosquitto", "pulsar", "activemq"], "broker_rack"],
		[["prometheus", "grafana", "alertmanager", "tautulli", "uptime-kuma", "cadvisor"], "monitoring_server"],
		[["loki", "fluent", "promtail", "logstash", "vector", "node-exporter", "filebeat"], "log_collector"],
		[["registry", "harbor", "minio", "nexus", "artifactory"], "registry_rack"],
		[["nginx", "traefik", "envoy", "haproxy", "ingress", "caddy", "kube-proxy", "frontend"], "load_balancer"],
		[["coredns", "dns", "pihole", "adguard", "wireguard", "tailscale", "zigbee2mqtt", "zwave"], "network_appliance"],
		[["buildkit", "woodpecker", "drone", "jenkins", "runner", "kaniko", "devcontainer", "code-server", "builder", "gitea"], "build_station"],
	]
	for row in by_image:
		for key in row[0]:
			if both.contains(key):
				return row[1]
	match str(pod.get("wkind", "")):
		"StatefulSet":
			return "statefulset"
		"DaemonSet":
			return "daemonset"
		"Job":
			return "job_station"
		"CronJob":
			return "cronjob_station"
		"Deployment":
			return "deployment_line"
		"Compose":
			return "compose_stack"
	return "container_machine" if str(pod.get("wkind", "")) != "Pod" else "pod_machine"

# ---- loading

static func _load_scene(id: String, t: String) -> Node3D:
	var e = entry(id)
	if e.is_empty():
		return null
	var v = e.get("variants", {}).get(t)
	if v == null:
		return null
	var path = _root.path_join(str(v["path"]).trim_prefix("assets/"))
	if not FileAccess.file_exists(path):
		return null
	var doc = GLTFDocument.new()
	var st = GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		return null
	return doc.generate_scene(st)

static func _collect(n: Node, xf: Transform3D, out: Array) -> void:
	var t = xf
	if n is Node3D:
		t = xf * n.transform
	if n is MeshInstance3D and n.mesh != null:
		out.append([str(n.name), n.mesh, t])
	for c in n.get_children():
		_collect(c, t, out)

static func _merge(parts: Array, shift: Vector3 = Vector3.ZERO) -> ArrayMesh:
	if parts.is_empty():
		return null
	var by_mat = {}
	for p in parts:
		var mesh: Mesh = p[1]
		for s in mesh.get_surface_count():
			var mat = mesh.surface_get_material(s)
			if not by_mat.has(mat):
				by_mat[mat] = SurfaceTool.new()
			by_mat[mat].append_from(mesh, s, Transform3D(Basis.IDENTITY, shift) * p[2])
	var res = ArrayMesh.new()
	for mat in by_mat:
		by_mat[mat].commit(res)
		res.surface_set_material(res.get_surface_count() - 1, mat)
	return res

static func _aabb(parts: Array) -> AABB:
	var a = AABB()
	var first = true
	for p in parts:
		var b = p[2] * p[1].get_aabb()
		a = b if first else a.merge(b)
		first = false
	return a

static func _box(size: Vector3, at: Vector3, mat: Material) -> Array:
	var b = BoxMesh.new()
	b.size = size
	b.material = mat
	return ["_built", b, Transform3D(Basis.IDENTITY, at)]

# A template for one model at one tier, or {} if it cannot be loaded:
#   core, accent, lamp, door (ArrayMesh or null)   bounds (AABB, model units)
#   screen: {pos, size, normal}   lamp_at   door: {hinge, aabb, side}   cavity: AABB
static func template(id: String, t: String = "") -> Dictionary:
	if t == "":
		t = tier()
	var key = id + ":" + t
	if _templates.has(key):
		return _templates[key]
	_templates[key] = {}
	var scene = _load_scene(id, t)
	if scene == null:
		return {}
	var parts = []
	_collect(scene, Transform3D.IDENTITY, parts)
	scene.free()
	var fix = FIXUPS.get(id, {})
	var steel: Material = null
	var frame: Material = null
	var accent_name = ""
	for p in parts:
		var nm: String = p[0]
		for pre in fix.get("nodes", []):
			if nm.begins_with(pre):
				p[2] = Transform3D(Basis.IDENTITY, fix["move"]) * p[2]
		var mat = p[1].surface_get_material(0)
		if nm.ends_with("_steel") and steel == null:
			steel = mat
		if nm.ends_with("_frame") and frame == null:
			frame = mat
		if nm.begins_with("TopArmor_"):
			accent_name = nm.get_slice("_", 1)
	for post in fix.get("posts", []):
		parts.append(_box(post[0], post[1], steel))

	var core = []
	var accent = []
	var lamp = []
	var door = []
	var screen_glass = []
	var chassis = []
	# The service door: the front door where the model has one, otherwise the rear
	# service panel. `side` is +1 for a door on the front (+Z) face, -1 for the rear.
	var front_leaf = ["Door_", "DoorInset_", "DoorHandle_", "HandleMount_", "FrontVent_"]
	var rear_leaf = ["RearServicePanel_", "RearFan_", "RearVent_", "RearPort_"]
	var is_leaf = func(nm: String, list: Array) -> bool:
		return list.any(func(pre): return nm.begins_with(pre))
	var side = 0
	if parts.any(func(p): return str(p[0]).begins_with("Door_")):
		side = 1
	elif parts.any(func(p): return str(p[0]).begins_with("RearServicePanel_")):
		side = -1
	var door_leaf = front_leaf if side > 0 else rear_leaf
	# is the screen mounted on the door? then it is part of the leaf and swings with it
	var screen_on_door = false
	if side > 0:
		var d0 = _aabb(parts.filter(func(p): return is_leaf.call(str(p[0]), door_leaf)))
		for p in parts:
			if str(p[0]) == "LiveView_glass":
				var c0 = (p[2] * p[1].get_aabb()).get_center()
				screen_on_door = c0.x > d0.position.x and c0.x < d0.end.x and c0.y > d0.position.y and c0.y < d0.end.y
	for p in parts:
		var nm: String = p[0]
		if nm.begins_with("StatusLamp_"):
			lamp.append(p)
		elif nm.begins_with("LiveView_") and not nm.ends_with("_frame") and not nm.ends_with("_glass"):
			pass    # the decorative glyph: dropped, the game draws the real screen
		elif nm.begins_with("LiveView_glass"):
			screen_glass.append(p)
			if screen_on_door:
				door.append(p)
		elif nm == "Chassis_frame":
			chassis.append(p)
		elif side != 0 and (is_leaf.call(nm, door_leaf) or (screen_on_door and nm.begins_with("LiveView_frame"))):
			door.append(p)
		elif accent_name != "" and nm.ends_with("_" + accent_name):
			accent.append(p)
		else:
			core.append(p)
	var res = {"id": id, "tier": t, "bounds": _aabb(parts)}
	# the screen: where the glass is, facing +Z (the asset front)
	if not screen_glass.is_empty():
		var g = _aabb(screen_glass)
		res["screen"] = {"pos": g.get_center() + Vector3(0, 0, g.size.z / 2.0 + 0.004), "size": Vector2(g.size.x, g.size.y), "on_door": screen_on_door}
		if not screen_on_door:
			core.append_array(screen_glass)
	if not lamp.is_empty():
		res["lamp_at"] = _aabb(lamp).get_center()
	# The solid chassis block is replaced by a hollow housing (five walls and a
	# framed opening), so there is a real interior behind the door.
	if side != 0 and not door.is_empty() and not chassis.is_empty():
		var c = _aabb(chassis)
		var d = _aabb(door)
		var w = 0.05     # wall thickness
		var lo = c.position
		var hi = c.end
		var cc = c.get_center()
		var open_z = (hi.z - w / 2.0) if side > 0 else (lo.z + w / 2.0)
		var back_z = (lo.z + w / 2.0) if side > 0 else (hi.z - w / 2.0)
		core.append(_box(Vector3(c.size.x, c.size.y, w), Vector3(cc.x, cc.y, back_z), frame))
		core.append(_box(Vector3(w, c.size.y, c.size.z), Vector3(lo.x + w / 2.0, cc.y, cc.z), frame))
		core.append(_box(Vector3(w, c.size.y, c.size.z), Vector3(hi.x - w / 2.0, cc.y, cc.z), frame))
		core.append(_box(Vector3(c.size.x, w, c.size.z), Vector3(cc.x, lo.y + w / 2.0, cc.z), frame))
		core.append(_box(Vector3(c.size.x, w, c.size.z), Vector3(cc.x, hi.y - w / 2.0, cc.z), frame))
		# the door's face, as four strips round the opening (the leaf overlaps them by its rim)
		var rim = 0.045
		var ox0 = maxf(d.position.x + rim, lo.x + w)
		var ox1 = minf(d.end.x - rim, hi.x - w)
		var oy0 = maxf(d.position.y + rim, lo.y + w)
		var oy1 = minf(d.end.y - rim, hi.y - w)
		core.append(_box(Vector3(ox0 - lo.x, c.size.y, w), Vector3((ox0 + lo.x) / 2.0, cc.y, open_z), frame))
		core.append(_box(Vector3(hi.x - ox1, c.size.y, w), Vector3((hi.x + ox1) / 2.0, cc.y, open_z), frame))
		core.append(_box(Vector3(ox1 - ox0, oy0 - lo.y, w), Vector3((ox0 + ox1) / 2.0, (oy0 + lo.y) / 2.0, open_z), frame))
		core.append(_box(Vector3(ox1 - ox0, hi.y - oy1, w), Vector3((ox0 + ox1) / 2.0, (hi.y + oy1) / 2.0, open_z), frame))
		# The hinge line: where the model put its hinge hardware on a front door (its
		# right-hand edge), the matching edge on a rear panel. The leaf hangs from it
		# along `along` and swings out towards `out`.
		var hinge: Vector3
		if side > 0:
			hinge = Vector3(d.end.x, d.get_center().y, d.position.z)
			for p in parts:
				if str(p[0]).begins_with("DoorHinge_"):
					var h = p[2] * p[1].get_aabb()
					hinge = Vector3(h.get_center().x, d.get_center().y, h.get_center().z)
		else:
			hinge = Vector3(d.position.x, d.get_center().y, d.end.z)
		res["door"] = {"hinge": hinge, "aabb": d, "width": d.size.x, "side": side,
			"along": Vector3(-1, 0, 0) if side > 0 else Vector3(1, 0, 0), "out": Vector3(0, 0, side)}
		var depth = c.size.z - 2.0 * w
		res["cavity"] = AABB(Vector3(ox0, oy0, lo.z + w), Vector3(ox1 - ox0, oy1 - oy0, depth))
		res["door_mesh"] = _merge(door, -hinge)      # modelled about its hinge, so the pivot node sits on the hinge
	else:
		if res.has("screen"):
			res["screen"]["on_door"] = false
		core.append_array(chassis)
		core.append_array(door)
	res["core"] = _merge(core)
	res["accent"] = _merge(accent)
	res["lamp"] = _merge(lamp)
	_templates[key] = res
	return res

# A whole model as one node, parts merged by material (characters, props).
static func instance(id: String, t: String = "") -> Node3D:
	if not available():
		return null
	if t == "":
		t = tier()
	var key = "whole:" + id + ":" + t
	if not _templates.has(key):
		var scene = _load_scene(id, t)
		if scene == null:
			_templates[key] = {}
		else:
			var parts = []
			_collect(scene, Transform3D.IDENTITY, parts)
			scene.free()
			_templates[key] = {"mesh": _merge(parts), "bounds": _aabb(parts)}
	var tpl = _templates[key]
	if tpl.is_empty():
		return null
	var n = Node3D.new()
	var mi = MeshInstance3D.new()
	mi.mesh = tpl["mesh"]
	n.add_child(mi)
	n.set_meta("bounds", tpl["bounds"])
	return n

static func clear_cache() -> void:
	_templates.clear()
