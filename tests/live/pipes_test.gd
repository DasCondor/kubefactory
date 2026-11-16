extends SceneTree
# The service belts as the library's pipe kit: with the library in use, every
# belt run is pipe, every corner a junction, every drop into a machine a valve,
# and the code-drawn tracks are hidden; without it (Compatibility renderer,
# the browser's Standard preset) the tracks stay. KF_SHOTS=<dir> saves
# screenshots from the belt yard. The operator's settings.json is restored.

var _fails = []
const PIPE_CLEARANCE = 0.26

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(220)])
	if not ok:
		_fails.append(what)

func _pipe_crossings(paths: Array) -> Array:
	var segments = []
	for route_index in paths.size():
		var path = paths[route_index]
		var pts: Array = path["pts"]
		var id = "service %d" % path["service"] if path.has("service") else "%s %d" % [path.get("kind", "VPN"), route_index]
		for i in range(1, pts.size()):
			var a: Vector3 = pts[i - 1]
			var b: Vector3 = pts[i]
			if a.distance_squared_to(b) > 0.05 * 0.05:
				segments.append([a.min(b), a.max(b), id])
	var crossings = []
	for i in segments.size():
		var a = segments[i]
		for j in range(i + 1, segments.size()):
			var b = segments[j]
			if a[2] == b[2]:
				continue
			# Axis-aligned segments occupy their bounds, so the axis gaps give their true distance.
			var ab: Vector3 = a[0] - b[1]
			var ba: Vector3 = b[0] - a[1]
			var gap = ab.max(ba).max(Vector3.ZERO)
			if gap.length_squared() < PIPE_CLEARANCE * PIPE_CLEARANCE:
				crossings.append("%s meets %s (gap %.3f)" % [a, b, gap.length()])
	return crossings

func _run() -> void:
	var path = OS.get_user_data_dir().path_join("settings.json")
	var before = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while (game.cluster.backend == null or game.world.machines.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	await create_timer(2.0).timeout
	game.hud.close_modal(false)
	var w = game.world
	var lib = w.Models.available()
	var preset = game.Gfx.preset if "preset" in game.Gfx else ""
	print("library in use: ", lib, "   paths: ", w._paths.size())
	_check("there are belts to draw", w._paths.size() > 0, w._paths.size())
	var branch = {"pts": [Vector3(-1, 2, 0), Vector3(1, 2, 0)]}
	var riser = {"pts": [Vector3(0, 0, 0), Vector3(0, 4, 0)]}
	var adjacent = {"pts": [Vector3(0, 0, 0.2), Vector3(0, 4, 0.2)]}
	_check("the clearance check catches a short branch crossing", _pipe_crossings([branch, riser]).size() == 1)
	_check("the clearance check catches overlapping parallel fittings", _pipe_crossings([riser, adjacent]).size() == 1)
	adjacent["pts"] = [Vector3(0, 0, 0.3), Vector3(0, 4, 0.3)]
	_check("the clearance check allows a clear parallel run", _pipe_crossings([riser, adjacent]).is_empty())
	var crossings = _pipe_crossings(w._paths)
	for crossing in crossings.slice(0, 12):
		print("CROSSING ", crossing)
	_check("unrelated pipes clear each other", crossings.is_empty(), crossings.size())
	var all_paths: Array = w._paths
	for kind in ["API", "Metrics", "Files"]:
		var expected = all_paths.filter(func(route): return route.get("kind") == kind)
		if expected.is_empty():
			continue
		w.pipe_filter = kind
		w.apply_state(game.cluster.state)
		var points = func(routes): return routes.map(func(route): return route["pts"])
		_check("%s filter keeps the original pipe routes" % kind, points.call(w._paths) == points.call(expected))
	w.pipe_filter = "All"
	w.apply_state(game.cluster.state)
	if lib:
		_check("the belts are pipes", w._pipe_mode and w._pipes != null and w._pipes.count() > 0, w._pipes.count() if w._pipes != null else 0)
		_check("the code-drawn tracks are hidden", not w._belt_mm.visible)
		var valves = w._pipes._sets["valve"][0].instance_count
		var drops = w._paths.filter(func(pa): return pa.get("valve", true)).size()     # a VPN tunnel rises out of a machine: no valve
		_check("one valve on every drop into a machine", valves == drops, "%d valves, %d drops" % [valves, drops])
		_check("corners have junctions", w._pipes._sets["joint"][0].instance_count > 0, w._pipes._sets["joint"][0].instance_count)
		_check("what flows is a collar on the pipe", w._item_mm.multimesh.mesh is CylinderMesh)
	else:
		_check("without the library the code-drawn tracks stay", not w._pipe_mode and w._belt_mm.visible)
	# B hides them, and showing them again brings the pipes back
	w.show_belts = false
	w.apply_state(game.cluster.state)
	await process_frame
	_check("B hides the belts", w._paths.is_empty())
	w.show_belts = true
	w.apply_state(game.cluster.state)
	await process_frame
	_check("and shows them again", w._paths.size() > 0 and (not lib or w._pipes.count() > 0))
	var dir = OS.get_environment("KF_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		var tag = OS.get_environment("KF_SHOT_TAG")
		var views = [["yard", Vector3(-22, 17, -18), Vector3(6, 12, -40)], ["drops", Vector3(-4, 9, -32), Vector3(-4, 6, -50)], ["depots", Vector3(-10, 6, -10), Vector3(0, 5, -26)]]
		for m in w.machines.values():
			if m.pod["wname"] == "jellyfin":
				var roof = m.to_global(m.pipe_port(Vector2.ZERO))
				views.append(["jellyfin", roof + Vector3(-6.6, 7.0, 6.0), roof + Vector3(0, 5.0, 0)])
				break
		for v in views:
			game.player.flying = true
			game.player.teleport(v[1], v[2])
			await create_timer(1.2).timeout
			root.get_texture().get_image().save_png(dir.path_join("pipes_%s_%s.png" % [tag, v[0]]))
	# a rough cost: frames per second over the yard, belts shown and hidden (printed, not judged)
	game.player.flying = true
	game.player.teleport(Vector3(-22, 17, -18), Vector3(6, 12, -40))
	var fps = []
	for shown in [true, false]:
		w.show_belts = shown
		w.apply_state(game.cluster.state)
		await create_timer(1.0).timeout
		var f0 = Engine.get_frames_drawn()
		var t0 = Time.get_ticks_msec()
		await create_timer(3.0).timeout
		fps.append((Engine.get_frames_drawn() - f0) * 1000.0 / (Time.get_ticks_msec() - t0))
	print("fps over the yard: belts shown %.0f, hidden %.0f" % fps)
	w.show_belts = true
	game.queue_free()
	await process_frame
	if before == "":
		DirAccess.remove_absolute(path)
	else:
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("PIPES PASSED" if _fails.is_empty() else "PIPES FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
