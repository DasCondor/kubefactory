extends Node
# LiveView: real web applications on screens in the world.
#
# A session is a headless browser page run by the native companion (the Edge or
# Chrome already on this machine, in a throw-away profile). Its frames arrive
# here and are drawn into a texture; mouse, wheel and keyboard go back the other
# way. What is on a screen is therefore the application itself, live. When
# there is nothing real to show (the simulation, the browser demo, no browser
# installed, an endpoint that does not answer) a session says so. It never
# shows a stand-in.
#
# Frame rate follows attention: full rate while you are using a display, less
# when you are merely near one, a trickle from afar, and paused out of sight.

signal changed(session)

const K = preload("res://scripts/kutil.gd")
const Agent = preload("res://scripts/agent.gd")

const RATE_ACTIVE = 30
const RATE_NEAR = 12
const RATE_FAR = 2
const MAX_SESSIONS = 4          # browser pages are heavy: a small fixed budget

var sessions = {}               # sid -> session
var _pending = {}               # key -> session still opening
var _queue = []                 # input and control requests, sent in order by one thread
var _queue_mx = Mutex.new()
var _queue_sem = Semaphore.new()
var _sender: Thread = null
var _quit = false
var _rate_t = 0.0
var _seq = 0

static func available() -> bool:
	return Agent.available()

func _ready() -> void:
	if available():
		_sender = Thread.new()
		_sender.start(_send_loop)

func _exit_tree() -> void:
	_quit = true
	_queue_sem.post()
	if _sender != null:
		_sender.wait_to_finish()

func _send_loop() -> void:
	while true:
		_queue_sem.wait()
		if _quit:
			return
		_queue_mx.lock()
		var job = _queue.pop_front() if not _queue.is_empty() else null
		_queue_mx.unlock()
		if job == null:
			continue
		var r = Agent.request(job["op"], job["args"], float(job.get("timeout", 20.0)))
		if job.has("done"):
			job["done"].call_deferred(r)

func _post(op: String, args: Dictionary, done = null, timeout: float = 20.0) -> void:
	var job = {"op": op, "args": args, "timeout": timeout}
	if done != null:
		job["done"] = done
	_queue_mx.lock()
	_queue.append(job)
	_queue_mx.unlock()
	_queue_sem.post()

# Open `url` on a new display. Returns the session straight away in state
# "opening"; it becomes "live" or "failed" (with kind + msg) when the page answers.
# allow: extra hosts the page may navigate to (it is otherwise held to its own).
func open(url: String, title: String, width: int = 1280, height: int = 720, allow: Array = []) -> Dictionary:
	_seq += 1
	var s = {"key": "lv%d" % _seq, "sid": "", "url": url, "home": url, "title": title, "state": "opening", "kind": "", "msg": "",
		"w": width, "h": height, "tex": null, "status": 0, "fps": RATE_NEAR, "paused": false, "frames": 0, "mounted": "", "blocked": ""}
	if not available():
		s["state"] = "failed"
		s["kind"] = "unsupported"
		s["msg"] = Agent.why_unavailable()
		return s
	if sessions.size() + _pending.size() >= MAX_SESSIONS:
		s["state"] = "failed"
		s["kind"] = "unsupported"
		s["msg"] = "%d displays are already live. Close one first." % MAX_SESSIONS
		return s
	_pending[s["key"]] = s
	_post("browser.open", {"url": url, "width": width, "height": height, "fps": RATE_NEAR, "allow": allow}, func(r): _opened(s, r), 45.0)
	return s

func _opened(s: Dictionary, r: Dictionary) -> void:
	_pending.erase(s["key"])
	if not r["ok"]:
		s["state"] = "failed"
		s["kind"] = r["kind"]
		s["msg"] = r["msg"]
	else:
		var d = r["data"]
		s["sid"] = str(d["sid"])
		s["status"] = int(d.get("status", 0))
		if str(d.get("title", "")) != "":
			s["page_title"] = str(d["title"])
		s["state"] = "live"
		sessions[s["sid"]] = s
		if s.get("closing", false):
			close(s)
			return
	changed.emit(s)

func close(s: Dictionary) -> void:
	if s["state"] == "opening":
		s["closing"] = true      # it is closed the moment it finishes opening
		return
	if s["sid"] != "" and sessions.has(s["sid"]):
		sessions.erase(s["sid"])
		_post("browser.close", {"sid": s["sid"]})
	s["state"] = "closed"
	changed.emit(s)

