extends RefCounted
# Bob 2.0: he reads a failing pod's log and events and tells you which lines
# matter, what each one means and what to do about it.
#
# Optional config: bob.json next to the game (see config() below). Without it
# the built-in rules are used as they are.

const K = preload("res://scripts/kutil.gd")

# Checked in order; the first rule that matches a line claims it. `weight` says
# how close to a root cause the line is: 3 = this is why it died, 2 = a strong
# lead, 1 = a symptom (it tells you something broke, not what).
const RULES = [
	# --- image and start-up (mostly in the events)
	{"id": "image", "weight": 3, "match": "manifest unknown|manifest for .* not found|pull access denied|repository does not exist|Failed to pull image|ErrImagePull|ImagePullBackOff|Back-off pulling image|InvalidImageName",
		"means": "The image cannot be pulled: that name or tag does not exist in the registry, or the registry is private.",
		"fix": "Check the image name and tag in the workload's spec for a typo. For a private registry, add an imagePullSecret."},
	{"id": "arch", "weight": 3, "match": "exec format error",
		"means": "The image was built for a different CPU architecture than this node (for example arm64 on amd64).",
		"fix": "Use a multi-arch image, or build one for this node's architecture."},
	{"id": "entrypoint", "weight": 3, "match": "executable file not found|command not found|no such file or directory.*(exec|entrypoint)|exec: \"[^\"]+\": ",
		"means": "The container's start command does not exist inside the image.",
		"fix": "Check `command` and `args` in the pod spec against what the image actually ships."},
	{"id": "missing-ref", "weight": 3, "match": "(secret|configmap) \"[^\"]+\" not found|couldn't find key .* in (Secret|ConfigMap)",
		"means": "The pod refers to a Secret or ConfigMap (or a key in one) that does not exist in this namespace.",
		"fix": "Create it, or fix the name in the pod spec. The line names the missing piece."},
	{"id": "mount", "weight": 3, "match": "FailedMount|MountVolume\\.\\w+ failed|Unable to attach or mount|persistentvolumeclaim \"[^\"]+\" not found|FailedAttachVolume",
		"means": "A volume could not be mounted, so the container never got to start.",
		"fix": "Check the PersistentVolumeClaim exists and is Bound, and that the volume is not still attached to another node."},
	{"id": "schedule", "weight": 3, "match": "FailedScheduling|Insufficient (cpu|memory)|nodes are available|didn't match (Pod's )?node (affinity|selector)|had untolerated taint",
		"means": "The scheduler found no node that can take this pod.",
		"fix": "Free up capacity, uncordon a node, or relax the pod's node selector, affinity or resource requests."},
	# --- crashes
	{"id": "oom", "weight": 3, "match": "OOMKilled|out of memory|OutOfMemoryError|Cannot allocate memory|JavaScript heap out of memory|Killed process",
		"means": "It ran out of memory and was killed.",
		"fix": "Raise the container's memory limit, or find what is leaking. Restarting only buys time."},
	{"id": "disk", "weight": 3, "match": "no space left on device|ENOSPC|disk quota exceeded",
		"means": "A disk it writes to is full.",
		"fix": "Grow the volume or clear it out. If it is the node's own disk, look at image and log garbage collection."},
	{"id": "refused", "weight": 3, "match": "connection refused|ECONNREFUSED|connect: connection reset",
		"means": "Something it depends on is not accepting connections at that address and port.",
		"fix": "Check the dependency is running and its Service points at ready pods. The line usually shows the address it tried."},
	{"id": "dns", "weight": 3, "match": "no such host|NXDOMAIN|ENOTFOUND|could not resolve|Name or service not known|Temporary failure in name resolution|getaddrinfo",
		"means": "A hostname does not resolve. Usually a wrong Service name, or the right name in the wrong namespace.",
		"fix": "Use the full name (service.namespace.svc) and check that Service exists."},
	{"id": "auth", "weight": 3, "match": "password authentication failed|authentication failed|access denied for user|invalid credentials|401 Unauthorized|\\bunauthorized\\b",
		"means": "It was refused at the door: wrong username, password or token.",
		"fix": "Check the Secret it reads its credentials from, and whether they were rotated on the other side."},
	{"id": "forbidden", "weight": 3, "match": "permission denied|EACCES|operation not permitted|403 Forbidden|\\bforbidden\\b|is forbidden: User",
		"means": "It is not allowed to do that: file permissions, a locked-down securityContext, or missing RBAC.",
		"fix": "For files, check runAsUser / fsGroup. For API calls, check the ServiceAccount's Role."},
	{"id": "tls", "weight": 3, "match": "x509:|certificate has expired|certificate signed by unknown authority|certificate verify failed|tls: (bad|handshake|failed)",
		"means": "A TLS certificate was rejected: expired, or signed by an authority this container does not trust.",
		"fix": "Renew the certificate, or mount the right CA bundle."},
	{"id": "port", "weight": 3, "match": "address already in use|EADDRINUSE",
		"means": "It tried to listen on a port something else in the pod already holds.",
		"fix": "Two containers in one pod share the network: give them different ports."},
	{"id": "nofile", "weight": 3, "match": "no such file or directory|ENOENT|FileNotFoundError|cannot open .*: No such",
		"means": "It went looking for a file that is not there: a missing mount, config file or path.",
		"fix": "Check the volume mounts and the path it expects. The line names the file."},
	{"id": "env", "weight": 3, "match": "environment variable .* (is )?(not set|required|missing|undefined)|missing required (env|environment|config|setting)|must be set|required key .* missing",
		"means": "A setting it needs was never given to it.",
		"fix": "Add the missing environment variable (or ConfigMap / Secret key) to the pod spec."},
	{"id": "schema", "weight": 3, "match": "relation \"[^\"]+\" does not exist|table .* doesn't exist|no such table|pending migration|database .* does not exist",
		"means": "The database is reachable but not set up: a table or the database itself is missing.",
		"fix": "Run the migrations (often a Job or an init container) before this workload starts."},
	{"id": "fds", "weight": 2, "match": "too many open files|EMFILE",
		"means": "It ran out of file handles.",
		"fix": "Look for a connection or file leak; raise the limit only once you know why."},
	{"id": "timeout", "weight": 2, "match": "i/o timeout|timed out|context deadline exceeded|deadline exceeded|ETIMEDOUT|connection timed out",
		"means": "It waited for something that never answered.",
		"fix": "The other side is down, slow, or blocked by a NetworkPolicy or firewall. Unlike 'refused', nothing is answering at all."},
	{"id": "probe", "weight": 2, "match": "(Liveness|Readiness|Startup) probe failed|Unhealthy",
		"means": "A health probe is failing, so the kubelet restarts the container or keeps traffic away from it.",
		"fix": "Check the probe's path, port and timings against how long the app really takes to start."},
	{"id": "stack", "weight": 2, "match": "panic:|fatal error:|Traceback \\(most recent call last\\)|Unhandled(Promise)?(Rejection| exception)|Exception in thread|Segmentation fault|SIGSEGV|core dumped",
		"means": "The program crashed on an error it did not handle. The lines right after this one are the stack trace.",
		"fix": "Read the first few lines of the trace: the top frame in your own code is where to look."},
	# --- symptoms: something broke, these only say that it did
	{"id": "exit", "weight": 1, "match": "exit(ed|ing)? (with )?(code|status) (\\d+)|Exit Code:\\s*(\\d+)",
		"means": "", "fix": ""},
	{"id": "backoff", "weight": 1, "match": "Back-off restarting failed container|CrashLoopBackOff|BackOff",
		"means": "The kubelet keeps restarting it and is waiting longer between tries each time.",
		"fix": "This is the symptom, not the cause. The cause is in the container's own log, usually its last few lines."},
	{"id": "waiting", "weight": 1, "match": "is waiting to start|previous terminated container .* not found",
		"means": "There is no log to read: the container has not managed to start.",
		"fix": "The reason is in the events, not the log."},
	{"id": "fatal", "weight": 1, "match": "\\b(FATAL|CRITICAL|PANIC|EMERG)\\b",
		"means": "The program logged this as fatal, right before giving up.",
		"fix": "Read it with the line above it: that pair is usually the whole story."},
	{"id": "error", "weight": 1, "match": "\\b(ERROR|ERR|SEVERE)\\b|\\bError:|\\bException\\b|\\bfailed\\b",
		"means": "An error-level line.",
		"fix": "Not always the cause, but worth a look if nothing more specific turned up."},
]

