extends SceneTree
# Run:  engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/normalize_test.gd

func _init():
	var Kube = load("res://scripts/backend_kubectl.gd")
	var K = load("res://scripts/kutil.gd")
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixture.json"))
	var st = Kube.normalize(data, "test")
	var fails = []
	var check = func(what, got, want):
		if str(got) != str(want):
			fails.append("%s: got %s, want %s" % [what, got, want])
	check.call("provider", st["provider"], "Rancher · AWS EKS")
	var n = st["nodes"][0]
	check.call("node ready", n["ready"], true)
	check.call("node cordoned", n["cordoned"], true)
	check.call("node roles", n["roles"], "control-plane")
	check.call("node cpu", n["cpu"], 1.93)
	check.call("node cpu_req", n["cpu_req"], 0.25)
	check.call("node mem_req", n["mem_req"], 128.0 * 1048576.0)
	check.call("node zone", n["zone"], "us-east-1a")
	var p = st["pods"]
	check.call("pod count", p.size(), 4)
	check.call("web workload", p[0]["wkind"] + "/" + p[0]["wname"], "Deployment/web")
	check.call("web health", p[0]["health"], "ok")
	check.call("web restarts", p[0]["restarts"], 2)
	check.call("api status", p[1]["status"], "CrashLoopBackOff")
	check.call("api health", p[1]["health"], "bad")
	check.call("api workload", p[1]["wname"], "api")
	check.call("job status", p[2]["status"], "Pending")
	check.call("job node", p[2]["node"], "")
	check.call("job health", p[2]["health"], "warn")
	check.call("done status", p[3]["status"], "Completed")
	check.call("done health", p[3]["health"], "done")
	check.call("workloads", st["workloads"].size(), 2)
	check.call("web replicas", "%d/%d" % [st["workloads"][0]["ready"], st["workloads"][0]["replicas"]], "1/3")
	check.call("svc ports", st["services"][0]["ports"], "80/TCP")
	check.call("svc selects web", K.selects(st["services"][0]["selector"], p[0]["labels"]), true)
	check.call("svc w/o selector", K.selects(st["services"][1]["selector"], p[0]["labels"]), false)
	check.call("hint eks", K.provider_hint("arn:aws:eks:us-east-1:1:cluster/x", "https://A.gr7.us-east-1.eks.amazonaws.com"), "AWS EKS")
	check.call("hint aks", K.provider_hint("prod", "https://x-dns-1.hcp.eastus.azmk8s.io:443"), "Azure AKS")
	check.call("hint gke", K.provider_hint("gke_proj_us-central1_c1", "https://34.1.2.3"), "Google GKE")
	check.call("hint rancher", K.provider_hint("edge", "https://rancher.example.com/k8s/clusters/c-m-abc"), "Rancher")
	check.call("valid name", K.valid_name("my-app-1"), true)
	check.call("invalid name", K.valid_name("My_App"), false)
	check.call("mem parse", K.parse_mem("2Gi"), 2147483648.0)
	var pol = {"max_tier": 3, "users": {"alice": 2}, "groups": {"sre": 5, "devs": 4}}
	check.call("policy user (service account)", K.policy_max_tier(pol, "system:serviceaccount:kubefactory:alice", ["sre"]), 2)
	check.call("policy best group", K.policy_max_tier(pol, "carol", ["devs", "sre"]), 5)
	check.call("policy default", K.policy_max_tier(pol, "dave", ["other"]), 3)
	check.call("policy none", K.policy_max_tier({}, "dave", []), 5)
	check.call("tier delete pod", K.tier_of({"op": "delete_pod", "ns": "a", "name": "b"}, st), 4)
	check.call("tier scale down", K.tier_of({"op": "scale_by", "delta": -1}, st), 3)
	check.call("tier scale up", K.tier_of({"op": "scale_by", "delta": 1}, st), 2)
	check.call("tier uncordon", K.tier_of({"op": "cordon", "on": false}, st), 2)
	check.call("tier drain", K.tier_of({"op": "drain", "node": "n"}, st), 5)
	check.call("tier logs", K.tier_of({"op": "logs"}, st), 1)
	check.call("short user", K.short_user("jane@example.com"), "jane")
	var Apps = load("res://scripts/apps.gd")
	var good = {"image": "registry:latest", "ports": ["5000/tcp"], "volumes": [{"container": "/var/lib/registry"}], "env": [{"name": "A_B", "default": "1"}]}
	check.call("template ok", Apps.template_problem(good), "")
	check.call("template flag as image", Apps.template_problem({"image": "--privileged"}) != "", true)
	check.call("template image with space", Apps.template_problem({"image": "alpine --privileged"}) != "", true)
	check.call("template bad bind", Apps.template_problem({"image": "a", "volumes": [{"container": "/x", "bind": "/a:/b"}]}) != "", true)
	check.call("template path traversal", Apps.template_problem({"image": "a", "volumes": [{"container": "/x/../../etc"}]}) != "", true)
	check.call("template bad env name", Apps.template_problem({"image": "a", "env": [{"name": "X=1 --privileged"}]}) != "", true)
	check.call("template bad restart", Apps.template_problem({"image": "a", "restart_policy": "always --privileged"}) != "", true)
	check.call("port proto injection", Apps.parse_port("80/TCP}, {evil: 1")[2], "TCP")
	check.call("port udp", Apps.parse_port("8080:53/udp"), [8080, 53, "UDP"])
	check.call("host binds listed", Apps.host_binds({"volumes": [{"container": "/s", "bind": "/var/run/docker.sock"}, {"container": "/d", "bind": "/portainer/Files/x"}]}), ["/var/run/docker.sock"])
	var dargs = Apps.template_docker_args({"image": "a", "volumes": [{"container": "/s", "bind": "/var/run/docker.sock"}]}, "x", [])
	check.call("host bind off by default", dargs.has("/var/run/docker.sock:/s"), false)
	check.call("host bind when allowed", Apps.template_docker_args({"image": "a", "volumes": [{"container": "/s", "bind": "/var/run/docker.sock"}]}, "x", [], true).has("/var/run/docker.sock:/s"), true)
	var man = Apps.template_manifest({"image": "a", "ports": ["80/tcp"], "env": []}, "x", [["K", "line1
line2\" injected: true"]])
	check.call("manifest value stays quoted", man.contains("injected: true
"), false)
	# Bob's diagnoses and log reading
	var jobs = K.issues(st)
	check.call("bob lists the crashing pod first", jobs[0]["name"] + " " + jobs[0]["status"], p[1]["name"] + " CrashLoopBackOff")
	check.call("bob lists the unscheduled pod", jobs.filter(func(j): return j["status"] == "Unschedulable").size(), 1)
	check.call("bob crashloop remedy", K.diagnose("CrashLoopBackOff")[2], "restart")
	check.call("bob image remedy has no button", K.diagnose("ImagePullBackOff")[2], "")
	var Bob = load("res://scripts/bob.gd")
	var rules = Bob.compile({"rules": [{"match": "widget quota", "means": "Out of widgets.", "fix": "Buy widgets.", "weight": 3}, {"match": "(unclosed"}], "ignore": ["healthz"]})
	check.call("bob skips a bad custom regex", rules["bad"], 1)
	var log = "INFO  starting\nINFO  GET /healthz 500 connection refused\nERROR db handshake failed: connection refused (10.0.0.5:5432)\nERROR db handshake failed: connection refused (10.0.0.5:5432)\nFATAL giving up, exiting with code 137\nWARN  widget quota exceeded"
	var found = Bob.rank(Bob.review(log, "log", rules), 6)
	var by = {}
	for f in found:
		by[f["rule"]] = f
	check.call("bob finds the refused connection", by.has("refused"), true)
	check.call("bob points at its last line", by["refused"]["n"], 4)
	check.call("bob counts repeats, ignoring ignored lines", by["refused"]["count"], 2)
	check.call("bob reads the exit code", by["exit"]["means"].contains("SIGKILL"), true)
	check.call("bob applies a custom rule", by["custom-1"]["means"], "Out of widgets.")
	check.call("bob ranks causes above symptoms", found[found.size() - 1]["weight"], 1)
	check.call("bob verdict names the cause", Bob.verdict(found).begins_with("Found it"), true)
	check.call("bob verdict on a clean log", Bob.verdict(Bob.rank(Bob.review("INFO  all good\nINFO  GET / 200", "log", rules), 6)).contains("nothing jumps out"), true)
	var ev = Bob.rank(Bob.review("Warning   Failed      Failed to pull image \"a:latset\": manifest unknown\nWarning   Failed      Error: ImagePullBackOff", "events", rules), 6)
	check.call("bob reads a bad image from events", ev[0]["rule"] + "/" + str(ev[0]["count"]), "image/2")
	check.call("bob config defaults", Bob.config()["log_review"], true)
	# every setup Porter offers ships both of its files
	for app in Apps.APPS:
		for flavor in ["k8s", "compose"]:
			check.call("app file %s.%s" % [app["id"], flavor], FileAccess.file_exists("res://apps/%s.%s.yaml" % [app["id"], flavor]) or FileAccess.file_exists(Apps.file_for(app["id"], flavor)), true)
	check.call("porter offers the media suite", Apps.find("media")["sim"].size(), 10)
	check.call("media suite has jackett", Apps.find("media")["sim"].filter(func(x): return x[1] == "jackett").size(), 1)
	var Demo = load("res://scripts/backend_demo.gd")
	var home = Demo.new("homelab-media").fetch()
	var names = {}
	for hp in home["pods"]:
		names[hp["wname"]] = hp["health"]
	check.call("homelab runs plex", names.has("plex"), true)
	check.call("homelab runs sonarr and radarr", names.has("sonarr") and names.has("radarr"), true)
	check.call("homelab runs grafana and cadvisor", names.has("grafana") and names.has("cadvisor"), true)
	check.call("homelab has nothing failing", home["pods"].filter(func(x): return x["health"] == "bad").size(), 0)
	check.call("demo types", Demo.DEMO_TYPES.size(), 4)
	check.call("demo id to flavor", Demo.demo_flavor("media") + " " + Demo.demo_flavor("home-assistant") + " " + Demo.demo_flavor("nope"), "homelab-media home-assistant ")
	for dt in Demo.DEMO_TYPES:
		var dst = Demo.new(dt["flavor"]).fetch()
		check.call("demo %s has pods" % dt["id"], dst["pods"].size() > 8, true)
	var ha = {}
	for hp in Demo.new("home-assistant").fetch()["pods"]:
		ha[hp["wname"]] = true
	check.call("home assistant stack", ha.has("homeassistant") and ha.has("zigbee2mqtt") and ha.has("mosquitto"), true)
	var dv = {}
	for hp in Demo.new("dev-containers").fetch()["pods"]:
		dv[hp["wname"]] = true
	check.call("dev containers stack", dv.has("devcontainer-cpp") and dv.has("buildkitd") and dv.has("gitea"), true)
	# graphics presets: hardware classes, and the preset never reaches below Standard
	var Gfx = load("res://scripts/gfx.gd")
	check.call("gpu high-end nvidia", Gfx.gpu_class("NVIDIA GeForce RTX 5070 Ti Laptop GPU"), 3)
	check.call("gpu mid nvidia", Gfx.gpu_class("NVIDIA GeForce RTX 3050"), 2)
	check.call("gpu old nvidia", Gfx.gpu_class("NVIDIA GeForce GTX 1050 Ti"), 1)
	check.call("gpu high-end amd", Gfx.gpu_class("AMD Radeon RX 7800 XT"), 3)
	check.call("gpu mid amd", Gfx.gpu_class("AMD Radeon RX 6600"), 2)
	check.call("gpu integrated intel", Gfx.gpu_class("Intel(R) UHD Graphics 620"), 1)
	check.call("gpu integrated amd", Gfx.gpu_class("AMD Radeon(TM) Graphics"), 1)
	check.call("gpu unknown", Gfx.gpu_class("Some Future Card"), 0)
	check.call("preset ids", Gfx.level_of("ultra") * 10 + Gfx.level_of("nonsense"), 20)
	Gfx.setup("enhanced", ["--gfx=ultra"])
	check.call("--gfx wins over the saved choice (headless is the light path)", Gfx.chosen + "/" + str(Gfx.detail()), "ultra/0")
	Gfx.setup("auto", [])
	# ---- storage inspection helpers
	var ls = K.parse_ls("total 12\ndrwxr-xr-x 2 root root 4096 Nov  3 10:12 .\ndrwxr-xr-x 3 root root 4096 Nov  3 10:12 ..\n-rw-r--r-- 1 app  app   1532 Nov  3 10:12 my file.conf\ndrwx------ 2 999  999   4096 Oct 30  2025 pgdata\nlrwxrwxrwx 1 root root    11 Nov  3 10:12 current -> ../outside\n")
	check.call("ls entries (dot dirs dropped)", ls.size(), 3)
	check.call("ls name with a space", ls[0]["name"] + "|" + ls[0]["type"] + "|" + str(ls[0]["size"]), "my file.conf|file|1532")
	check.call("ls dir", ls[1]["name"] + "|" + ls[1]["type"], "pgdata|dir")
	check.call("ls link target kept apart", ls[2]["name"] + "|" + ls[2]["type"] + "|" + ls[2]["link"], "current|link|../outside")
	check.call("path inside", K.path_inside("/var/lib/data/", "a/./b"), "/var/lib/data/a/b")
	check.call("path at mount root", K.path_inside("/data", ""), "/data")
	check.call("path escape refused", K.path_inside("/data", "a/../../etc/passwd"), "")
	check.call("path escape with backslashes refused", K.path_inside("/data", "..\\secret"), "")
	check.call("bytes", K.fmt_bytes(512) + " " + K.fmt_bytes(65536) + " " + K.fmt_bytes(3221225472.0), "512 B 64.0 KiB 3.00 GiB")
	# ---- LiveView endpoint discovery
	var Live = load("res://scripts/liveview.gd")
	var eps = Live.endpoints({"pods": [{"name": "grafana", "ns": "mon", "ip": "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp, 0.0.0.0:9443->9443/tcp, 5432/tcp"}]}, "docker")
	check.call("docker endpoints: published ports only, once each", eps.size(), 2)
	check.call("docker url", eps[0]["url"] + " " + eps[1]["url"], "http://127.0.0.1:3000/ https://127.0.0.1:9443/")
	eps = Live.endpoints({"services": [
		{"name": "grafana", "ns": "mon", "selector": {"app": "grafana"}, "ports": "3000/TCP"},
		{"name": "db", "ns": "shop", "selector": {"app": "db"}, "ports": "5432/TCP"},
		{"name": "dns", "ns": "kube-system", "selector": {"k": "v"}, "ports": "53/UDP,53/TCP,9153/TCP"},
		{"name": "external", "ns": "shop", "selector": {}, "ports": "80/TCP"}]}, "kubernetes")
	check.call("kubernetes endpoints: http-looking ports of selected services", eps.size(), 2)
	check.call("kubernetes endpoint needs a forward, has no url yet", eps[0]["kind"] + "|" + eps[0]["url"] + "|" + str(eps[1]["port"]), "forward||9153")
	check.call("simulation offers nothing", Live.endpoints({"services": [{"name": "a", "ns": "b", "selector": {"x": "y"}, "ports": "80/TCP"}]}, "simulation").size(), 0)
	# ---- model library
	var Models = load("res://scripts/models.gd")
	if Models.root() != "":
		check.call("library size", Models.ids().size(), 141)
		check.call("krew and machines", "%d/%d" % [Models.ids("krew").size(), Models.ids("machines").size()], "15/25")
		var missing = []
		for id in Models.ids():
			for tier in Models.TIERS:
				var v = Models.entry(id).get("variants", {}).get(tier)
				if v == null or not FileAccess.file_exists(Models.root().path_join(str(v["path"]).trim_prefix("assets/"))):
					missing.append(id + ":" + tier)
		check.call("every model has a file at every tier", missing, [])
		check.call("database image -> database server", Models.machine_for({"wkind": "Deployment", "containers": [{"image": "postgres:16"}]}), "database_server")
		check.call("statefulset kind", Models.machine_for({"wkind": "StatefulSet", "containers": [{"image": "example/app:1"}]}), "statefulset")
		check.call("bare pod", Models.machine_for({"wkind": "Pod", "containers": [{"image": "example/app:1"}]}), "pod_machine")
		for id in Models.ids("machines"):
			var scene = Models._load_scene(id, "standard")
			if scene == null:
				fails.append("machine model does not load: " + id)
			else:
				scene.free()
	else:
		print("NOTE model library not present: its checks were skipped")
	if fails.is_empty():
		print("ALL CHECKS PASSED")
	else:
		for f in fails:
			print("FAIL ", f)
	quit(0 if fails.is_empty() else 1)
