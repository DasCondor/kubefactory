extends Node3D
# KubeFactory - a first-person factory builder whose factory is your cluster.
#
# Command line (after "--"):
#   --demo | --kubectl | --docker   force a data source (default: auto-detect)
#   --context=<name>                connect to a specific kubeconfig context
#   --sim=<name>                    a simulated cluster (aws-eks-prod, azure-aks-staging,
#                                   gke-analytics, rancher-edge, helmsman-sim)
#   --read-only                     block every action that changes the cluster
#   --shots=<dir>                   automated screenshot tour, then quit (dev)

const K = preload("res://scripts/kutil.gd")
const Cluster = preload("res://scripts/cluster.gd")
const World = preload("res://scripts/world.gd")
const Player = preload("res://scripts/player.gd")
const Hud = preload("res://scripts/hud.gd")
const Sfx = preload("res://scripts/sfx.gd")
const Demo = preload("res://scripts/backend_demo.gd")
const Gfx = preload("res://scripts/gfx.gd")
const Bench = preload("res://scripts/bench.gd")
const LiveView = preload("res://scripts/liveview.gd")
const VERSION = "2.0.0-dev"

const SKY_SHADER = """
shader_type sky;
uniform vec3 top_color : source_color = vec3(0.2, 0.4, 0.78);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.8, 0.88);
uniform vec3 ground_color : source_color = vec3(0.25, 0.3, 0.22);
uniform sampler2D clouds : repeat_enable, filter_linear;

void sky() {
	float h = EYEDIR.y;
	vec3 col = mix(horizon_color, top_color, pow(clamp(h, 0.0, 1.0), 0.5));
	col = mix(col, ground_color, clamp(-h * 6.0, 0.0, 1.0));
	if (LIGHT0_ENABLED) {
		float c = max(dot(EYEDIR, LIGHT0_DIRECTION), 0.0);
		col += LIGHT0_COLOR * (pow(c, 24.0) * 0.08 + pow(c, 200.0) * 0.4 + smoothstep(0.9993, 0.9997, c) * 5.0);
	}
	if (h > 0.0) {
		vec2 uv = EYEDIR.xz / (h + 0.12);
		float n = texture(clouds, uv * 0.05).r * 0.62 + texture(clouds, uv * 0.14 + vec2(0.37, 0.11)).r * 0.38;
		float cover = smoothstep(0.6, 0.74, n) * smoothstep(0.02, 0.2, h);
		vec3 lit = mix(vec3(0.85), vec3(0.4, 0.46, 0.58), smoothstep(0.66, 0.9, n));
		col = mix(col, lit, cover * 0.9);
	}
	COLOR = col;
}
"""

var cluster
var world
var player
var hud
var sfx

var mode = 0            # 0 inspect, 1 build, 2 dismantle
var blueprint = null
var _dis = 0.0
var _dis_lock = false
var _prob_i = 0
var settings = {}
var world_sun: DirectionalLight3D
var _env: Environment
var _gfx_base = {}
var _shots_running = false
var _storage_uid = ""        # the machine whose service door is open
var live: Node
var _live_rate_t = 0.0
var _charge_test = 0.0   # dev: forces the tool's wind-up pose for --toolshots

func _ready() -> void:
	_setup_input()
	# the graphics preset has to be known before the world is built
	settings = K.load_settings()
	Gfx.setup(str(settings.get("graphics", "auto")), OS.get_cmdline_user_args())
	_setup_environment()
	cluster = Cluster.new()
	add_child(cluster)
	world = World.new()
	world.sun = world_sun
	add_child(world)
	player = Player.new()
	add_child(player)
	sfx = Sfx.new()
	add_child(sfx)
	hud = Hud.new()
	hud.sfx = sfx
	hud.version = VERSION
	hud.cluster = cluster
	hud.world = world
	hud.player = player
	world.player = player
	add_child(hud)

	cluster.state_updated.connect(func(st):
		world.apply_state(st)
		hud.on_state(st))
	cluster.action_done.connect(func(ok, msg):
		hud.notify(msg, "ok" if ok else "bad")
		sfx.play("ok" if ok else "error", -12.0))
	player.stepped.connect(func(): sfx.play("step", -20.0, randf_range(0.85, 1.15)))
	cluster.logs_ready.connect(hud.on_logs)
	cluster.action_finished.connect(hud.on_action)
	cluster.source_changed.connect(func(label, note):
		hud.notify("Connected to %s. %s" % [label, note], "ok" if label != "simulation" else "info"))
	world.event.connect(hud.notify)
	# multi-user: tell the cluster where we are; show who else is here and what they do
	cluster.presence_info = func():
		var doing = ""
		if hud.modal_open():
			doing = "at a terminal"
		elif _dis > 0.0:
			doing = "using the " + hud.TOOLS[mode]["name"].capitalize()
		return {"pos": "%.1f,%.1f,%.1f,%.2f" % [player.global_position.x, player.global_position.y, player.global_position.z, player.rotation.y],
			"tool": mode, "doing": doing}
	cluster.peers_updated.connect(func(peers):
		var names = []
		for t in hud.TOOLS:
			names.append("MK.%d %s" % [t["mk"], t["name"].capitalize()])
		world.set_peers(peers, names)
		hud.refresh_who())
	cluster.feed_event.connect(func(_user, msg, ok):
		hud.notify(msg, "info" if ok else "bad")
		sfx.play("click", -14.0, 1.4))
	hud.blueprint_chosen.connect(func(bp):
		blueprint = bp
		_set_mode(2))
	hud.target_requested.connect(_connect_target)
	hud.graphics_requested.connect(set_graphics)
	hud.storage_requested.connect(_storage)
	hud.storage_modules.connect(func(uid, mounts):
		var m = world.machines.get(uid)
		if m != null:
			m.set_modules(mounts))
	cluster.data_ready.connect(hud.on_data)
	# LiveView: real application pages on screens
	live = LiveView.new()
	add_child(live)
	hud.live = live
	live.changed.connect(_on_live_changed)
	cluster.agent_event.connect(live.on_agent_event)
	cluster.source_changed.connect(func(_l, _n): live.close_all())
	# connection wizard: how an attempt ended, and kubeconfig files dropped on the window
	cluster.source_changed.connect(func(_label, _note): hud.on_connect_result(cluster.last_connect_error))
	get_window().files_dropped.connect(func(files):
		if files.size() > 0 and cluster.native_kube() and not OS.has_feature("web"):
			var p = hud.Connections.add_file(str(files[0]))
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			hud.open_connect(str(p.get("id", ""))))
	cluster.targets_changed.connect(func():
		world.set_targets(cluster.targets, cluster.backend.label, cluster.backend.context))

	var source = "auto"
	var ctx = ""
	var shots = ""
	var mptest = ""
	var flyby = false
	# Two packaged editions share this code (export presets "Windows Docker" and
	# "Windows Demo" set the feature tag; --edition= does the same from source):
	#   docker  opens on the local Docker engine and never touches kubectl
	#   demo    the full game on the built-in simulated clusters only
	var edition = "docker" if OS.has_feature("docker_edition") else ("demo" if OS.has_feature("demo_edition") else "")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--edition="):
			edition = a.trim_prefix("--edition=")
		elif a == "--demo":
			source = "simulation"
		elif a.begins_with("--demo="):
			# a demo world by name: kubernetes, home-assistant, dev-containers or media
			source = "simulation"
			ctx = Demo.demo_flavor(a.trim_prefix("--demo="))
		elif a == "--kubectl":
			source = "kubernetes"
		elif a == "--kubectl-cli":
			# legacy: reach Kubernetes through the kubectl on PATH instead of the native companion
			source = "kubernetes"
			cluster.legacy_kubectl = true
		elif a == "--docker":
			source = "docker"
		elif a.begins_with("--context="):
			source = "kubernetes"
			ctx = a.trim_prefix("--context=")
		elif a.begins_with("--sim="):
			source = "simulation"
			ctx = a.trim_prefix("--sim=")
		elif a == "--read-only":
			cluster.read_only = true
		elif a.begins_with("--shots="):
			shots = a.trim_prefix("--shots=")
		elif a == "--flyby":
			flyby = true
		elif a.begins_with("--bench="):
			shots = "-"
			Bench.run(self, a.trim_prefix("--bench="), Gfx.id_of(Gfx.level))
		elif a.begins_with("--liveshots="):
			# --liveshots=<dir>,<url>
			shots = "-"
			_run_liveshots(a.trim_prefix("--liveshots=").get_slice(",", 0), a.trim_prefix("--liveshots=").get_slice(",", 1))
		elif a.begins_with("--storageshots="):
			shots = "-"
			_run_storageshots(a.trim_prefix("--storageshots="))
		elif a.begins_with("--krewshots="):
			shots = "-"
			_run_krewshots(a.trim_prefix("--krewshots="))
		elif a.begins_with("--connectshots="):
			shots = "-"
			_run_connectshots(a.trim_prefix("--connectshots="))
		elif a.begins_with("--gfxshots="):
			shots = "-"
			_run_gfxshots(a.trim_prefix("--gfxshots="))
		elif a == "--trailer":
			shots = "-"
			_run_trailer()
		elif a.begins_with("--toolshots="):
			shots = "-"
			_run_toolshots(a.trim_prefix("--toolshots="))
		elif a.begins_with("--mptest="):
			mptest = a.trim_prefix("--mptest=")
		elif a.begins_with("--flythrough="):
			shots = "-"
			_run_flythrough(a.trim_prefix("--flythrough="))
	player.teleport(Vector3(0, 0.4, 17))
	_set_mode(0)
	if not OS.has_feature("web"):   # browsers only grant mouse capture on a click
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_icon()
	# saved per-user settings
	settings = K.load_settings()
	hud.settings = settings
	player.sensitivity = clampf(float(settings["sensitivity"]), 0.2, 4.0)
	world.show_belts = bool(settings["belts"])
	if OS.has_feature("web"):
		source = "simulation"   # a browser cannot run kubectl or docker
	elif edition == "demo":
		source = "simulation"
		get_window().title = "KubeFactory Demo"
	elif edition == "docker":
		if source != "simulation":
			source = "docker"
			ctx = ""
		get_window().title = "KubeFactory Docker"
	cluster.edition = edition
	if shots == "" and mptest == "" and not flyby:
		sfx.set_muted(bool(settings["muted"]))
		if bool(settings["fullscreen"]):
			get_window().mode = Window.MODE_FULLSCREEN
		# on the simulation with no world named: let the player pick one of the demos
		hud.offer_demos = source == "simulation" and ctx == ""
		if not bool(settings["welcomed"]):
			hud.open_welcome.call_deferred()
		elif hud.offer_demos:
			hud.open_demos.call_deferred()
	cluster.start(source, ctx)
	if shots != "" and shots != "-":
		_run_shots(shots)
	if mptest != "":
		_run_mptest(mptest)
	if flyby:
		_run_flyby()