const EXIT_CODES = {
	"0": ["It exited cleanly (code 0), which a Deployment still treats as a failure because it expects the process to keep running.", "If it is meant to finish, run it as a Job instead."],
	"1": ["It exited with code 1: a general error raised by the program itself.", "The reason is in the lines just above this one."],
	"2": ["It exited with code 2: usually bad command-line arguments or a shell misuse.", "Check `command` and `args` in the pod spec."],
	"126": ["Exit code 126: the start command was found but could not be executed.", "Check the file is executable and built for this architecture."],
	"127": ["Exit code 127: the start command was not found.", "Check `command` in the pod spec against what the image ships."],
	"137": ["Exit code 137: it was killed with SIGKILL. Nearly always the memory limit, sometimes a failed liveness probe.", "Compare its memory use with its limit, and check the events for OOMKilled or a probe failure."],
	"139": ["Exit code 139: a segmentation fault. The program crashed inside native code.", "Look for a bad native library or an architecture mismatch."],
	"143": ["Exit code 143: it was asked to stop (SIGTERM) and did.", "Something told it to shut down: a rollout, a drain or a failed probe. Check the events."],
}

# bob.json, all keys optional:
#   log_review    false switches the log reading off (the fix list stays)
#   tail          how many log lines to read per container
#   previous      also read the previous (crashed) container's log when the pod has restarted
#   max_findings  how many lines he reports per case
#   ignore        regexes: lines matching any of these are skipped
#   rules         your own rules, checked before the built-in ones:
#                 {"match": "<regex>", "means": "...", "fix": "...", "weight": 1-3}
static func config() -> Dictionary:
	var c = {"log_review": true, "tail": 200, "previous": true, "max_findings": 6, "ignore": [], "rules": []}
	var d = K.read_json(K.data_path("bob.json"))
	if typeof(d) == TYPE_DICTIONARY:
		for k in c:
			if not d.has(k):
				continue
			var want = typeof(c[k])
			var got = typeof(d[k])
			if got == want or (want == TYPE_INT and got == TYPE_FLOAT):   # JSON numbers arrive as floats
				c[k] = d[k]
	c["tail"] = clampi(int(c["tail"]), 20, 2000)
	c["max_findings"] = clampi(int(c["max_findings"]), 1, 20)
	return c

