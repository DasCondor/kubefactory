extends RefCounted
# Gauge's observations are read-only. Requests are not runtime utilization.

const K = preload("res://scripts/kutil.gd")

static func node_rows(state: Dictionary) -> Array:
	var out = []
	var requests_available = str(state.get("source", "")) in ["kubernetes", "simulation"]
	for node in state.get("nodes", []):
		var cpu = float(node.get("cpu", 0.0))
		var mem = float(node.get("mem", 0.0))
		var hidden = str(node.get("roles", "")) == "node details hidden"
		out.append({"name": str(node.get("name", "")), "ready": null if hidden or not node.has("ready") else bool(node["ready"]),
			"cpu": cpu if cpu > 0.0 else null, "memory": mem if mem > 0.0 else null,
			"cpu_requested": float(node.get("cpu_req", 0.0)) if requests_available and not hidden and node.has("cpu_req") else null,
			"memory_requested": float(node.get("mem_req", 0.0)) if requests_available and not hidden and node.has("mem_req") else null})
	return out

static func cpu(value) -> String:
	if value == null:
		return "unavailable"
	return "%.2f cores" % float(value)

static func memory(value) -> String:
	return "unavailable" if value == null else K.fmt_bytes(float(value))

static func readiness(value) -> String:
	return "Unavailable" if value == null else ("Ready" if value else "Not ready")

static func node_matches(node: Dictionary, filter: String) -> bool:
	var needle = filter.strip_edges().to_lower()
	if needle == "":
		return true
	var cells = [node["name"], cpu(node["cpu_requested"]), cpu(node["cpu"]), memory(node["memory_requested"]),
		memory(node["memory"]), readiness(node["ready"])]
	return cells.any(func(cell): return str(cell).to_lower().contains(needle))

static func reading(result: Dictionary) -> String:
	if not result.get("ok", false):
		return "Unavailable: " + str(result.get("msg", "the source did not report usage"))
	var data: Dictionary = result.get("data", {})
	var source = str(data.get("source", "source not reported"))
	var stamp = str(data.get("at", "time not reported"))
	if stamp == "":
		stamp = "time not reported"
	return "CPU %s   ·   Memory %s\nNetwork totals: in %s / out %s   ·   Disk totals: read %s / write %s\nSource: %s   ·   %s%s" % [cpu(data.get("cpu_cores")), memory(data.get("mem_bytes")),
		memory(data.get("net_rx_bytes")), memory(data.get("net_tx_bytes")), memory(data.get("disk_read_bytes")), memory(data.get("disk_write_bytes")), source, stamp,
		"   ·   SIMULATED" if data.get("simulated", false) else ""]
