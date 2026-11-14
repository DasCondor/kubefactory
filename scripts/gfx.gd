extends RefCounted
# Graphics presets. One world, one set of models and one code path: a preset
# only decides how much is layered on top and how hard the renderer works.
#
#   STANDARD  the look the game shipped with. It is the floor: nothing here is
#             ever turned down below it. Cheaper to draw than it used to be
#             (merged machine meshes, occlusion culling), not plainer.
#   ENHANCED  more industrial detail on machines, platforms and in the yard,
#             lit lamp posts, finer shadows and anti-aliasing.
#   ULTRA     everything in Enhanced plus global illumination, reflections,
#             a heavier atmosphere and the far industrial skyline.
#
# Presets change what you see, never what you can do: every tool, panel, board
# and action is built by code that does not look at the preset.
#
# The browser build always runs the light path (no extra detail, one shadow
# pass) whatever is asked for.

const STANDARD = 0
const ENHANCED = 1
const ULTRA = 2
const NAMES = ["Standard", "Enhanced", "Ultra"]
const IDS = ["standard", "enhanced", "ultra"]
const BLURB = [
	"The classic look, tuned to run on modest hardware.",
	"More detail on machines and in the yard, lamp light, finer shadows.",
	"Global illumination, reflections, thick atmosphere and the industrial skyline.",
]

static var level = STANDARD
static var chosen = "auto"          # what the player picked: "auto" or one of IDS
# Occlusion culling is built in (machines, platform slabs and the big boards are occluders)
# but off unless asked for with --occlusion: the yard is open, so on the benchmark route
# it hides almost nothing and its CPU cost made every preset slower (see docs/BENCHMARK.md).
static var use_occlusion = false
static var _rec = {}

static func lite() -> bool:
	return OS.has_feature("web") or RenderingServer.get_rendering_device() == null

static func occlusion() -> bool:
	return use_occlusion and not lite()

# Extra detail tier for models and scenery: 0, 1 or 2 (always 0 on the light path).
static func detail() -> int:
	return 0 if lite() else level

static func id_of(lv: int) -> String:
	return IDS[clampi(lv, 0, 2)]

static func level_of(id: String) -> int:
	return maxi(IDS.find(id.to_lower()), 0)

# Pick the level from the saved choice ("auto" follows the hardware) or a
# `--gfx=<id>` argument, which wins.
static func setup(saved: String, args: Array) -> void:
	chosen = saved if saved in IDS else "auto"
	for a in args:
		if str(a) == "--occlusion":
			use_occlusion = true
		if str(a).begins_with("--gfx="):
			var v = str(a).trim_prefix("--gfx=").to_lower()
			chosen = v if v in IDS else "auto"
	level = recommend()["level"] if chosen == "auto" else level_of(chosen)
	if lite():
		level = STANDARD

# ---- hardware -> recommended preset

# A rough class for a GPU from its name: 3 high-end, 2 mid-range, 1 entry / old, 0 unknown.
static func gpu_class(gpu_name: String) -> int:
	var n = gpu_name.to_lower()
	var rx = RegEx.new()
	# NVIDIA: RTX 2060 and up; the last two digits are the tier within a generation
	rx.compile("(rtx|gtx)\\s*(\\d{3,4})")
	var m = rx.search(n)
	if m != null:
		var num = int(m.get_string(2))
		var tier = num % 100
		if m.get_string(1) == "rtx":
			var gen = int(num / 1000.0)
			if tier >= 70 or (gen >= 4 and tier >= 60):
				return 3
			return 2
		if num >= 1060 and num < 2000:
			return 2 if tier >= 70 else 1
		return 1
	rx.compile("rx\\s*(\\d{3,4})")
	m = rx.search(n)
	if m != null:
		var num = int(m.get_string(1))
		if num >= 6700 and num % 1000 >= 700:
			return 3
		return 2 if num >= 5600 else 1
	rx.compile("arc\\s*(a|b)(\\d{3})")
	m = rx.search(n)
	if m != null:
		return 2 if int(m.get_string(2)) >= 570 else 1
	if n.contains("apple m"):
		return 2 if (n.contains("pro") or n.contains("max") or n.contains("ultra")) else 1
	if n.contains("intel") or n.contains("uhd") or n.contains("iris") or n.contains("radeon graphics") or n.contains("radeon(tm) graphics") or n.contains("vega") or n.contains("llvmpipe") or n.contains("swiftshader"):
		return 1
	return 0

