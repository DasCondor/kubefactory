extends SceneTree

const Agent = preload("res://scripts/agent.gd")
const Cluster = preload("res://scripts/cluster.gd")

class TestCluster extends "res://scripts/cluster.gd":
	var webhook_calls = 0
	func _webhook(_url: String, _body: String) -> void:
		webhook_calls += 1

class TestProviders extends "res://scripts/providers.gd":
	var reads = 0
	func available() -> bool:
		return true
	func _saved() -> Dictionary:
		reads += 1
		return {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var cluster = TestCluster.new()
	root.add_child(cluster)
	cluster.start("simulation", "helmsman-sim")
	var deadline = Time.get_ticks_msec() + 15000
	while cluster.detecting and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var marker = OS.get_environment("KF_TEST_DOCKER_MARKER")
	var ok = cluster.backend != null and cluster.backend.label == "simulation" and not Agent.running()
	var providers = TestProviders.new()
	providers.world = Node3D.new()
	providers.restore({"source": "simulation"})
	ok = ok and providers.reads == 0
	providers.restore({"source": "kubernetes"})
	ok = ok and providers.reads == 1
	providers.world.free()
	providers.free()
	if marker != "":
		ok = ok and not FileAccess.file_exists(marker)
	if ok:
		cluster.local_policy = {"audit_webhook": "https://example.invalid/test"}
		cluster._action_finished({"op": "restart", "kind": "Deployment", "ns": "test", "name": "test"}, {"ok": true, "msg": "ok"}, cluster._gen)
		await create_timer(0.2).timeout
		ok = ok and cluster.webhook_calls == 0
		var templates = cluster.backend.run_action({"op": "templates", "catalog": {"url": "https://example.invalid/test"}})
		ok = ok and not templates["ok"] and str(templates["text"]).contains("unavailable")
	for target in cluster.targets:
		ok = ok and target["source"] == "simulation"
	if not ok or cluster.targets.is_empty():
		printerr("Simulation started local discovery or did not load")
	else:
		cluster.discover_targets()
		deadline = Time.get_ticks_msec() + 30000
		while cluster.finding_targets and Time.get_ticks_msec() < deadline:
			await create_timer(0.05).timeout
		ok = not cluster.finding_targets and (not Agent.available() or Agent.running())
		if marker != "":
			ok = ok and FileAccess.file_exists(marker)
			ok = ok and cluster.targets.any(func(t): return t["source"] == "docker" and t["context"] == "simulation-test")
			if ok:
				cluster.connect_target({"source": "docker", "context": "simulation-test", "provider": "Docker Engine"})
				deadline = Time.get_ticks_msec() + 30000
				while cluster.detecting and Time.get_ticks_msec() < deadline:
					await create_timer(0.05).timeout
				ok = not cluster.detecting and cluster.backend != null and cluster.backend.label == "docker"
		if not ok:
			printerr("Explicit local discovery did not finish")
	cluster.queue_free()
	await process_frame
	await process_frame
	Agent.shutdown()
	if ok:
		print("SIMULATION ISOLATION PASSED")
	quit(0 if ok else 1)
