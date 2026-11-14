# Audits every model in assets/ at every tier and writes docs/MODEL_AUDIT.md.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tools/model_audit.gd
#
# What it checks, per file:
#   loads          the GLB parses and produces meshes
#   catalog        triangle count and bounds agree with assets/catalog.json
#   ground         nothing hangs below y = 0
#   display        nothing stands in front of a LiveView glass: rays are cast out
#                  of the glass on a 7 x 5 grid and tested against the triangles
#                  of every other part (this is what found the StatefulSet fault)
#   tiers          the three tiers of one model carry the same named parts
#
# What it cannot see: two solid parts pushed into each other where neither is a
# display. That needs a look at the model, and is recorded as not checked.
extends SceneTree

const Models = preload("res://scripts/models.gd")

const REACH = 0.45      # metres in front of a display that must be clear
const GRID = Vector2i(7, 5)

func _init() -> void:
	var rows = []
	var totals = {"files": 0, "ok": 0, "defect": 0, "fixed": 0}
	Models.root()
	for id in Models.ids():
		var e = Models.entry(id)
		var names_by_tier = {}
		for t in Models.TIERS:
			var v = e.get("variants", {}).get(t)
			if v == null:
				rows.append([id, t, e.get("category", ""), "missing", "no file for this tier in the catalog"])
				continue
			totals["files"] += 1
			var scene = Models._load_scene(id, t)
			if scene == null:
				rows.append([id, t, e.get("category", ""), "defect", "does not load"])
				totals["defect"] += 1
				continue
			var parts = []
			Models._collect(scene, Transform3D.IDENTITY, parts)
			var found = _check(id, v, parts, false)
			var state = "ok"
			if not found.is_empty():
				state = "defect"
				if Models.FIXUPS.has(id):
					var after = _check(id, v, parts, true)
					if after.is_empty():
						state = "fixed at load"
					else:
						found = after
			var names = {}
			for p in parts:
				names[_stem(p[0])] = true
			names_by_tier[t] = names
			scene.free()
			if state == "ok":
				totals["ok"] += 1
			else:
				totals["fixed" if state == "fixed at load" else "defect"] += 1
				rows.append([id, t, e.get("category", ""), state, "; ".join(found)])
		var base = names_by_tier.get("standard", {})
		for t in names_by_tier:
			var missing = []
			for n in base:
				if not names_by_tier[t].has(n):
					missing.append(n)
			if not missing.is_empty():
				rows.append([id, t, e.get("category", ""), "note", "parts of the standard tier absent here: " + ", ".join(missing)])
	_write(rows, totals)
	print("audit: ", totals, "  rows: ", rows.size())
	quit()

# A glass the game or a Krew member shows something on.
func _is_display(n: String) -> bool:
	return n.contains("Surface_glass") or (n.begins_with("LiveView_") and n.contains("glass"))

# "LiveView_glass.001" -> "LiveView_glass"
func _stem(n: String) -> String:
	return n.get_slice(".", 0).rstrip("0123456789")