# Window / taskbar icon, drawn in code: an orange factory block on dark.
func _set_icon() -> void:
	var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.1, 0.11))
	var o = Color(0.98, 0.584, 0.286)
	img.fill_rect(Rect2i(8, 30, 48, 26), o)
	img.fill_rect(Rect2i(12, 14, 9, 18), o)
	img.fill_rect(Rect2i(26, 20, 9, 12), o)
	img.fill_rect(Rect2i(16, 38, 10, 10), Color(0.3, 0.95, 0.5))
	img.fill_rect(Rect2i(32, 38, 10, 10), Color(0.09, 0.1, 0.11))
	img.fill_rect(Rect2i(8, 52, 48, 4), Color(0.2, 0.21, 0.23))
	DisplayServer.set_icon(img)

func _key(action: String, keys: Array) -> void:
	InputMap.add_action(action)
	for k in keys:
		var ev = InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)

func _setup_input() -> void:
	_key("move_forward", [KEY_W, KEY_UP])
	_key("move_back", [KEY_S, KEY_DOWN])
	_key("move_left", [KEY_A, KEY_LEFT])
	_key("move_right", [KEY_D, KEY_RIGHT])
	_key("jump", [KEY_SPACE])
	_key("descend", [KEY_CTRL, KEY_C])
	_key("sprint", [KEY_SHIFT])
	_key("interact", [KEY_E])
	_key("build_menu", [KEY_Q])
	_key("codex", [KEY_TAB])
	for i in 6:
		_key("tool%d" % (i + 1), [KEY_1 + i])
	_key("belts", [KEY_B])
	_key("next_problem", [KEY_G])
	_key("logs", [KEY_L])
	_key("storage", [KEY_F])
	_key("liveview", [KEY_V])
	_key("mute", [KEY_M])
	_key("fullscreen", [KEY_F11])
	for pair in [["fire", MOUSE_BUTTON_LEFT], ["sample", MOUSE_BUTTON_MIDDLE]]:
		InputMap.add_action(pair[0])
		var ev = InputEventMouseButton.new()
		ev.button_index = pair[1]
		InputMap.action_add_event(pair[0], ev)

func _setup_environment() -> void:
	# Gradient sky with a sun halo and a layer of drifting-looking (static) clouds
	var cn = FastNoiseLite.new()
	cn.seed = 8
	cn.frequency = 0.007
	cn.fractal_octaves = 5
	var ct = NoiseTexture2D.new()
	ct.noise = cn
	ct.seamless = true
	ct.width = 512
	ct.height = 512
	var ssh = Shader.new()
	ssh.code = SKY_SHADER
	var sky_mat = ShaderMaterial.new()
	sky_mat.shader = ssh
	sky_mat.set_shader_parameter("clouds", ct)
	sky_mat.set_shader_parameter("top_color", Color(0.2, 0.4, 0.78))
	sky_mat.set_shader_parameter("horizon_color", Color(0.72, 0.8, 0.88))
	sky_mat.set_shader_parameter("ground_color", Color(0.25, 0.3, 0.22))
	var sky = Sky.new()
	sky.sky_material = sky_mat
	var env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.66, 0.7, 0.78)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 2.2
	env.ssil_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.88)
	env.fog_density = 0.0011
	env.fog_aerial_perspective = 0.7
	env.fog_sky_affect = 0.2
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0035
	env.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
	env.volumetric_fog_length = 220.0
	env.volumetric_fog_anisotropy = 0.55
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.05
	var we = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(38.0), 0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 260.0
	sun.directional_shadow_blend_splits = true
	if RenderingServer.get_rendering_device() == null:
		# Compatibility renderer (the browser build): no HDR pipeline, so the Forward+
		# light levels blow out. Tone them down and drop the effects it cannot do.
		sun.light_energy = 0.9
		env.ambient_light_energy = 0.45
		env.fog_density = 0.0004
		env.fog_aerial_perspective = 0.0
		env.glow_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.volumetric_fog_enabled = false
	if OS.has_feature("web"):
		# WebGL draws nothing at all once a frame passes ~4096 elements, and every
		# shadow cascade re-draws the scene. One cascade keeps the demo well under.
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 120.0
	world_sun = sun
	add_child(sun)
	# the shipped values are the Standard preset; the others are built on top of them
	_env = env
	_gfx_base = {"shadow_dist": sun.directional_shadow_max_distance, "ssao": env.ssao_intensity, "ambient": env.ambient_light_energy,
		"glow": env.glow_intensity, "bloom": env.glow_bloom, "vfog": env.volumetric_fog_density, "contrast": env.adjustment_contrast}
	Gfx.apply(env, sun, get_viewport(), _gfx_base)

