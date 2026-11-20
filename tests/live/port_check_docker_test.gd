extends SceneTree
# Check from here, against the local Docker engine, through the game's backend.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/live/port_check_docker_test.gd
#
# Runs a throw-away busybox web server published on 127.0.0.1:18080, checks the
# port row offers that address and the probe connects and gets an HTTP answer;
# stops it and checks the same binding is no longer reported as connected; then
# removes the container by name. Nothing else on the engine is touched.

const NAME = "kf-live-portcheck"
const PORT = 18080

var _results = []

func _docker(args: Array) -> Array:
	var out = []
	var code = OS.execute("docker", PackedStringArray(args), out, true)
	return [code, str(out[0]) if out.size() > 0 else ""]

func _step(name: String, ok: bool, note = "") -> void:
	_results.append(ok)
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, str(note).left(190)])

func _row(K, d) -> Dictionary:
	for row in K.port_rows(d.fetch()):
		if row["name"] == NAME:
			return row
	return {}

func _init() -> void:
	var K = load("res://scripts/kutil.gd")
	var Docker = load("res://scripts/backend_docker.gd")
	_docker(["rm", "-f", NAME])
	_docker(["pull", "-q", "busybox:1.36"])
	var run = _docker(["run", "-d", "--name", NAME, "-p", "127.0.0.1:%d:80" % PORT, "busybox:1.36", "httpd", "-f", "-p", "80"])
	_step("a throw-away web server is running", run[0] == 0, run[1].strip_edges().left(80))
	if run[0] != 0:
		_docker(["rm", "-f", NAME])
		quit(1)
		return
	OS.delay_msec(1500)
	var d = Docker.new()
	d.probe()
	var row = _row(K, d)
	var target: Dictionary = row.get("check", {})
	_step("its row offers the published address", target == {"host": "127.0.0.1", "port": PORT, "proto": "tcp", "local": true}, target)
	var r = K.port_probe(str(target.get("host", "")), int(target.get("port", 0)), "tcp")
	_step("TCP connects", r["tcp"] == "connected", r)
	_step("HTTP answers, reported on its own", str(r["http"]).begins_with("HTTP "), r)
	_docker(["stop", "-t", "1", NAME])
	OS.delay_msec(800)
	var stopped = _row(K, d)
	_step("a stopped container keeps its configured binding and target", stopped.get("check", {}).get("port") == PORT and stopped.get("status") == "Container offline", stopped)
	var r2 = K.port_probe("127.0.0.1", PORT, "tcp")
	_step("the stopped binding is not reported as connected", r2["tcp"] != "connected", r2)
	_docker(["rm", "-f", NAME])
	var left = _docker(["ps", "-a", "--filter", "name=" + NAME, "-q"])
	_step("the container is gone", left[1].strip_edges() == "", left[1])
	var ok = not _results.has(false)
	print("PORT CHECK DOCKER PASSED" if ok else "PORT CHECK DOCKER FAILED")
	quit(0 if ok else 1)
