extends SceneTree
# Clean slate (scripts/clean_slate.gd): the commands it hands over match the
# install scripts, the plan mirrors what is on the machine, and checking this
# machine only reads.
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/clean_slate_test.gd

const CS = preload("res://scripts/clean_slate.gd")
var failures = 0

func check(ok: bool, what: String, got = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if ok else "  got: " + str(got)))
	if not ok:
		failures += 1

func _initialize() -> void:
	var ps = CS.script_text("windows")
	var sh = CS.script_text("linux")
	check(ps.contains("[ValidateSet(\"docker\", \"docker-desktop\", \"kind\", \"k3s\")]"), "the Windows script offers every target")
	check(sh.contains("docker|k3s|kind)"), "the Linux script offers its targets")
	check(ps.contains("does not elevate itself") and sh.contains("does not elevate itself"), "both scripts say they never elevate")
	for os in ["windows", "linux"]:
		for t in CS.TARGETS:
			if not CS.available(t["id"], os):
				continue
			for host in [false, true]:
				var c = CS.command(os, t["id"], host, "Ubuntu")
				var words = Array(c.split(" ", false))
				var flag = "-Target" if os == "windows" else "--target"
				var i = words.find(flag)
				check(i >= 0 and words[i + 1] == t["id"], "%s %s: the command names the target" % [os, t["id"]], c)
				for w in words:
					if w.begins_with("-") and not w in ["-ExecutionPolicy", "-File"]:
						var body = ps if os == "windows" else sh
						var known = body.contains("[switch]$" + w.trim_prefix("-")) or body.contains("[string]$" + w.trim_prefix("-")) or body.contains("$" + w.trim_prefix("-") + " =") or body.contains("    " + w + ")")
						check(known, "%s: the script knows %s" % [os, w], c)
				if os == "windows" and t["id"] == "k3s":
					check(not c.contains("-HostService"), "k3s on Windows never asks for the host service", c)
					check(c.contains("-WslDistro Ubuntu"), "k3s on Windows names the WSL distribution", c)
				if os == "linux":
					check(c.begins_with("sudo sh install-kubefactory.sh"), "the Linux command runs the script with sudo", c)
				else:
					check(c.begins_with("powershell -ExecutionPolicy Bypass -File .\\install-kubefactory.ps1"), "the Windows command runs only this script past the execution policy", c)
	check(not CS.available("docker-desktop", "linux"), "Docker Desktop Kubernetes is offered on Windows only")
	check(CS.plan_command("windows", "kind").contains("-Plan") and CS.plan_command("linux", "kind").contains("--plan"), "the plan commands change nothing")
	check(CS.download_command("windows").contains("releases/latest/download/install-kubefactory.ps1"), "the download command uses the release", CS.download_command("windows"))

	# the plan, with and without a checked machine
	var unchecked = CS.steps("kind", {}, false, "windows")
	check(unchecked.size() == 6 and unchecked.all(func(s): return s[1] == null), "without a check every step is 'if missing'", unchecked)
	var det = {"checked": true, "os": "windows", "wsl": true, "docker": true, "engine": "29.0.0", "kubectl": true, "kind": true,
		"kind_clusters": ["other"], "docker_desktop_k8s": false, "distros": ["Ubuntu"], "k3s": false}
	var kind = CS.steps("kind", det, true, "windows")
	check(kind[0] == ["WSL 2", true] and kind[2] == ["Docker engine answering", true], "done steps are marked done", kind)
	check(kind[5] == ["kind cluster kubefactory", false], "a missing kind cluster is to do", kind)
	check(kind[-1][0] == "KubeFactory host service", "the host service step is added when chosen", kind)
	check(CS.steps("docker", det, false, "linux").all(func(s): return s[1] == null), "a Windows check says nothing about a Linux plan")
	check(CS.steps("k3s", det, true, "windows").all(func(s): return s[0] != "KubeFactory host service"), "k3s on Windows has no host service step")
	check(CS.ready_hint("docker", det).contains("Docker engine"), "a running engine is ready to connect")
	check(CS.ready_hint("kind", det) == "", "a kind cluster with another name is not ready")
	det["kind_clusters"] = ["kubefactory"]
	check(CS.ready_hint("kind", det).contains("kind-kubefactory"), "the kind cluster is ready to connect")
	var facts = CS.facts(det)
	check(facts.size() == 6 and facts[1][2].contains("29.0.0"), "the machine list shows the engine version", facts)

	# live, read only: this machine
	var t0 = Time.get_ticks_msec()
	var live = CS.detect()
	check(live.get("checked", false) and live.has("engine") and live.has("kind_clusters"), "checking this machine works", live)
	print("  this machine: docker=%s engine=%s kubectl=%s kind=%s (%d ms)" % [live.get("docker"), live.get("engine"), live.get("kubectl"), live.get("kind"), Time.get_ticks_msec() - t0])
	print("CLEAN SLATE PASSED" if failures == 0 else "CLEAN SLATE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