# Switch graphics preset while playing: renderer settings first, then the world
# rebuilds its scenery and machines at the new detail level.
func set_graphics(id: String) -> void:
	settings["graphics"] = id
	K.save_settings(settings)
	Gfx.setup(id, OS.get_cmdline_user_args() if id == "auto" else [])
	Gfx.apply(_env, world_sun, get_viewport(), _gfx_base)
	world.rebuild_graphics(cluster.state)
	hud.notify("Graphics: %s" % Gfx.NAMES[Gfx.level], "info")

func _set_mode(m: int) -> void:
	if m != mode:
		sfx.play("click", -12.0, 0.8 + m * 0.08)
	mode = m
	hud.set_mode(mode, blueprint)
	player.set_tool(mode, K.tier_color(hud.TOOLS[mode]["mk"]))

# What holding the trigger does with the current tool on the current target.
# Returns {} or {label, time, act}. Stronger tools take longer to charge.
func _hold_action(type: String, meta: Dictionary) -> Dictionary:
	if mode < 3:
		return {}
	var st = cluster.state
	if hud.TOOLS[mode]["mk"] > cluster.max_tier():
		return {}
	if type == "pod":
		var p = K.find_pod(st, meta["uid"])
		if p == null:
			return {}
		var w = K.find_workload(st, p["ns"], p["wkind"], p["wname"])
		if mode == 3:
			if st["source"] == "docker":
				return {"label": "restart this container", "time": 0.7,
					"act": {"op": "restart", "ns": p["ns"], "kind": p["wkind"], "name": p["wname"], "pod": p["name"]}}
			if w != null:
				return {"label": "rolling restart of %s" % w["name"], "time": 0.7,
					"act": {"op": "restart", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}}
		elif mode == 4:
			return {"label": "delete this pod", "time": 0.9, "act": {"op": "delete_pod", "ns": p["ns"], "name": p["name"]}}
		elif mode == 5 and w != null:
			return {"label": "DELETE WORKLOAD %s and all %d pods" % [w["name"], w["replicas"]], "time": 2.4,
				"act": {"op": "delete_workload", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}}
	elif type == "node":
		for n in st["nodes"]:
			if n["name"] == meta["name"]:
				if mode == 3:
					return {"label": "uncordon node" if n["cordoned"] else "cordon node", "time": 0.7,
						"act": {"op": "cordon", "node": n["name"], "on": not n["cordoned"]}}
				if mode == 5:
					return {"label": "DRAIN NODE - evict every pod", "time": 2.4, "act": {"op": "drain", "node": n["name"]}}
	return {}

# A display changed: keep the machine screen it is mounted on showing it.
func _on_live_changed(s: Dictionary) -> void:
	hud.on_live_changed(s)
	for m in world.machines.values():
		if m.get_meta("live", "") == s["key"] and (s["state"] != "live" or str(s["mounted"]) != m.uid):
			m.set_screen_texture(null)
			m.remove_meta("live")
	if s["state"] == "live" and str(s["mounted"]) != "" and s["tex"] != null:
		var m = world.machines.get(str(s["mounted"]))
		if m != null:
			m.set_screen_texture(s["tex"])
			m.set_meta("live", s["key"])

# Frame rate follows attention: the display in the viewer runs at full rate, one
# mounted on a machine slows with distance, and one nobody can see is paused.
func _live_rates(delta: float) -> void:
	_live_rate_t += delta
	if _live_rate_t < 0.5 or live == null:
		return
	_live_rate_t = 0.0
	for s in live.sessions.values():
		var fps = live.RATE_FAR
		var paused = true
		if hud._modal_kind == "liveview" and hud._lv == s:
			fps = live.RATE_ACTIVE
			paused = false
		elif str(s["mounted"]) != "":
			var m = world.machines.get(str(s["mounted"]))
			if m != null:
				var dist = player.global_position.distance_to(m.global_position)
				var facing = player.camera.global_transform.basis.z.dot(m.global_position - player.camera.global_position) < 0.0
				paused = dist > 90.0 or not facing
				fps = live.RATE_NEAR if dist < 25.0 else live.RATE_FAR
		live.set_rate(s, fps, paused)

# Open a machine's service door and look at what is mounted behind it. The door
# swings out as far as its stop (or as far as you, if you are standing in its
# path) and shuts again when the storage panel closes.
func _storage(uid: String) -> void:
	var m = world.machines.get(uid)
	_storage_uid = uid
	if m != null and m.has_door():
		var view = m.door_view()
		if not view.is_empty():
			player.teleport(view[0], view[1])
		m.set_door(true, player.global_position)
		sfx.play("build", -14.0, 0.7)
	hud.open_storage(uid)

func _process(delta: float) -> void:
	_live_rates(delta)
	if _storage_uid != "" and hud._modal_kind != "storage":
		var sm = world.machines.get(_storage_uid)
		if sm != null and sm.has_door():
			sm.set_door(false)
			sfx.play("click", -14.0, 0.6)
		_storage_uid = ""
	if hud.modal_open():
		world.hide_hologram()
		world.select(null)
		hud.set_target("")
		hud.set_progress(0.0)
		sfx.charge(0.0)
		player.tool_charge(0.0)
		return
	var h = player.hit
	var meta = h.get("meta", {})
	var type = meta.get("type", "")
	var hold = _hold_action(type, meta)
	world.select(h.get("collider") if type in ["pod", "node", "service", "hub", "cluster", "logs", "npc", "bob"] else null,
		K.tier_color(hud.TOOLS[mode]["mk"]) if not hold.is_empty() else Color(0.98, 0.584, 0.286))
	if mode == 2 and blueprint != null and type == "platform":
		world.show_hologram(h["pos"])
	else:
		world.hide_hologram()
	hud.set_target(_tooltip(type, meta, hold))
	if not hold.is_empty() and Input.is_action_pressed("fire") and not _dis_lock and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _shots_running):
		_dis += delta / hold["time"]
		if _dis >= 1.0:
			_dis = 0.0
			_dis_lock = true
			player.tool_kick(1.0)
			if K.tier_of(hold["act"], cluster.state) >= cluster.confirm_tier():
				# the most destructive tier also asks you to type the target's name
				hud.guarded_act(hold["act"], hold["label"] + "?", str(hold["act"].get("name", hold["act"].get("node", ""))))
			else:
				sfx.play(["click", "click", "build", "click", "dismantle", "boom"][mode], -8.0)
				cluster.act(hold["act"])
	elif delta > 0.0:
		_dis = 0.0
		if not Input.is_action_pressed("fire"):
			_dis_lock = false
	hud.set_progress(_dis)
	sfx.charge(_dis)
	player.tool_charge(_charge_test if _charge_test > 0.0 else _dis)

