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
	var Gauge = load("res://scripts/gauge.gd")
	var grows = Gauge.node_rows(st)
	check.call("Gauge uses visible container requests", grows[0]["cpu_requested"], 0.25)
	check.call("Gauge reports allocatable CPU", grows[0]["cpu"], 1.93)
	var docker_rows = Gauge.node_rows({"source": "docker", "nodes": [{"name": "host", "cpu": 4.0, "mem": 0.0, "cpu_req": 0.0, "mem_req": 0.0}]})
	check.call("Gauge does not invent Docker request totals", docker_rows[0]["cpu_requested"], null)
	check.call("Gauge does not invent missing capacity", docker_rows[0]["memory"], null)
	var hidden = Gauge.node_rows({"source": "kubernetes", "nodes": [{"name": "hidden", "roles": "node details hidden", "ready": true, "cpu_req": 0.0, "mem_req": 0.0}]})[0]
	check.call("Gauge does not invent hidden node readiness or requests", hidden["ready"] == null and hidden["cpu_requested"] == null and hidden["memory_requested"] == null, true)
	check.call("Gauge filters formatted units", Gauge.node_matches(grows[0], "0.25 cores") and Gauge.node_matches(grows[0], "128.0 MiB"), true)
	check.call("Gauge filters unavailable values", Gauge.node_matches(docker_rows[0], "unavailable"), true)
	check.call("Gauge distinguishes missing usage from zero", Gauge.reading({"ok": true, "data": {"cpu_cores": 0.0}}).contains("0.00 cores") and Gauge.reading({"ok": true, "data": {}}).contains("unavailable"), true)
	check.call("Gauge identifies simulated usage", Gauge.reading({"ok": true, "data": {"simulated": true}}).contains("SIMULATED"), true)
	check.call("Gauge exposes usage failures", Gauge.reading({"ok": false, "msg": "metrics API absent"}), "Unavailable: metrics API absent")
	var Docker = load("res://scripts/backend_docker.gd")
	var partial = Docker._usage_data({"CPUPerc": "0.00%", "MemUsage": "bad / 1GiB", "NetIO": "3kB / invalid", "BlockIO": ""})
	check.call("Docker keeps reported zero", partial.get("cpu_cores"), 0.0)
	check.call("Docker omits invalid or absent measurements", not partial.has("mem_bytes") and not partial.has("net_tx_bytes") and not partial.has("disk_read_bytes"), true)
	check.call("Docker retains valid partial counters", partial.get("net_rx_bytes"), 3000.0)
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
	# ---- KubeFactory.exe --kubeconfig <file>
	var Conn = load("res://scripts/connections.gd")
	check.call("--kubeconfig <file>", Conn.cli_kubeconfig(["--verbose", "--kubeconfig", "C:\\k\\prod.yaml", "--read-only"]), "C:/k/prod.yaml")
	check.call("--kubeconfig=<file>", Conn.cli_kubeconfig(["--kubeconfig=C:/k/prod.json"]), "C:/k/prod.json")
	check.call("the last one named wins", Conn.cli_kubeconfig(["--kubeconfig=C:/a.yaml", "--kubeconfig", "C:/b.yaml"]), "C:/b.yaml")
	check.call("no kubeconfig named", Conn.cli_kubeconfig(["--demo", "--gfx=ultra"]), "")
	check.call("a bare file that exists (dropped on the exe)", Conn.cli_kubeconfig([ProjectSettings.globalize_path("res://tests/fixture.json")]).get_file(), "fixture.json")
	check.call("a bare name that is not a file is ignored", Conn.cli_kubeconfig(["nothing-here.yaml"]), "")
	# ---- LiveView providers
	var Prov = load("res://scripts/providers.gd")
	var pst = {"pods": [
		{"name": "grafana-1", "ns": "mon", "uid": "u1", "ip": "0.0.0.0:3001->3000/tcp", "containers": [{"image": "grafana/grafana:11.2.0"}]},
		{"name": "web", "ns": "shop", "uid": "u2", "ip": "0.0.0.0:3000->3000/tcp", "containers": [{"image": "example/web:1"}]},
		{"name": "tautulli-1", "ns": "media", "uid": "u3", "ip": "", "containers": [{"image": "ghcr.io/tautulli/tautulli:v2.14"}]},
		{"name": "plex-1", "ns": "media", "uid": "u4", "ip": "", "containers": [{"image": "plexinc/pms-docker:latest"}]}]}
	var cands = Prov.candidates(pst, "docker")
	check.call("candidates by image, never by port 3000", cands.size(), 2)
	check.call("docker candidate address from its published port", cands[0]["type"] + " " + cands[0]["url"], "grafana http://127.0.0.1:3001")
	check.call("no address is guessed for a cluster pod", Prov.candidates(pst, "kubernetes")[0]["url"], "")
	check.call("media machines", Prov.media_machines(pst).size(), 2)
	var lines = Prov.summary_lines({"streams": 3.0, "transcode": 0.0, "total_kbps": 18250.0, "lan_kbps": 640.0})
	check.call("a count", lines[0][1], "3")
	check.call("zero is zero", lines[3][1], "0")
	check.call("a missing count is unavailable, not zero", lines[1][1], "unavailable")
	check.call("bandwidth", lines[4][1] + " / " + lines[5][1] + " / " + lines[6][1], "18.3 Mbps / 640 kbps / unavailable")
	# ---- simulated screens in the demo worlds
	var DS = load("res://scripts/demo_screens.gd")
	check.call("a Grafana machine shows the dashboard", DS.kind_of({"containers": [{"image": "grafana/grafana:11.2.0"}]}), "grafana")
	check.call("Plex and Tautulli machines show streams", DS.kind_of({"containers": [{"image": "plexinc/pms-docker"}]}) + DS.kind_of({"containers": [{"image": "tautulli/tautulli"}]}), "streamsstreams")
	check.call("any other machine keeps its neutral screen", DS.kind_of({"containers": [{"image": "nginx:1.27"}]}), "")
	var consistent = true
	for ti in 400:
		var sa = DS.streams_at(ti * 7.3)
		consistent = consistent and sa["streams"] >= 2 and sa["streams"] <= 5 and sa["direct_play"] + sa["direct_stream"] + sa["transcode"] == sa["streams"] and sa["lan_kbps"] + sa["wan_kbps"] == sa["total_kbps"] and sa["direct_play"] >= 0 and sa["direct_stream"] >= 0
	check.call("simulated streams always add up", consistent, true)
	var fg = DS.cluster_figures({"nodes": [{"name": "a", "cpu": 8.0, "cpu_req": 2.0, "mem": 16.0, "mem_req": 12.0}], "pods": [{"health": "ok"}, {"health": "bad"}, {"health": "warn"}, {"health": "done"}]})
	check.call("dashboard figures come from the simulated cluster", "%.2f %.2f %d %d %d" % [fg["cpu"], fg["mem"], fg["running"], fg["pending"], fg["failing"]], "0.25 0.75 2 1 1")
	# ---- application icons and screen views
	var Ic = load("res://scripts/icons.gd")
	check.call("icon kind by image", Ic.kind_of({"containers": [{"image": "postgres:16"}]}) + " " + Ic.kind_of({"containers": [{"image": "plexinc/pms-docker"}]}) + " " + Ic.kind_of({"containers": [{"image": "linuxserver/sonarr"}]}) + " " + Ic.kind_of({"containers": [{"image": "registry.k8s.io/coredns/coredns:v1"}]}) + " " + Ic.kind_of({"containers": [{"image": "example/thing"}]}), "database media download network app")
	var drawn = true
	for ik in Ic.KINDS:
		var tx = Ic.texture(ik)
		drawn = drawn and tx != null and tx.get_width() == 64 and tx.get_image().get_pixel(32, 4).a > 0.9 and tx.get_image().get_pixel(1, 1).a < 0.1
	check.call("every icon draws: a tile with clear corners", drawn, true)
	var MS = load("res://scripts/machine_screens.gd")
	var mrows = MS.metrics_rows({"status": "Running", "health": "ok", "ns": "shop", "node": "n1", "wkind": "Deployment", "wname": "cart", "restarts": 3, "created": 0.0, "ip": "10.0.0.4",
		"containers": [{"name": "cart", "state": "running", "ready": true, "reason": "", "restarts": 3}, {"name": "sidecar", "state": "waiting", "ready": false, "reason": "CrashLoopBackOff", "restarts": 0}]})
	var mtext = ""
	for mr in mrows:
		mtext += str(mr[0]) + "|"
	check.call("metrics view lists the pod and each container", mtext.contains("Running   ·   shop   ·   n1|") and mtext.contains("owner Deployment/cart   ·   restarts 3") and mtext.contains("cart  running  x3") and mtext.contains("sidecar  CrashLoopBackOff"), true)
	# usage: a cluster that reports CPU and memory only
	var uk = MS.add_usage({}, {"ok": true, "data": {"cpu_cores": 0.42, "mem_bytes": 268435456.0, "source": "metrics.k8s.io"}}, 10.0)
	uk = MS.add_usage(uk, {"ok": true, "data": {"cpu_cores": 1.5, "mem_bytes": 268435456.0, "source": "metrics.k8s.io"}}, 15.0)
	var tk = MS.usage_tiles(uk)
	check.call("usage: cpu and memory from the metrics API", tk[0]["value"] + " | " + tk[1]["value"] + " | " + str(tk[0]["values"].size()), "1.50 cores | 256.0 MiB | 2")
	check.call("usage: network is unavailable there, and says why", tk[2]["value"] + " | " + tk[2]["note"], "unavailable | not reported by the cluster's metrics API")
	check.call("millicores", MS.fmt_cpu(0.42), "420 m")
	# usage: totals become rates only with a second reading
	var ud = MS.add_usage({}, {"ok": true, "data": {"cpu_cores": 0.1, "mem_bytes": 1048576.0, "net_rx_bytes": 1000.0, "net_tx_bytes": 0.0, "disk_read_bytes": 0.0, "disk_write_bytes": 0.0, "source": "docker stats"}}, 100.0)
	check.call("usage: one reading of a total is not a rate yet", MS.usage_tiles(ud)[2]["value"], "measuring...")
	ud = MS.add_usage(ud, {"ok": true, "data": {"cpu_cores": 0.1, "mem_bytes": 1048576.0, "net_rx_bytes": 11240.0, "net_tx_bytes": 5120.0, "disk_read_bytes": 0.0, "disk_write_bytes": 0.0, "source": "docker stats"}}, 105.0)
	check.call("usage: rate from two totals", MS.usage_tiles(ud)[2]["value"] + " | " + MS.usage_tiles(ud)[3]["value"], "3.0 KiB/s | 0 B/s")
	# usage: a refusal is shown, and nothing is put in its place
	var uf = MS.add_usage({}, {"ok": false, "msg": "no usage figures for this pod"}, 1.0)
	check.call("usage: refused -> unavailable on every tile", [MS.usage_tiles(uf)[0]["value"], MS.usage_tiles(uf)[1]["value"], MS.usage_tiles(uf)[2]["value"], uf["error"]], ["unavailable", "unavailable", "unavailable", "no usage figures for this pod"])
	check.call("storage view: nothing mounted", MS.storage_rows([])[0][0], "Nothing is mounted into this workload.")
	check.call("storage view: a refusal is shown as such", MS.storage_rows("not permitted")[0][0], "not permitted")
	var srows = MS.storage_rows([{"path": "/var/lib/data", "type": "pvc", "claim": "data-0", "read_only": false, "readable": true}, {"path": "/var/run/secrets", "type": "projected", "claim": "", "read_only": true, "readable": false}])
	check.call("storage view: mounts, with what is never shown", srows[1][0].strip_edges() + " / " + srows[3][0].strip_edges(), "data-0 / projected   read-only   contents never shown")
	check.call("four views in order", MS.MODES, ["dashboard", "metrics", "logs", "storage"])
	# ---- paths on screen never show the account's folder
	check.call("home folder shown as ~ (Windows)", K.tidy_path("C:\\Users\\someone\\.kube\\config", "C:\\Users\\someone"), "~/.kube/config")
	check.call("home folder shown as ~ (any case, either slash)", K.tidy_path("c:/users/Someone/AppData/Roaming/x", "C:\\Users\\someone"), "~/AppData/Roaming/x")
	check.call("a path elsewhere is left alone", K.tidy_path("D:\\clusters\\prod.yaml", "C:\\Users\\someone"), "D:\\clusters\\prod.yaml")
	check.call("a folder that only starts the same is not the home folder", K.tidy_path("C:/Users/someone-else/x", "C:/Users/someone"), "C:/Users/someone-else/x")
	# The machine's collision box can sit well in front of its visible screen.
	var screen = {"pos": Vector3.ZERO, "normal": Vector3.BACK, "right": Vector3.RIGHT, "up": Vector3.UP, "size": Vector2(2, 1)}
	check.call("screen ray: center from in front", K.ray_hits_screen(Vector3(0, 0, 4), Vector3.FORWARD, screen, 70), true)
	check.call("screen ray: miss the edge", K.ray_hits_screen(Vector3(2, 0, 4), Vector3.FORWARD, screen, 70), false)
	check.call("screen ray: behind the screen", K.ray_hits_screen(Vector3(0, 0, -4), Vector3.BACK, screen, 70), false)
	check.call("screen ray: beyond reach", K.ray_hits_screen(Vector3(0, 0, 4), Vector3.FORWARD, screen, 3), false)
	check.call("screen ray: parallel", K.ray_hits_screen(Vector3(0, 0, 4), Vector3.RIGHT, screen, 70), false)
	check.call("a path inside a message is tidied too", K.tidy_text("cannot read C:\\Users\\someone\\.kube\\config: denied", "C:\\Users\\someone"), "cannot read ~\\.kube\\config: denied")
	check.call("... in either slash style and any case", K.tidy_text("Saved to c:/users/SOMEONE/AppData/x.log and C:\\Users\\someone\\y", "C:\\Users\\someone"), "Saved to ~/AppData/x.log and ~\\y")
	check.call("a message without it is untouched", K.tidy_text("pod not found", "C:\\Users\\someone"), "pod not found")
	# ---- tables: contains and sort by column
	var trows = [{"n": "web", "r": 3, "i": "nginx:1.27"}, {"n": "Cart", "r": 12, "i": "shop/cart"}, {"n": "api", "r": 2, "i": "shop/api"}, {"n": "db", "r": 12, "i": "postgres:16"}]
	var tget = {"n": func(x): return x["n"], "r": func(x): return x["r"], "i": func(x): return x["i"]}
	var tnames = func(a): return ",".join(a.map(func(x): return x["n"]))
	check.call("table: untouched without a sort or a filter", tnames.call(K.table_rows(trows, "", false, "", tget)), "web,Cart,api,db")
	check.call("table: text sorts without regard to case", tnames.call(K.table_rows(trows, "n", false, "", tget)), "api,Cart,db,web")
	check.call("table: numbers sort as numbers, ties keep their order", tnames.call(K.table_rows(trows, "r", false, "", tget)), "api,web,Cart,db")
	check.call("table: reversed", tnames.call(K.table_rows(trows, "r", true, "", tget)), "Cart,db,web,api")
	check.call("table: contains looks in every column, any case", tnames.call(K.table_rows(trows, "", false, "SHOP", tget)), "Cart,api")
	check.call("table: contains then sort", tnames.call(K.table_rows(trows, "n", true, "1", tget)), "web,db,Cart")
	check.call("table: nothing contains it", K.table_rows(trows, "n", false, "zzz", tget).size(), 0)
	var big = []
	for bi in K.TABLE_LIMIT:
		big.append({"n": str(K.TABLE_LIMIT - bi), "r": bi, "i": ""})
	check.call("table: 10000 rows are handed back untouched", K.table_rows(big, "n", false, "5", tget).size() == K.TABLE_LIMIT and K.table_rows(big, "n", false, "", tget)[0]["n"] == str(K.TABLE_LIMIT), true)
	big.pop_back()
	var t0 = Time.get_ticks_msec()
	var sorted_big = K.table_rows(big, "r", true, "", tget)
	check.call("table: 9999 rows sort", sorted_big[0]["r"], K.TABLE_LIMIT - 2)
	print("NOTE sorting 9999 rows took ", Time.get_ticks_msec() - t0, " ms")
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
		check.call("a StatefulSet's pod is a pod", Models.machine_for({"wkind": "StatefulSet", "containers": [{"image": "example/app:1"}]}), "pod_machine")
		check.call("coredns from registry.k8s.io is not a registry", Models.machine_for({"wkind": "Deployment", "containers": [{"image": "registry.k8s.io/coredns/coredns:v1.11.3"}]}), "network_appliance")
		check.call("a pod named frontend is not a load balancer", Models.machine_for({"wkind": "Deployment", "name": "frontend-abc", "wname": "frontend", "containers": [{"image": "helmsman/shop-frontend:2.4.1"}, {"image": "envoyproxy/envoy:v1.31"}]}), "pod_machine")
		check.call("a real registry", Models.machine_for({"wkind": "Deployment", "containers": [{"image": "docker.io/library/registry:2"}]}), "registry_rack")
		check.call("image name", Models.image_name("ghcr.io/org/Redis:7.4@sha256:abc"), "redis")
		check.call("a Docker container", Models.machine_for({"wkind": "Compose", "containers": [{"image": "example/app:1"}]}), "container_machine")
		check.call("bare pod", Models.machine_for({"wkind": "Pod", "containers": [{"image": "example/app:1"}]}), "pod_machine")
		# every file is the one the catalog describes (a changed file must be re-reviewed)
		var wrong = []
		for id in Models.ids():
			for tier in Models.TIERS:
				var v = Models.entry(id)["variants"][tier]
				if FileAccess.get_sha256(Models.root().path_join(str(v["path"]).trim_prefix("assets/"))) != str(v["sha256"]):
					wrong.append(id + ":" + tier)
		check.call("every file matches its catalog hash", wrong, [])
		# the machine contract the game binds to
		var doors = 0
		for id in Models.ids("machines"):
			var tp = Models.template(id, "standard")
			if not (tp.has("screen") and tp.has("name_surface") and tp.has("type_label") and tp.get("core") != null):
				fails.append("machine model lacks a display surface or type label: " + id)
			if tp.has("door"):
				doors += 1
				if not tp["cavity"].has_volume() or tp.get("door_mesh") == null:
					fails.append("machine door without a bay: " + id)
		check.call("machines with a storage door", doors, 22)
		# the handheld tools: aim +Z, display towards the operator (-Z), a grip to hold
		var VM = load("res://scripts/viewmodel.gd")
		for id in VM.LIB_IDS:
			var an = Models.entry(id).get("variants", {}).get("standard", {}).get("anchors", {})
			if not an.has("Grip") or an.get("ToolAim", {}).get("normal") != [0.0, 0.0, 1.0]:
				fails.append("tool model without a grip or not aimed +Z: " + id)
			if an.has("LiveViewSurface") and an["LiveViewSurface"]["normal"] != [0.0, 0.0, -1.0]:
				fails.append("tool display does not face the operator: " + id)
		check.call("reviewer page is in the repo", FileAccess.file_exists("res://tools/model-viewer/index.html"), true)
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
