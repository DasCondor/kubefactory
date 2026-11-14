extends RefCounted
const Gfx = preload("res://scripts/gfx.gd")
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

# Darken an albedo image with soft, tileable stains so big surfaces are not flat.
static func _grime(img: Image, sd: int, amount: float) -> void:
	var n = FastNoiseLite.new()
	n.seed = sd
	n.frequency = 0.012
	n.fractal_octaves = 4
	var s = img.get_width()
	var g = n.get_seamless_image(s, s)
	for y in s:
		for x in s:
			var c = img.get_pixel(x, y)
			var k = 1.0 - amount * clampf((g.get_pixel(x, y).r - 0.35) * 2.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r * k, c.g * k, c.b * k))

# Tileable tangent-space normal map from a greyscale height image (white = raised).
static func normal_from(height: Image, strength: float) -> ImageTexture:
	height.convert(Image.FORMAT_L8)
	var s = height.get_width()
	var d = height.get_data()
	var out = PackedByteArray()
	out.resize(s * s * 3)
	for y in s:
		var yy = y * s
		var yu = ((y + s - 1) % s) * s
		var yd = ((y + 1) % s) * s
		for x in s:
			var dx = (d[yy + (x + s - 1) % s] - d[yy + (x + 1) % s]) / 255.0 * strength
			var dy = (d[yd + x] - d[yu + x]) / 255.0 * strength
			var n = Vector3(dx, dy, 1.0).normalized()
			var i = (yy + x) * 3
			out[i] = int(n.x * 127.5 + 127.5)
			out[i + 1] = int(n.y * 127.5 + 127.5)
			out[i + 2] = int(n.z * 127.5 + 127.5)
	return _finish(Image.create_from_data(s, s, false, Image.FORMAT_RGB8, out))

static func _grey(v: float) -> Color:
	return Color(v, v, v)

static func foundation() -> ImageTexture:
	if _cache.has("foundation"):
		return _cache["foundation"]
	var s = 256
	var img = _noise(s, 0.62, 0.035, 11)
	var hgt = _noise(s, 0.6, 0.03, 12)
	_grime(img, 5, 0.22)
	var line = Color(0.3, 0.3, 0.31)
	for r in [Rect2i(0, 0, s, 4), Rect2i(0, s - 4, s, 4), Rect2i(0, 0, 4, s), Rect2i(s - 4, 0, 4, s)]:
		img.fill_rect(r, line)
		hgt.fill_rect(r, _grey(0.25))
	var soft = Color(0.52, 0.52, 0.53)
	for r in [Rect2i(s / 2 - 1, 4, 2, s - 8), Rect2i(4, s / 2 - 1, s - 8, 2)]:
		img.fill_rect(r, soft)
		hgt.fill_rect(r, _grey(0.42))
	for c in [Vector2i(12, 12), Vector2i(s - 36, 12), Vector2i(12, s - 36), Vector2i(s - 36, s - 36)]:
		img.fill_rect(Rect2i(c.x, c.y, 24, 6), ORANGE)
		img.fill_rect(Rect2i(c.x if c.x < s / 2 else c.x + 18, c.y, 6, 24), ORANGE)
	_cache["foundation"] = _finish(img)
	_cache["foundation_n"] = normal_from(hgt, 2.5)
	return _cache["foundation"]

static func panel() -> ImageTexture:
	if _cache.has("panel"):
		return _cache["panel"]
	var s = 256
	var img = _noise(s, 0.9, 0.025, 23)
	var hgt = _noise(s, 0.6, 0.008, 24)
	_grime(img, 9, 0.16)
	var seam = Color(0.5, 0.5, 0.5)
	for y in [0, 84, 170]:
		img.fill_rect(Rect2i(0, y, s, 3), seam)
		hgt.fill_rect(Rect2i(0, y, s, 3), _grey(0.2))
	for i in 3:
		var off = 0 if i % 2 == 0 else 64
		for x in [off, off + 128]:
			img.fill_rect(Rect2i(x % s, [0, 84, 170][i], 3, 86), seam)
			hgt.fill_rect(Rect2i(x % s, [0, 84, 170][i], 3, 86), _grey(0.2))
	var rivet = Color(0.42, 0.42, 0.42)
	for y in [10, 94, 180]:
		for x in range(12, s, 40):
			img.fill_rect(Rect2i(x, y, 4, 4), rivet)
			hgt.fill_rect(Rect2i(x - 1, y - 1, 6, 6), _grey(0.8))
			hgt.fill_rect(Rect2i(x, y, 4, 4), _grey(1.0))
	_cache["panel"] = _finish(img)
	_cache["panel_n"] = normal_from(hgt, 3.0)
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