func _tooltip(type: String, meta: Dictionary, hold: Dictionary) -> String:
	var tool = hud.TOOLS[mode]
	var action = ""
	if not hold.is_empty():
		action = "[Hold LMB]  MK.%d %s:  %s" % [tool["mk"], tool["name"], hold["label"]]
	match type:
		"pod":
			var p = K.find_pod(cluster.state, meta["uid"])
			if p == null:
				return ""
			var head = "%s\n%s  ·  %s  ·  %s\n" % [p["name"], p["status"], p["ns"], p["node"] if p["node"] != "" else "unscheduled"]
			if action != "":
				return head + action
			if mode == 1:
				return head + "[LMB] open its log ledger"
			if mode == 2 and blueprint != null:
				return head + "[LMB] build: " + hud.bp_text(blueprint)
			if tool["mk"] > cluster.max_tier():
				return head + "MK.%d %s is locked for you on this cluster" % [tool["mk"], tool["name"]]
			if mode >= 3:
				return head + "%s has nothing to do here" % tool["name"]
			return head + "[E] inspect     [MMB] copy as blueprint"
		"node":
			return "Node %s\n%s" % [meta["name"], action if action != "" else "[E] node terminal"]
		"service":
			return "Service %s / %s\n[E] details" % [meta["ns"], meta["name"]]
		"hub":
			return "THE HUB\n[E] cluster codex"
		"bob":
			return "BOB  ·  repair stand\n[E] fix list: what is broken, why, and what to do about it"
		"npc":
			return "PORTER  ·  Portainer dock\n[E] talk: complete app setups, Portainer templates"
		"logs":
			return "LOGGING STATION\n[E] open the datapad: pod logs, cluster events, audit trail"
		"cluster":
			if meta["index"] < cluster.targets.size():
				var t = cluster.targets[meta["index"]]
				return "%s\n%s\n[E] connect to this cluster" % [t["provider"], t["context"]]
		"platform":
			if mode == 2 and blueprint != null:
				return "[LMB] build: " + hud.bp_text(blueprint)
	return ""

func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("fullscreen"):
		var w = get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		settings["fullscreen"] = w.mode == Window.MODE_FULLSCREEN
		K.save_settings(settings)
		return
	if ev.is_action_pressed("ui_cancel"):
		if hud.modal_open():
			hud.close_modal()
		else:
			hud.open_pause()
		return
	if hud.modal_open():
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if ev is InputEventMouseButton and ev.pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	for i in 6:
		if ev.is_action_pressed("tool%d" % (i + 1)):
			_set_mode(i)
			return
	if ev is InputEventMouseButton and ev.pressed and (ev.button_index == MOUSE_BUTTON_WHEEL_UP or ev.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_set_mode(posmod(mode + (1 if ev.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1), 6))
	elif ev.is_action_pressed("build_menu"):
		hud.open_build()
	elif ev.is_action_pressed("codex"):
		hud.open_codex()
	elif ev.is_action_pressed("belts"):
		world.show_belts = not world.show_belts
		world.apply_state(cluster.state)
		hud.notify("Conveyor belts %s" % ("shown" if world.show_belts else "hidden"), "info")
	elif ev.is_action_pressed("logs"):
		hud.open_logs()
	elif ev.is_action_pressed("mute"):
		sfx.set_muted(not sfx.muted)
		settings["muted"] = sfx.muted
		K.save_settings(settings)
		hud.notify("Sound %s" % ("off" if sfx.muted else "on"), "info")
	elif ev.is_action_pressed("next_problem"):
		_next_problem()
	elif ev.is_action_pressed("interact"):
		_interact()
	elif ev.is_action_pressed("liveview"):
		hud.open_liveview()
	elif ev.is_action_pressed("storage"):
		var smeta = player.hit.get("meta", {})
		if smeta.get("type", "") == "pod":
			_storage(smeta["uid"])
	elif ev.is_action_pressed("sample"):
		_sample()
	elif ev.is_action_pressed("fire"):
		var meta = player.hit.get("meta", {})
		if mode <= 2:
			player.tool_kick(0.55)
		if mode == 0:
			_interact()
		elif mode == 1:
			if meta.get("type", "") == "pod":
				hud.open_logs(meta["uid"])
			else:
				hud.open_logs()
		elif mode == 2:
			_build()

func _interact() -> void:
	var meta = player.hit.get("meta", {})
	match meta.get("type", ""):
		"pod":
			hud.open_pod(meta["uid"])
		"node":
			hud.open_node(meta["name"])
		"service":
			hud.open_service(meta["ns"], meta["name"])
		"hub":
			hud.open_codex()
		"logs":
			hud.open_logs()
		"npc":
			hud.open_talk()
		"bob":
			hud.open_bob()
		"cluster":
			if meta["index"] < cluster.targets.size():
				_connect_target(cluster.targets[meta["index"]])

func _connect_target(t: Dictionary) -> void:
	if cluster.backend != null and t["source"] == cluster.backend.label and t["context"] == cluster.backend.context:
		hud.notify("Already connected to %s" % t["context"], "info")
		return
	hud.notify("Connecting to %s  (%s)..." % [t["context"], t["provider"]], "info")
	blueprint = null
	_set_mode(0)
	world.ns_filter = ""
	cluster.connect_target(t)

func _sample() -> void:
	var meta = player.hit.get("meta", {})
	if meta.get("type", "") != "pod":
		return
	var p = K.find_pod(cluster.state, meta["uid"])
	if p == null:
		return
	var w = K.find_workload(cluster.state, p["ns"], p["wkind"], p["wname"])
	if w == null or w["kind"] == "DaemonSet":
		hud.notify("%s is not part of a scalable workload, so it cannot be copied" % p["name"], "warn")
		return
	blueprint = {"type": "replica", "ns": w["ns"], "kind": w["kind"], "name": w["name"]}
	_set_mode(2)

func _build() -> void:
	if blueprint == null:
		hud.notify("No blueprint selected: press Q for the build menu, or middle-click a machine to copy it", "warn")
		return
	var type = player.hit.get("meta", {}).get("type", "")
	if type != "platform" and type != "pod":
		hud.notify("Aim at a foundation to build", "warn")
		return
	if blueprint["type"] == "replica":
		var w = K.find_workload(cluster.state, blueprint["ns"], blueprint["kind"], blueprint["name"])
		if w == null:
			hud.notify("%s is not in the cluster (yet) - try again in a moment" % blueprint["name"], "warn")
			return
		sfx.play("build", -9.0)
		cluster.act({"op": "scale_by", "ns": w["ns"], "kind": w["kind"], "name": w["name"], "delta": 1})
	else:
		sfx.play("build", -9.0)
		cluster.act({"op": "create", "ns": blueprint["ns"], "name": blueprint["name"],
			"image": blueprint["image"], "replicas": blueprint["replicas"]})
		# further clicks add replicas of the thing just built
		blueprint = {"type": "replica", "ns": blueprint["ns"], "kind": "Deployment", "name": blueprint["name"]}
		_set_mode(2)

func _next_problem() -> void:
	if hud.problems.is_empty():
		hud.notify("No problems in the cluster right now", "ok")
		return
	for i in hud.problems.size():
		_prob_i = (_prob_i + 1) % hud.problems.size()
		var spot = world.machine_spot(hud.problems[_prob_i])
		if spot != null:
			player.teleport(spot[0], spot[1])
			return
	hud.notify("The failing pods are hidden by the namespace filter", "warn")

# ---- dev: automated screenshot tour -------------------------------------

func _shot(dir: String, name_: String) -> void:
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir.path_join(name_ + ".png"))
	print("shot ", name_)

