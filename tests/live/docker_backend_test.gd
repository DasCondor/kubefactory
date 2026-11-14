extends SceneTree
# The Docker backend against a real container on the local engine.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/live/docker_backend_test.gd
#
# It starts one throw-away container (kf-live-test, busybox) with one throw-away
# volume, exercises logs, storage inspection and usage figures on it through the
# game's own Docker backend, and removes both again. Nothing else on the engine
# is touched.

const NAME = "kf-live-test"
const VOL = "kf-live-test-vol"

var _results = []

func _docker(args: Array) -> Array:
	var out = []
	var code = OS.execute("docker", PackedStringArray(args), out, true)
	return [code, str(out[0]) if out.size() > 0 else ""]

func _step(name: String, ok: bool, note = "") -> void:
	_results.append(ok)
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, str(note).left(190)])

func _init() -> void:
	var Docker = load("res://scripts/backend_docker.gd")
	_docker(["rm", "-f", NAME])
	_docker(["volume", "rm", "-f", VOL])
	var run = _docker(["run", "-d", "--name", NAME, "-v", VOL + ":/data", "busybox:1.36", "sh", "-c",
		"mkdir -p /data/sub && echo hello-from-a-real-volume > /data/hello.txt && echo nested > /data/sub/deep.txt && ln -s /etc /data/escape && ln -s /etc/hostname /data/linkfile && i=0; while true; do i=$((i+1)); echo line $i from a real container; dd if=/dev/zero of=/data/churn bs=4096 count=64 2>/dev/null; sleep 1; done"])
	_step("a throw-away container is running on the local engine", run[0] == 0, run[1].strip_edges().left(12))
	if run[0] != 0:
		quit(1)
		return
	OS.delay_msec(4000)
	var d = Docker.new()
	var pr = d.probe()
	_step("the backend reaches the engine", pr.ok, pr.get("msg", ""))
	var st = d.fetch()
	var mine = null
	for p in st.get("pods", []):
		if p["name"] == NAME:
			mine = p
	_step("the container is listed as a machine", mine != null and mine["status"] == "Running", mine["status"] if mine != null else "not listed")
	var logs = d.run_action({"op": "logs", "ns": mine["ns"] if mine != null else "", "name": NAME, "container": NAME, "tail": 20})
	_step("logs: real lines from the container", str(logs.get("text", "")).contains("from a real container"), str(logs.get("text", logs.get("msg", ""))).strip_edges().right(60))
	# storage inspection
	var mr = d.run_action({"op": "file_mounts", "ns": "", "name": NAME})
	var mounts = mr.get("data", {}).get("mounts", [])
	var has_data = false
	for m in mounts:
		has_data = has_data or m["path"] == "/data"
	_step("storage: the volume is listed", mr["ok"] and has_data, mounts.map(func(m): return m["path"]))
	var base = {"ns": "", "name": NAME, "container": NAME, "root": "/data"}
	var ask = func(op: String, path: String) -> Dictionary:
		var a = base.duplicate()
		a["op"] = op
		a["path"] = path
		return d.run_action(a)
	var ls = ask.call("file_list", "")
	var names = ls.get("data", {}).get("entries", []).map(func(e): return e["name"])
	names.sort()
	_step("storage: a real folder listing", ls["ok"] and "hello.txt" in names and "sub" in names and "linkfile" in names, names)
	var rd = ask.call("file_read", "hello.txt")
	var body = Marshalls.base64_to_utf8(str(rd.get("data", {}).get("data", ""))) if rd["ok"] else ""
	_step("storage: a real file's contents", body.strip_edges() == "hello-from-a-real-volume", body.strip_edges() if rd["ok"] else rd["msg"])
	rd = ask.call("file_read", "sub/deep.txt")
	_step("storage: a file in a sub-folder", rd["ok"] and Marshalls.base64_to_utf8(str(rd["data"]["data"])).strip_edges() == "nested")
	var r = ask.call("file_list", "../etc")
	_step("storage: leaving the volume with .. is refused", not r["ok"] and r["kind"] == "invalid", r["msg"])
	r = ask.call("file_read", "linkfile")
	_step("storage: a symlinked file that points outside the volume is not read", not r["ok"], "%s: %s" % [r["kind"], r["msg"]])
	r = ask.call("file_read", "escape/passwd")
	_step("storage: a file reached through a symlinked folder is not read", not r["ok"], "%s: %s" % [r["kind"], r["msg"]])
	r = ask.call("file_list", "escape")
	var leaked = r["ok"] and r["data"]["entries"].any(func(e): return e["name"] in ["passwd", "hostname", "hosts"])
	_step("storage: a symlinked folder is not listed as if it were inside the volume", not leaked, "%s: %s" % [r.get("kind", ""), r.get("msg", "") if not r["ok"] else str(r["data"]["entries"].size()) + " entries"])
	var a2 = base.duplicate()
	a2["op"] = "file_list"
	a2["root"] = "/etc"
	a2["path"] = ""
	r = d.run_action(a2)
	_step("storage: a path that is not a mount is refused", not r["ok"] and r["kind"] == "invalid", r["msg"])
	# usage figures: two readings, so the totals become rates
	var MS = load("res://scripts/machine_screens.gd")
	var u = {}
	var m1 = d.run_action({"op": "pod_metrics", "ns": "", "name": NAME})
	_step("usage: the engine reports CPU, memory, network and disk for the container", m1["ok"] and m1["data"].has("net_rx_bytes") and m1["data"].has("disk_write_bytes") and float(m1["data"]["mem_bytes"]) > 0.0, m1["data"] if m1["ok"] else m1["msg"])
	u = MS.add_usage(u, m1, 0.0)
	OS.delay_msec(5000)
	var m2 = d.run_action({"op": "pod_metrics", "ns": "", "name": NAME})
	u = MS.add_usage(u, m2, 7.0)
	var tiles = MS.usage_tiles(u)
	_step("usage: four tiles with real values", tiles.all(func(t): return not (str(t["value"]) in ["unavailable", "reading...", "measuring..."])), tiles.map(func(t): return "%s %s" % [t["title"], t["value"]]))
	_step("usage: the disk being written to shows a rate above zero", float(u["disk"][-1]) > 0.0 if not u["disk"].is_empty() else false, tiles[3]["note"])
	var gone = d.run_action({"op": "pod_metrics", "ns": "", "name": "kf-no-such-container"})
	_step("usage: a container that is not there gives no figures, and says so", not gone["ok"], gone["msg"])
	_docker(["stop", "-t", "1", NAME])
	var stopped = d.run_action({"op": "pod_metrics", "ns": "", "name": NAME})
	_step("usage: a stopped container gives no figures rather than zeros", not stopped["ok"] and stopped["kind"] == "unsupported", stopped["msg"])
	_docker(["rm", "-f", NAME])
	_docker(["volume", "rm", "-f", VOL])
	var left = _docker(["ps", "-a", "--filter", "name=" + NAME, "--format", "{{.Names}}"])
	_step("the container and its volume are removed again", left[1].strip_edges() == "")
	var passed = _results.count(true)
	print("\n%d of %d steps passed against a real Docker engine" % [passed, _results.size()])
	quit(0 if passed == _results.size() else 1)
