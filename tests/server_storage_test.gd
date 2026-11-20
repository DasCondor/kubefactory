extends SceneTree

const Cluster = preload("res://scripts/cluster.gd")
const Demo = preload("res://scripts/backend_demo.gd")
var failures = 0

class CaptureServer extends "res://scripts/server.gd":
	var messages = []
	func _send(_id: int, message: Dictionary) -> void:
		messages.append(message)

func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _initialize() -> void:
	var cluster = Cluster.new()
	cluster.backend = Demo.new("docker-media-gatherer")
	cluster.state = cluster.backend.fetch()
	cluster.log_dir = ProjectSettings.globalize_path("res://tests")
	var server = CaptureServer.new()
	server.cluster = cluster
	server._clients[1] = {"tier":1, "role":"viewer", "name":"test", "authed":true}
	var action = {"op":"file_write", "ns":"media-host", "name":"radarr", "root":"/config", "path":"config.yaml", "text":"PRIVATE_CONTENT", "expected":"private-hash"}
	server._act(1, {"id":1, "action":action})
	check(not server.messages.back()["result"]["ok"], "the server rejects viewer file writes")
	server._clients[1]["tier"] = 4
	cluster.read_only = true
	server._act(1, {"id":2, "action":action})
	check(not server.messages.back()["result"]["ok"] and "read-only" in server.messages.back()["result"]["msg"], "server read-only mode overrides operator write access")
	cluster.read_only = false
	cluster.state["policy"] = {"default_max_tier":5, "protected_namespaces":["media-host"], "protected_max_tier":1}
	server._act(1, {"id":3, "action":action})
	check(not server.messages.back()["result"]["ok"], "protected namespace rules also block remote file writes")
	server._on_action_finished(action, {"ok":true})
	var feed = server.messages.back()
	check(feed["type"] == "feed" and not feed["action"].has("text") and not feed["action"].has("expected"), "shared action feeds contain no file contents or content hashes")
	check("PRIVATE_CONTENT" not in Cluster.describe(action) and "private-hash" not in Cluster.describe(action), "file audit descriptions contain only the target path")
	server.free()
	cluster.free()
	print("SERVER STORAGE PASSED" if failures == 0 else "SERVER STORAGE FAILED")
	quit(0 if failures == 0 else 1)
