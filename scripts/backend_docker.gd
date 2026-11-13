extends RefCounted
# Plain Docker engine as a one-node "cluster": every container is a machine,
# compose projects become namespaces and compose services become workloads.

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")

var label = "docker"
var poll_interval = 2.5
var caps = {"scale": false, "delete_pod": true, "restart": true, "delete_workload": false,
	"create": true, "cordon": false, "drain": false, "logs": true}
var context = ""
var log_cfg = {}
var providers = [{"id": "kube", "name": "Docker Engine", "ready": true, "note": "docker logs"}]
var _host = {}

func _run(args: Array, with_err: bool = true) -> Dictionary:
	var out = []
	var code = OS.execute("docker", PackedStringArray(args), out, with_err)
	return {"code": code, "out": (str(out[0]) if out.size() > 0 else "")}

func probe() -> Dictionary:
	var r = _run(["info", "--format", "{{json .}}"], false)
	if r.code != 0:
		return {"ok": false, "msg": "Docker engine is not running"}
	var d = JSON.parse_string(r.out)
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "msg": "could not read docker info"}
	_host = d
	context = str(d.get("Name", "docker"))
	return {"ok": true, "msg": context}

func fetch() -> Dictionary:
	var r = _run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], false)
	if r.code != 0:
		return {"source": label, "context": context, "error": "docker ps failed - is the engine running?", "failed": true}
	var st = {"source": label, "context": context, "provider": "Docker Engine", "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	var node_name = context if context != "" else "docker"
	st.nodes.append({"name": node_name, "ready": true, "cordoned": false, "roles": "docker-engine", "zone": "", "itype": str(_host.get("OperatingSystem", "")),
		"version": str(_host.get("ServerVersion", "")), "cpu": float(_host.get("NCPU", 0)),
		"mem": float(_host.get("MemTotal", 0)), "cpu_req": 0.0, "mem_req": 0.0, "created": 0.0})
	var wl = {}
	for line in r.out.split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var c = JSON.parse_string(line)
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var labels = {}
		for kv in str(c.get("Labels", "")).split(","):
			var i = kv.find("=")
			if i > 0:
				labels[kv.substr(0, i)] = kv.substr(i + 1)
		var ns = str(labels.get("com.docker.compose.project", "default"))
		var svc = str(labels.get("com.docker.compose.service", ""))
		var state = str(c.get("State", ""))
		var status_text = str(c.get("Status", ""))
		var status = state.capitalize()
		var health = "warn"
		if state == "running":
			status = "Running"
			health = "warn" if status_text.contains("unhealthy") else "ok"
		elif state == "exited":
			health = "done" if status_text.begins_with("Exited (0)") else "bad"
			status = "Completed" if health == "done" else "Error"
		elif state == "dead":
			health = "bad"
		var nm = str(c.get("Names", ""))
		st.pods.append({"uid": str(c.get("ID", nm)), "name": nm, "ns": ns, "node": node_name,
			"status": status, "ready": state == "running", "health": health, "restarts": 0,
			"wkind": "Compose" if svc != "" else "Pod", "wname": svc,
			"ip": str(c.get("Ports", "")), "created": 0.0, "labels": labels,
			"containers": [{"name": nm, "image": str(c.get("Image", "")), "state": "running" if state == "running" else "terminated",
				"reason": status_text, "ready": state == "running", "restarts": 0}]})
		if svc != "":
			var key = ns + "/" + svc
			if not wl.has(key):
				wl[key] = {"kind": "Compose", "name": svc, "ns": ns, "replicas": 0, "ready": 0, "image": str(c.get("Image", ""))}
			wl[key]["replicas"] += 1
			if state == "running":
				wl[key]["ready"] += 1
	st.workloads = wl.values()
	return st

func run_action(a: Dictionary) -> Dictionary:
	var special = _app_action(a)
	if not special.is_empty():
		return special
	var r
	match a["op"]:
		"delete_pod":
			r = _run(["rm", "-f", a["name"]])
		"restart":
			if a.get("pod", "") == "":
				return {"ok": false, "msg": "restart a container from its own panel"}
			r = _run(["restart", a["pod"]])
		"create":
			r = _run(["run", "-d", "--name", a["name"], a["image"]])
		"logs":
			r = _run(["logs", "--tail", str(int(a.get("tail", 150))), a["name"]])
			return {"ok": r.code == 0, "msg": "", "text": r.out if r.out.strip_edges() != "" else "(no log output)"}
		"events":
			r = _run(["inspect", "--format", "Status: {{.State.Status}}\nExit code: {{.State.ExitCode}}\nError: {{.State.Error}}\nOOM killed: {{.State.OOMKilled}}\nStarted: {{.State.StartedAt}}\nFinished: {{.State.FinishedAt}}\nRestart count: {{.RestartCount}}", a["name"]])
			return {"ok": r.code == 0, "msg": "", "text": r.out}
		_:
			return {"ok": false, "msg": "not supported for Docker"}
	var lines = r.out.strip_edges().split("\n")
	return {"ok": r.code == 0, "msg": lines[lines.size() - 1] if r.code != 0 else "docker: %s %s" % [a["op"], a.get("pod", a["name"]) if a["op"] == "restart" else a["name"]]}

# ---- Porter / Portainer: full app setups as Compose projects, template runs

func _env_file(project: String) -> String:
	var dir = OS.get_user_data_dir().path_join("app-env")
	DirAccess.make_dir_recursive_absolute(dir)
	var path = dir.path_join(project + ".env")
	if not FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.WRITE)
		f.store_line("DB_PASSWORD=" + Apps.random_password())
		f.close()
	return path

