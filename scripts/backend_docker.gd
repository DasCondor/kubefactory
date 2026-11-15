extends RefCounted
# Plain Docker engine as a one-node "cluster": every container is a machine,
# compose projects become namespaces and compose services become workloads.

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")

var label = "docker"
var poll_interval = 2.5
var caps = {"remove_image": true, "scale": false, "delete_pod": true, "restart": true, "delete_workload": false,
	"create": true, "cordon": false, "drain": false, "logs": true, "files": true}
var context = ""
var log_cfg = {}
var providers = [{"id": "kube", "name": "Docker Engine", "ready": true, "note": "docker logs"}]
var _host = {}
# Which Docker context (the docker CLI's named engines: this machine, or another
# host over tcp:// or ssh://). "" is the CLI's current one. Every command is
# run against it, so several hosts are several connections.
var docker_context = ""
var endpoint = ""          # its address, as the context states it
var remote = false         # not this machine's own engine

func _args(args: Array) -> PackedStringArray:
	return PackedStringArray((["--context", docker_context] if docker_context != "" else []) + args)

func _run(args: Array, with_err: bool = true) -> Dictionary:
	var out = []
	var code = OS.execute("docker", _args(args), out, with_err)
	return {"code": code, "out": (str(out[0]) if out.size() > 0 else "")}

# The docker CLI's contexts: [{name, endpoint, current, remote}]. Nothing is contacted.
static func contexts() -> Array:
	var out = []
	if OS.execute("docker", PackedStringArray(["context", "ls", "--format", "{{json .}}"]), out, false) != 0 or out.is_empty():
		return []
	var res = []
	for line in str(out[0]).split("\n", false):
		var d = JSON.parse_string(line.strip_edges())
		if typeof(d) != TYPE_DICTIONARY or str(d.get("Error", "")) != "":
			continue
		var ep = str(d.get("DockerEndpoint", ""))
		res.append({"name": str(d.get("Name", "")), "endpoint": ep, "current": bool(d.get("Current", false)), "remote": is_remote(ep)})
	return res

# This machine's own engine is a local socket or pipe; tcp:// and ssh:// are another host
# (a tcp://127.0.0.1 port is usually a tunnel or proxy to one).
static func is_remote(ep: String) -> bool:
	return not (ep.begins_with("unix://") or ep.begins_with("npipe://"))

func probe() -> Dictionary:
	var r = _run(["info", "--format", "{{json .}}"], false)
	if r.code != 0:
		return {"ok": false, "msg": "Docker engine is not running"}
	var d = JSON.parse_string(r.out)
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "msg": "could not read docker info"}
	_host = d
	context = docker_context if docker_context != "" else str(d.get("Name", "docker"))
	for c in contexts():
		if c["name"] == docker_context or (docker_context == "" and c["current"]):
			endpoint = c["endpoint"]
			remote = c["remote"]
	return {"ok": true, "msg": context}

var _inspect = {}      # container id -> {state, sec, finished}: `docker inspect` is asked only for what changed

func _inspect_all(rows: Array) -> void:
	var want = []
	var live = {}
	for c in rows:
		var id = str(c.get("ID", ""))
		live[id] = true
		if id != "" and (not _inspect.has(id) or _inspect[id]["state"] != str(c.get("State", ""))):
			want.append(id)
	for id in _inspect.keys():
		if not live.has(id):
			_inspect.erase(id)
	if want.is_empty():
		return
	var r = _run(["inspect"] + want, false)
	var arr = JSON.parse_string(r.out) if r.code == 0 else null
	if typeof(arr) != TYPE_ARRAY:
		return
	for i in arr:
		if typeof(i) != TYPE_DICTIONARY:
			continue
		var fin = str(i.get("State", {}).get("FinishedAt", ""))
		var finished = 0.0 if fin == "" or fin.begins_with("0001") else Time.get_unix_time_from_datetime_string(fin.get_slice(".", 0))
		_inspect[str(i.get("Id", ""))] = {"state": str(i.get("State", {}).get("Status", "")), "sec": K.container_security(i), "store": K.container_storage(i),
			"net": K.container_net(i), "finished": finished}

