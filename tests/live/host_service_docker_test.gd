extends SceneTree
# The high-availability host service (kf-host), live against this machine's
# Docker, with throw-away names only.
#
#   tools\build-server-image.ps1            (once: builds kubefactory-server:dev)
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/live/host_service_docker_test.gd
#
# It runs agent\bin\kf-host.exe in the foreground with its own settings folder,
# container, volume and ports, signs a game client in through the access point,
# then stops the container and later removes it: the client stays connected and
# is told the server is restarting, actions are refused meanwhile, and kf-host
# brings the server back so live state flows again. Everything it made is
# removed by name at the end; nothing else is touched.

const Remote = preload("res://scripts/backend_remote.gd")
const IMAGE = "kubefactory-server:dev"
const INTERVAL = 15

var failures = 0
var name = "kf-host-test-%d" % (randi() % 100000)
var host_pid = -1
var token = ""    # a member: a lambda assigning a local only changes its own copy

func check(ok: bool, what: String, got = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if ok else "  got: " + str(got)))
	if not ok:
		failures += 1

func docker(args: Array) -> String:
	var out = []
	OS.execute("docker", PackedStringArray(args), out, true)
	return "".join(PackedStringArray(out)).strip_edges()

func _initialize() -> void:
	_run.call_deferred()

func wait_for(cond: Callable, seconds: float) -> bool:
	var deadline = Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await create_timer(0.5).timeout
	return cond.call()

func _run() -> void:
	if docker(["image", "inspect", "--format", "{{.Id}}", IMAGE]) == "" or not docker(["image", "inspect", "--format", "{{.Id}}", IMAGE]).begins_with("sha256"):
		print("SKIP the image %s is not built (tools\\build-server-image.ps1)" % IMAGE)
		quit(1)
		return
	var exe = ProjectSettings.globalize_path("res://agent/bin/kf-host.exe")
	if not FileAccess.file_exists(exe):
		print("SKIP agent\\bin\\kf-host.exe is not built")
		quit(1)
		return
	var dir = OS.get_user_data_dir().path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	var internal = 27000 + randi() % 900
	var listen = internal + 1000
	var cfg = {"container": name, "image": IMAGE, "pull": false, "source": ["--demo"], "volume": name + "-data",
		"internal_port": internal, "listen": "127.0.0.1:%d" % listen, "interval_seconds": INTERVAL}
	var f = FileAccess.open(dir.path_join("host.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(cfg))
	f.close()
	OS.set_environment("KF_HOST_DIR", dir)
	host_pid = OS.create_process(exe, PackedStringArray(["run", "--config", dir.path_join("host.json")]))
	check(host_pid > 0, "kf-host starts in the foreground")
	# 1. it creates the server container
	var running = func(): return docker(["ps", "--filter", "name=^" + name + "$", "--filter", "label=io.kubefactory.managed=host", "--format", "{{.State}}"]) == "running"
	check(await wait_for(running, 30), "kf-host creates and starts the server container with its label")
	var read_token = func():
		for line in docker(["exec", name, "cat", "/data/server-new-tokens.txt"]).split("\n"):
			if line.begins_with("operator-1"):
				token = line.get_slice(": ", 1).strip_edges()
		return token != ""
	check(await wait_for(read_token, 30), "the server made its tokens in the data volume")
	# 2. a game client signs in through the access point
	var r = Remote.new()
	r.url = "ws://127.0.0.1:%d" % listen
	r.token = token
	var p = r.probe()
	check(p.get("ok", false), "a client signs in through the access point", p)
	var has_state = func():
		var st = r.fetch()
		return not st.get("failed", false) and st.get("pods", []).size() > 0 and not r.restarting
	check(await wait_for(has_state, 20), "live state flows through the access point")
	# 3. the container stops: the client stays connected and is told
	docker(["stop", "-t", "2", name])
	check(await wait_for(func(): r.fetch(); return r.restarting, 20), "the client is told the server is restarting")
	var st = r.fetch()
	check(not st.get("failed", false) and st.get("pods", []).size() > 0, "the connection stays open and the last state stays on screen", st.get("error", ""))
	check(str(st.get("provider", "")).contains("restarting"), "the status line says the server is restarting", st.get("provider", ""))
	var act = r.run_action({"op": "noop"})
	check(not act.get("ok", true) and str(act.get("msg", "")).contains("restarting"), "an action meanwhile is refused, not lost", act)
	# 4. kf-host starts it again within a check or two, and the client is signed in again
	check(await wait_for(has_state, INTERVAL * 6 + 30), "kf-host restarts the stopped server and live state flows again")
	# 5. the container is removed: kf-host recreates it, the tokens survive in the volume
	docker(["rm", "-f", name])
	check(await wait_for(func(): r.fetch(); return r.restarting, 20), "the client is told again when the container is removed")
	check(await wait_for(has_state, INTERVAL * 6 + 40), "kf-host recreates the removed server and the same token still signs in")
	var status = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("status.json")))
	check(typeof(status) == TYPE_DICTIONARY and status.get("history", []).size() >= 2, "kf-host records what it did in status.json")
	check(not FileAccess.get_file_as_string(dir.path_join("host.log")).contains(token), "the token is not in kf-host's log")
	r.cleanup()
	if failures > 0:
		print("--- kf-host log ---\n" + FileAccess.get_file_as_string(dir.path_join("host.log")))
	_cleanup(dir)
	print("HOST SERVICE PASSED" if failures == 0 else "HOST SERVICE FAILED")
	quit(0 if failures == 0 else 1)

func _cleanup(dir: String) -> void:
	if host_pid > 0:
		OS.kill(host_pid)
	docker(["rm", "-f", name])
	docker(["volume", "rm", name + "-data"])
	for fn in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(fn))
	DirAccess.remove_absolute(dir)
