extends RefCounted
# Log providers for real clusters. The datapad can read a pod's logs from any
# of these; each one reports whether it is ready and, if not, what is missing.
#
#   kube        Kubernetes API (kubectl logs)      - always there, live but short-lived
#   loki        Grafana Loki (HTTP API via curl)   - needs loki.url
#   cloudwatch  AWS CloudWatch Logs (aws CLI)      - needs Container Insights / a log group
#   azure       Azure Monitor (az CLI)             - needs a Log Analytics workspace id
#   gcp         Google Cloud Logging (gcloud CLI)  - works out of the box on GKE
#
# Settings live in config/log-providers.json (beside the exe when installed).

const KU = preload("res://scripts/kutil.gd")

static func load_config() -> Dictionary:
	var cfg = {"hours": 1, "loki": {}, "cloudwatch": {}, "azure": {}, "gcp": {}}
	if true:
		var d = KU.read_json(KU.config_path("log-providers.json"))
		if typeof(d) == TYPE_DICTIONARY:
			for k in d:
				cfg[k] = d[k]
	return cfg

static func has_cli(cli: String) -> bool:
	var out = []
	return OS.execute("where", PackedStringArray([cli]), out, true) == 0

static func _cw_group(cfg: Dictionary, context: String) -> String:
	var g = str(cfg.get("cloudwatch", {}).get("log_group", ""))
	if g == "" and context.contains(":cluster/"):
		# EKS context names are ARNs; Container Insights uses this group by default
		g = "/aws/containerinsights/%s/application" % context.get_slice(":cluster/", 1)
	return g

# -> [{id, name, ready, note}]
static func list_for(provider: String, context: String, cfg: Dictionary) -> Array:
	var res = [{"id": "kube", "name": "Kubernetes API", "ready": true, "note": "live from the kubelet (kubectl logs)"}]
	var loki_url = str(cfg.get("loki", {}).get("url", ""))
	res.append({"id": "loki", "name": "Grafana Loki", "ready": loki_url != "",
		"note": loki_url if loki_url != "" else "not configured: set loki.url in log-providers.json"})
	var p = provider.to_lower()
	var cw = _cw_group(cfg, context)
	if p.contains("aws") or cw != "":
		var ok = cw != "" and has_cli("aws")
		res.append({"id": "cloudwatch", "name": "AWS CloudWatch", "ready": ok,
			"note": cw if ok else ("aws CLI not installed" if cw != "" else "not configured: set cloudwatch.log_group")})
	var ws = str(cfg.get("azure", {}).get("workspace_id", ""))
	if p.contains("azure") or ws != "":
		var ok = ws != "" and has_cli("az")
		res.append({"id": "azure", "name": "Azure Monitor", "ready": ok,
			"note": "workspace " + ws if ok else ("az CLI not installed" if ws != "" else "not configured: set azure.workspace_id")})
	if p.contains("google") or str(cfg.get("gcp", {}).get("project", "")) != "":
		var ok = has_cli("gcloud")
		res.append({"id": "gcp", "name": "Google Cloud Logging", "ready": ok,
			"note": "gcloud logging" if ok else "gcloud CLI not installed"})
	return res

static func _exec(cmd: String, args: Array) -> Dictionary:
	var out = []
	var code = OS.execute(cmd, PackedStringArray(args), out, true)
	return {"code": code, "out": str(out[0]) if out.size() > 0 else ""}

