extends Node3D
# One pod = one factory machine. Containers are the tanks bolted to its side.

const K = preload("res://scripts/kutil.gd")
const Tex = preload("res://scripts/tex.gd")
const Sfx = preload("res://scripts/sfx.gd")

static var _m = {}

var uid = ""
var pod = {}
var slot = -1
var removing = false

var _fan: Node3D
var _beacon: MeshInstance3D
var _screen: MeshInstance3D
var _label: Label3D
var _sub: Label3D
var _smoke: CPUParticles3D
var _tanks = []
var _alarm: Node3D
var _siren: AudioStreamPlayer3D
var _warn: Label3D
var _health = ""
var _t = 0.0

static func _box(key: String, size: Vector3) -> BoxMesh:
	if not _m.has(key):
		var b = BoxMesh.new()
		b.size = size
		_m[key] = b
	return _m[key]

static func _cyl(key: String, r: float, h: float) -> CylinderMesh:
	if not _m.has(key):
		var c = CylinderMesh.new()
		c.top_radius = r
		c.bottom_radius = r
		c.height = h
		c.radial_segments = 16
		_m[key] = c
	return _m[key]

func _add(mesh: Mesh, material: Material, pos: Vector3, parent: Node3D = self) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	parent.add_child(mi)
	return mi

