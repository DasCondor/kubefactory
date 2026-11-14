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
	# ---- Krew: the facts every source reports
	check.call("floating tags", [K.floating_tag("nginx"), K.floating_tag("nginx:latest"), K.floating_tag("registry:5000/app"), K.floating_tag("nginx:1.27"), K.floating_tag("x@sha256:ab"), K.floating_tag("")], [true, true, true, false, false, false])
	var ksec = K.pod_security({"hostNetwork": true, "securityContext": {"runAsUser": 0},
		"volumes": [{"name": "sock", "hostPath": {"path": "/var/run/docker.sock"}}, {"name": "logs", "hostPath": {"path": "/var/log"}}, {"name": "cfg", "configMap": {"name": "x"}}],
		"initContainers": [{"name": "init", "image": "busybox:1.36"}],
		"containers": [{"name": "app", "image": "nginx", "securityContext": {"privileged": true, "capabilities": {"add": ["SYS_ADMIN", "CHOWN"]}}, "ports": [{"containerPort": 80, "hostPort": 8080}]},
			{"name": "side", "image": "envoy:v1.31", "securityContext": {"runAsUser": 1000}}]})
	check.call("pod facts: privileged, socket, host paths", [ksec["privileged"], ksec["docker_socket"], ksec["host_paths"]], [["app"], true, ["/var/run/docker.sock", "/var/log"]])
	check.call("pod facts: pod-level root applies unless a container overrides it", ksec["root"], ["init", "app"])
	check.call("pod facts: only powerful capabilities, floating tag, host port", [ksec["caps"], ksec["latest"], ksec["host_ports"], ksec["host_network"]], [["app: SYS_ADMIN"], ["app: nginx"], [8080], true])
	check.call("pod facts: nothing stated, nothing recorded", K.pod_security({"containers": [{"name": "a", "image": "a:1"}]}) == K.empty_security(), true)
	var dsec = K.container_security({"Name": "/web", "HostConfig": {"Privileged": false, "NetworkMode": "bridge", "CapAdd": ["NET_ADMIN"],
		"PortBindings": {"80/tcp": [{"HostIp": "", "HostPort": "8099"}]}}, "Config": {"User": "root", "Image": "web:latest"},
		"Mounts": [{"Type": "bind", "Source": "/var/run/docker.sock"}, {"Type": "volume", "Source": "/var/lib/docker/volumes/x"}]})
	check.call("container facts", [dsec["docker_socket"], dsec["host_paths"], dsec["root"], dsec["caps"], dsec["latest"], dsec["host_ports"], dsec["all_interfaces"]],
		[true, ["/var/run/docker.sock"], ["web"], ["web: NET_ADMIN"], ["web: web:latest"], [8099], true])
	check.call("container facts: a port on 127.0.0.1 is not on every address",
		K.container_security({"HostConfig": {"PortBindings": {"80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8099"}]}}})["all_interfaces"], false)
	# ---- Krew: the rules
	var KrewM = load("res://scripts/krew.gd")
	var now = 1000000.0
	var sec_priv = K.empty_security()
	sec_priv["privileged"] = ["proxy"]
	sec_priv["host_network"] = true
	var sec_sock = K.empty_security()
	sec_sock["docker_socket"] = true
	sec_sock["host_paths"] = ["/var/run/docker.sock"]
	var kst = {"source": "kubernetes", "nodes": [{"name": "n1", "ready": true, "cordoned": false, "roles": "worker", "cpu": 4.0, "mem": 8e9, "cpu_req": 3.8, "mem_req": 1e9}],
		"pods": [
			{"uid": "u1", "name": "proxy-a", "ns": "kube-system", "wname": "kube-proxy", "wkind": "DaemonSet", "node": "n1", "status": "Running", "health": "ok", "restarts": 0, "ready": true, "labels": {"k8s-app": "kube-proxy"}, "sec": sec_priv, "phase": "Running"},
			{"uid": "u2", "name": "proxy-b", "ns": "kube-system", "wname": "kube-proxy", "wkind": "DaemonSet", "node": "n1", "status": "Running", "health": "ok", "restarts": 0, "ready": true, "labels": {"k8s-app": "kube-proxy"}, "sec": sec_priv, "phase": "Running"},
			{"uid": "u3", "name": "ci-1", "ns": "ci", "wname": "builder", "wkind": "Deployment", "node": "n1", "status": "Running", "health": "ok", "restarts": 0, "ready": true, "labels": {"app": "builder"}, "sec": sec_sock, "phase": "Running"},
			{"uid": "u4", "name": "api-1", "ns": "shop", "wname": "api", "wkind": "Deployment", "node": "n1", "status": "CrashLoopBackOff", "health": "bad", "restarts": 7, "ready": false, "labels": {"app": "api"}, "sec": K.empty_security(), "phase": "Running"},
			{"uid": "u5", "name": "migrate-x", "ns": "shop", "wname": "migrate", "wkind": "Job", "node": "n1", "status": "Completed", "health": "done", "restarts": 0, "ready": false, "labels": {}, "sec": K.empty_security(), "phase": "Succeeded", "finished": now - 7200.0},
			{"uid": "u6", "name": "migrate-y", "ns": "shop", "wname": "migrate", "wkind": "Job", "node": "n1", "status": "Completed", "health": "done", "restarts": 0, "ready": false, "labels": {}, "sec": K.empty_security(), "phase": "Succeeded", "finished": now - 60.0}],
		"services": [{"name": "api", "ns": "shop", "type": "ClusterIP", "ports": "80/TCP", "selector": {"app": "api"}},
			{"name": "search", "ns": "shop", "type": "ClusterIP", "ports": "9200/TCP", "selector": {"app": "search"}},
			{"name": "web", "ns": "shop", "type": "LoadBalancer", "ports": "443/TCP", "selector": {"app": "api"}},
			{"name": "manual", "ns": "shop", "type": "ClusterIP", "ports": "80/TCP", "selector": {}}], "workloads": []}
	var kf = KrewM.analyze(kst, {}, now)
	var fk = func(k): return kf.get(k, {})
	check.call("Sentinel: a privileged system DaemonSet is one finding, lowered, with both replicas", [fk.call("sentinel:privileged:kube-system/kube-proxy").get("severity"), fk.call("sentinel:privileged:kube-system/kube-proxy").get("uids")], ["medium", ["u1", "u2"]])
	check.call("Sentinel: the engine socket outside the system namespaces is high", fk.call("sentinel:engine-socket:ci/builder").get("severity"), "high")
	check.call("Sentinel: the socket is not also counted as a host path", kf.has("sentinel:host-path:ci/builder"), false)
	check.call("Sentinel proposes, never acts", kf.values().filter(func(f): return f["worker"] == "sentinel" and not f["action"].is_empty()).size(), 0)
	check.call("Scout: a Service selecting nothing", fk.call("scout:no-pods:shop/search").get("severity"), "medium")
	check.call("Scout: a Service whose pods are all failing", fk.call("scout:no-ready:shop/api").get("severity"), "high")
	check.call("Scout: exposure noted, a hand-managed Service left alone", [fk.call("scout:exposed:shop/web").get("severity"), kf.has("scout:no-pods:shop/manual")], ["info", false])
	check.call("Bob: the crash loop", kf.has("bob:CrashLoopBackOff:shop/api-1"), true)
	check.call("Gauge: requests at 95% of a node's CPU", fk.call("gauge:requests-cpu:node/n1").get("severity"), "medium")
	check.call("Scrappy: a finished pod after an hour, with an approvable removal", fk.call("scrappy:finished:shop/migrate-x").get("action"), {"op": "delete_pod", "ns": "shop", "name": "migrate-x"})
	check.call("Scrappy: one that just finished is left alone", kf.has("scrappy:finished:shop/migrate-y"), false)
	var scan_r = {"ok": true, "data": {"images": [{"id": "sha256:aaaaaaaaaaaa1111", "repo": "old", "tag": "1", "size": 2e8, "unique": 5e7, "containers": 0},
		{"id": "sha256:bbbbbbbbbbbb2222", "repo": "live", "tag": "2", "size": 2e8, "unique": 5e7, "containers": 1}],
		"volumes": [{"name": "data", "links": 0, "size": 3e9}, {"name": "used", "links": 1, "size": 1e6}]}}
	var sf = KrewM.analyze({"source": "docker", "nodes": [], "pods": [], "services": []}, scan_r, now)
	check.call("Scrappy: an unused image, removable; a used one not reported", [sf.get("scrappy:unused-image:image/aaaaaaaaaaaa", {}).get("action", {}).get("op"), sf.has("scrappy:unused-image:image/bbbbbbbbbbbb")], ["remove_image", false])
	check.call("Scrappy: an unattached volume is reported, never offered for removal", [sf.get("scrappy:unattached-volume:volume/data", {}).get("action"), sf.has("scrappy:unattached-volume:volume/used")], [{}, false])
	check.call("Gauge has nothing to say about Docker requests", sf.keys().filter(func(k): return str(k).begins_with("gauge")).size(), 0)
	# ---- Krew: the manager keeps first-seen times and records what got resolved
	var km = KrewM.new()
	km.update(kst, now)
	var first = km.findings["scout:no-pods:shop/search"]["first_seen"]
	var kst2 = kst.duplicate(true)
	kst2["services"].remove_at(1)
	km.update(kst2, now + 30.0)
	check.call("Krew: a lasting finding keeps its first-seen time", km.findings["scout:no-ready:shop/api"]["first_seen"], now)
	check.call("Krew: a finding that is gone is resolved, with its time", [km.findings.has("scout:no-pods:shop/search"), km.history[0]["key"], km.history[0]["resolved_at"]], [false, "scout:no-pods:shop/search", now + 30.0])
	check.call("Krew: worst first", km.of_worker("")[0]["severity"], "high")
	check.call("Krew: a changed source starts afresh", (func(): km.update({"source": "simulation", "nodes": [], "pods": [], "services": []}, now); return km.findings.size()).call(), 0)
	km.update(kst, now)
	var rep = km.report_markdown()
	check.call("Krew report: Markdown carries the findings", rep.contains("Service shop/search selects no pods") and rep.contains("## SENTINEL (Security)"), true)
	check.call("Krew report: JSON reads back", typeof(JSON.parse_string(km.report_json())), TYPE_DICTIONARY)
	km.free()
	# ---- Foreman: incidents, redaction, and what a model may propose
	var FM = load("res://scripts/foreman.gd")
	var km2 = KrewM.new()
	km2.update(kst, now)
	var incs = FM.incidents(km2)
	check.call("Foreman: one incident per resource, worst first", [incs[0]["severity"], incs.size() < km2.findings.size()], ["high", true])
	var proxy_inc = incs.filter(func(i): return i["resource"] == "kube-system/kube-proxy")
	check.call("Foreman: a resource seen by one worker twice is one incident", [proxy_inc.size(), proxy_inc[0]["findings"].size() >= 2], [1, true])
	check.call("Foreman: incident ids are stable", FM.incidents(km2)[0]["id"], incs[0]["id"])
	check.call("Foreman: the brief counts proposals awaiting approval", FM.brief(km2, kst).contains("await"), true)
	check.call("Foreman: redaction", FM.redact("password=hunter2 token: abc.def Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.x https://bob:pw@db.local/x sk-abcdefghijklmnop1234"),
		"password=[redacted] token: [redacted] Authorization: [redacted] [redacted] https://[redacted]@db.local/x [redacted]")
	check.call("Foreman: redaction keeps ordinary text", FM.redact("Deployment shop/api has 3 replicas, 0 ready"), "Deployment shop/api has 3 replicas, 0 ready")
	var kwl = kst.duplicate(true)
	kwl["workloads"] = [{"kind": "Deployment", "ns": "shop", "name": "api", "replicas": 3, "ready": 0}]
	var ctx = FM.build_context(kwl, km2)
	check.call("Foreman: the context names exact resources and the findings", [ctx.contains("shop/Deployment/api 3 0"), ctx.contains("scout:no-pods:shop/search"), ctx.length() <= FM.MAX_CONTEXT + 60], [true, true, true])
	var reply = 'Sure. {"answer": "api is crash-looping.", "actions": [' + \
		'{"tool": "restart_workload", "args": {"namespace": "shop", "kind": "Deployment", "name": "api"}, "why": "w"},' + \
		'{"tool": "scale_workload", "args": {"namespace": "shop", "kind": "Deployment", "name": "api", "replicas": 2}},' + \
		'{"tool": "scale_workload", "args": {"namespace": "shop", "kind": "Deployment", "name": "api", "replicas": 500}},' + \
		'{"tool": "restart_workload", "args": {"namespace": "shop", "kind": "Deployment", "name": "ghost"}},' + \
		'{"tool": "execute_shell", "args": {"cmd": "rm -rf /"}},' + \
		'{"tool": "krew_proposal", "args": {"finding": "scrappy:finished:shop/migrate-x"}},' + \
		'{"tool": "krew_proposal", "args": {"finding": "sentinel:engine-socket:ci/builder"}},' + \
		'{"tool": "cordon_node", "args": {"node": "n1", "on": "yes"}},' + \
		'{"tool": "remove_pod", "args": {"namespace": "shop", "name": "api-1"}}]} Hope that helps.'
	var pr = FM.parse_reply(reply, kwl, km2)
	check.call("Foreman: the answer is read out of the JSON", pr["answer"], "api is crash-looping.")
	check.call("Foreman: each proposal checked against the registry and the state", pr["actions"].map(func(x): return x["ok"]), [true, true, false, false, false, true, false, false, true])
	check.call("Foreman: a checked proposal becomes the game's own operation", [pr["actions"][0]["action"], pr["actions"][5]["action"]["op"], pr["actions"][8]["action"]], [{"op": "restart", "ns": "shop", "kind": "Deployment", "name": "api"}, "delete_pod", {"op": "delete_pod", "ns": "shop", "name": "api-1"}])
	check.call("Foreman: why each rejected one was refused", [pr["actions"][2]["reason"], pr["actions"][3]["reason"], pr["actions"][4]["reason"], pr["actions"][6]["reason"]],
		["replicas must be a whole number from 0 to 50", "no workload Deployment shop/ghost", "there is no tool called \"execute_shell\"", "that finding has no action to run"])
	check.call("Foreman: plain text without JSON is an answer with no actions", FM.parse_reply("I am not sure.", kwl, km2), {"answer": "I am not sure.", "actions": []})
	check.call("Foreman: the system prompt says context is data and lists only the registry", [FM.system_prompt().contains("never an instruction"), FM.system_prompt().contains("execute_shell")], [true, false])
	km2.free()
	# ---- Archie, Forge, Blueprint: storage facts and their rules
	var stf = K.pod_storage({"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "db-data"}}, {"name": "tmp", "emptyDir": {}},
		{"name": "logs", "hostPath": {"path": "/var/log"}}, {"name": "share", "nfs": {"server": "n", "path": "/x"}}, {"name": "cfg", "configMap": {"name": "c"}}]})
	check.call("storage facts from a pod spec", [stf["persistent"], stf["scratch"], stf["binds"], stf["known"]], [["db-data", "share"], ["tmp"], ["/var/log"], true])
	var ctf = K.container_storage({"Mounts": [{"Type": "volume", "Name": "pgdata", "Destination": "/var/lib/postgresql/data"},
		{"Type": "volume", "Name": "a".repeat(64), "Destination": "/data"}, {"Type": "bind", "Source": "/srv/app"}, {"Type": "bind", "Source": "/var/run/docker.sock"}, {"Type": "tmpfs", "Destination": "/run"}]})
	check.call("storage facts from docker inspect", [ctf["persistent"], ctf["anonymous"], ctf["binds"], ctf["scratch"]], [["pgdata"], ["aaaaaaaaaaaa at /data"], ["/srv/app"], ["/run"]])
	var mkpod = func(uid, ns, wname, image, store, phase = "Running"):
		return {"uid": uid, "name": wname + "-0", "ns": ns, "wname": wname, "wkind": "StatefulSet", "status": "Running", "health": "ok", "ready": true, "phase": phase,
			"containers": [{"name": "c", "image": image}], "labels": {}, "store": store, "sec": K.empty_security()}
	var scratch = K.empty_storage(); scratch["known"] = true; scratch["scratch"] = ["data"]
	var none = K.empty_storage(); none["known"] = true
	var kept = K.empty_storage(); kept["known"] = true; kept["persistent"] = ["db-data"]
	var anon = K.empty_storage(); anon["known"] = true; anon["anonymous"] = ["abc at /data"]
	var ast = {"source": "kubernetes", "nodes": [], "services": [], "workloads": [], "pods": [
		mkpod.call("a1", "shop", "orders-db", "postgres:16", scratch), mkpod.call("a2", "shop", "cache", "redis:7.4", none),
		mkpod.call("a3", "shop", "catalog-db", "postgres:16", kept), mkpod.call("a4", "shop", "web", "nginx:1.27", none),
		mkpod.call("a5", "shop", "mq", "rabbitmq:3", anon), mkpod.call("a6", "shop", "old-db", "mysql:8", K.empty_storage())]}
	var af = KrewM.archie_rules(ast)
	var ak = {}
	for f in af:
		ak[f["key"]] = f
	check.call("Archie: a database on scratch space is high, a bare cache low", [ak.get("archie:no-persistent-storage:shop/orders-db", {}).get("severity"), ak.get("archie:no-persistent-storage:shop/cache", {}).get("severity")], ["high", "low"])
	check.call("Archie: a database with a claim, a stateless web server, and unknown storage are left alone", [ak.has("archie:no-persistent-storage:shop/catalog-db"), ak.keys().any(func(x): return x.ends_with("shop/web")), ak.keys().any(func(x): return x.ends_with("shop/old-db"))], [false, false, false])
	check.call("Archie: a broker whose only volume has no name", [ak.get("archie:no-persistent-storage:shop/mq", {}).get("severity"), ak["archie:no-persistent-storage:shop/mq"]["evidence"][1].contains("no name")], ["medium", true])
	check.call("Archie never offers an action", af.all(func(f): return f["action"].is_empty()), true)
	var fscan = {"ok": true, "data": {"images": [{"id": "sha256:111111111111aaaa", "repo": "myapp", "tag": "dev", "containers": 2, "digests": 0},
		{"id": "sha256:222222222222bbbb", "repo": "nginx", "tag": "1.27", "containers": 1, "digests": 1}, {"id": "sha256:333333333333cccc", "repo": "old", "tag": "1", "containers": 0, "digests": 0}],
		"volumes": [], "build_cache": {"entries": 10, "reclaimable": 2.5e9, "in_use": 1}}}
	var ff = KrewM.forge_rules({"source": "docker", "pods": []}, fscan)
	check.call("Forge: only an image in use with no registry digest, and the idle build cache", ff.map(func(f): return f["key"]), ["forge:local-build:image/111111111111", "forge:build-cache:build-cache"])
	check.call("Forge: nothing without a scan", KrewM.forge_rules({"source": "docker", "pods": []}, {}).size(), 0)
	var bst = {"source": "kubernetes", "nodes": [], "services": [], "pods": [], "workloads": [
		{"kind": "Deployment", "ns": "shop", "name": "api", "replicas": 3, "ready": 1}, {"kind": "Deployment", "ns": "shop", "name": "down", "replicas": 2, "ready": 0},
		{"kind": "Deployment", "ns": "shop", "name": "ok", "replicas": 2, "ready": 2}, {"kind": "Deployment", "ns": "shop", "name": "off", "replicas": 0, "ready": 0},
		{"kind": "Job", "ns": "shop", "name": "once", "replicas": 1, "ready": 0}, {"kind": "Compose", "ns": "blog", "name": "db", "replicas": 2, "ready": 1}]}
	var bk = KrewM.blueprint_rules(bst).map(func(f): return [f["key"], f["severity"]])
	check.call("Blueprint: drift by severity, Jobs and scaled-to-zero left alone", bk, [["blueprint:drift:shop/api", "low"], ["blueprint:drift:shop/down", "medium"], ["blueprint:drift:blog/db", "low"]])
	var bm = KrewM.new()
	bm.update(bst, now)
	check.call("Blueprint: a rollout in progress is not reported at once", bm.findings.has("blueprint:drift:shop/api"), false)
	bm.update(bst, now + 60.0)
	check.call("Blueprint: ... nor after a minute", bm.findings.has("blueprint:drift:shop/api"), false)
	bm.update(bst, now + 130.0)
	check.call("Blueprint: after the hold it is, seen since the start", [bm.findings.has("blueprint:drift:shop/api"), bm.findings.get("blueprint:drift:shop/api", {}).get("first_seen")], [true, now])
	var bst2 = bst.duplicate(true)
	bst2["workloads"][0]["ready"] = 3
	bm.update(bst2, now + 140.0)
	bm.update(bst, now + 150.0)
	check.call("Blueprint: a fresh drift waits again", bm.findings.has("blueprint:drift:shop/api"), false)
	bm.free()
	# ---- Backend plugins: whatever a plugin sends is checked, coerced and capped
	var PB = load("res://scripts/backend_plugin.gd")
	var junk = PB.normalize({"nodes": [{"name": "n1", "cpu": "lots"}, "not a node", {"name": "x".repeat(500)}],
		"pods": [{"name": "a", "node": "nowhere", "status": "CrashLoopBackOff", "labels": {"k": 1}}, 42, {"name": "b", "node": "n1", "containers": [{"name": "c", "image": "i", "restarts": "9"}]}],
		"workloads": "not a list", "services": [{"name": "s", "selector": "app=x"}]}, "test")
	check.call("plugin state: non-objects dropped, names capped", [junk["nodes"].size(), junk["nodes"][1]["name"].length(), junk["pods"].size()], [2, 120, 2])
	check.call("plugin state: a bad number is unknown, not a crash", [junk["nodes"][0]["cpu"], junk["pods"][1]["containers"][0]["restarts"]], [0.0, 0])
	check.call("plugin state: a pod on an unknown node goes to the first node", junk["pods"][0]["node"], "n1")
	check.call("plugin state: health from status, labels as text, a bad selector ignored", [junk["pods"][0]["health"], junk["pods"][0]["labels"], junk["services"][0]["selector"], junk["workloads"]], ["bad", {"k": "1"}, {}, []])
	check.call("plugin state: uids are namespaced by the plugin", junk["pods"][1]["uid"].begins_with("test/"), true)
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
