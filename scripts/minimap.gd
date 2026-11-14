extends Control
# The minimap: a small top-down view that turns with you (forward is up).
# Node platforms, every machine as a dot in its health colour (failing ones
# pulse), the HUB, the cluster gates, Bob, Porter, Gauge, the Krew's stations
# and you. It only reads the world; it draws, it never changes anything.
# N shows or hides it (saved), and it steps aside while touch controls are up.

const K = preload("res://scripts/kutil.gd")

const SIZE = 210.0
const SCALE = 0.95         # pixels per metre: about 110 m around you, the HUB and the first rows of nodes
const BG = Color(0.06, 0.07, 0.08, 0.78)
const EDGE = Color(0.98, 0.584, 0.286, 0.9)

var world = null
var player = null
var hud = null             # for its touch controls: their left thumb pad sits where the map would
var enabled = true         # the player's choice (N)
var _t = 0.0
var _redraw = 0.0

func _ready() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	var touch = hud.touch if hud != null else null
	visible = enabled and not (touch != null and touch.active)
	_t += delta
	_redraw -= delta
	if visible and _redraw <= 0.0:
		_redraw = 0.08
		queue_redraw()

# world position -> map position: the player in the middle, their forward up
func _to_map(p: Vector3) -> Vector2:
	var rel = p - player.global_position
	return Vector2(rel.x, rel.z).rotated(player.rotation.y) * SCALE + _centre()

# you, a little below the middle: more of what is ahead fits
func _centre() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.62)

func _inside(v: Vector2, pad: float = 0.0) -> bool:
	return v.x >= -pad and v.y >= -pad and v.x <= size.x + pad and v.y <= size.y + pad

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	if world == null or player == null:
		return
	# node platforms
	for pf in world.platforms.values():
		if not is_instance_valid(pf):
			continue
		var o: Vector3 = pf.global_position
		var hw = 20.0
		var d = float(pf.get("depth")) if pf.get("depth") != null else 20.0
		var pts = PackedVector2Array([_to_map(o + Vector3(-hw, 0, 0)), _to_map(o + Vector3(hw, 0, 0)), _to_map(o + Vector3(hw, 0, -d)), _to_map(o + Vector3(-hw, 0, -d))])
		draw_colored_polygon(pts, Color(0.22, 0.24, 0.27, 0.9))
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.42, 0.45, 0.5, 0.9), 1.0)
	# the HUB and the gates
	_mark(Vector3.ZERO, EDGE, 6.0, "HUB")
	for g in world.get("_gates") if world.get("_gates") != null else []:
		if is_instance_valid(g):
			var v = _to_map(g.global_position)
			if _inside(v, 4):
				draw_colored_polygon(PackedVector2Array([v + Vector2(0, -4), v + Vector2(4, 3), v + Vector2(-4, 3)]), Color(0.85, 0.88, 0.92, 0.8))
	# the people and stations
	for pair in [["_bob", Color(1.0, 0.8, 0.45), "B"], ["_npc", Color(0.35, 0.75, 1.0), "P"], ["_gauge", Color(0.4, 0.92, 1.0), "G"], ["_foreman", Color(1.0, 0.68, 0.15), "F"]]:
		var n = world.get(pair[0])
		if n != null and is_instance_valid(n) and n.is_visible_in_tree():
			_mark(n.global_position, pair[1], 4.0, pair[2])
	var tags = world.get("_krew_tags")
	if tags != null:
		for id in tags:
			var tag = tags[id]
			if is_instance_valid(tag):
				_mark(tag.get_parent().global_position, tag.modulate, 3.0, "")
	# machines, failing ones pulsing
	for m in world.machines.values():
		if not is_instance_valid(m):
			continue
		var v = _to_map(m.global_position)
		if not _inside(v, 6):
			continue
		var h = str(m.pod.get("health", "ok")) if m.get("pod") != null else "ok"
		var r = 2.6
		if h == "bad":
			r += 1.6 + 1.4 * sin(_t * 6.0)
		draw_circle(v, r, K.health_color(h))
	# you, and north
	var c = _centre()
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -8), c + Vector2(6, 6), c + Vector2(0, 3), c + Vector2(-6, 6)]), Color.WHITE)
	var north = Vector2(0, -1).rotated(player.rotation.y)
	var np = size / 2.0 + north * (size.x / 2.0 - 12.0)
	draw_circle(np, 8.0, Color(0, 0, 0, 0.55))
	draw_string(get_theme_default_font(), np + Vector2(-4, 5), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, EDGE)
	draw_rect(Rect2(Vector2.ZERO, size), EDGE, false, 2.0)

func _mark(p: Vector3, col: Color, r: float, letter: String) -> void:
	var v = _to_map(p)
	if not _inside(v, r):
		return
	draw_rect(Rect2(v - Vector2(r, r), Vector2(r, r) * 2.0), col)
	if letter != "":
		draw_string(get_theme_default_font(), v + Vector2(r + 2.0, 4.0), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