# A VPN's outside address. Images that record it themselves (Gluetun writes
# /tmp/gluetun/ip) are read with the container's own `head`, at most every
# minute, with no call to the internet. For the others the operator can ask
# for it (vpn_check): that one call goes from inside the tunnel, on request.
var _exit = {}      # container id -> {"ip", "note", "at", "asked"}

func _exit_ip(id: String, running: bool, ip_file: String) -> Dictionary:
	if not running:
		return {"ip": "", "note": "the VPN container is not running"}
	var now = Time.get_unix_time_from_system()
	var e = _exit.get(id, {})
	if not e.is_empty() and (e.get("asked", false) or now - float(e["at"]) < 60.0):
		return e
	if ip_file == "":
		return {"ip": "", "note": "this image does not record it: use Check now"}
	var r = _run(["exec", id, "head", "-c", "64", ip_file], false)
	var ip = r.out.strip_edges() if r.code == 0 else ""
	if ip != "" and K.valid_ip(ip):
		e = {"ip": ip, "note": "", "at": now}
	elif r.code == 0:
		e = {"ip": "", "note": "the tunnel is not up yet (no public address recorded)", "at": now}
	else:
		e = {"ip": "", "note": "not readable here" + (" (this host is read-only)" if remote else ""), "at": now}
	_exit[id] = e
	return e

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
	var rows = []
	for line in r.out.split("\n"):
		var cj = JSON.parse_string(line.strip_edges()) if line.strip_edges() != "" else null
		if typeof(cj) == TYPE_DICTIONARY:
			rows.append(cj)
	_inspect_all(rows)
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
				"reason": status_text, "ready": state == "running", "restarts": 0}],
			"phase": "Running" if state == "running" else ("Succeeded" if status == "Completed" else ("Failed" if state in ["exited", "dead"] else "Pending")),
			"finished": float(_inspect.get(str(c.get("ID", "")), {}).get("finished", 0.0)),
			"sec": _inspect.get(str(c.get("ID", "")), {}).get("sec", K.empty_security()),
			"store": _inspect.get(str(c.get("ID", "")), {}).get("store", K.empty_storage()),
			"net": _inspect.get(str(c.get("ID", "")), {}).get("net", K.empty_net()).duplicate(true)})
		if svc != "":
			var key = ns + "/" + svc
			if not wl.has(key):
				wl[key] = {"kind": "Compose", "name": svc, "ns": ns, "replicas": 0, "ready": 0, "image": str(c.get("Image", ""))}
			wl[key]["replicas"] += 1
			if state == "running":
				wl[key]["ready"] += 1
	st.workloads = wl.values()
	# who goes through whom: a container sharing a VPN gateway's network is
	# listed on the gateway, and the gateway's outside address is read
	var by_id = {}
	for p in st.pods:
		by_id[p["uid"]] = p
	for p in st.pods:
		var via = str(p["net"]["via"])
		if via != "" and by_id.has(via) and not by_id[via]["net"]["vpn"].is_empty():
			by_id[via]["net"]["vpn"]["through"].append(p["name"])
	for p in st.pods:
		if not p["net"]["vpn"].is_empty():
			var e = _exit_ip(p["uid"], p["ready"], str(p["net"]["vpn"].get("ip_file", "")))
			p["net"]["vpn"]["exit_ip"] = e["ip"]
			p["net"]["vpn"]["exit_note"] = e["note"]
			p["net"]["vpn"]["can_check"] = p["ready"] and not remote
	return st

# Asked for by the operator: the address the internet sees, asked of a
# what's-my-address service from inside the VPN container (so through its
# tunnel), with whichever of wget and curl the image has. Nothing else is sent.
const IP_ECHO = "https://ipinfo.io/ip"

func _vpn_check(id: String) -> Dictionary:
	if id == "":
		return {"ok": false, "msg": "which container?", "data": {}}
	var r = _run(["exec", id, "wget", "-qO-", "-T", "8", IP_ECHO], false)
	if r.code != 0:
		r = _run(["exec", id, "curl", "-fsS", "-m", "8", IP_ECHO], false)
	var ip = r.out.strip_edges().left(64)
	if r.code != 0 or not K.valid_ip(ip):
		return {"ok": false, "msg": "Could not ask from inside that container (it needs wget or curl, and a working tunnel)", "data": {}}
	_exit[id] = {"ip": ip, "note": "asked ipinfo.io from inside the tunnel, " + Time.get_time_string_from_system(), "at": Time.get_unix_time_from_system(), "asked": true}
	return {"ok": true, "msg": "The internet sees %s from inside that container." % ip, "data": {"ip": ip}}

