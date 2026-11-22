extends RefCounted
# Clean slate (docs/CLEAN_SLATE.md): set up a Docker host or a Kubernetes cluster
# from nothing, together with the player. KubeFactory looks at this machine (read
# only), the player picks what to build, and KubeFactory hands over its install
# script (setup/install-kubefactory.ps1 or .sh) with the exact command to run as
# administrator. KubeFactory never runs anything with admin rights itself.

const REPO = "DasCondor/kubefactory"
const RELEASES = "https://github.com/DasCondor/kubefactory/releases/latest"
const DOWNLOAD = "https://github.com/DasCondor/kubefactory/releases/latest/download/"
const DOCKER_DIR = "C:/Program Files/Docker/Docker/resources/bin/"

const TARGETS = [
	{"id": "docker", "name": "Docker host", "os": ["windows", "linux"],
		"desc": "Docker on this machine. KubeFactory shows its containers, networks and volumes. Windows: WSL 2 and Docker Desktop. Linux: Docker Engine."},
	{"id": "docker-desktop", "name": "Docker Desktop Kubernetes", "os": ["windows"],
		"desc": "A one-node Kubernetes cluster built into Docker Desktop. You switch it on in Docker Desktop's settings; the script shows where and waits for it."},
	{"id": "kind", "name": "kind cluster", "os": ["windows", "linux"],
		"desc": "Kubernetes in Docker containers, made by kind. Quick to create and to throw away. Needs a Docker host, which the script sets up first."},
	{"id": "k3s", "name": "k3s cluster", "os": ["windows", "linux"],
		"desc": "A small, complete Kubernetes. Linux: installed on this machine. Windows: inside a WSL distribution that runs systemd."},
]

static func platform() -> String:
	if OS.has_feature("web"):
		return "web"
	match OS.get_name():
		"Windows":
			return "windows"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return "linux"
	return "other"

static func target(id: String) -> Dictionary:
	for t in TARGETS:
		if t["id"] == id:
			return t
	return TARGETS[0]

static func available(id: String, os: String) -> bool:
	return os in target(id)["os"]

static func script_file(os: String) -> String:
	return "install-kubefactory.ps1" if os == "windows" else "install-kubefactory.sh"

static func script_text(os: String) -> String:
	return FileAccess.get_file_as_string("res://setup/" + script_file(os))

# the command the player runs, in the folder that holds the script
static func command(os: String, id: String, host_service: bool, distro: String = "") -> String:
	if os == "windows":
		# Bypass applies to this one run only: Windows refuses unsigned scripts by default
		var c = "powershell -ExecutionPolicy Bypass -File .\\install-kubefactory.ps1 -Target " + id
		if id == "k3s" and distro != "":
			c += " -WslDistro " + distro
		if host_service and id != "k3s":
			c += " -HostService"
		return c
	var s = "sudo sh install-kubefactory.sh --target " + id
	if host_service:
		s += " --host-service"
	return s

static func plan_command(os: String, id: String) -> String:
	if os == "windows":
		return "powershell -ExecutionPolicy Bypass -File .\\install-kubefactory.ps1 -Plan -Target " + id
	return "sh install-kubefactory.sh --plan --target " + id

static func download_command(os: String) -> String:
	if os == "windows":
		return "Invoke-WebRequest %s%s -OutFile %s" % [DOWNLOAD, script_file(os), script_file(os)]
	return "curl -fsSLO " + DOWNLOAD + script_file(os)

static func host_service_allowed(os: String, id: String) -> bool:
	return not (os == "windows" and id == "k3s")

# ----- what is on this machine: read only, a few quick commands; run it off the main thread

static func _run(exe: String, args: Array) -> Dictionary:
	var out = []
	var code = OS.execute(exe, PackedStringArray(args), out, false)
	return {"code": code, "out": "".join(PackedStringArray(out)).replace(char(0), "").strip_edges()}

static func _docker_exe() -> String:
	if platform() == "windows" and FileAccess.file_exists(DOCKER_DIR + "docker.exe") and _run("docker", ["--version"])["code"] != 0:
		return DOCKER_DIR + "docker.exe"
	return "docker"

static func _kubectl_exe() -> String:
	if platform() == "windows" and FileAccess.file_exists(DOCKER_DIR + "kubectl.exe") and _run("kubectl", ["version", "--client"])["code"] != 0:
		return DOCKER_DIR + "kubectl.exe"
	return "kubectl"