# LiveView against a real page at `url` (tests/liveview_page.html, served by
# tools\liveview-test.ps1): frames arrive, a click reaches the page's script, typed
# text lands in a field, a jump to another host is refused, bad addresses fail honestly.
func _run_liveshots(dir: String, url: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(6.0).timeout
	var pixel = func(s: Dictionary, x: int, y: int) -> String:
		return s["tex"].get_image().get_pixel(x, y).to_html(false) if s["tex"] != null else "none"
	var wait_live = func(s: Dictionary, secs: float) -> void:
		var t = 0.0
		while t < secs and (s["state"] == "opening" or (s["state"] == "live" and s["frames"] == 0)):
			await get_tree().create_timer(0.25).timeout
			t += 0.25
	var s = live.open(url, "Test page")
	hud.open_live(s)
	await wait_live.call(s, 40.0)
	print("live: state=", s["state"], " status=", s["status"], " frames=", s["frames"], " ", s.get("kind", ""), " ", s.get("msg", ""))
	if s["state"] == "live":
		await get_tree().create_timer(1.0).timeout
		print("live: box before click = #", pixel.call(s, 150, 120))
		await _shot(dir, "live_1_page")
		for kind in ["move", "down", "up"]:
			live.input(s, kind, {"x": 140.0, "y": 310.0, "button": "left"})
		await get_tree().create_timer(1.2).timeout
		print("live: box after click  = #", pixel.call(s, 150, 120), "  (the page's script turns it green)")
		for kind in ["down", "up"]:
			live.input(s, kind, {"x": 200.0, "y": 400.0, "button": "left"})
		for ch in "typed in the game":
			live.input(s, "text", {"text": ch})
		await get_tree().create_timer(1.2).timeout
		await _shot(dir, "live_2_clicked_typed")
		for kind in ["down", "up"]:
			live.input(s, kind, {"x": 120.0, "y": 475.0, "button": "left"})
		await get_tree().create_timer(1.5).timeout
		print("live: link to another host -> blocked=", s["blocked"], "  still on ", s["url"])
		var frames = s["frames"]
		await get_tree().create_timer(2.0).timeout
		print("live: frames in 2 s while the page animates = ", s["frames"] - frames)
		# mounted on a machine's screen
		var m = world.machines.values()[0]
		s["mounted"] = m.uid
		live.changed.emit(s)
		hud.close_modal()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		var r = m.screen_rect()
		if not r.is_empty():
			player.flying = true
			player.teleport(r["pos"] + r["normal"] * 2.6 + Vector3(0, -1.2, 0), r["pos"])
			await _shot(dir, "live_3_on_machine")
		live.close(s)
	for bad in ["http://127.0.0.1:9/", "file:///C:/Windows/win.ini"]:
		var b = live.open(bad, "bad")
		await wait_live.call(b, 40.0)
		print("live: ", bad, " -> ", b["state"], " ", b["kind"], ": ", b["msg"])
		if b["state"] == "live":
			live.close(b)
	hud.open_liveview()
	await _shot(dir, "live_4_list")
	hud.close_modal()
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()

# Storage doors: open one front-door machine and one rear-panel machine, browse
# into a folder, preview a text file and a binary one, then try to leave the mount.
# Porter and Bob, close up and in their surroundings.
func _run_krewshots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	while world.machines.is_empty():
		await get_tree().process_frame
	await get_tree().create_timer(5.0).timeout
	for v in [["porter_close", world._npc.position + Vector3(0.6, 0.1, 4.2), world._npc.position + Vector3(0, 1.5, 0)],
			["porter_dock", world._npc.position + Vector3(-2, 0.4, 9), world._npc.position + Vector3(2, 2.0, 0)],
			["bob_close", world._bob.position + Vector3(0.6, 0.1, 4.2), world._bob.position + Vector3(0, 1.3, 0)],
			["bob_stand", world._bob.position + Vector3(1, 0.4, 8), world._bob.position + Vector3(-2.2, 2.0, -0.5)]]:
		player.teleport(v[1], v[2])
		await _shot(dir, v[0])
	get_tree().quit()

func _run_storageshots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	while world.machines.is_empty():
		await get_tree().process_frame
	await get_tree().create_timer(7.0).timeout
	var picks = {}
	for m in world.machines.values():
		if m.has_door() and not picks.has(m.model_id) and m.pod["health"] == "ok":
			picks[m.model_id] = m
	print("storage: door-capable models in this world: ", picks.keys())
	var n = 0
	for id in ["database_server", "deployment_line", "monitoring_server"]:
		if not picks.has(id):
			continue
		var m = picks[id]
		var view = m.door_view()
		player.teleport(view[0], view[1])
		await _shot(dir, "%d_%s_closed" % [n, id])
		_storage(m.uid)
		await get_tree().create_timer(1.6).timeout
		await _shot(dir, "%d_%s_open" % [n, id])
		print("storage: ", id, " door angle ", snappedf(rad_to_deg(m._door.rotation.y), 0.1), " side ", m._tpl["door"]["side"], " mounts ", hud._store["mounts"].size() if hud._store["mounts"] != null else -1)
		if n == 0 and hud._store["mounts"] != null and not hud._store["mounts"].is_empty():
			hud._store_dir(hud._store["mounts"][0], "base")
			await get_tree().create_timer(0.8).timeout
			await _shot(dir, "%d_%s_folder" % [n, id])
			hud._store_file("postgresql.conf", 0)
			await get_tree().create_timer(0.8).timeout
			await _shot(dir, "%d_%s_text" % [n, id])
			hud._store_file("base/1/1259", 0)
			await get_tree().create_timer(0.8).timeout
			await _shot(dir, "%d_%s_hex" % [n, id])
			hud._store_dir(hud._store["mounts"][0], "../../etc")
			await get_tree().create_timer(0.8).timeout
			print("storage: leaving the mount -> ", hud._store["error"])
			hud._store_dir(hud._store["mounts"][2], "")
			await get_tree().create_timer(0.6).timeout
			hud._store_file("token", 0)
			await get_tree().create_timer(0.8).timeout
			print("storage: reading a token volume -> ", hud._store["error"])
			await _shot(dir, "%d_%s_secret" % [n, id])
		hud.close_modal()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		await get_tree().create_timer(0.9).timeout
		print("storage: ", id, " door angle after closing ", snappedf(rad_to_deg(m._door.rotation.y), 0.1))
		n += 1
	# a door opened with someone standing in its path stops short of them
	if not picks.is_empty():
		var m = picks.values()[0]
		var d = m._tpl["door"]
		var g = m._body.global_transform
		var in_path = g * (d["hinge"] + (d["along"] * 0.6 + d["out"] * 0.6) * float(d["width"]))
		var ang = m.set_door(true, in_path)
		print("storage: blocked sweep stops at ", snappedf(rad_to_deg(ang), 0.1), " of ", snappedf(rad_to_deg(m.DOOR_OPEN), 0.1), " degrees")
	get_tree().quit()

# The connection wizard: the kubeconfig list, then an attempt on each context
# of the first kubeconfig so every kind of result is on screen once.
func _run_connectshots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(6.0).timeout
	hud.open_connect()
	await _shot(dir, "connect_list")
	var profs = hud.Connections.profiles()
	if not profs.is_empty():
		var n = 0
		for c in hud.Native.contexts_of(hud.Connections.source_of(profs[0])):
			hud._connect_wait(profs[0], c)
			var t = 0.0
			while hud._modal_kind == "connecting" and t < 40.0:
				await get_tree().create_timer(0.5).timeout
				t += 0.5
			await _shot(dir, "connect_result_%d" % n)
			print("connect ", c["context"], " -> ", cluster.backend.label if cluster.backend != null else "none", " ", cluster.backend.context if cluster.backend != null else "", "  error=", cluster.last_connect_error.get("kind", ""))
			n += 1
			if n >= 2:
				break
	get_tree().quit()

# The same views under each graphics preset, switching live, then one panel on
# each to show the interface does not depend on the preset.
func _run_gfxshots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	while world.machines.is_empty():
		await get_tree().process_frame
	var views = [["spawn", Vector3(0, 0.4, 19), Vector3(0, 3.6, 0)], ["overview", Vector3(-52, 30, 6), Vector3(0, 2, -70)],
		["platform", Vector3(6, 9, -30), Vector3(-30, 4, -62)], ["yard", Vector3(26, 7, 34), Vector3(60, 3, 26)],
		["skyline", Vector3(0, 14, -40), Vector3(-20, 30, -470)]]
	for lv in 3:
		set_graphics(Gfx.id_of(lv))
		await get_tree().create_timer(9.0 if lv == 0 else 7.0).timeout
		player.flying = true
		for v in views:
			player.teleport(v[1], v[2])
			await _shot(dir, "%d_%s_%s" % [lv, Gfx.id_of(lv), v[0]])
		var m = world.machines.values()[0]
		var c = m.get_parent().position + m.position
		player.teleport(c + Vector3(5.5, 2.0, 7.5), c + Vector3(0, 2.4, 0))
		await _shot(dir, "%d_%s_machine" % [lv, Gfx.id_of(lv)])
		player.teleport(c + Vector3(-6.5, 3.0, -6.0), c + Vector3(0, 2.2, 0))
		await _shot(dir, "%d_%s_machine_back" % [lv, Gfx.id_of(lv)])
		hud.open_bob()
		await get_tree().create_timer(1.3).timeout
		await _shot(dir, "%d_%s_panel" % [lv, Gfx.id_of(lv)])
		hud.open_graphics()
		await _shot(dir, "%d_%s_menu" % [lv, Gfx.id_of(lv)])
		hud.close_modal()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_graphics("standard")
	get_tree().quit()

# One shot of each handheld tool at rest, plus one mid wind-up, then quit.
func _run_toolshots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	await get_tree().create_timer(6.0).timeout
	player.teleport(Vector3(6, 0.4, -24), Vector3(-10, 3, -52))
	for i in 6:
		_set_mode(i)
		await _shot(dir, "tool%d" % (i + 1))
	_charge_test = 0.8
	await _shot(dir, "tool6_charging")
	_charge_test = 0.0
	# and the signs, to check their text sits inside its panel
	_set_mode(0)
	var pf = world.platforms.values()[0].position
	var dp = world._depots.values()[0].position
	var views = [["sign_hub", Vector3(4, 0.4, 14), Vector3(9, 2.6, 0)], ["sign_hub_front", Vector3(0, 0.4, 11), Vector3(0, 4.4, 0)],
		["sign_dock", Vector3(12.5, 0.4, 17), Vector3(13, 2.4, 8)], ["sign_logs", Vector3(18, 0.4, 9.5), Vector3(18, 2.3, 1.5)],
		["sign_node", pf + Vector3(0, 0.4, 20), pf + Vector3(0, 8.0, 1.2)], ["sign_depot", dp + Vector3(0, 0.4, 5.5), dp + Vector3(0, 1.9, 1.5)]]
	for v in views:
		player.teleport(v[1], v[2])
		await _shot(dir, v[0])
	# Bob's repair stand, close up and from the spawn, then his fix list
	player.teleport(Vector3(-9.5, 0.4, 16.5), Vector3(-12.6, 2.3, 8.5))
	await _shot(dir, "bob_stand")
	player.teleport(Vector3(0, 0.4, 17), Vector3(0, 3.5, 0))
	await _shot(dir, "bob_from_spawn")
	hud.open_bob()
	await get_tree().create_timer(1.4).timeout
	await _shot(dir, "bob_list")
	# Bob 2.0: his case file on each failing pod (log and events read line by line)
	var ci = 0
	for j in K.issues(cluster.state):
		if j["kind"] == "pod" and ci < 3:
			hud.open_bob_case(j["uid"])
			await get_tree().create_timer(2.2).timeout
			await _shot(dir, "bob_case_%d_%s" % [ci, j["status"]])
			ci += 1
	# the demo chooser, then each demo world: an overview, and Bob on its first failing pod
	hud.open_demos()
	await _shot(dir, "demo_chooser")
	hud.close_modal()
	for d in Demo.DEMO_TYPES.slice(1):
		_connect_target({"source": "simulation", "context": d["flavor"], "provider": Demo.FLAVORS[d["flavor"]]["provider"]})
		await get_tree().create_timer(16.0).timeout
		player.flying = true
		player.teleport(Vector3(-40, 26, 8), Vector3(0, 2, -62))
		await _shot(dir, "demo_%s" % d["id"])
		player.teleport(Vector3(-22, 17, -18), Vector3(6, 12, -40))   # in among the belts
		await _shot(dir, "demo_%s_belts" % d["id"])
		for j in K.issues(cluster.state):
			if j["kind"] == "pod" and j["status"] != "ImagePullBackOff":
				hud.open_bob_case(j["uid"])
				await get_tree().create_timer(2.2).timeout
				await _shot(dir, "demo_%s_bob" % d["id"])
				hud.close_modal()
				break
	await get_tree().process_frame
	get_tree().quit()

func _run_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(9.0).timeout
	hud.open_welcome()
	await _shot(dir, "00_welcome")
	hud.open_pause()
	await _shot(dir, "00_pause")
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _shot(dir, "01_spawn")
	player.flying = true
	player.teleport(Vector3(-52, 30, 6), Vector3(0, 2, -70))
	await _shot(dir, "02_overview")
	player.teleport(Vector3(6, 9, -30), Vector3(-30, 4, -62))
	await _shot(dir, "03_platform")
	player.flying = false
	var bad = ""
	var good = ""
	for p in cluster.state["pods"]:
		if p["health"] == "bad" and bad == "":
			bad = p["uid"]
		if p["health"] == "ok" and p["wname"] == "frontend":
			good = p["uid"]
	var spot = world.machine_spot(good)
	if spot != null:
		player.teleport(spot[0], spot[1])
		await get_tree().create_timer(0.5).timeout
		_process(0.016)
		await _shot(dir, "04_machine")
	spot = world.machine_spot(bad)
	if spot != null:
		player.flying = true
		player.teleport(spot[1] + Vector3(9, 7, 16), spot[1] + Vector3(0, 3, 0))
		await _shot(dir, "05_problem")
		player.flying = false
		hud.open_pod(bad)
		await get_tree().create_timer(1.5).timeout
		await _shot(dir, "06_pod_panel")
	hud.open_codex()
	await _shot(dir, "07_codex")
	hud.open_build()
	await _shot(dir, "08_build_menu")
	hud.close_modal()
	blueprint = {"type": "replica", "ns": "shop", "kind": "Deployment", "name": "frontend"}
	_set_mode(2)
	var bspot = world.workload_spot("shop", "Deployment", "frontend")
	if bspot != null:
		player.teleport(bspot[0] + Vector3(1.5, 0, 2.5), bspot[1] + Vector3(0, -2.4, 3.0))
	await get_tree().create_timer(0.4).timeout
	for i in 2:
		_build()
	await get_tree().create_timer(5.0).timeout
	await _shot(dir, "09_build_mode")
	hud.open_node(cluster.state["nodes"][cluster.state["nodes"].size() - 1]["name"])
	await _shot(dir, "10_node")
	if cluster.state["workloads"].size() > 0:
		hud._ask_delete_workload(cluster.state["workloads"][0])
		await _shot(dir, "10b_typed_confirm")
		hud.close_modal()
	hud.open_logs()
	await get_tree().create_timer(1.5).timeout
	await _shot(dir, "12_logs")
	hud._ls["tab"] = "events"
	hud.open_logs()
	await get_tree().create_timer(1.5).timeout
	await _shot(dir, "13_events")
	hud._ls["tab"] = "audit"
	hud.open_logs()
	await _shot(dir, "14_audit")
	hud.open_clusters()
	await _shot(dir, "15_clusters")
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.teleport(Vector3(-4, 0.4, 20), Vector3(-22, 4, 0))
	await _shot(dir, "16_gates")
	# --- Porter (Portainer NPC): conversation screens + real deploys
	hud.open_talk()
	await get_tree().create_timer(1.3).timeout
	await _shot(dir, "20_porter_talk")
	hud.open_talk("apps")
	await get_tree().create_timer(1.0).timeout
	await _shot(dir, "21_porter_apps")
	hud._talk["app"] = "wordpress"
	hud.open_talk("app")
	await get_tree().create_timer(1.3).timeout
	await _shot(dir, "22_porter_app")
	hud.open_talk("lists")
	await get_tree().create_timer(1.0).timeout
	await _shot(dir, "23a_porter_lists")
	var cats = hud.Apps.load_catalogs()
	var registry = null
	for ci in mini(cats.size(), 2):
		hud._talk["cat"] = cats[cats.size() - 1 - ci] if cats.size() > 1 else cats[0]
		hud._talk["cat"] = cats[1 - ci] if cats.size() > 1 else cats[0]
		hud.open_talk("catalogue")
		await get_tree().create_timer(6.0).timeout
		var data = hud._lists.get(hud._talk["cat"]["url"])
		print("porter list '", hud._talk["cat"]["name"], "': ", data["templates"].size() if typeof(data) == TYPE_DICTIONARY else str(data).left(120))
		await _shot(dir, "23b_porter_catalogue_%d" % ci)
		if typeof(data) == TYPE_DICTIONARY:
			for t in data["templates"]:
				if str(t.get("title", "")) == "Registry":
					registry = t
	if registry != null:
		hud._talk["tpl"] = registry
		hud.open_talk("tpl")
		await get_tree().create_timer(1.0).timeout
		await _shot(dir, "24_porter_template")
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var live = cluster.state["source"] != "simulation"
	cluster.act({"op": "apply_app", "id": "postgres", "ns": "kf-pg"})
	if registry != null:
		cluster.act({"op": "deploy_template", "template": registry, "name": "kf-registry", "ns": "kf-apps"})
	player.teleport(Vector3(8.5, 0.4, 15.5), Vector3(11.5, 1.9, 9.0))
	await _shot(dir, "25_porter")
	await get_tree().create_timer(40.0 if live else 6.0).timeout
	for p in cluster.state["pods"]:
		if p["ns"] in ["kf-pg", "kf-apps"] or p["name"].begins_with("kf-"):
			print("porter built: ", p["ns"], "/", p["name"], "  ", p["status"], "  ", p["wkind"], "/", p["wname"])
	for s in cluster.state["services"]:
		if s["ns"] in ["kf-pg", "kf-apps"]:
			print("porter service: ", s["ns"], "/", s["name"], "  ", s["ports"])
	var pspot = world.workload_spot("kf-pg", "StatefulSet" if cluster.state["source"] != "docker" else "Compose", "postgres")
	if pspot != null:
		player.teleport(pspot[0] + Vector3(2.5, 0, 3.5), pspot[1])
		await _shot(dir, "26_porter_result")
	hud.open_talk("installed")
	await get_tree().create_timer(1.0).timeout
	await _shot(dir, "27_porter_installed")
	if cluster.state["source"] == "docker":
		cluster.act({"op": "portainer_install"})
		await get_tree().create_timer(45.0).timeout
		print("porter: portainer installed = ", hud._portainer_installed())
		hud.open_talk("portainer")
		await get_tree().create_timer(1.2).timeout
		await _shot(dir, "28_porter_portainer")
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	cluster.act({"op": "remove_app", "id": "postgres", "ns": "kf-pg"})
	if registry != null:
		cluster.act({"op": "remove_template", "name": "kf-registry", "ns": "kf-apps"})
	await get_tree().create_timer(4.0).timeout
	if cluster.state["source"] == "simulation":
		_connect_target({"source": "simulation", "context": "azure-aks-staging", "provider": "Azure AKS"})
		await get_tree().create_timer(5.0).timeout
		player.flying = true
		player.teleport(Vector3(-40, 26, 10), Vector3(0, 2, -70))
		await _shot(dir, "17_aws")
		player.flying = false
	elif cluster.state["source"] == "docker":
		# live Docker engine: run, inspect, restart and remove one throwaway container
		cluster.act({"op": "create", "ns": "default", "name": "kf-selftest", "image": "nginx:1.27-alpine", "replicas": 1})
		await get_tree().create_timer(12.0).timeout
		var uid = ""
		for p in cluster.state["pods"]:
			if p["name"] == "kf-selftest":
				uid = p["uid"]
		print("docker selftest container visible: ", uid != "")
		if uid != "":
			var dspot = world.machine_spot(uid)
			player.teleport(dspot[0] + Vector3(2, 0, 3), dspot[1])
			await _shot(dir, "17_docker_machine")
			hud.open_logs(uid)
			await get_tree().create_timer(1.5).timeout
			await _shot(dir, "18_docker_logs")
			hud.close_modal()
			cluster.act({"op": "restart", "ns": "default", "kind": "Pod", "name": "", "pod": "kf-selftest"})
			await get_tree().create_timer(4.0).timeout
		cluster.act({"op": "delete_pod", "ns": "default", "name": "kf-selftest"})
		await get_tree().create_timer(3.0).timeout
	else:
		# live cluster: exercise every mutating action once, on a throwaway deployment
		var node_name = cluster.state["nodes"][cluster.state["nodes"].size() - 1]["name"]
		for a in [{"op": "create", "ns": "default", "name": "kf-selftest", "image": "nginx:1.27-alpine", "replicas": 1},
				{"op": "scale", "ns": "default", "kind": "Deployment", "name": "kf-selftest", "replicas": 2},
				{"op": "restart", "ns": "default", "kind": "Deployment", "name": "kf-selftest"},
				{"op": "cordon", "node": node_name, "on": true},
				{"op": "cordon", "node": node_name, "on": false}]:
			cluster.act(a)
			await get_tree().create_timer(3.0).timeout
		player.flying = true
		player.teleport(Vector3(-40, 26, 10), Vector3(0, 2, -70))
		await _shot(dir, "17_live_after_actions")
		player.flying = false
		cluster.act({"op": "delete_workload", "ns": "default", "kind": "Deployment", "name": "kf-selftest"})
		await get_tree().create_timer(3.0).timeout
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var wspot = world.workload_spot("shop", "Deployment", "frontend")
	if wspot != null:
		# real hold-to-fire test: dismantle one frontend pod with the MK.4 tool
		_set_mode(4)
		player.teleport(wspot[0] + Vector3(2.5, 0, 3.5), wspot[1])
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		await get_tree().create_timer(0.4).timeout
		print("hold-test target: ", player.hit.get("meta", {}))
		Input.action_press("fire")
		await get_tree().create_timer(0.5).timeout
		print("hold-test mid: progress=", _dis)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir.path_join("11_charging.png"))
		await get_tree().create_timer(0.7).timeout
		Input.action_release("fire")
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_mode(0)
		await get_tree().create_timer(2.5).timeout
	for l in cluster.audit_lines.slice(maxi(0, cluster.audit_lines.size() - 40)):
		print("AUDIT ", l)
	get_tree().quit()

