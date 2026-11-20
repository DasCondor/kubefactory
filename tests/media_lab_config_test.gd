extends SceneTree

const Demo = preload("res://scripts/backend_demo.gd")
const K = preload("res://scripts/kutil.gd")
const Lab = preload("res://scripts/demo_media_lab.gd")
var failures = 0

func _check(ok: bool, description: String) -> void:
	print(("PASS " if ok else "FAIL ") + description)
	if not ok:
		failures += 1

func _initialize() -> void:
	var expected = Lab.configured_host_count()      # media-lab.json; --expect-hosts= overrides
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expect-hosts="):
			expected = int(arg.trim_prefix("--expect-hosts="))
	var backend = Demo.new("docker-media-gatherer")
	var state = backend.fetch()
	_check(state["nodes"].size() == expected and state["lab"]["host_count"] == expected,
		"normal demo entry point applies the config")
	_check(state["pods"].size() == 15, "both layouts keep all fifteen services")
	var gathering_apps = ["sonarr", "radarr", Lab.configured_indexer(), "downloader", "gluetun", "syncthing", "gatherer-metrics"]
	for pod in state["pods"]:
		var host = "gathering-node" if expected == 2 and pod["wname"] in gathering_apps else "media-host"
		_check(pod["node"] == host, pod["wname"] + " runs on its configured host")
		if expected == 1:
			_check(not pod["net"]["segments"].any(func(segment): return segment.get("vlan", 0) == 40),
				pod["wname"] + " uses local networks")
	var info = Demo.flavor_info("docker-media-gatherer")
	_check(info["nodes"].size() == expected, "demo picker reports the configured host count")
	_check(backend.caps["lab_sync"] and state["lab"]["sync_ready"], "sync controls remain available")
	var ingress: Array = state["lab"]["gateway_ports"]["lan"]
	_check(ingress.size() == 2 and ingress[0]["port"] == "32400/tcp" and ingress[1]["port"] == "5055/tcp",
		"inlet sockets identify the device listener ports")
	_check(ingress.all(func(port): return port["ready"] and not port["reachable"]),
		"loopback listeners stay local")
	var outbound: Array = state["lab"]["egress"]
	var plex = outbound.filter(func(route): return route["app"] == "plex")
	_check(plex.size() == 1 and plex[0]["listener_port"] == "32400/tcp" and plex[0]["port"] == "443/tcp"
		and plex[0]["source_port"] == "ephemeral", "listener and outbound ports have separate meanings")
	var protected = outbound.filter(func(route): return route["via"] == "gluetun")
	_check(protected.size() == 4 and protected.all(func(route): return route["port"] == "51820/udp" and route["trace"].size() == 2),
		"each protected app reaches WWW through the configured VPN port")
	var endpoints = {}
	for pod in state["pods"]:
		endpoints[pod["uid"]] = true
	for id in state["lab"]["fixtures"]:
		endpoints["lab:" + id] = true
	for link in state["links"]:
		_check(endpoints.has(link["from"]) and endpoints.has(link["to"]), "route endpoints exist")
		if expected == 1:
			_check(not "management LAN/VLAN" in link["what"], "local route has a local scope")
	var disks = K.shared_disks(state)
	var outbox = disks.filter(func(disk): return disk["label"].ends_with(" · outbox"))
	_check(outbox.size() == 1 and outbox[0]["mounts"].size() == 2, "outbox remains one shared volume")
	_check(Demo.new("docker-media").fetch()["pods"].size() == 7, "the existing media starter stays available")
	# Prowlarr instead of Jackett: same place in the stack, behind the VPN, plus indexer sync
	Lab.forced_indexer = "prowlarr"
	var pst = Demo.new("docker-media-gatherer").fetch()
	Lab.forced_indexer = ""
	var names = pst["pods"].map(func(pod): return pod["wname"])
	_check("prowlarr" in names and not "jackett" in names and pst["pods"].size() == 15 and pst["lab"]["indexer"] == "prowlarr",
		"Prowlarr replaces Jackett in the fifteen-service stack")
	var prowlarr = pst["pods"].filter(func(pod): return pod["wname"] == "prowlarr")[0]
	var gw = pst["pods"].filter(func(pod): return pod["wname"] == "gluetun")[0]
	_check(prowlarr["net"]["via"] == gw["uid"] and "prowlarr" in gw["net"]["vpn"]["through"], "Prowlarr reaches the internet only through Gluetun")
	var pl = pst["links"].map(func(link): return [link["from_name"], link["to_name"], link["kind"]])
	_check(["sonarr", "prowlarr", "API"] in pl and ["radarr", "prowlarr", "API"] in pl, "Sonarr and Radarr search through Prowlarr")
	_check(["prowlarr", "sonarr", "API"] in pl and ["prowlarr", "radarr", "API"] in pl, "Prowlarr pushes its indexers into Sonarr and Radarr")
	_check(["prowlarr", "prowlarr-config", "Mounts"] in pl and not pl.any(func(row): return "jackett" in row[0] or "jackett" in row[1]),
		"Prowlarr has its own config volume and nothing points at Jackett")
	var pv = pst["lab"]["egress"].filter(func(route): return route["via"] == "gluetun")
	_check(pv.size() == 4 and pv.any(func(route): return route["app"] == "prowlarr"), "Prowlarr is one of the four VPN-protected apps")
	print("MEDIA LAB CONFIG PASSED" if failures == 0 else "MEDIA LAB CONFIG FAILED")
	quit(0 if failures == 0 else 1)
