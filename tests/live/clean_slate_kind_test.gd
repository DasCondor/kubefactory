extends SceneTree
# After Clean slate made a kind cluster: the wizard sees it, Switch cluster finds
# its context, and the game connects to it (read only) and shows its node.
#
#   powershell -ExecutionPolicy Bypass -File setup\install-kubefactory.ps1 -Target kind -ClusterName kf-cleanslate-test -Yes
#   $env:KF_KIND_CLUSTER = "kf-cleanslate-test"
#   Godot --path . -s tests/live/clean_slate_kind_test.gd -- --read-only
#   kind delete cluster --name kf-cleanslate-test      (the test leaves the cluster alone)
#
# The operator's settings.json is restored afterwards.

const CS = preload("res://scripts/clean_slate.gd")
var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(200)])
	if not ok:
		_fails.append(what)

func _run() -> void:
	var name = OS.get_environment("KF_KIND_CLUSTER")
	if name == "":
		print("SKIP set KF_KIND_CLUSTER to the kind cluster Clean slate made")
		quit(1)
		return
	var path = OS.get_user_data_dir().path_join("settings.json")
	var before = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var det = CS.detect()
	_check("the wizard sees the kind cluster", name in det.get("kind_clusters", []), det.get("kind_clusters"))
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 30000
	while game.cluster.backend == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	game.cluster.discover_targets()
	var ctx = "kind-" + name
	var find = func():
		for t in game.cluster.targets:
			if t["context"] == ctx:
				return t
		return null
	deadline = Time.get_ticks_msec() + 30000
	while find.call() == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.3).timeout
	var target = find.call()
	_check("Switch cluster finds the context " + ctx, target != null, game.cluster.targets.map(func(t): return t["context"]))
	if target != null:
		game.hud.target_requested.emit(target)
		deadline = Time.get_ticks_msec() + 60000
		var connected = func(): return game.cluster.state.get("context", "") == ctx and game.cluster.state.get("nodes", []).size() > 0
		while not connected.call() and Time.get_ticks_msec() < deadline:
			await create_timer(0.5).timeout
		var st = game.cluster.state
		_check("the game connects and shows the cluster's node", connected.call(), "%s nodes=%s" % [st.get("context"), st.get("nodes", []).map(func(n): return n.get("name"))])
		_check("the factory has machines for it", game.world.machines.size() > 0, game.world.machines.size())
		print("  provider: %s  pods: %d" % [st.get("provider", ""), st.get("pods", []).size()])
	if before != "":
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(before)
		f.close()
	print("CLEAN SLATE KIND PASSED" if _fails.is_empty() else "CLEAN SLATE KIND FAILED: " + ", ".join(PackedStringArray(_fails)))
	quit(0 if _fails.is_empty() else 1)