# ---- dev: multi-user test bot. Several instances run at once, each as a
# different identity; each reports what it can see and do, then quits.
#   --mptest=<dir>,<x>,<z>,<seconds>

func _run_mptest(spec: String) -> void:
	var parts = spec.split(",")
	var dir = parts[0]
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sfx.set_muted(true)
	await get_tree().create_timer(10.0).timeout
	var me = cluster.user_name()
	player.teleport(Vector3(parts[1].to_float(), 0.4, parts[2].to_float()), Vector3(0, 1.6, 12))
	var st = cluster.state
	var by_ns = {}
	for p in st["pods"]:
		by_ns[p["ns"]] = by_ns.get(p["ns"], 0) + 1
	print("[%s] user=%s groups=%s" % [me, st.get("user", ""), st.get("groups", [])])
	print("[%s] max_tier=%d scoped_ns='%s' multiuser=%s nodes=%d pods_by_ns=%s" % [me, cluster.max_tier(), st.get("scoped_ns", ""), st.get("multiuser", false), st["nodes"].size(), by_ns])
	print("[%s] permissions=%s" % [me, cluster.backend.caps])
	var results = []
	cluster.action_done.connect(func(ok, msg): results.append("%s | %s" % ["ok" if ok else "REFUSED", msg]))
	if me != "kubernetes-admin":
		# try one action of each tier and see which are let through
		var pod = null
		for p in st["pods"]:
			if p["ns"] == "shop" and p["wname"] == "frontend":
				pod = p
		for a in [{"op": "scale_by", "ns": "shop", "kind": "Deployment", "name": "frontend", "delta": 1},
				{"op": "restart", "ns": "shop", "kind": "Deployment", "name": "redis"},
				{"op": "delete_pod", "ns": "shop", "name": pod["name"] if pod != null else "none"},
				{"op": "delete_workload", "ns": "shop", "kind": "Deployment", "name": "redis"},
				{"op": "restart", "ns": "kube-system", "kind": "Deployment", "name": "coredns"}]:
			_set_mode([2, 3, 4, 5, 3][results.size()] if results.size() < 5 else 0)
			cluster.act(a)
			await get_tree().create_timer(3.5).timeout
			print("[%s] MK.%d %s  =>  %s" % [me, K.tier_of(a, cluster.state), cluster.describe(a), results[results.size() - 1] if results.size() > 0 else "?"])
	var seconds = parts[3].to_float()
	var t = 0.0
	while t < seconds:
		await get_tree().create_timer(5.0).timeout
		t += 5.0
		var names = []
		for p in cluster.peers:
			names.append("%s@%s tool=%d" % [p["user"], p["pos"], p["tool"]])
		print("[%s] t=%d online: %s" % [me, int(t), names])
	if cluster.peers.size() > 0:
		var pp = str(cluster.peers[0]["pos"]).split(",")
		player.teleport(player.global_position, Vector3(pp[0].to_float(), 1.5, pp[2].to_float()))
	hud.set_mode(mode, blueprint)
	await _shot(dir, "mp_" + me)
	get_tree().quit()