static func detect() -> Dictionary:
	var os = platform()
	var d = {"os": os, "checked": false}
	if os != "windows" and os != "linux":
		return d
	d["checked"] = true
	var dk = _docker_exe()
	d["docker"] = _run(dk, ["--version"])["code"] == 0
	var eng = _run(dk, ["version", "--format", "{{.Server.Version}}"]) if d["docker"] else {"code": 1}
	d["engine"] = eng["out"] if eng["code"] == 0 else ""
	var kc = _kubectl_exe()
	d["kubectl"] = _run(kc, ["version", "--client"])["code"] == 0
	d["kind"] = _run("kind", ["version"])["code"] == 0
	d["kind_clusters"] = []
	if d["kind"]:
		var kl = _run("kind", ["get", "clusters"])
		if kl["code"] == 0:
			d["kind_clusters"] = Array(kl["out"].split("\n", false)).filter(func(x): return not x.begins_with("No kind"))
	d["docker_desktop_k8s"] = false
	if os == "windows" and d["kubectl"]:
		var r = _run(kc, ["--context", "docker-desktop", "--request-timeout=4s", "get", "--raw", "/readyz"])
		d["docker_desktop_k8s"] = r["code"] == 0 and r["out"] == "ok"
	if os == "windows":
		# wsl.exe prints UTF-16 unless asked for UTF-8; Godot would cut the text at the first NUL
		OS.set_environment("WSL_UTF8", "1")
		d["wsl"] = _run("wsl", ["--status"])["code"] == 0
		d["distros"] = []
		if d["wsl"]:
			var l = _run("wsl", ["-l", "-q"])
			if l["code"] == 0:
				for line in l["out"].split("\n", false):
					var n = line.strip_edges()
					if n != "" and not n.begins_with("docker-desktop"):
						d["distros"].append(n)
		d["k3s"] = FileAccess.file_exists(OS.get_environment("USERPROFILE").path_join(".kube/kubefactory-k3s.yaml"))
	else:
		d["k3s"] = _run("k3s", ["--version"])["code"] == 0
	return d

# One line per check, for the "this machine" list: [label, ok(bool), detail]
static func facts(d: Dictionary) -> Array:
	if not d.get("checked", false):
		return []
	var rows = []
	if d["os"] == "windows":
		rows.append(["WSL 2", d.get("wsl", false), "" if d.get("wsl", false) else "not installed"])
	rows.append(["Docker", d["docker"], "not installed" if not d["docker"] else ("engine %s answering" % d["engine"] if d["engine"] != "" else "installed, engine not answering")])
	rows.append(["kubectl", d["kubectl"], "" if d["kubectl"] else "not installed"])
	rows.append(["kind", d["kind"], ", ".join(PackedStringArray(d["kind_clusters"])) if d["kind_clusters"].size() > 0 else ("no clusters" if d["kind"] else "not installed")])
	if d["os"] == "windows":
		rows.append(["Docker Desktop Kubernetes", d["docker_desktop_k8s"], "running" if d["docker_desktop_k8s"] else "off or not ready"])
		rows.append(["k3s (in WSL)", d["k3s"], "kubeconfig saved" if d["k3s"] else "not set up by Clean slate"])
	else:
		rows.append(["k3s", d["k3s"], "" if d["k3s"] else "not installed"])
	return rows

# What the script will do here, mirroring its plan: [step, done] where done is
# true, false, or null when this machine was not checked.
static func steps(id: String, d: Dictionary, host_service: bool, os: String) -> Array:
	var c = d.get("checked", false) and d.get("os", "") == os
	var v = func(key):
		if not c:
			return null
		var x = d.get(key, false)
		return x != "" if x is String else bool(x)
	var out = []
	var need_docker = id != "k3s" or (host_service and os == "linux")
	if os == "windows":
		out.append(["WSL 2", v.call("wsl")])
	if need_docker:
		out.append(["Docker Desktop" if os == "windows" else "Docker Engine", v.call("docker")])
		out.append(["Docker engine answering", v.call("engine")])
	match id:
		"docker-desktop":
			out.append(["Docker Desktop's Kubernetes (you switch it on; the script waits)", v.call("docker_desktop_k8s")])
		"kind":
			out.append(["kubectl", v.call("kubectl")])
			out.append(["kind", v.call("kind")])
			out.append(["kind cluster kubefactory", ("kubefactory" in d.get("kind_clusters", [])) if c else null])
		"k3s":
			if os == "windows":
				out.append(["a WSL distribution with systemd (you turn it on)", (d.get("distros", []).size() > 0) if c else null])
				out.append(["k3s in WSL, kubeconfig saved for Windows", v.call("k3s")])
			else:
				out.append(["k3s", v.call("k3s")])
				out.append(["kubeconfig for you (~/.kube/kubefactory-k3s.yaml)", null])
	if host_service and host_service_allowed(os, id):
		out.append(["KubeFactory host service", null])
	return out

# Ready to connect? Says what to pick in Switch cluster, or "".
static func ready_hint(id: String, d: Dictionary) -> String:
	if not d.get("checked", false):
		return ""
	match id:
		"docker":
			return "Docker is answering. Pick the Docker engine in Switch cluster." if d["engine"] != "" else ""
		"docker-desktop":
			return "Docker Desktop's Kubernetes is running. Pick the docker-desktop context in Switch cluster." if d["docker_desktop_k8s"] else ""
		"kind":
			return "The kind cluster is there. Pick kind-kubefactory in Switch cluster." if "kubefactory" in d["kind_clusters"] else ""
		"k3s":
			return "k3s is set up. Add ~/.kube/kubefactory-k3s.yaml with Add or manage kubeconfigs, then pick kubefactory-k3s." if d["k3s"] else ""
	return ""

# Save the script for the player: to Downloads on a desktop, as a browser download on the web.
static func save(os: String) -> Dictionary:
	var text = script_text(os)
	if text == "":
		return {"ok": false, "msg": "The install script is not in this build. Download it from the release page instead."}
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(text.to_utf8_buffer(), script_file(os), "text/plain")
		return {"ok": true, "msg": "Your browser is saving %s." % script_file(os), "path": ""}
	var dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		dir = OS.get_user_data_dir()
	var path = dir.path_join(script_file(os))
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "msg": "Could not write %s." % path}
	f.store_string(text)
	f.close()
	return {"ok": true, "msg": "Saved " + script_file(os), "path": path, "dir": dir}