func _tail(r: Dictionary) -> String:
	var lines = r.out.strip_edges().split("\n")
	return lines[lines.size() - 1]

func _app_action(a: Dictionary) -> Dictionary:
	match a["op"]:
		"apply_app":
			var app = Apps.find(a["id"])
			if app == null:
				return {"ok": false, "msg": "unknown app"}
			var env = _env_file(a["ns"])
			var r = _run(["compose", "-p", a["ns"], "--env-file", env, "-f", Apps.file_for(a["id"], "compose"), "up", "-d"])
			var note = ("  Password is in " + env) if app["secret"] else ""
			return {"ok": r.code == 0, "msg": ("%s is up as Compose project %s.%s" % [app["name"], a["ns"], note]) if r.code == 0 else _tail(r)}
		"remove_app":
			var r = _run(["compose", "-p", a["ns"], "--env-file", _env_file(a["ns"]), "-f", Apps.file_for(a["id"], "compose"), "down"])
			return {"ok": r.code == 0, "msg": ("Compose project %s removed (volumes kept)" % a["ns"]) if r.code == 0 else _tail(r)}
		"portainer_install":
			var r = _run(["run", "-d", "-p", "9443:9443", "--name", "portainer", "--restart=always",
				"-v", "/var/run/docker.sock:/var/run/docker.sock", "-v", "portainer_data:/data", "portainer/portainer-ce:lts"])
			return {"ok": r.code == 0, "msg": "Portainer is running at https://localhost:9443" if r.code == 0 else _tail(r)}
		"portainer_open":
			return {"ok": true, "msg": "Opening Portainer at https://localhost:9443", "open": "https://localhost:9443"}
		"deploy_template":
			var t = a["template"]
			var envinfo = Apps.template_env(t)
			var r = _run(Apps.template_docker_args(t, a["name"], envinfo[0], a.get("host_binds", false)))
			var note = ""
			if envinfo[1].size() > 0:
				note = "  Generated: %s (docker inspect %s)." % [", ".join(PackedStringArray(envinfo[1])), a["name"]]
			return {"ok": r.code == 0, "msg": ("%s is running as container %s.%s" % [t.get("title", a["name"]), a["name"], note]) if r.code == 0 else _tail(r)}
		"remove_template":
			var r = _run(["rm", "-f", a["name"]])
			return {"ok": r.code == 0, "msg": ("container %s removed (volumes kept)" % a["name"]) if r.code == 0 else _tail(r)}
		"templates":
			var r = Apps.fetch_templates(a.get("catalog", {}))
			return {"ok": r.ok, "msg": "", "text": r.text}
	return {}