func run_action(a: Dictionary) -> Dictionary:
	var special = _app_action(a)
	if not special.is_empty():
		return special
	var r
	match a["op"]:
		"vpn_check":
			return _vpn_check(str(a.get("pod", "")))
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
	return {"ok": r.code == 0, "msg": _tail(r) if r.code != 0 else "docker: %s %s" % [a["op"], a.get("pod", a["name"]) if a["op"] == "restart" else a["name"]]}

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
	var all = r.out.strip_edges()
	if all.contains("403 Forbidden") or all.contains("forbidden by administrative rules"):
		return "The Docker host refused this (403 Forbidden): it only allows looking, through a read-only proxy."
	var lines = all.split("\n")
	return lines[lines.size() - 1]

# ---- read-only storage inspection (the storage doors)
# Uses only `docker inspect` and `docker exec <container> ls / head / dd` with
# fixed arguments: nothing is mounted, started or written, and browsing stays
# inside one of the container's own mounts.

func _mounts(container: String) -> Array:
	var r = _run(["inspect", "--format", "{{json .Mounts}}|{{.State.Running}}", container], false)
	if r.code != 0:
		return []
	var bits = r.out.strip_edges().rsplit("|", true, 1)
	var list = JSON.parse_string(bits[0])
	var res = []
	if typeof(list) == TYPE_ARRAY:
		for m in list:
			res.append({"container": container, "path": str(m.get("Destination", "")), "read_only": not bool(m.get("RW", true)),
				"volume": str(m.get("Name", "")), "type": str(m.get("Type", "bind")), "claim": str(m.get("Name", "")) if str(m.get("Type", "")) == "volume" else str(m.get("Source", "")),
				"readable": true, "running": bits.size() > 1 and bits[1] == "true"})
	return res

