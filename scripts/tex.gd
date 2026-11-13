extends RefCounted
# Procedural textures and shared materials - the game ships no image assets.

const ORANGE = Color(0.98, 0.584, 0.286)
const DARK = Color(0.13, 0.14, 0.16)

static var _cache = {}

static func _noise(size: int, base: float, amp: float, sd: int) -> Image:
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var rng = RandomNumberGenerator.new()
	rng.seed = sd
	for y in size:
		for x in size:
			var v = base + rng.randf_range(-amp, amp)
			img.set_pixel(x, y, Color(v, v, v))
	return img

static func _finish(img: Image) -> ImageTexture:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func foundation() -> ImageTexture:
	if _cache.has("foundation"):
		return _cache["foundation"]
	var s = 256
	var img = _noise(s, 0.62, 0.035, 11)
	var line = Color(0.3, 0.3, 0.31)
	img.fill_rect(Rect2i(0, 0, s, 4), line)
	img.fill_rect(Rect2i(0, s - 4, s, 4), line)
	img.fill_rect(Rect2i(0, 0, 4, s), line)
	img.fill_rect(Rect2i(s - 4, 0, 4, s), line)
	var soft = Color(0.52, 0.52, 0.53)
	img.fill_rect(Rect2i(s / 2 - 1, 4, 2, s - 8), soft)
	img.fill_rect(Rect2i(4, s / 2 - 1, s - 8, 2), soft)
	for c in [Vector2i(12, 12), Vector2i(s - 36, 12), Vector2i(12, s - 36), Vector2i(s - 36, s - 36)]:
		img.fill_rect(Rect2i(c.x, c.y, 24, 6), ORANGE)
		img.fill_rect(Rect2i(c.x if c.x < s / 2 else c.x + 18, c.y, 6, 24), ORANGE)
	_cache["foundation"] = _finish(img)
	return _cache["foundation"]

static func panel() -> ImageTexture:
	if _cache.has("panel"):
		return _cache["panel"]
	var s = 256
	var img = _noise(s, 0.9, 0.025, 23)
	var seam = Color(0.5, 0.5, 0.5)
	for y in [0, 84, 170]:
		img.fill_rect(Rect2i(0, y, s, 3), seam)
	for i in 3:
		var off = 0 if i % 2 == 0 else 64
		for x in [off, off + 128]:
			img.fill_rect(Rect2i(x % s, [0, 84, 170][i], 3, 86), seam)
	var rivet = Color(0.42, 0.42, 0.42)
	for y in [10, 94, 180]:
		for x in range(12, s, 40):
			img.fill_rect(Rect2i(x, y, 4, 4), rivet)
	_cache["panel"] = _finish(img)
	return _cache["panel"]

static func hazard() -> ImageTexture:
	if _cache.has("hazard"):
		return _cache["hazard"]
	var s = 128
	var img = Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			img.set_pixel(x, y, Color(0.96, 0.74, 0.1) if int((x + y) / 32.0) % 2 == 0 else Color(0.1, 0.1, 0.11))
	_cache["hazard"] = _finish(img)
	return _cache["hazard"]

static func mat(color: Color, rough: float = 0.7, metal: float = 0.0, tex: Texture2D = null, tri_scale: float = 0.0) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if tex != null:
		m.albedo_texture = tex
		if tri_scale > 0.0:
			m.uv1_triplanar = true
			m.uv1_world_triplanar = true
			m.uv1_scale = Vector3.ONE * tri_scale
	return m

static func glow(color: Color, energy: float = 2.5) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

static func ghost(color: Color) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

# Named shared materials.
static func shared(key: String) -> StandardMaterial3D:
	if _cache.has("m_" + key):
		return _cache["m_" + key]
	var m
	match key:
		"dark":
			m = mat(DARK, 0.55, 0.6)
		"steel":
			m = mat(Color(0.55, 0.57, 0.6), 0.4, 0.8)
		"orange":
			m = mat(ORANGE, 0.5, 0.2)
		"foundation":
			m = mat(Color.WHITE, 0.85, 0.0, foundation(), 0.125)
		"hazard":
			m = mat(Color.WHITE, 0.7, 0.0, hazard(), 0.5)
		"board":
			m = mat(Color(0.07, 0.08, 0.09), 0.5, 0.3)
		"off":
			m = mat(Color(0.05, 0.05, 0.05), 0.4, 0.2)
		_:
			m = mat(Color.MAGENTA)
	_cache["m_" + key] = m
	return m

static func status_glow(h: String) -> StandardMaterial3D:
	if not _cache.has("g_" + h):
		var K = load("res://scripts/kutil.gd")
		_cache["g_" + h] = glow(K.health_color(h).darkened(0.15), 1.25)
	return _cache["g_" + h]

static func body(color: Color) -> StandardMaterial3D:
	var key = "b_" + color.to_html()
	if not _cache.has(key):
		_cache[key] = mat(color, 0.55, 0.25, panel(), 0.25)
	return _cache[key]