func setup(p: Dictionary) -> void:
	uid = p["uid"]
	var sb = StaticBody3D.new()
	sb.set_meta("kf", {"type": "pod", "uid": uid})
	var cs = CollisionShape3D.new()
	var sh = BoxShape3D.new()
	sh.size = Vector3(5.4, 4.4, 5.4)
	cs.shape = sh
	cs.position.y = 2.2
	sb.add_child(cs)
	add_child(sb)

	var wkey = p["ns"] + "/" + p["wname"]
	var col = K.hue_color(wkey, 0.5, 0.9) if p["wname"] != "" else Color(0.75, 0.76, 0.78)
	var dark = Tex.shared("dark")
	_add(_box("base", Vector3(5.6, 0.4, 5.6)), dark, Vector3(0, 0.2, 0))
	_add(_box("body", Vector3(4.4, 3.0, 4.4)), Tex.body(col), Vector3(0, 1.9, 0))
	_add(_box("band", Vector3(4.5, 0.45, 4.5)), dark, Vector3(0, 0.95, 0))
	_add(_box("lip", Vector3(4.6, 0.2, 4.6)), Tex.shared("orange"), Vector3(0, 3.45, 0))
	_add(_box("roof", Vector3(2.6, 0.8, 2.6)), dark, Vector3(-0.5, 3.9, 0.3))
	_add(_cyl("chimney", 0.42, 2.4), Tex.shared("steel"), Vector3(1.35, 4.6, -1.35))
	_add(_cyl("chimney_cap", 0.52, 0.25), dark, Vector3(1.35, 5.75, -1.35))

	# Front face (+Z): spinning rotor and a status screen
	var hub = _add(_cyl("rotor_ring", 1.15, 0.25), dark, Vector3(-0.85, 2.0, 2.25))
	hub.rotation.x = PI / 2
	_fan = Node3D.new()
	_fan.position = Vector3(-0.85, 2.0, 2.42)
	add_child(_fan)
	for i in 3:
		var blade = _add(_box("blade", Vector3(1.9, 0.26, 0.08)), Tex.shared("steel"), Vector3.ZERO, _fan)
		blade.rotation.z = i * PI / 3.0
	_add(_box("screen_frame", Vector3(1.5, 1.1, 0.12)), dark, Vector3(1.2, 2.2, 2.22))
	_screen = _add(_box("screen", Vector3(1.3, 0.9, 0.06)), Tex.status_glow("warn"), Vector3(1.2, 2.2, 2.29))

	if not OS.has_feature("web"):   # the browser build has a tight draw budget (see main.gd)
		# detail: side vents, a feed pipe along the back, hazard kick-plates
		for vz in [-1.2, 0.0, 1.2]:
			_add(_box("vent", Vector3(0.08, 0.7, 0.8)), dark, Vector3(-2.22, 2.3, vz))
			for vy in [2.1, 2.3, 2.5]:
				_add(_box("slit", Vector3(0.1, 0.06, 0.66)), Tex.shared("steel"), Vector3(-2.24, vy, vz))
		var pipe = _add(_cyl("pipe", 0.16, 4.6), Tex.shared("steel"), Vector3(0, 2.9, -2.36))
		pipe.rotation.z = PI / 2
		for px in [-2.2, 2.2]:
			_add(_cyl("pipe_down", 0.16, 2.6), Tex.shared("steel"), Vector3(px, 1.65, -2.36))
		_add(_box("kick", Vector3(5.62, 0.14, 0.06)), Tex.shared("hazard"), Vector3(0, 0.33, 2.81))
		_add(_box("lamp_bar", Vector3(1.6, 0.08, 0.08)), Tex.glow(Color(1.0, 0.85, 0.6), 1.2), Vector3(0.2, 3.3, 2.24))
	_add(_cyl("pole", 0.06, 1.3), Tex.shared("steel"), Vector3(-1.7, 4.2, 1.7))
	if not _m.has("bulb"):
		var s = SphereMesh.new()
		s.radius = 0.3
		s.height = 0.6
		_m["bulb"] = s
	_beacon = _add(_m["bulb"], Tex.status_glow("warn"), Vector3(-1.7, 4.95, 1.7))

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 44
	_label.pixel_size = 0.0075
	_label.outline_size = 10
	_label.position = Vector3(0, 7.1, 0)
	_label.visibility_range_end = 90.0
	add_child(_label)
	_sub = Label3D.new()
	_sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sub.font_size = 34
	_sub.pixel_size = 0.0075
	_sub.outline_size = 8
	_sub.position = Vector3(0, 6.55, 0)
	_sub.visibility_range_end = 60.0
	add_child(_sub)

	_smoke = CPUParticles3D.new()
	_smoke.position = Vector3(1.35, 5.9, -1.35)
	_smoke.amount = 10
	_smoke.lifetime = 2.6
	_smoke.direction = Vector3.UP
	_smoke.spread = 10.0
	_smoke.gravity = Vector3(0.5, 0.3, 0)
	_smoke.initial_velocity_min = 1.0
	_smoke.initial_velocity_max = 1.7
	_smoke.scale_amount_min = 0.6
	_smoke.scale_amount_max = 1.3
	if not _m.has("puff"):
		var s = SphereMesh.new()
		s.radius = 0.4
		s.height = 0.8
		s.radial_segments = 8
		s.rings = 4
		var pm = Tex.ghost(Color.WHITE)
		pm.vertex_color_use_as_albedo = true
		s.material = pm
		_m["puff"] = s
		var g = Gradient.new()
		g.set_color(0, Color(0.85, 0.87, 0.9, 0.5))
		g.set_color(1, Color(0.85, 0.87, 0.9, 0.0))
		_m["ramp"] = g
	_smoke.mesh = _m["puff"]
	_smoke.color_ramp = _m["ramp"]
	_smoke.emitting = false
	add_child(_smoke)

	# Alarm: a red light column + warning sign, visible from across the factory.
	if not _m.has("beam"):
		var bm = Tex.ghost(Color(1.0, 0.12, 0.08, 0.22))
		bm.emission_enabled = true
		bm.emission = Color(1.0, 0.1, 0.05)
		bm.emission_energy_multiplier = 2.0
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_m["beam_mat"] = bm
		var cm = CylinderMesh.new()
		cm.top_radius = 0.5
		cm.bottom_radius = 0.9
		cm.height = 60.0
		cm.radial_segments = 12
		cm.cap_top = false
		cm.cap_bottom = false
		_m["beam"] = cm
	_alarm = Node3D.new()
	_alarm.visible = false
	add_child(_alarm)
	_add(_m["beam"], _m["beam_mat"], Vector3(0, 36.0, 0), _alarm).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lamp = OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.15, 0.08)
	lamp.light_energy = 4.0
	lamp.omni_range = 16.0
	lamp.position = Vector3(0, 6.0, 0)
	_alarm.add_child(lamp)
	Sfx.build_streams()
	_siren = AudioStreamPlayer3D.new()
	_siren.stream = Sfx.streams["alarm"]
	_siren.volume_db = -14.0
	_siren.unit_size = 5.0
	_siren.max_distance = 60.0
	_siren.position = Vector3(0, 5.0, 0)
	add_child(_siren)
	_warn = Label3D.new()
	_warn.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_warn.font_size = 64
	_warn.pixel_size = 0.01
	_warn.outline_size = 14
	_warn.modulate = Color(1.0, 0.3, 0.22)
	_warn.position = Vector3(0, 8.3, 0)
	_warn.visibility_range_end = 220.0
	_alarm.add_child(_warn)

	update(p)
	# "Build" animation: rise out of the foundation.
	scale = Vector3(1, 0.02, 1)
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector3.ONE, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func update(p: Dictionary) -> void:
	pod = p
	_label.text = p["name"]
	var line = p["status"]
	if p["restarts"] > 0:
		line += "  ·  %d restarts" % p["restarts"]
	_sub.text = line
	var h = p["health"]
	_sub.modulate = K.health_color(h)
	if h != _health:
		_health = h
		_screen.material_override = Tex.status_glow(h)
		_beacon.material_override = Tex.status_glow(h)
		_smoke.emitting = h == "ok"
		_alarm.visible = h == "bad"
		if h == "bad" and not _siren.playing:
			_siren.play(randf())
		elif h != "bad" and _siren.playing:
			_siren.stop()
	_warn.text = "!  " + p["status"]
	# Container tanks along the +X side
	var conts = p["containers"]
	var want = mini(conts.size(), 4)
	while _tanks.size() < want:
		var i = _tanks.size()
		var z = -1.5 + i * 1.05
		_add(_cyl("tank", 0.42, 2.2), Tex.shared("steel"), Vector3(2.62, 1.5, z))
		var ring = _add(_cyl("tank_ring", 0.46, 0.22), Tex.status_glow("warn"), Vector3(2.62, 2.3, z))
		_tanks.append(ring)
	for i in want:
		var c = conts[i]
		var ch = "ok" if c["state"] == "running" and c["ready"] else ("warn" if c["state"] != "terminated" else ("done" if c["reason"] == "Completed" else "bad"))
		if h == "bad":
			ch = "bad"
		_tanks[i].material_override = Tex.status_glow(ch)

func dismantle() -> void:
	if removing:
		return
	removing = true
	var tw = create_tween()
	tw.tween_property(self, "scale", Vector3(0.9, 0.01, 0.9), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)

func _process(delta: float) -> void:
	_t += delta
	if _health == "ok":
		_fan.rotation.z -= delta * 5.0
	elif _health == "bad":
		_beacon.visible = fmod(_t, 0.5) < 0.28
		_alarm.scale.x = 1.0 + 0.25 * sin(_t * 6.0)
		_alarm.scale.z = _alarm.scale.x
	elif _health == "warn":
		_beacon.visible = fmod(_t, 1.2) < 0.7
		_fan.rotation.z -= delta * 0.8
	if _health == "ok" or _health == "done":
		_beacon.visible = true