func close_all() -> void:
	for s in sessions.values():
		close(s)

func navigate(s: Dictionary, action: String, url: String = "") -> void:
	if s["state"] == "live":
		_post("browser.navigate", {"sid": s["sid"], "action": action, "url": url})

# kind: move | down | up | wheel | text | key   (x, y in page pixels)
func input(s: Dictionary, kind: String, args: Dictionary = {}) -> void:
	if s["state"] != "live":
		return
	args["sid"] = s["sid"]
	args["kind"] = kind
	if kind == "move":
		# only the newest pointer position matters: drop a move that is still waiting
		_queue_mx.lock()
		for i in range(_queue.size() - 1, -1, -1):
			if _queue[i]["op"] == "browser.input" and _queue[i]["args"].get("kind") == "move" and _queue[i]["args"].get("sid") == s["sid"]:
				_queue.remove_at(i)
				break
		_queue_mx.unlock()
	_post("browser.input", args)

func set_rate(s: Dictionary, fps: int, paused: bool) -> void:
	if s["state"] != "live" or (s["fps"] == fps and s["paused"] == paused):
		return
	s["fps"] = fps
	s["paused"] = paused
	_post("browser.rate", {"sid": s["sid"], "fps": fps, "paused": paused})

func _process(delta: float) -> void:
	for sid in sessions:
		var f = Agent.take_frame(sid)
		if f == null:
			continue
		var s = sessions[sid]
		var img = Image.new()
		if img.load_jpg_from_buffer(Marshalls.base64_to_raw(str(f.get("jpeg", "")))) != OK:
			continue
		img.generate_mipmaps()
		if s["tex"] == null or s["tex"].get_size() != Vector2(img.get_size()):
			s["tex"] = ImageTexture.create_from_image(img)
			changed.emit(s)
		else:
			s["tex"].update(img)
		s["frames"] += 1

# What the companion reports on its own about a page.
func on_agent_event(e: Dictionary) -> void:
	var s = sessions.get(str(e.get("sid", "")))
	if s == null:
		return
	match str(e.get("event", "")):
		"nav":
			s["url"] = str(e.get("url", s["url"]))
			changed.emit(s)
		"blocked":
			s["blocked"] = str(e.get("host", ""))
			changed.emit(s)

# ---- where applications can be reached

# Web-looking endpoints the connected source exposes: [{title, ns, service, port, kind, url}]
# kind "url": reachable as is (a Docker published port). kind "forward": a
# Kubernetes Service that needs a loopback port-forward first. Port numbers are
# only a hint that something speaks HTTP; nothing is probed until you open it.
static func endpoints(state: Dictionary, source: String) -> Array:
	var res = []
	if source == "docker":
		var rx = RegEx.new()
		rx.compile("(?:0\\.0\\.0\\.0|127\\.0\\.0\\.1|\\[?::\\]?):(\\d+)->(\\d+)/tcp")
		for p in state.get("pods", []):
			var seen = {}
			for m in rx.search_all(str(p.get("ip", ""))):
				var host_port = m.get_string(1).to_int()
				if seen.has(host_port):
					continue
				seen[host_port] = true
				var cport = m.get_string(2).to_int()
				res.append({"title": "%s :%d" % [p["name"], host_port], "ns": p["ns"], "service": p["name"], "port": host_port, "kind": "url",
					"url": "%s://127.0.0.1:%d/" % ["https" if cport in [443, 8443, 9443] else "http", host_port]})
	elif source == "kubernetes":
		for s in state.get("services", []):
			if s.get("selector", {}).is_empty():
				continue
			for part in str(s.get("ports", "")).split(",", false):
				if not part.ends_with("/TCP"):
					continue
				var port = part.get_slice("/", 0).to_int()
				if port in [53, 22, 5432, 3306, 6379, 27017, 9092, 5672, 1883, 11211]:
					continue     # well-known non-HTTP ports: not web pages
				res.append({"title": "%s/%s :%d" % [s["ns"], s["name"], port], "ns": s["ns"], "service": s["name"], "port": port, "kind": "forward",
					"scheme": "https" if port in [443, 8443, 9443] else "http", "url": ""})
	return res