# ---- dev: scripted camera fly-through for the README clip.
#   engine\Godot...console.exe --path . --write-movie <dir>/f.png --fixed-fps 30 -- --demo --flyby

func _run_flyby() -> void:
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sfx.set_muted(true)
	player.flying = true
	player.enabled = false
	while world.machines.is_empty():
		await get_tree().process_frame
	# [camera position, look-at point]
	var path = [[Vector3(0, 3, 30), Vector3(0, 4, 0)], [Vector3(-20, 18, 10), Vector3(-27, 2, -70)],
		[Vector3(-54, 10, -56), Vector3(-27, 3, -66)], [Vector3(0, 10, -58), Vector3(27, 2, -64)],
		[Vector3(60, 24, -10), Vector3(0, 2, -60)], [Vector3(16, 3, 20), Vector3(11, 2, 9)]]
	for i in range(1, path.size()):
		var t = 0.0
		while t < 1.0:
			t += get_process_delta_time() / 2.2
			var k = smoothstep(0.0, 1.0, t)
			player.teleport(path[i - 1][0].lerp(path[i][0], k), path[i - 1][1].lerp(path[i][1], k))
			await get_tree().process_frame
	get_tree().quit()

# ---- dev: a ~35 s scripted tour for a video. Record it with Godot's movie writer:
#   Godot --path . --write-movie out.avi --fixed-fps 60 --resolution 1920x1080 -- --demo --trailer