static func fetch(id: String, a: Dictionary, cfg: Dictionary, context: String) -> Dictionary:
	var ns = str(a["ns"])
	var pod = str(a["name"])
	var limit = int(a.get("tail", 200))
	var hours = float(cfg.get("hours", 1))
	var since = Time.get_unix_time_from_system() - hours * 3600.0
	match id:
		"loki":
			var c = cfg.get("loki", {})
			var url = str(c.get("url", "")).trim_suffix("/")
			if url == "":
				return {"ok": false, "text": "Loki is not configured.\nSet loki.url in log-providers.json, e.g. http://localhost:3100"}
			var q = str(c.get("query", "{namespace=\"%NS%\", pod=\"%POD%\"}")).replace("%NS%", ns).replace("%POD%", pod)
			var args = ["-s", "-S", "-G", "--max-time", "20", url + "/loki/api/v1/query_range",
				"--data-urlencode", "query=" + q, "--data-urlencode", "limit=%d" % limit,
				"--data-urlencode", "direction=backward", "--data-urlencode", "start=%d000000000" % int(since)]
			var secrets = []
			if str(c.get("tenant", "")) != "":
				secrets.append(["header", "X-Scope-OrgID: " + str(c["tenant"])])
			if str(c.get("user", "")) != "":
				secrets.append(["user", str(c["user"])])
			var r = KU.curl(args, secrets)
			var d = JSON.parse_string(r.out)
			if r.code != 0 or typeof(d) != TYPE_DICTIONARY or d.get("status", "") != "success":
				return {"ok": false, "text": "Loki query failed (%s)\n%s\n\nquery: %s" % [url, r.out.left(600), q]}
			var rows = []
			for stream in d.get("data", {}).get("result", []):
				for v in stream.get("values", []):
					rows.append([str(v[0]), str(v[1])])
			rows.sort_custom(func(x, y): return x[0] < y[0])
			var lines = []
			for row in rows:
				lines.append("%sZ %s" % [Time.get_datetime_string_from_unix_time(int(row[0].left(row[0].length() - 9).to_int())), row[1].strip_edges()])
			return {"ok": true, "text": "\n".join(PackedStringArray(lines)) if lines.size() > 0 else "(Loki returned no lines for %s in the last %sh)" % [q, str(hours)]}
		"cloudwatch":
			var c = cfg.get("cloudwatch", {})
			var args = ["logs", "filter-log-events", "--log-group-name", _cw_group(cfg, context),
				"--log-stream-name-prefix", pod, "--start-time", "%d000" % int(since),
				"--limit", str(limit), "--output", "json"]
			if str(c.get("region", "")) != "":
				args.append_array(["--region", str(c["region"])])
			var r = _exec("aws", args)
			var d = JSON.parse_string(r.out)
			if r.code != 0 or typeof(d) != TYPE_DICTIONARY:
				return {"ok": false, "text": "CloudWatch query failed\n" + r.out.left(800)}
			var lines = []
			for e in d.get("events", []):
				var msg = str(e.get("message", ""))
				var inner = JSON.parse_string(msg)
				if typeof(inner) == TYPE_DICTIONARY and inner.has("log"):
					msg = str(inner["log"])
				lines.append("%sZ %s" % [Time.get_datetime_string_from_unix_time(int(float(e.get("timestamp", 0)) / 1000.0)), msg.strip_edges()])
			return {"ok": true, "text": "\n".join(PackedStringArray(lines)) if lines.size() > 0 else "(CloudWatch has no events for this pod in the last %sh)" % str(hours)}
		"azure":
			var ws = str(cfg.get("azure", {}).get("workspace_id", ""))
			var kql = "ContainerLogV2 | where PodNamespace == '%s' and PodName == '%s' | top %d by TimeGenerated desc | order by TimeGenerated asc | project TimeGenerated, LogMessage" % [ns, pod, limit]
			var r = _exec("cmd.exe", ["/c", "az", "monitor", "log-analytics", "query", "-w", ws,
				"--analytics-query", kql, "--timespan", "PT%dH" % int(maxf(hours, 1.0)), "-o", "tsv"])
			return {"ok": r.code == 0, "text": r.out if r.out.strip_edges() != "" else "(Azure Monitor returned no rows)"}
		"gcp":
			var filt = "resource.type=k8s_container AND resource.labels.namespace_name=%s AND resource.labels.pod_name=%s" % [ns, pod]
			var args = ["/c", "gcloud", "logging", "read", filt, "--limit", str(limit),
				"--freshness", "%dh" % int(maxf(hours, 1.0)), "--format", "value(timestamp,textPayload)"]
			if str(cfg.get("gcp", {}).get("project", "")) != "":
				args.append_array(["--project", str(cfg["gcp"]["project"])])
			var r = _exec("cmd.exe", args)
			var lines = r.out.strip_edges().split("\n")
			lines.reverse()
			return {"ok": r.code == 0, "text": "\n".join(lines) if r.out.strip_edges() != "" else "(Cloud Logging returned no entries)"}
	return {"ok": false, "text": "unknown log provider " + id}
