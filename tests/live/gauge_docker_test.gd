extends SceneTree

const Docker = preload("res://scripts/backend_docker.gd")
const Gauge = preload("res://scripts/gauge.gd")

func _init() -> void:
	var name = OS.get_environment("KF_GAUGE_TEST_CONTAINER")
	if not name.begins_with("kf-gauge-test-"):
		printerr("A disposable kf-gauge-test container is required")
		quit(1)
		return
	var backend = Docker.new()
	var probe = backend.probe()
	var result = backend.run_action({"op": "pod_metrics", "name": name, "ns": ""})
	var data: Dictionary = result.get("data", {})
	var rendered = Gauge.reading(result)
	var ok = probe.get("ok", false) and result.get("ok", false) and data.get("source") == "docker stats"
	ok = ok and data.has("cpu_cores") and float(data.get("mem_bytes", 0.0)) > 0.0
	ok = ok and rendered.contains("docker stats") and rendered.contains("Network totals:") and not rendered.contains("SIMULATED")
	if ok:
		print("GAUGE DOCKER PASSED: ", rendered.replace("\n", " | "))
	else:
		printerr("Gauge could not read the disposable container: ", result.get("msg", ""))
	quit(0 if ok else 1)