func _glide(a: Array, b: Array, secs: float) -> void:
	var t = 0.0
	while t < 1.0:
		t += get_process_delta_time() / secs
		var k = smoothstep(0.0, 1.0, t)
		player.teleport(a[0].lerp(b[0], k), a[1].lerp(b[1], k))
		await get_tree().process_frame

func _run_trailer() -> void:
	_shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sfx.set_muted(true)
	player.flying = true
	player.enabled = false
	var spawn = [Vector3(0, 0.6, 26), Vector3(0, 4.2, 0)]
	player.teleport(spawn[0], spawn[1])
	while world.machines.is_empty():
		await get_tree().process_frame
	await get_tree().create_timer(2.5).timeout
	var bad = ""
	for p in cluster.state["pods"]:
		if p["health"] == "bad":
			bad = p["uid"]
			break
	var hub = [Vector3(0, 0.6, 13), Vector3(0, 4.2, 0)]
	var over = [Vector3(-46, 30, 8), Vector3(0, 2, -66)]
	var row = [Vector3(-52, 9, -30), Vector3(-27, 3, -58)]
	var row_end = [Vector3(40, 11, -30), Vector3(27, 3, -60)]
	await _glide(spawn, hub, 3.5)
	await get_tree().create_timer(0.8).timeout
	await _glide(hub, over, 4.0)
	await get_tree().create_timer(0.8).timeout
	await _glide(over, row, 3.5)
	await _glide(row, row_end, 5.5)
	var last = row_end
	var spot = world.machine_spot(bad)
	if spot != null:
		var at = [spot[1] + Vector3(6.5, 1.2, 9.5), spot[1] + Vector3(0, 0.6, 0)]
		await _glide(row_end, at, 3.5)
		last = at
		# show off the six tools, then wind the dismantler up on the failing machine
		for i in [1, 2, 3, 5, 4]:
			_set_mode(i)
			await get_tree().create_timer(0.9).timeout
		var t = 0.0
		while t < 1.0:
			t += get_process_delta_time() / 1.6
			_charge_test = clampf(t, 0.01, 1.0)
			await get_tree().process_frame
		_charge_test = 0.0
		player.tool_kick(1.0)
		await get_tree().create_timer(0.8).timeout
		_set_mode(0)
		hud.open_pod(bad)
		await get_tree().create_timer(3.0).timeout
		hud.close_modal()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.open_codex()
	await get_tree().create_timer(2.5).timeout
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# back to the yard: Bob's repair stand and his fix list, then Porter's dock
	var high = [Vector3(-30, 14, 6), Vector3(-12, 2, 2)]
	var bob = [Vector3(-8.6, 0.6, 15.6), Vector3(-12.2, 2.3, 8.6)]
	await _glide(last, high, 3.0)
	await _glide(high, bob, 3.0)
	await get_tree().create_timer(3.2).timeout
	hud.open_bob()
	await get_tree().create_timer(4.0).timeout
	hud.close_modal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var dock = [Vector3(12.5, 0.6, 17.5), Vector3(11.5, 2.2, 9)]
	await _glide(bob, dock, 3.5)
	await get_tree().create_timer(1.8).timeout
	get_tree().quit()

# ---- dev: README fly-through. Saves numbered frames; tools/make_gif.py turns them into docs/flythrough.gif.
#   --demo --flythrough=<dir>

func _run_flythrough(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_running = true
	await get_tree().create_timer(9.0).timeout
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sfx.set_muted(true)
	player.flying = true
	player.enabled = false
	var keys = [[Vector3(0, 2.2, 24), Vector3(0, 4, 0)], [Vector3(-14, 10, 6), Vector3(-27, 3, -52)],
		[Vector3(-44, 22, -18), Vector3(-22, 2, -62)], [Vector3(-27, 13, -34), Vector3(-27, 2, -58)],
		[Vector3(8, 18, -30), Vector3(27, 2, -58)], [Vector3(48, 9, -36), Vector3(62, 3, -56)],
		[Vector3(30, 5, -18), Vector3(0, 3, -24)], [Vector3(11.5, 2.3, 17), Vector3(10.5, 1.8, 9)]]
	var n = 0
	for k in keys.size() - 1:
		for i in 13:
			var f = smoothstep(0.0, 1.0, i / 13.0)
			player.teleport(keys[k][0].lerp(keys[k + 1][0], f), keys[k][1].lerp(keys[k + 1][1], f))
			await get_tree().create_timer(0.07).timeout
			await RenderingServer.frame_post_draw
			var img = get_viewport().get_texture().get_image()
			img.resize(640, 360, Image.INTERPOLATE_LANCZOS)
			img.save_png(dir.path_join("f%03d.png" % n))
			n += 1
	get_tree().quit()