static func mat(color: Color, rough: float = 0.7, metal: float = 0.0, tex: Texture2D = null, tri_scale: float = 0.0, normal: Texture2D = null) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if normal != null:
		m.normal_enabled = true
		m.normal_texture = normal
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

# ---- preset-dependent surface response (Gfx.detail(): 0 Standard, 1 Enhanced, 2 Ultra)
# Colours and albedo textures never change with the preset. The higher presets
# add a roughness map (stained areas dull, clean areas glossier) and a little
# more metal, so reflections and bounce light have something to work with.

# Tileable roughness map: values between lo and hi, and with `wet` > 0 a share of
# the surface drops to puddle-smooth so it picks up reflections.
static func _rough_map(key: String, sd: int, lo: float, hi: float, wet: float = 0.0) -> ImageTexture:
	if _cache.has(key):
		return _cache[key]
	var s = 256
	var n = FastNoiseLite.new()
	n.seed = sd
	n.frequency = 0.012
	n.fractal_octaves = 4
	var g = n.get_seamless_image(s, s)
	var fine = _noise(s, 0.5, 0.5, sd + 1)
	var img = Image.create(s, s, false, Image.FORMAT_RGB8)
	for y in s:
		for x in s:
			var v = clampf((g.get_pixel(x, y).r - 0.3) * 2.2, 0.0, 1.0)
			var r = lerpf(lo, hi, v) + (fine.get_pixel(x, y).r - 0.5) * 0.06
			if wet > 0.0 and v < wet:
				r = lerpf(0.08, r, smoothstep(wet * 0.55, wet, v))
			img.set_pixel(x, y, Color(r, r, r))
	_cache[key] = _finish(img)
	return _cache[key]

static func _style_body(m: StandardMaterial3D) -> void:
	var d = Gfx.detail()
	m.roughness_texture = _rough_map("rough_panel", 9, 0.42, 0.82) if d >= 1 else null
	m.roughness = 1.0 if d >= 1 else 0.55
	m.metallic = [0.25, 0.3, 0.4][d]
	m.metallic_specular = [0.5, 0.5, 0.6][d]

static func _style_foundation(m: StandardMaterial3D) -> void:
	var d = Gfx.detail()
	m.roughness_texture = null if d == 0 else (_rough_map("rough_found", 5, 0.72, 0.97) if d == 1 else _rough_map("rough_found_wet", 5, 0.72, 0.97, 0.22))
	m.roughness = 1.0 if d >= 1 else 0.85

# Re-style every material already made, after the preset changed.
static func apply_detail() -> void:
	for key in _cache.keys():
		if key.begins_with("b_"):
			_style_body(_cache[key])
	if _cache.has("m_foundation"):
		_style_foundation(_cache["m_foundation"])

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
			m = mat(Color.WHITE, 0.85, 0.0, foundation(), 0.125, _cache["foundation_n"])
			_style_foundation(m)
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

# After the palette changes: the status lamps are rebuilt in the new colours.
static func clear_status() -> void:
	for k in _cache.keys():
		if str(k).begins_with("g_"):
			_cache.erase(k)

static func status_glow(h: String) -> StandardMaterial3D:
	if not _cache.has("g_" + h):
		var K = load("res://scripts/kutil.gd")
		_cache["g_" + h] = glow(K.health_color(h).darkened(0.15), 1.25)
	return _cache["g_" + h]

# Painted armour for library models, in a workload's colour.
static func accent(color: Color) -> StandardMaterial3D:
	var key = "a_" + color.to_html()
	if not _cache.has(key):
		_cache[key] = mat(color, 0.42, 0.35)
	return _cache[key]

static func body(color: Color) -> StandardMaterial3D:
	var key = "b_" + color.to_html()
	if not _cache.has(key):
		_cache[key] = mat(color, 0.55, 0.25, panel(), 0.25, _cache["panel_n"])
		_style_body(_cache[key])
	return _cache[key]