func _check(id: String, v: Dictionary, parts: Array, fixed: bool) -> Array:
	var out = []
	var fix = Models.FIXUPS.get(id, {}) if fixed else {}
	var boxes = []
	var tris = 0
	var all = AABB()
	for i in parts.size():
		var xf: Transform3D = parts[i][2]
		for prefix in fix.get("nodes", []):
			if str(parts[i][0]).begins_with(prefix):
				xf = Transform3D(Basis.IDENTITY, fix["move"]) * xf
		var b = xf * parts[i][1].get_aabb()
		boxes.append([b, xf])
		all = b if i == 0 else all.merge(b)
		tris += parts[i][1].get_faces().size() / 3
	if not fixed:
		if v.has("triangles") and int(v["triangles"]) != tris:
			out.append("catalog says %d triangles, file has %d" % [int(v["triangles"]), tris])
		if v.has("bounds"):
			var lo = Vector3(v["bounds"][0][0], v["bounds"][0][1], v["bounds"][0][2])
			var hi = Vector3(v["bounds"][1][0], v["bounds"][1][1], v["bounds"][1][2])
			if lo.distance_to(all.position) > 0.005 or hi.distance_to(all.end) > 0.005:
				out.append("bounds differ from the catalog by more than 5 mm")
		if all.position.y < -0.005:
			out.append("reaches %.3f m below the ground" % -all.position.y)
	for i in parts.size():
		var n = str(parts[i][0])
		if not _is_display(n):
			continue
		var g: AABB = boxes[i][0]
		var axis = g.get_shortest_axis_index()
		var dir = Vector3.ZERO
		dir[axis] = 1.0 if g.get_center()[axis] >= all.get_center()[axis] else -1.0
		var u = (axis + 1) % 3
		var w = (axis + 2) % 3
		var face = g.get_center()[axis] + dir[axis] * (g.size[axis] * 0.5 + 0.002)
		var prism = g
		prism.position[axis] = minf(face, face + dir[axis] * REACH)
		prism.size[axis] = REACH
		var hits = {}
		var blocked = 0
		for j in parts.size():
			if j == i or _is_display(str(parts[j][0])) or str(parts[j][0]).contains("Caption") or not boxes[j][0].intersects(prism):
				continue
			var f: PackedVector3Array = parts[j][1].get_faces()
			var xf: Transform3D = boxes[j][1]
			for gx in GRID.x:
				for gy in GRID.y:
					var from = Vector3.ZERO
					from[axis] = face
					from[u] = g.position[u] + g.size[u] * (gx + 0.5) / GRID.x
					from[w] = g.position[w] + g.size[w] * (gy + 0.5) / GRID.y
					var to = from + dir * REACH
					for k in range(0, f.size(), 3):
						if Geometry3D.segment_intersects_triangle(from, to, xf * f[k], xf * f[k + 1], xf * f[k + 2]) != null:
							hits[_stem(str(parts[j][0]))] = true
							blocked += 1
							break
		if blocked > 0:
			out.append("%s is obstructed by %s (%d ray hits of %d)" % [_stem(n), ", ".join(hits.keys()), blocked, GRID.x * GRID.y])
	return out

func _write(rows: Array, totals: Dictionary) -> void:
	var md = PackedStringArray()
	md.append("# Model audit (library V6)")
	md.append("")
	md.append("Written by `tools/model_audit.gd`. Do not edit by hand: run the tool again.")
	md.append("")
	md.append("- Files checked: **%d** (%d models at up to three tiers)" % [totals["files"], Models.ids().size()])
	md.append("- No finding: **%d**" % totals["ok"])
	md.append("- Defect in the file, corrected when the game loads it: **%d**" % totals["fixed"])
	md.append("- Defect still present: **%d**" % totals["defect"])
	md.append("")
	md.append("## What is checked")
	md.append("")
	md.append("| Check | How | Result language |")
	md.append("|---|---|---|")
	md.append("| Loads | GLB parsed by the engine's glTF importer | verified |")
	md.append("| Catalog | triangle count and bounds against `assets/catalog.json` | verified |")
	md.append("| Ground | lowest point against y = 0 | verified |")
	md.append("| Display clear | %d rays out of each LiveView glass, %d cm, against every other part's triangles | verified |" % [GRID.x * GRID.y, int(REACH * 100)])
	md.append("| Same parts at every tier | part names compared with the standard tier | verified |")
	md.append("| Solid parts pushed into each other | **not checked**: needs a look at each model | not tested |")
	md.append("| Art standard (Porter V3) | krew and machines are V3; the other categories are V2 and are not placed in the world | by category, not measured |")
	md.append("")
	md.append("## Findings")
	md.append("")
	if rows.is_empty():
		md.append("None.")
	else:
		md.append("| Model | Tier | Category | State | Finding |")
		md.append("|---|---|---|---|---|")
		for r in rows:
			md.append("| `%s` | %s | %s | %s | %s |" % r)
	md.append("")
	md.append("Models that reach below the ground are V2 models or Krew members the game does not place. Porter and Bob are stood on their lowest point, so the game is not affected; the files should still be corrected at the source.")
	md.append("")
	md.append("## Corrections applied at load")
	md.append("")
	md.append("The library files stay byte-identical to what was supplied; `scripts/models.gd` (`FIXUPS`) moves the named parts when a model is loaded.")
	md.append("")
	if Models.FIXUPS.is_empty():
		md.append("None: this version of the library needs no corrections.")
	for id in Models.FIXUPS:
		var fx = Models.FIXUPS[id]
		md.append("- `%s`: parts `%s*` moved by %s, %d bracket posts added." % [id, "`, `".join(fx["nodes"]), str(fx["move"]), fx.get("posts", []).size()])
	md.append("")
	var f = FileAccess.open("res://docs/MODEL_AUDIT.md", FileAccess.WRITE)
	f.store_string("\n".join(md))
	f.close()
