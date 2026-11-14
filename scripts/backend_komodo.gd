extends RefCounted
# Komodo (komo.do), read-only: every server a Komodo Core manages is a
# platform, every container on it a machine. The companion (agent/komodo.go)
# holds the API key and sends Komodo only read requests; this backend never
# offers an action, so changes stay in Komodo itself.

const K = preload("res://scripts/kutil.gd")
const Agent = preload("res://scripts/agent.gd")

var label = "komodo"
var poll_interval = 6.0
var caps = {"remove_image": false, "scale": false, "delete_pod": false, "restart": false, "delete_workload": false,
	"create": false, "cordon": false, "drain": false, "logs": false, "files": false}
var context = ""           # the connection's name
var conn_id = ""
var log_cfg = {}
var providers = [{"id": "kube", "name": "Komodo", "ready": false, "note": "logs are read in Komodo"}]
var version = ""

func probe() -> Dictionary:
	var r = Agent.request("komodo.test", {"id": conn_id}, 20.0)
	if not r["ok"]:
		return {"ok": false, "msg": r["msg"]}
	version = str(r["data"].get("version", ""))
	return {"ok": true, "msg": context}

func fetch() -> Dictionary:
	var r = Agent.request("komodo.state", {"id": conn_id}, 40.0)
	if not r["ok"]:
		return {"source": label, "context": context, "error": r["msg"], "failed": true}
	return normalize(r["data"], context)

# Komodo's lists -> the state every backend reports. Static so the tests can feed it.
static func normalize(d: Dictionary, ctx: String) -> Dictionary:
	var st = {"source": "komodo", "context": ctx, "provider": "Komodo", "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	var names = {}
	for s in d.get("servers", []):
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var info: Dictionary = s.get("info", {}) if typeof(s.get("info")) == TYPE_DICTIONARY else {}
		var state = str(info.get("state", ""))
		names[str(s.get("id", ""))] = str(s.get("name", s.get("id", "")))
		# capacity is not in the list; it is reported as unknown, never as zero
		st.nodes.append({"name": str(s.get("name", "")), "ready": state == "Ok", "cordoned": state == "Disabled",
			"roles": "komodo server" + ("" if state == "Ok" else " (%s)" % state.to_lower()), "zone": str(info.get("region", "")), "itype": "", "version": "",
			"cpu": 0.0, "mem": 0.0, "cpu_req": 0.0, "mem_req": 0.0, "created": 0.0})
	for c in d.get("containers", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var server = str(names.get(str(c.get("server_id", "")), "unknown server"))
		var state = str(c.get("state", ""))
		var text = str(c.get("status", ""))
		var status = "Running" if state == "running" else ("Completed" if text.begins_with("Exited (0)") else ("Error" if state in ["exited", "dead"] else state.capitalize()))
		var health = "ok" if state == "running" and not text.contains("unhealthy") else ("done" if status == "Completed" else ("warn" if state in ["created", "paused", "restarting", "removing", ""] or text.contains("unhealthy") else "bad"))
		var sec = K.empty_security()
		for p in c.get("ports", []):
			if typeof(p) == TYPE_DICTIONARY and p.get("PublicPort") != null and int(p.get("PublicPort", 0)) > 0:
				sec["host_ports"].append(int(p["PublicPort"]))
				if str(p.get("IP", "")) in ["0.0.0.0", "::", ""]:
					sec["all_interfaces"] = true
		var image = str(c.get("image", ""))
		if K.floating_tag(image):
			sec["latest"].append("%s: %s" % [c.get("name", ""), image])
		var nm = str(c.get("name", ""))
		st.pods.append({"uid": "%s/%s" % [server, str(c.get("id", nm))], "name": nm, "ns": server, "node": server,
			"status": status, "ready": state == "running", "health": health, "restarts": 0, "wkind": "Container", "wname": "",
			"ip": "", "created": float(c.get("created", 0)) if c.get("created") != null else 0.0, "labels": {},
			"containers": [{"name": nm, "image": image, "state": "running" if state == "running" else "terminated", "reason": text, "ready": state == "running", "restarts": 0}],
			"phase": "Running" if state == "running" else ("Succeeded" if status == "Completed" else ("Failed" if status == "Error" else "Pending")),
			"finished": 0.0, "sec": sec, "store": K.empty_storage()})
	return st

func run_action(a: Dictionary) -> Dictionary:
	return {"ok": false, "kind": "unsupported", "msg": "A Komodo connection only looks: make changes in Komodo itself.", "data": {}}
