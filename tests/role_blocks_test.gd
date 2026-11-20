extends SceneTree
# Role blocks: which shape a workload gets, and that an override changes only that.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/role_blocks_test.gd

const Machine = preload("res://scripts/machine.gd")
var failures = 0

func check(ok: bool, what: String, got = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if ok else "  got: " + str(got)))
	if not ok:
		failures += 1

func pod(ns: String, name: String, image: String) -> Dictionary:
	return {"uid": ns + "-" + name, "ns": ns, "name": name + "-abc12", "wname": name, "containers": [{"name": name, "image": image}]}

func _init() -> void:
	var cases = [
		[pod("shop", "catalog-db", "postgres:16"), "storage"],
		[pod("shop", "redis", "redis:7.4"), "storage"],
		[pod("monitoring", "prometheus", "prom/prometheus:v3"), "reporting"],
		[pod("media", "plex", "plexinc/pms-docker:latest"), "app"],
		[pod("media", "sonarr", "lscr.io/linuxserver/sonarr:latest"), "worker"],
		[pod("media-vpn", "arr-vpn", "qmcgaw/gluetun:v3"), "gateway"],
		[pod("kube-system", "coredns", "registry.k8s.io/coredns/coredns:v1.11.3"), "gateway"],
		[pod("shop", "frontend", "helmsman/shop-frontend:2.4.1"), "app"],
		[pod("lab", "tautulli-exporter", "quay.io/prometheuscommunity/json-exporter:v0.8.0"), "reporting"],
		[pod("misc", "thing", "example/thing:1"), "generic"],
	]
	Machine.role_overrides = {}
	for c in cases:
		check(Machine.auto_role(c[0]) == c[1], "%s is a %s block" % [c[0]["wname"], c[1]], Machine.auto_role(c[0]))
	var thing = cases[-1][0]
	Machine.role_overrides = {"misc/thing": "worker"}
	check(Machine.role_for(thing) == "worker" and Machine.auto_role(thing) == "generic", "an override changes the role and keeps the automatic guess")
	Machine.role_overrides = {"misc/thing": "not-a-role"}
	check(Machine.role_for(thing) == "generic", "an unknown override is ignored")
	Machine.role_overrides = {}
	# every role has a shape of its own
	var Blocks = load("res://scripts/plan_blocks.gd")
	var sizes = {}
	for r in Machine.ROLES:
		var mesh: ArrayMesh = Blocks.role_mesh(r)
		var key = "%d:%s" % [mesh.get_surface_count(), str(mesh.get_aabb().size.snapped(Vector3.ONE * 0.01))]
		sizes[r] = key
	var unique = {}
	for r in sizes:
		unique[sizes[r]] = true
	check(unique.size() == Machine.ROLES.size(), "each of the six roles has a distinct shape", sizes)
	print("ROLE BLOCKS PASSED" if failures == 0 else "ROLE BLOCKS FAILED")
	quit(0 if failures == 0 else 1)
