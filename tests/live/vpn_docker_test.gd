extends SceneTree
# A VPN gateway on the local Docker engine, through the game's own backend.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/live/vpn_docker_test.gd
#
# A stand-in for Gluetun (busybox under a local tag with "gluetun" in its
# name: no VPN account is needed or used) writes a documentation-range address
# to /tmp/gluetun/ip as Gluetun does, on a throw-away network; a second
# container shares its network the way Deluge shares Gluetun's. The test checks
# that the backend reads both sides of the tunnel and never keeps the fake key,
# then removes the containers, the network and the tag it made. Nothing else on
# the engine is touched.

const TAG = "kf-live-test/gluetun-stub:1"
const NET = "kf-live-vpn-net"
const GW = "kf-live-vpn-gateway"
const DL = "kf-live-vpn-downloader"
const EXIT = "203.0.113.77"
const BX_TAG = "kf-live-test/binhex/arch-delugevpn:1"     # a stand-in under a name the registry knows
const BX = "kf-live-vpn-builtin"
const SECRET = "kf-test-wireguard-key-must-not-be-kept"

var _results = []

func _docker(args: Array) -> Array:
	var out = []
	var code = OS.execute("docker", PackedStringArray(args), out, true)
	return [code, str(out[0]) if out.size() > 0 else ""]

func _step(name: String, ok: bool, note = "") -> void:
	_results.append(ok)
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, str(note).left(190)])

func _clean() -> void:
	_docker(["rm", "-f", DL])
	_docker(["rm", "-f", GW])
	_docker(["rm", "-f", BX])
	_docker(["network", "rm", NET])
	_docker(["rmi", TAG])
	_docker(["rmi", BX_TAG])

func _init() -> void:
	var Docker = load("res://scripts/backend_docker.gd")
	_clean()
	_docker(["pull", "-q", "busybox:1.36"])
	_docker(["tag", "busybox:1.36", TAG])
	_docker(["tag", "busybox:1.36", BX_TAG])
	_docker(["network", "create", NET])
	var gw = _docker(["run", "-d", "--name", GW, "--network", NET,
		"-e", "VPN_SERVICE_PROVIDER=testprovider", "-e", "VPN_TYPE=wireguard", "-e", "SERVER_COUNTRIES=Testland",
		"-e", "WIREGUARD_PRIVATE_KEY=" + SECRET, TAG, "sh", "-c", "mkdir -p /tmp/gluetun && echo %s > /tmp/gluetun/ip && sleep 300" % EXIT])
	var dl = _docker(["run", "-d", "--name", DL, "--network", "container:" + GW, "busybox:1.36", "sleep", "300"])
	_step("a stand-in gateway and a container in its network are running", gw[0] == 0 and dl[0] == 0, (gw[1] + dl[1]).strip_edges().left(80))
	if gw[0] != 0 or dl[0] != 0:
		_clean()
		quit(1)
		return
	OS.delay_msec(2000)
	var d = Docker.new()
	d.probe()
	var st = d.fetch()
	var g = null
	var c = null
	for p in st.get("pods", []):
		if p["name"] == GW:
			g = p
		elif p["name"] == DL:
			c = p
	_step("both are machines", g != null and c != null)
	if g != null and c != null:
		var v: Dictionary = g["net"]["vpn"]
		_step("the gateway is recognised, with provider, type and countries", [v.get("provider"), v.get("type"), v.get("countries")] == ["testprovider", "wireguard", "Testland"], v)
		_step("inside: the gateway's address on the throw-away network", g["net"]["addrs"].size() == 1 and str(g["net"]["addrs"][0]).ends_with("(%s)" % NET), g["net"]["addrs"])
		_step("outside: the address the gateway recorded", v.get("exit_ip") == EXIT, v.get("exit_ip"))
		_step("the downloader has no network of its own: it uses the gateway's", c["net"]["via"] == g["uid"], c["net"]["via"].left(12))
		_step("the gateway lists what goes through it", DL in v.get("through", []), v.get("through"))
		_step("the fake WireGuard key is nowhere in what the game holds", not JSON.stringify(st).contains(SECRET))
	# an image with its VPN built in (binhex's *vpn images): recognised only with its VPN on
	var bx = _docker(["run", "-d", "--name", BX, "-e", "VPN_ENABLED=yes", "-e", "VPN_PROV=airvpn", "-e", "VPN_CLIENT=wireguard",
		"-e", "VPN_PASS=" + SECRET, BX_TAG, "sleep", "300"])
	OS.delay_msec(1500)
	st = d.fetch()
	var b = null
	for p in st.get("pods", []):
		if p["name"] == BX:
			b = p
	var bv: Dictionary = b["net"]["vpn"] if b != null else {}
	_step("an image with a built-in VPN is recognised", bx[0] == 0 and bv.get("role") == "built-in" and bv.get("provider") == "airvpn", bv)
	_step("it carries its own app", BX in bv.get("through", []), bv.get("through"))
	_step("its outside address can be asked for, and is not guessed", bv.get("exit_ip") == "" and bv.get("can_check") == true, bv.get("exit_note"))
	_step("its VPN password is nowhere in what the game holds", not JSON.stringify(st).contains(SECRET))
	_clean()
	var left = _docker(["ps", "-a", "--filter", "name=kf-live-vpn", "-q"])
	_step("everything the test made is gone", left[1].strip_edges() == "", left[1])
	var ok = not _results.has(false)
	print("VPN DOCKER PASSED" if ok else "VPN DOCKER FAILED")
	quit(0 if ok else 1)
