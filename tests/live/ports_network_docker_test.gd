extends SceneTree
# Port rows for macvlan and host networking, on the local Docker engine, through
# the game's own backend.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/live/ports_network_docker_test.gd
#
# Makes a throw-away macvlan network on a documentation address range
# (192.0.2.0/24, never routed), one container on it with port 80 exposed, and one
# on the host network; checks the backend reports the network's driver, the
# container's own address and the host mode; then removes the containers and the
# network by name. Nothing else on the engine is touched.

const NET = "kf-live-ports-mv"
const MV = "kf-live-ports-macvlan"
const HOSTNET = "kf-live-ports-hostnet"
const ADDR = "192.0.2.50"

var _results = []

func _docker(args: Array) -> Array:
	var out = []
	var code = OS.execute("docker", PackedStringArray(args), out, true)
	return [code, str(out[0]) if out.size() > 0 else ""]

func _step(name: String, ok: bool, note = "") -> void:
	_results.append(ok)
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, str(note).left(190)])

func _clean() -> void:
	_docker(["rm", "-f", MV])
	_docker(["rm", "-f", HOSTNET])
	_docker(["network", "rm", NET])

func _init() -> void:
	var K = load("res://scripts/kutil.gd")
	var Docker = load("res://scripts/backend_docker.gd")
	_clean()
	_docker(["pull", "-q", "busybox:1.36"])
	var net = _docker(["network", "create", "-d", "macvlan", "--subnet", "192.0.2.0/24", "-o", "parent=eth0", NET])
	var mv = _docker(["run", "-d", "--name", MV, "--network", NET, "--ip", ADDR, "--expose", "80", "busybox:1.36", "sleep", "300"])
	var hn = _docker(["run", "-d", "--name", HOSTNET, "--network", "host", "--expose", "8123", "busybox:1.36", "sleep", "300"])
	_step("a throw-away macvlan network and two containers are running", net[0] == 0 and mv[0] == 0 and hn[0] == 0, (net[1] + mv[1] + hn[1]).strip_edges().left(120))
	if net[0] != 0 or mv[0] != 0 or hn[0] != 0:
		_clean()
		quit(1)
		return
	OS.delay_msec(1500)
	var d = Docker.new()
	d.probe()
	var st = d.fetch()
	var m = null
	var h = null
	for p in st.get("pods", []):
		if p["name"] == MV:
			m = p
		elif p["name"] == HOSTNET:
			h = p
	_step("both are machines", m != null and h != null)
	if m != null and h != null:
		var seg = m["net"]["segments"].filter(func(s): return s["name"] == NET)
		_step("the network's driver is read from the engine", not seg.is_empty() and seg[0].get("driver") == "macvlan", seg)
		_step("the container's own address on that network", not seg.is_empty() and seg[0].get("ip") == ADDR, seg)
		var rows = K.port_rows(st)
		var mrow = rows.filter(func(r): return r["name"] == MV)
		_step("its exposed port is listed on its LAN address, listener unverified",
			mrow.size() == 1 and mrow[0]["port"] == ADDR + ":80/tcp" and mrow[0]["group"] == 0 and "listener unverified" in mrow[0]["scope"], mrow)
		_step("the row names the network with its driver", not mrow.is_empty() and (NET + " (macvlan)") in mrow[0]["networks"], mrow[0]["networks"] if not mrow.is_empty() else [])
		var hrow = rows.filter(func(r): return r["name"] == HOSTNET)
		_step("the host-network container's mode is named", h["net"]["mode"] == "host" and not hrow.is_empty() and hrow[0]["mode"] == "host network", hrow)
		var only = K.filter_ports(rows, -1, "", NET + " (macvlan)")
		_step("filtering by that network leaves only its container", only.size() == 1 and only[0]["name"] == MV, only.map(func(r): return r["name"]))
	_clean()
	var left = _docker(["ps", "-a", "--filter", "name=kf-live-ports", "-q"])
	var net_left = _docker(["network", "ls", "--filter", "name=" + NET, "-q"])
	_step("everything the test made is gone", left[1].strip_edges() == "" and net_left[1].strip_edges() == "", left[1] + net_left[1])
	var ok = not _results.has(false)
	print("PORTS NETWORK DOCKER PASSED" if ok else "PORTS NETWORK DOCKER FAILED")
	quit(0 if ok else 1)