static func _rx(pattern: String) -> RegEx:
	var r = RegEx.new()
	if r.compile("(?i)" + pattern) != OK:
		return null
	return r

# [[RegEx, rule], ...]: the config's own rules first, then the built-in ones.
# A rule whose regex does not compile is left out (and counted in `bad`).
static func compile(cfg: Dictionary) -> Dictionary:
	var out = []
	var bad = 0
	var n = 0
	for r in cfg.get("rules", []):
		if typeof(r) != TYPE_DICTIONARY or str(r.get("match", "")) == "":
			bad += 1
			continue
		var rx = _rx(str(r["match"]))
		if rx == null:
			bad += 1
			continue
		n += 1
		out.append([rx, {"id": "custom-%d" % n, "weight": clampi(int(r.get("weight", 3)), 1, 3),
			"means": str(r.get("means", "Matches one of your own rules in bob.json.")), "fix": str(r.get("fix", "")), "custom": true}])
	for r in RULES:
		out.append([_rx(r["match"]), r])
	var ignore = []
	for p in cfg.get("ignore", []):
		var rx = _rx(str(p))
		if rx != null:
			ignore.append(rx)
		else:
			bad += 1
	return {"rules": out, "ignore": ignore, "bad": bad}

# Go through `text` (a log or an events listing) line by line. Returns one finding
# per rule that fired: its last matching line (the one nearest the crash), the
# line number, how often it fired, and what it means.
static func review(text: String, source: String, compiled: Dictionary) -> Array:
	var by_rule = {}
	var lines = text.split("\n")
	for i in lines.size():
		var line = lines[i].strip_edges()
		if line == "":
			continue
		var skip = false
		for ig in compiled["ignore"]:
			if ig.search(line) != null:
				skip = true
				break
		if skip:
			continue
		for pair in compiled["rules"]:
			var m = pair[0].search(line)
			if m == null:
				continue
			var rule = pair[1]
			var f = by_rule.get(rule["id"])
			if f == null:
				f = {"rule": rule["id"], "source": source, "weight": rule["weight"], "count": 0, "custom": rule.get("custom", false)}
				by_rule[rule["id"]] = f
			f["count"] += 1
			f["n"] = i + 1
			f["line"] = line.left(260)
			f["means"] = rule["means"]
			f["fix"] = rule["fix"]
			if rule["id"] == "exit":
				var code = m.get_string(4) if m.get_string(4) != "" else m.get_string(5)
				var known = EXIT_CODES.get(code, ["It exited with code %s." % code, "The reason is in the lines just above this one."])
				f["means"] = known[0]
				f["fix"] = known[1]
			break
	return by_rule.values()

# The findings worth showing, most telling first, at most `limit` of them.
static func rank(findings: Array, limit: int) -> Array:
	var f = findings.duplicate()
	f.sort_custom(func(a, b):
		if a["weight"] != b["weight"]:
			return a["weight"] > b["weight"]
		if a["source"] != b["source"]:
			return a["source"] == "log"
		return a["n"] > b["n"])
	# the same rule firing in both the log and the events is one finding, not two
	var seen = {}
	var out = []
	for x in f:
		if not seen.has(x["rule"]):
			seen[x["rule"]] = true
			out.append(x)
	return out.slice(0, limit)

# Bob's one-line verdict from the ranked findings.
static func verdict(ranked: Array) -> String:
	if ranked.is_empty():
		return "I read every line and nothing jumps out. No errors, no crash, no complaints. Whatever is wrong, it is not saying so in the log."
	var top = ranked[0]
	if top["weight"] >= 3:
		return "Found it, I reckon. Line %d of the %s: %s" % [top["n"], top["source"], top["means"]]
	if top["weight"] == 2:
		return "A strong lead on line %d of the %s, though I would not swear to it: %s" % [top["n"], top["source"], top["means"]]
	return "It tells me that it broke, not why. Best I can offer is line %d of the %s: %s" % [top["n"], top["source"], top["means"]]
