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
#   screen   the LiveView glass: a separate quad the game draws on
#   name / list surfaces: the glasses that show the real resource name and
#            container list; type_label: the permanent model-type plate
#
# Only categories built to the Porter V3 standard are used in the world
# (krew, machines). The V2 categories stay in the library, catalogued, until
# they are rebuilt: see docs/MODEL_AUDIT.md.

const K = preload("res://scripts/kutil.gd")
const Gfx = preload("res://scripts/gfx.gd")

const TIERS = ["standard", "enhanced", "ultra"]
# Corrections applied when a model is loaded: verified defects in the supplied
# files, fixed here so the files themselves stay byte-identical to the library.
# The V6 library needs none (the V4 display fault it used to correct is gone).
#   move:  shift every node whose name starts with one of `nodes`
#   posts: steel brackets added to carry what was moved, as [size, centre]
const FIXUPS = {}

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

# A machine in the world is one pod (or one Docker container), and the model's
# plate says what it is, so the choice has to be true:
#   - a pod is a POD and a Docker container a CONTAINER, whatever owns it. A
#     Deployment's pod is not "a Deployment", so the workload models are not used
#     for pods
#   - a pod gets a role model (DATABASE SERVER, CACHE SERVER...) only when the
#     image it runs is that software. The image's own name decides: the last part
#     of its path, without registry host, organisation or tag. "registry.k8s.io/
#     coredns/coredns" is coredns, not a registry; a pod called "frontend" is not
#     a load balancer
# Health never picks the model: the beacon and the status line show it.
const ROLES = [
	[["postgres", "postgresql", "mysql", "mariadb", "mongo", "mongodb", "cockroach", "influxdb", "clickhouse", "mssql", "timescaledb"], "database_server"],
	[["redis", "memcached", "valkey", "dragonfly", "sccache"], "cache_server"],
	[["kafka", "rabbitmq", "nats", "mosquitto", "pulsar", "activemq"], "broker_rack"],
	[["prometheus", "grafana", "alertmanager", "tautulli", "uptime-kuma"], "monitoring_server"],
	[["loki", "fluentd", "fluent-bit", "promtail", "logstash", "vector", "filebeat"], "log_collector"],
	[["registry", "harbor-core", "harbor-registry", "nexus", "nexus3", "artifactory"], "registry_rack"],
	[["traefik", "haproxy", "envoy", "nginx-ingress", "nginx-ingress-controller"], "load_balancer"],
	[["coredns", "pihole", "adguardhome", "wireguard", "tailscale", "kube-proxy"], "network_appliance"],
	[["buildkit", "kaniko", "jenkins", "gitlab-runner", "act_runner", "woodpecker-agent", "drone-runner-docker"], "build_station"],
]

# "registry.k8s.io/coredns/coredns:v1.11.3" -> "coredns"
static func image_name(image: String) -> String:
	var s = image.to_lower().get_slice("@", 0)
	var last = s.get_slice("/", s.get_slice_count("/") - 1)
	return last.get_slice(":", 0)

static func machine_for(pod: Dictionary) -> String:
	var conts: Array = pod.get("containers", [])
	if not conts.is_empty():
		var name = image_name(str(conts[0].get("image", "")))     # the pod's main container
		for row in ROLES:
			if name in row[0]:
				return row[1]
	return "container_machine" if str(pod.get("wkind", "")) in ["Compose", "Container"] else "pod_machine"
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

# A template for one model at one tier, or {} if it cannot be loaded.
#   core, accent, lamp (ArrayMesh or null)     bounds (AABB, model units)
#   screen / name_surface / list_surface: {pos, size}   the model's display glasses, facing +Z
#   type_label: {text, pos}                    the permanent model-type plate
#   lamp_at
#   door_mesh, door: {hinge, aabb, width, side, along, out}, cavity: AABB   where the model has a storage door
#
# The node contract is the library's (V5/V6): the leaf is every part named
# DoorMoving_*, hung on the catalog's DoorPivot; the housing is already a sealed
# shell with a real opening (ShellOpening / ShellBounds). The model's own drive
# modules are left out: the game puts one module per real volume in the bay.
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
	var anchors: Dictionary = entry(id).get("variants", {}).get(t, {}).get("anchors", {})
	var fix = FIXUPS.get(id, {})
	var accent_name = ""
	for p in parts:
		var nm: String = str(p[0]).get_slice(".", 0)
		p[0] = nm
		for pre in fix.get("nodes", []):
			if nm.begins_with(pre):
				p[2] = Transform3D(Basis.IDENTITY, fix["move"]) * p[2]
		if nm.begins_with("Roof_"):
			accent_name = nm.get_slice("_", 1)
	var core = []
	var accent = []
	var lamp = []
	var door = []
	var has_door = anchors.has("DoorPivot") and anchors.has("ShellOpening") and parts.any(func(p): return str(p[0]).begins_with("DoorMoving_"))
	var stock = ["DriveModule_", "DriveFace_", "DriveHandle_", "DriveLED_", "Shelf_"]
	for p in parts:
		var nm: String = p[0]
		if nm.begins_with("Beacon_"):
			lamp.append(p)
		elif nm.begins_with("DoorMoving_"):
			door.append(p)
		elif has_door and stock.any(func(pre): return nm.begins_with(pre)):
			pass
		elif accent_name != "" and nm.ends_with("_" + accent_name):
			accent.append(p)
		else:
			core.append(p)
	var res = {"id": id, "tier": t, "bounds": _aabb(parts)}
	for pair in [["LiveViewSurface", "screen"], ["ResourceNameSurface", "name_surface"], ["ContainerListSurface", "list_surface"]]:
		var a = anchors.get(pair[0])
		if typeof(a) == TYPE_DICTIONARY and a.has("position") and a.has("size"):
			res[pair[1]] = {"pos": _v3(a["position"]) + Vector3(0, 0, 0.004), "size": Vector2(a["size"][0], a["size"][1]), "on_door": false}
	var tl = anchors.get("TypeLabel")
	if typeof(tl) == TYPE_DICTIONARY and tl.has("position"):
		var plate = _aabb(parts.filter(func(p): return str(p[0]).begins_with("TypeLabel_")))
		res["type_label"] = {"text": str(tl.get("text", "")), "pos": _v3(tl["position"]), "size": Vector2(plate.size.x, plate.size.y), "front": plate.end.z}
	if not lamp.is_empty():
		res["lamp_at"] = _aabb(lamp).get_center()
	if has_door:
		var hinge = _v3(anchors["DoorPivot"])
		var d = _aabb(door)
		var so: Dictionary = anchors["ShellOpening"]
		var sb: Dictionary = anchors.get("ShellBounds", {})
		var back = float(sb.get("z_min", d.position.z - 1.0)) + 0.06
		res["door"] = {"hinge": hinge, "aabb": d, "width": d.size.x, "side": 1, "along": Vector3(-1, 0, 0), "out": Vector3(0, 0, 1)}
		res["cavity"] = AABB(Vector3(float(so["x_min"]), float(so["y_min"]), back),
			Vector3(float(so["x_max"]) - float(so["x_min"]), float(so["y_max"]) - float(so["y_min"]), float(so["z"]) - back))
		res["door_mesh"] = _merge(door, -hinge)      # modelled about its hinge, so the pivot node sits on the hinge
	else:
		core.append_array(door)
	res["core"] = _merge(core)
	res["accent"] = _merge(accent)
	res["lamp"] = _merge(lamp)
	_templates[key] = res
	return res

static func _v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
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