# {level, gpu, why}: the preset this machine should be comfortable with.
static func recommend() -> Dictionary:
	if not _rec.is_empty():
		return _rec
	var gpu = RenderingServer.get_video_adapter_name()
	var why = ""
	var lv = STANDARD
	if lite():
		why = "the browser / compatibility renderer always uses the light path"
	else:
		var kind = RenderingServer.get_video_adapter_type()
		var cls = gpu_class(gpu)
		var ram_gb = float(OS.get_memory_info().get("physical", 0)) / 1073741824.0
		var cores = OS.get_processor_count()
		var discrete = kind == RenderingDevice.DEVICE_TYPE_DISCRETE_GPU
		if cls == 0:
			cls = 2 if discrete else 1    # an unrecognised discrete card is assumed mid-range
		if kind == RenderingDevice.DEVICE_TYPE_CPU or kind == RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
			cls = 1
		lv = [STANDARD, STANDARD, ENHANCED, ULTRA][cls]
		why = ["", "an integrated or entry-level GPU", "a mid-range GPU", "a high-end GPU"][cls]
		# not enough memory or cores to feed the heavier presets
		if lv == ULTRA and (ram_gb > 0.0 and ram_gb < 15.0 or cores < 8):
			lv = ENHANCED
			why += ", but under 16 GB of memory or 8 CPU threads"
		if lv >= ENHANCED and (ram_gb > 0.0 and ram_gb < 7.0 or cores < 4):
			lv = STANDARD
			why += ", but under 8 GB of memory or 4 CPU threads"
	_rec = {"level": lv, "gpu": gpu, "why": why}
	return _rec

# ---- applying a preset to the renderer

# `base` holds the shipped (Standard) values so switching back restores them exactly.
static func apply(env: Environment, sun: DirectionalLight3D, vp: Viewport, base: Dictionary) -> void:
	if lite():
		return
	var lv = level
	vp.msaa_3d = [Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_4X][lv]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if lv == ULTRA else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_occlusion_culling = occlusion()
	vp.mesh_lod_threshold = [1.0, 1.0, 0.5][lv]
	RenderingServer.directional_shadow_atlas_set_size([4096, 8192, 16384][lv], true)
	RenderingServer.directional_soft_shadow_filter_set_quality([RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH, RenderingServer.SHADOW_QUALITY_SOFT_ULTRA][lv])
	RenderingServer.positional_soft_shadow_filter_set_quality([RenderingServer.SHADOW_QUALITY_SOFT_LOW, RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH][lv])
	RenderingServer.environment_set_ssao_quality([RenderingServer.ENV_SSAO_QUALITY_MEDIUM, RenderingServer.ENV_SSAO_QUALITY_HIGH, RenderingServer.ENV_SSAO_QUALITY_ULTRA][lv], true, 0.5, 2, 50, 300)
	RenderingServer.environment_glow_set_use_bicubic_upscale(lv >= ENHANCED)
	RenderingServer.environment_set_volumetric_fog_volume_size([64, 64, 96][lv], [64, 64, 96][lv])
	RenderingServer.environment_set_volumetric_fog_filter_active(true)
	# sun and shadows
	sun.directional_shadow_max_distance = base["shadow_dist"] * [1.0, 1.25, 1.6][lv]
	sun.light_angular_distance = [0.0, 0.3, 0.6][lv]          # softer, contact-hardening penumbra
	sun.shadow_blur = [1.0, 1.0, 1.2][lv]
	# ambient occlusion and bounce light
	env.ssao_intensity = base["ssao"] * [1.0, 1.1, 1.15][lv]
	env.sdfgi_enabled = lv == ULTRA
	if lv == ULTRA:
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.4
		env.sdfgi_use_occlusion = true
		env.sdfgi_energy = 0.8
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
	# with real bounce light the flat ambient term has less to make up for
	env.ambient_light_energy = base["ambient"] * [1.0, 1.0, 0.8][lv]
	env.ssr_enabled = lv == ULTRA
	env.ssr_max_steps = 48
	env.ssr_fade_in = 0.2
	env.ssr_fade_out = 2.5
	# atmosphere
	env.glow_intensity = base["glow"] * [1.0, 1.1, 1.2][lv]
	env.glow_bloom = base["bloom"] + [0.0, 0.02, 0.05][lv]
	env.volumetric_fog_density = base["vfog"] * [1.0, 1.05, 1.15][lv]
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.adjustment_contrast = base["contrast"] + [0.0, 0.01, 0.03][lv]

# One line for the settings menu: what is on, and why it was recommended.
static func summary() -> String:
	var r = recommend()
	return "%s  ·  recommended for this machine: %s (%s%s)" % [NAMES[level], NAMES[r["level"]], r["gpu"], (", " + r["why"]) if r["why"] != "" else ""]
