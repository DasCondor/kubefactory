extends SceneTree

const Docker = preload("res://scripts/backend_docker.gd")
var failures = 0

func check(ok: bool, what: String, detail: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + (" · " + detail if not ok else ""))
	if not ok:
		failures += 1

func docker(args: Array) -> Array:
	var output = []
	var code = OS.execute("docker", PackedStringArray(args), output, true)
	return [code, str(output[0]) if not output.is_empty() else ""]

func _initialize() -> void:
	var name = "kf-storage-edit-" + str(OS.get_process_id())
	var volume = name + "-data"
	var start = docker(["run", "-d", "--name", name, "-v", volume+":/data", "-v", volume+":/readonly:ro", "-v", volume+":/shared", "busybox:1.36", "sh", "-c", "mkdir -p /data/sub; printf 'original\\n' > /data/config.yaml; chmod 640 /data/config.yaml; printf '\\000\\377' > /data/database.db; ln -s /etc /data/escape; ln -s /etc/hostname /data/linkfile; sleep 180"])
	check(start[0] == 0, "disposable Docker fixture starts", start[1])
	if start[0] != 0:
		quit(1)
		return
	var backend = Docker.new()
	var request = {"op":"file_read", "ns":"", "name":name, "container":name, "root":"/data", "path":"config.yaml"}
	var read = backend.run_action(request)
	check(read.get("ok", false), "mounted config is readable", str(read))
	var text = Marshalls.base64_to_utf8(str(read.get("data", {}).get("data", "")))
	var write = request.duplicate()
	write.merge({"op":"file_write", "expected":text.sha256_text(), "text":"# café\nvalue: '$(touch /data/INJECTED)'\n"}, true)
	var saved = backend.run_action(write)
	check(saved.get("ok", false), "real Docker text file saves through stdin", str(saved))
	var after = backend.run_action(request)
	check(Marshalls.base64_to_utf8(str(after.get("data", {}).get("data", ""))) == write["text"], "saved Unicode and shell-like contents stay literal")
	check(docker(["exec", name, "test", "!", "-e", "/data/INJECTED"])[0] == 0, "file contents are never executed")
	if saved.get("ok", false):
		check(docker(["exec", name, "cat", saved["data"]["backup"]])[1] == text, "backup contains the exact original file")
	check(docker(["exec", name, "stat", "-c", "%a", "/data/config.yaml"])[1].strip_edges() == "640", "save preserves file permissions")
	check(not backend.run_action(write).get("ok", false), "stale content token prevents overwriting a newer save")
	write["expected"] = str(write["text"]).sha256_text()
	write["root"] = "/readonly"
	check(not backend.run_action(write).get("ok", false), "read-only mounts refuse edits")
	write["root"] = "/data"
	for path in ["../etc/hostname", "linkfile", "escape/hostname", "database.db"]:
		write["path"] = path
		check(not backend.run_action(write).get("ok", false), "unsafe or binary target is refused: " + path)
	write["path"] = "config.yaml"
	write["text"] = "x".repeat(65537)
	check(not backend.run_action(write).get("ok", false), "oversized text is refused before writing")
	write["text"] = ""
	check(backend.run_action(write).get("ok", false), "an empty file saves successfully")
	request["root"] = "/shared"
	after = backend.run_action(request)
	check(after.get("ok", false) and int(after["data"]["size"]) == 0, "another mount of the shared disk sees the saved file")
	write["expected"] = "".sha256_text()
	write["text"] = "x".repeat(65536)
	check(backend.run_action(write).get("ok", false), "a complete 64 KiB text file saves without blocking the pipe")
	check(docker(["exec", name, "wc", "-c", "/data/config.yaml"])[1].strip_edges().begins_with("65536"), "the maximum-size file is complete")
	var cleanup = docker(["rm", "-f", name])
	var removed = docker(["volume", "rm", volume])
	check(cleanup[0] == 0 and removed[0] == 0, "only the disposable fixture is removed")
	print("DOCKER STORAGE WRITES PASSED" if failures == 0 else "DOCKER STORAGE WRITES FAILED")
	quit(0 if failures == 0 else 1)
