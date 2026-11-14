extends RefCounted
# The game's end of the pipe to kf-agent, the native companion (see agent/).
#
# The agent is started as a child process the first time it is needed and is
# reached only through that process's own stdin/stdout: one JSON object per
# line, a fixed set of typed operations, no network port. It ends when the
# game does (its stdin closes).
#
# request() blocks until the answer arrives, so call it from a worker thread
# (cluster.gd already runs every backend call on one). Events the agent sends
# on its own (LiveView frames, a forward closing) are queued for poll_events().
#
# The browser build has no agent: available() is false there and everything
# that needs it reports that instead of pretending.

const K = preload("res://scripts/kutil.gd")

static var _pipe: FileAccess = null
static var _err: FileAccess = null
static var _pid = -1
static var _reader: Thread = null
static var _mx = Mutex.new()
static var _write_mx = Mutex.new()
static var _next_id = 0
static var _waiting = {}        # id -> [Semaphore, response or null]
static var _events = []
static var _frames = {}         # LiveView session id -> newest frame (older ones are dropped)
static var _dead = ""           # why the agent is not usable, once known

static func path() -> String:
	var name = "kf-agent.exe" if OS.get_name() == "Windows" else "kf-agent"
	# installed build: beside the game's exe. From source: where tools\build-agent.ps1 puts it.
	for p in [K.data_path(name), K.data_path("agent/bin/" + name)]:
		if FileAccess.file_exists(p):
			return p
	return ""

static func available() -> bool:
	return not OS.has_feature("web") and path() != ""

static func why_unavailable() -> String:
	if OS.has_feature("web"):
		return "The browser demo is sealed off from real infrastructure."
	if path() == "":
		return "The native companion (kf-agent) is missing. Build it with tools\\build-agent.ps1, or reinstall."
	return _dead

static func _start() -> bool:
	if _pipe != null:
		return true
	if not available():
		return false
	var r = OS.execute_with_pipe(path(), PackedStringArray())
	if r.is_empty() or r.get("stdio") == null:
		_dead = "The native companion could not be started."
		return false
	_pipe = r["stdio"]
	_err = r.get("stderr")
	_pid = int(r.get("pid", -1))
	_reader = Thread.new()
	_reader.start(_read_loop.bind(_pipe))
	return true

static func _read_loop(pipe: FileAccess) -> void:
	while true:
		var line = pipe.get_line()
		if line == "":
			if pipe.get_error() != OK or not OS.is_process_running(_pid):
				break
			OS.delay_msec(4)
			continue
		var d = JSON.parse_string(line)
		if typeof(d) != TYPE_DICTIONARY:
			continue
		_mx.lock()
		if d.has("event"):
			if d["event"] == "frame":
				_frames[str(d.get("sid", ""))] = d
			else:
				_events.append(d)
		else:
			var w = _waiting.get(int(d.get("id", 0)))
			if w != null:
				w[1] = d
				w[0].post()
		_mx.unlock()
	# the agent is gone: release everyone still waiting
	_mx.lock()
	_dead = "The native companion stopped."
	for id in _waiting:
		_waiting[id][0].post()
	_mx.unlock()

# -> {ok: bool, data: Dictionary, kind: String, msg: String, extra: Dictionary}
static func request(op: String, args: Dictionary = {}, timeout: float = 45.0) -> Dictionary:
	_mx.lock()
	var started = _start()
	_next_id += 1
	var id = _next_id
	var sem = Semaphore.new()
	var slot = [sem, null]
	if started:
		_waiting[id] = slot
	_mx.unlock()
	if not started:
		return {"ok": false, "data": {}, "kind": "unsupported", "msg": why_unavailable(), "extra": {}}
	_write_mx.lock()
	_pipe.store_line(JSON.stringify({"id": id, "op": op, "args": args}))
	_pipe.flush()
	_write_mx.unlock()
	var deadline = Time.get_ticks_msec() + int(timeout * 1000.0)
	var got = false
	while Time.get_ticks_msec() < deadline:
		if sem.try_wait():
			got = true
			break
		OS.delay_msec(3)
	_mx.lock()
	_waiting.erase(id)
	var d = slot[1]
	_mx.unlock()
	if not got or d == null:
		return {"ok": false, "data": {}, "kind": "timeout" if not got else "other",
			"msg": "The native companion did not answer." if not got else _dead, "extra": {}}
	if d.get("ok", false):
		var data = d.get("data")
		return {"ok": true, "data": data if typeof(data) == TYPE_DICTIONARY else {}, "kind": "", "msg": "", "extra": {}}
	var e = d.get("error", {})
	var extra = e.get("extra")
	return {"ok": false, "data": {}, "kind": str(e.get("kind", "other")), "msg": K.tidy_text(str(e.get("msg", "failed"))),
		"extra": extra if typeof(extra) == TYPE_DICTIONARY else {}}

# Events since the last call (not LiveView frames: see take_frame).
static func poll_events() -> Array:
	_mx.lock()
	var e = _events
	_events = []
	_mx.unlock()
	return e

# The newest undrawn frame for a LiveView session, or null.
static func take_frame(sid: String) -> Variant:
	_mx.lock()
	var f = _frames.get(sid)
	_frames.erase(sid)
	_mx.unlock()
	return f

static func running() -> bool:
	return _pipe != null and _dead == ""

# Called after the game's worker threads stop, so the companion can close its
# browsers and forwards before we join the pipe reader.
static func shutdown() -> void:
	if _reader == null:
		return
	if running():
		request("shutdown", {}, 5.0)
	var deadline = Time.get_ticks_msec() + 15000
	while _reader.is_alive() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(10)
	if _reader.is_alive() and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_reader.wait_to_finish()
	_reader = null
	_pipe = null
	_err = null
	_pid = -1

# What a failure kind means, in the words shown to the player.
static func kind_title(kind: String) -> String:
	return {"auth": "AUTHENTICATION", "rbac": "PERMISSION (RBAC)", "tls": "TLS / CERTIFICATE", "timeout": "TIMEOUT",
		"unreachable": "UNREACHABLE", "config": "KUBECONFIG", "exec_untrusted": "CREDENTIAL HELPER", "needs_base_dir": "MISSING FILES",
		"notfound": "NOT FOUND", "conflict": "CONFLICT", "invalid": "INVALID", "unsupported": "UNAVAILABLE"}.get(kind, "ERROR")
