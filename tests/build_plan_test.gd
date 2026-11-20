extends SceneTree

const Plan = preload("res://scripts/build_plan.gd")
const Planner = preload("res://scripts/flow_planner.gd")
const Demo = preload("res://scripts/backend_demo.gd")
var failures = 0

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ")+message)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var model = Plan.new()
	var app = model.add("Plex",[0,0,0],"app","plexinc/pms-docker:latest")
	var disk = model.add("Library",[2,0,0],"storage")
	check(app != "" and disk != "", "place typed blocks on distinct grid cells")
	check(model.add("Collision",[0,0,0]) == "" and model.data["nodes"].size() == 2, "occupied cells reject placement without changing the plan")
	check(model.connect_blocks(app,disk,"Mounts"), "compatible named sockets connect")
	check(not model.connect_blocks(app,disk,"Mounts"), "duplicate routes are rejected")
	check(not model.connect_blocks(app,disk,"API"), "storage rejects network sockets")
	check(not model.connect_blocks(app,"missing","API"), "unknown endpoints are rejected")
	var before = model.data.duplicate(true)
	check(model.edit(app,{"rotation":1}) and model.node(app)["id"] == app, "rotation preserves stable IDs")
	model.undo()
	check(model.data == before, "undo restores the complete prior edit")
	model.remove([app])
	check(model.data["edges"].is_empty() and model.node(app) == null, "removal atomically removes dependent edges")
	model.undo()
	check(model.data == before, "undo restores a removed block and its routes together")
	var legacy = {"nodes":[{"title":"old/app","x":40,"y":40,"vlan":30},{"title":"old/worker","x":40,"y":40,"vlan":40}],"edges":[[0,1,0]]}
	check(model.load_plan(legacy) and model.data["nodes"][0]["vlan"] == 30 and model.data["nodes"][0]["cell"] != model.data["nodes"][1]["cell"], "legacy layouts migrate overlapping positions and preserve VLANs")
	var roundtrip = JSON.parse_string(JSON.stringify(model.data))
	check(model.load_plan(roundtrip), "versioned plans round-trip through JSON")
	var invalid = model.data.duplicate(true)
	invalid["nodes"][0]["cell"] = [0.5,0,0]
	check(not model.load_plan(invalid), "fractional grid positions cannot enter the plan")
	check(model.from_state(Demo.new("docker-media-gatherer").fetch()), "current media map imports with every endpoint and route")
	check(model.data["nodes"].size() == 33 and model.data["edges"].size() > 50, "media source IDs and defined routes are retained")
	var editor = Planner.new()
	root.add_child(editor)
	editor.restore(model.data)
	await process_frame
	await process_frame
	check(editor.snapshot() == model.data and editor.view.blocks.blocks.size() == 33, "graph and factory blocks load the same versioned plan")
	editor.load_preset(false)
	check(editor.snapshot()["edges"].size() == 6, "existing shop preset remains available")
	var saved = editor.snapshot()
	editor.restore(saved)
	check(editor.snapshot() == saved, "restoring a saved graph preserves the full block plan")
	editor.queue_free()
	await process_frame
	print("BUILD PLAN PASSED" if failures == 0 else "BUILD PLAN FAILED")
	quit(0 if failures == 0 else 1)
