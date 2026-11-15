extends SceneTree
# Leaving a KubeFactory server connection while a state fetch is running: the
# old backend's cleanup (close) and its fetch (poll) must not touch the
# WebSocket at the same time. Before the fix this corrupted the heap
# (Windows 0xc0000374) when switching from a server to anything else.
#   KF_TEST_SERVER=ws://127.0.0.1:7670 KF_REMOTE_TOKEN=<viewer token> \
#     engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/remote_switch_test.gd -- --sim=helmsman-sim
# needs a server, e.g.: KubeFactory --headless -- --server=7670 --demo --read-only

const ROUNDS = 30

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(220)])
	if not ok:
		_fails.append(what)

func _wait_for(game, label: String, ms: int) -> bool:
	var deadline = Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if game.cluster.backend != null and game.cluster.backend.label == label:
			return true
		await create_timer(0.05).timeout
	return false

func _run() -> void:
	var url = OS.get_environment("KF_TEST_SERVER")
	var token = OS.get_environment("KF_REMOTE_TOKEN")
	if url == "" or token == "":
		print("set KF_TEST_SERVER and KF_REMOTE_TOKEN")
		quit(2)
		return
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	_check("starts in the simulation", await _wait_for(game, "simulation", 25000))
	var rng = RandomNumberGenerator.new()
	rng.seed = 7
	var connected = 0
	for i in ROUNDS:
		game.cluster.remote_token = token
		game.cluster.connect_target({"source": "remote", "context": url, "provider": "KubeFactory server"})
		if await _wait_for(game, "remote", 10000):
			connected += 1
		# leave at a random moment, often while a fetch is in flight
		await create_timer(rng.randf_range(0.5, 2.5)).timeout
		game.cluster.connect_target({"source": "simulation", "context": "helmsman-sim", "provider": "simulation"})
		await _wait_for(game, "simulation", 10000)
		await create_timer(rng.randf_range(0.0, 0.3)).timeout
	_check("connected to the server every round", connected == ROUNDS, "%d of %d" % [connected, ROUNDS])
	_check("still running after %d switches away from a server" % ROUNDS, true)
	print("REMOTE SWITCH PASSED" if _fails.is_empty() else "REMOTE SWITCH FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
