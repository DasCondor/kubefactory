extends RefCounted
# Rendering benchmark: flies a fixed camera route through the demo cluster with
# vsync off and writes frame-time and draw statistics as JSON, then quits.
#
#   Godot --path . --resolution 1920x1080 -- --demo=kubernetes --gfx=<preset> --bench=<out.json>
#
# It only touches things the game has always had (player, world, sfx), so the
# same file can be dropped into an older checkout to measure a past release:
# tools\bench.ps1 does exactly that to compare the presets with the last release.

const ROUTE = [[Vector3(0, 3, 30), Vector3(0, 4, 0)], [Vector3(-20, 18, 10), Vector3(-27, 2, -70)],
	[Vector3(-54, 10, -56), Vector3(-27, 3, -66)], [Vector3(0, 10, -58), Vector3(27, 2, -64)],
	[Vector3(60, 24, -10), Vector3(0, 2, -60)], [Vector3(16, 3, 20), Vector3(11, 2, 9)],
	[Vector3(0, 2.2, 22), Vector3(0, 4, 0)]]
const SECONDS_PER_LEG = 3.0

static func run(m: Node, out_path: String, label: String) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	m._shots_running = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	m.sfx.set_muted(true)
	m.player.flying = true
	m.player.enabled = false
	m.player.teleport(ROUTE[0][0], ROUTE[0][1])
	var tree = m.get_tree()
	while m.world.machines.is_empty():
		await tree.process_frame
	await tree.create_timer(8.0).timeout      # let build animations and texture generation finish
	var times = PackedFloat32Array()
	var draws = 0.0
	var objects = 0.0
	var prims = 0.0
	var last = Time.get_ticks_usec()
	for i in range(1, ROUTE.size()):
		var t = 0.0
		while t < 1.0:
			await tree.process_frame
			var now = Time.get_ticks_usec()
			var dt = (now - last) / 1000000.0
			last = now
			t += dt / SECONDS_PER_LEG
			var k = smoothstep(0.0, 1.0, t)
			m.player.teleport(ROUTE[i - 1][0].lerp(ROUTE[i][0], k), ROUTE[i - 1][1].lerp(ROUTE[i][1], k))
			times.append(dt * 1000.0)
			draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
			prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var n = times.size()
	var total = 0.0
	for x in times:
		total += x
	var sorted = Array(times)
	sorted.sort()
	var size = DisplayServer.window_get_size()
	var res = {
		"label": label,
		"gpu": RenderingServer.get_video_adapter_name(),
		"resolution": "%dx%d" % [size.x, size.y],
		"machines": m.world.machines.size(),
		"frames": n,
		"avg_fps": snappedf(n / (total / 1000.0), 0.1),
		"avg_ms": snappedf(total / n, 0.01),
		"p95_ms": snappedf(sorted[int(n * 0.95)], 0.01),
		"p99_ms": snappedf(sorted[int(n * 0.99)], 0.01),
		"low_1pct_fps": snappedf(1000.0 / sorted[int(n * 0.99)], 0.1),
		"draw_calls": int(draws / n),
		"objects": int(objects / n),
		"primitives": int(prims / n),
		"video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}
	var f = FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	print("bench ", JSON.stringify(res))
	tree.quit()