func _file_action(a: Dictionary) -> Dictionary:
	if a["op"] == "file_mounts":
		return {"ok": true, "msg": "", "kind": "", "data": {"mounts": _mounts(a["name"])}}
	var m = null
	for x in _mounts(a["name"]):
		if x["path"] == a["root"]:
			m = x
	if m == null:
		return {"ok": false, "kind": "invalid", "msg": "%s is not a mount of this container" % a["root"], "data": {}}
	if not m["running"]:
		return {"ok": false, "kind": "unsupported", "msg": "The container is not running, so its files cannot be read.", "data": {}}
	var full = K.path_inside(a["root"], str(a.get("path", "")))
	if full == "":
		return {"ok": false, "kind": "invalid", "msg": "That path is outside the mounted volume.", "data": {}}
	# no directory between the mount and the target may be a link
	var chain = []
	var p = full.get_base_dir()
	while p.length() > str(a["root"]).rstrip("/").length() and p != a["root"]:
		chain.append(p)
		p = p.get_base_dir()
	if not chain.is_empty():
		var c = _run(["exec", a["name"], "ls", "-ldn", "--"] + chain, false)
		for ln in c.out.strip_edges().split("\n"):
			if c.code != 0 or not ln.begins_with("d"):
				return {"ok": false, "kind": "invalid", "msg": "That path goes through a link, which is not followed.", "data": {}}
	if a["op"] == "file_list":
		# the folder itself must be a real folder: a link here could point anywhere in the container
		if full != str(a["root"]).rstrip("/") and full != a["root"]:
			var self_ls = _run(["exec", a["name"], "ls", "-ldn", "--", full], false)
			if self_ls.code != 0:
				return {"ok": false, "kind": "notfound", "msg": "There is no such folder in this volume.", "data": {}}
			if not self_ls.out.begins_with("d"):
				return {"ok": false, "kind": "invalid", "msg": "That is a link, which is not followed: it may point outside the volume.", "data": {}}
		var r = _run(["exec", a["name"], "ls", "-la", "--", full + "/."])
		if r.code != 0:
			var kind = "unsupported" if r.out.contains("executable file not found") else ("rbac" if r.out.contains("Permission denied") else "notfound")
			var msg = "This container has no file tools (no `ls`), so its volumes cannot be browsed from inside it." if kind == "unsupported" else _tail(r)
			return {"ok": false, "kind": kind, "msg": msg, "data": {}}
		var es = K.parse_ls(r.out)
		return {"ok": true, "msg": "", "kind": "", "data": {"path": full, "entries": es.slice(0, 500), "truncated": es.size() > 500, "readable": true}}
	# file_read: one 64 KiB page of a regular file
	var page = clampi(int(a.get("page", 0)), 0, 255)
	var st = _run(["exec", a["name"], "ls", "-ldn", "--", full], false)
	var f = st.out.strip_edges().split(" ", false)
	if st.code != 0 or f.size() < 5 or not st.out.begins_with("-"):
		return {"ok": false, "kind": "invalid", "msg": "Only regular files can be previewed (links and devices are not followed).", "data": {}}
	var size = f[4].to_int()
	var tmp = OS.get_user_data_dir().path_join("preview-%d.bin" % OS.get_process_id())
	# `docker cp` would follow the file out of the container; a bounded read through exec does not
	var args = ["exec", a["name"], "head", "-c", "65536", "--", full] if page == 0 else ["exec", a["name"], "dd", "if=" + full, "bs=65536", "skip=%d" % page, "count=1"]
	var out = []
	var code = OS.execute("docker", _args(args), out, false)
	DirAccess.remove_absolute(tmp)
	if code != 0:
		return {"ok": false, "kind": "rbac", "msg": "The container's user may not read this file.", "data": {}}
	var text = str(out[0]) if out.size() > 0 else ""
	return {"ok": true, "msg": "", "kind": "", "data": {"path": full, "size": size, "page": page, "pages": mini(int(ceil(size / 65536.0)), 256),
		"data": Marshalls.utf8_to_base64(text), "text_only": true}}

# "12.5MiB", "1.2kB", "3GB" -> bytes (docker stats mixes binary and decimal units)
static func _size(s: String) -> Variant:
	var t = s.strip_edges()
	var units = {"kib": 1024.0, "mib": 1048576.0, "gib": 1073741824.0, "tib": 1099511627776.0, "kb": 1000.0, "mb": 1000000.0, "gb": 1000000000.0, "tb": 1000000000000.0, "b": 1.0}
	var multiplier = 1.0
	for u in units:
		if t.to_lower().ends_with(u):
			t = t.left(t.length() - u.length()).strip_edges()
			multiplier = units[u]
			break
	if not t.is_valid_float() or t.to_float() < 0.0:
		return null
	return t.to_float() * multiplier

static func _usage_data(d: Dictionary) -> Dictionary:
	var data = {"at": Time.get_datetime_string_from_system(true) + "Z", "source": "docker stats"}
	var cpu = str(d.get("CPUPerc", "")).strip_edges().trim_suffix("%").strip_edges()
	if cpu.is_valid_float() and cpu.to_float() >= 0.0:
		data["cpu_cores"] = cpu.to_float() / 100.0
	var mem = _size(str(d.get("MemUsage", "")).get_slice("/", 0))
	if mem != null:
		data["mem_bytes"] = mem
	for field in [["NetIO", "net_rx_bytes", "net_tx_bytes"], ["BlockIO", "disk_read_bytes", "disk_write_bytes"]]:
		var pair = str(d.get(field[0], "")).split("/")
		if pair.size() != 2:
			continue
		for i in 2:
			var value = _size(pair[i])
			if value != null:
				data[field[i + 1]] = value
	return data

