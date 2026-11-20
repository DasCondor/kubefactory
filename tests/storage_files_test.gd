extends SceneTree

const Demo = preload("res://scripts/backend_demo.gd")
const Storage = preload("res://scripts/storage_files.gd")
const Editor = preload("res://scripts/text_editor.gd")
const K = preload("res://scripts/kutil.gd")
var failures = 0

func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var demo = Demo.new("docker-media-gatherer")
	var pods = demo.fetch()["pods"]
	var radarr = pods.filter(func(p): return p["wname"] == "radarr")[0]
	var a = {"op": "file_read", "ns": radarr["ns"], "name": radarr["name"], "container": radarr["containers"][0]["name"], "root": "/config", "path": "demo-settings.yaml"}
	var original = demo.run_action(a)
	check(original["ok"], "app configuration can be opened from its mounted volume")
	var text = Marshalls.base64_to_utf8(original["data"]["data"])
	var write = a.duplicate()
	write.merge({"op": "file_write", "expected": text.sha256_text(), "text": "demo: true\nlog_level: debug\n"}, true)
	var saved = demo.run_action(write)
	check(saved["ok"] and saved["data"].has("backup"), "save keeps a backup")
	var again = demo.run_action(a)
	check(again["ok"] and Marshalls.base64_to_utf8(again["data"]["data"]) == write["text"], "reopening a file returns its saved edits")
	check(not demo.run_action(write)["ok"], "a stale editor cannot overwrite newer contents")
	var backup = a.duplicate()
	backup["path"] = saved["data"]["backup"]
	check(Marshalls.base64_to_utf8(demo.run_action(backup)["data"]["data"]) == text, "the backup preserves the original contents")
	write["expected"] = str(write["text"]).sha256_text()
	write["text"] = ""
	check(demo.run_action(write)["ok"] and demo.run_action(a)["data"]["size"] == 0, "empty text files can be saved and reopened")
	write["path"] = "../escape.yaml"
	check(not demo.run_action(write)["ok"], "writes cannot leave their mounted volume")
	write["path"] = "radarr.db"
	check(not demo.run_action(write)["ok"], "binary databases are never edited")
	var downloader = pods.filter(func(p): return p["wname"] == "downloader")[0]
	var sync = pods.filter(func(p): return p["wname"] == "syncthing")[0]
	var shared = {"op":"file_read", "ns":downloader["ns"], "name":downloader["name"], "container":downloader["containers"][0]["name"], "root":"/downloads", "path":"README.txt"}
	var shared_text = Marshalls.base64_to_utf8(demo.run_action(shared)["data"]["data"])
	shared.merge({"op":"file_write", "text":"shared notes\n", "expected":shared_text.sha256_text()}, true)
	check(demo.run_action(shared)["ok"], "a shared data-container text file can be edited")
	shared.merge({"op":"file_read", "ns":sync["ns"], "name":sync["name"], "container":sync["containers"][0]["name"], "root":"/var/syncthing/outbox"}, true)
	var shared_read = demo.run_action(shared)
	check(shared_read["ok"] and Marshalls.base64_to_utf8(shared_read["data"]["data"]) == "shared notes\n", "another app sees the same shared-volume edit through its own mount")
	check(Storage.text_problem(PackedByteArray([0])) != "" and Storage.text_problem("a".repeat(65537).to_utf8_buffer()) != "", "binary and oversized editor buffers are rejected")
	check(Storage.text_problem("café\n".to_utf8_buffer()) == "" and Storage.text_problem(PackedByteArray()) == "", "UTF-8 and empty text are allowed")
	check(K.tier_of({"op":"file_write"}, {}) == 3, "saving is a guarded MK.3 action")
	var editor = Editor.new()
	root.add_child(editor)
	editor.setup({"text":"old", "path":"config.yaml", "remote_save":true})
	var requests = []
	editor.save_requested.connect(func(t): requests.append(t))
	editor.ed.text = "edited"
	check(not editor.save() and editor.modified() and requests == ["edited"], "a pending remote save does not mark edits saved")
	editor.save_result(false, "refused")
	check(editor.modified() and editor.ed.text == "edited" and not editor._save_btn.disabled, "a failed save keeps edits and allows retry")
	editor.save()
	editor.save_result(true, "saved")
	check(not editor.modified(), "only a successful response clears modified status")
	var closed = []
	editor.closed.connect(func(): closed.append(true))
	editor.ed.text = "another edit"
	editor.save_and_close()
	check(closed.is_empty(), "save and close waits for backend confirmation")
	editor.save_result(true, "saved")
	check(closed.size() == 1, "save and close finishes after successful write")
	editor.queue_free()
	print("STORAGE FILES PASSED" if failures == 0 else "STORAGE FILES FAILED")
	quit(0 if failures == 0 else 1)