# What a container is using right now, as the engine itself reports it.
func _metrics(container: String) -> Dictionary:
	var r = _run(["stats", "--no-stream", "--format", "{{json .}}", container], false)
	var d = JSON.parse_string(r.out.strip_edges()) if r.code == 0 else null
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "kind": "unsupported", "msg": "The engine gave no usage figures for this container (is it running?).", "data": {}}
	# a container that is not running is reported by the engine as all zeros: that is not a measurement
	if str(d.get("PIDs", "")) == "0" or str(d.get("MemUsage", "")).replace(" ", "").begins_with("0B/0B"):
		return {"ok": false, "kind": "unsupported", "msg": "This container is not running, so it is using nothing.", "data": {}}
	return {"ok": true, "msg": "", "kind": "", "data": _usage_data(d)}

# Images and volumes with their sizes and users, as `docker system df -v` reports them.
func _cleanup_scan() -> Dictionary:
	var r = _run(["system", "df", "-v", "--format", "{{json .}}"], false)
	var d = JSON.parse_string(r.out.strip_edges()) if r.code == 0 else null
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "kind": "unsupported", "msg": "The engine did not report its disk use.", "data": {}}
	var images = []
	for i in (d.get("Images", []) if typeof(d.get("Images")) == TYPE_ARRAY else []):
		var size = _size(str(i.get("Size", "")))
		var unique = _size(str(i.get("UniqueSize", "")))
		images.append({"id": str(i.get("ID", "")), "repo": str(i.get("Repository", "<none>")), "tag": str(i.get("Tag", "<none>")),
			"size": size if size != null else 0.0, "unique": unique if unique != null else 0.0,
			"containers": int(str(i.get("Containers", "1"))) if str(i.get("Containers", "")).is_valid_int() else 1, "created": str(i.get("CreatedSince", ""))})
	var volumes = []
	for v in (d.get("Volumes", []) if typeof(d.get("Volumes")) == TYPE_ARRAY else []):
		volumes.append({"name": str(v.get("Name", "")), "links": int(str(v.get("Links", "1"))) if str(v.get("Links", "")).is_valid_int() else 1, "size": _size(str(v.get("Size", "")))})
	# Forge: has an image in use ever come from (or gone to) a registry? No repo
	# digest means it was built here and exists nowhere else.
	# The containerd image store (Docker Desktop's default) gives every image a
	# digest of its own, built here or pulled, so it does not tell: say so.
	var provenance = "recorded"
	if JSON.stringify(_host.get("DriverStatus", [])).contains("containerd.snapshotter") or str(_host.get("Driver", "")).contains("containerd"):
		provenance = "unrecorded"
	var used = images.filter(func(i): return int(i["containers"]) > 0 and str(i["id"]) != "")
	if not used.is_empty() and provenance == "recorded":
		var ri = _run(["image", "inspect", "--format", "{{.Id}}|{{len .RepoDigests}}"] + used.map(func(i): return str(i["id"])), false)
		var digests = {}
		for line in ri.out.split("\n"):
			if line.contains("|"):
				digests[line.get_slice("|", 0).strip_edges()] = line.get_slice("|", 1).strip_edges()
		for i in images:
			var n = digests.get(str(i["id"]), "")
			if str(n).is_valid_int():
				i["digests"] = int(n)
	var cache = {"entries": 0, "reclaimable": 0.0, "in_use": 0}
	for b in (d.get("BuildCache", []) if typeof(d.get("BuildCache")) == TYPE_ARRAY else []):
		cache["entries"] += 1
		if str(b.get("InUse", "false")).to_lower() == "true":
			cache["in_use"] += 1
		else:
			var sz = _size(str(b.get("Size", "")))
			cache["reclaimable"] += sz if sz != null else 0.0
	return {"ok": true, "msg": "", "kind": "", "data": {"images": images, "volumes": volumes, "build_cache": cache, "provenance": provenance, "source": "docker system df"}}

func _app_action(a: Dictionary) -> Dictionary:
	if a["op"] == "pod_metrics":
		return _metrics(a["name"])
	if a["op"] == "cleanup_scan":
		return _cleanup_scan()
	if a["op"] == "remove_image":
		# no --force: the engine refuses while any container still uses it
		var rr = _run(["image", "rm", str(a.get("id", a["name"]))])
		return {"ok": rr.code == 0, "msg": ("Removed image " + str(a["name"])) if rr.code == 0 else _tail(rr)}
	if a["op"] in ["file_mounts", "file_list", "file_read"]:
		return _file_action(a)
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
