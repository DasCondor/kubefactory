extends RefCounted
# A KubeFactory server as a source (server.gd, docs/SERVER.md): this client
# holds no infrastructure credential. It signs in with a token, receives the
# server's state as it changes, and sends actions the server checks against the
# player's role and its own read-only mode before running them.

const K = preload("res://scripts/kutil.gd")

var label = "remote"
var poll_interval = 1.0
# WebSocketPeer.close() from a worker thread crashed Godot 4.3 (heap corruption on
# Windows, SIGSEGV on Linux) when switching away from a server; closing only sends
# a close frame, so cluster.gd runs this cleanup on the main thread.
var cleanup_on_main_thread = true
var caps = {"remove_image": true, "scale": true, "delete_pod": true, "restart": true, "delete_workload": false,
	"create": true, "cordon": true, "drain": false, "logs": true, "files": true}
var context = ""
var log_cfg = {}
var providers = [{"id": "kube", "name": "KubeFactory server", "ready": true, "note": "through the server"}]
var url = ""
var token = ""
var role = ""
var tier = 1
var server_read_only = false
var server_source = ""

var _ws = WebSocketPeer.new()
var _mx = Mutex.new()
var _state = {}
var _results = {}
var _seq = 0
var feed = []           # what other players did, newest last

func probe() -> Dictionary:
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		return {"ok": false, "msg": "a server address starts with ws:// or wss://"}
	_ws.inbound_buffer_size = 32 << 20
	if _ws.connect_to_url(url) != OK:
		return {"ok": false, "msg": "cannot open %s" % url}
	var deadline = Time.get_ticks_msec() + 10000
	while _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING and Time.get_ticks_msec() < deadline:
		_ws.poll()
		OS.delay_msec(20)
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return {"ok": false, "msg": "the server at %s cannot be reached" % url}
	_ws.send_text(JSON.stringify({"op": "hello", "token": token, "protocol": 1}))
	token = ""             # not kept once sent
	while Time.get_ticks_msec() < deadline:
		_pump()
		_mx.lock()
		var h = _results.get("hello")
		_mx.unlock()
		if h != null:
			if not h.get("ok", false):
				return {"ok": false, "msg": str(h.get("msg", "the server refused the sign-in"))}
			role = str(h.get("role", "viewer"))
			tier = int(h.get("tier", 1))
			server_read_only = bool(h.get("read_only", false))
			server_source = str(h.get("source", ""))
			context = "%s @ %s" % [str(h.get("context", "")), url.get_slice("://", 1).get_slice("/", 0)]
			return {"ok": true, "msg": context}
		if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return {"ok": false, "msg": "the server closed the connection (%s)" % (_ws.get_close_reason() if _ws.get_close_reason() != "" else "code %d" % _ws.get_close_code())}
		OS.delay_msec(20)
	return {"ok": false, "msg": "the server did not answer the sign-in"}

func _pump() -> void:
	_mx.lock()
	_ws.poll()
	while _ws.get_available_packet_count() > 0:
		var d = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if typeof(d) != TYPE_DICTIONARY:
			continue
		match str(d.get("type", "")):
			"hello":
				_results["hello"] = d
			"state":
				if typeof(d.get("state")) == TYPE_DICTIONARY:
					_state = d["state"]
			"result":
				_results[int(d.get("id", 0))] = d.get("result", {})
			"feed":
				feed.append(d)
				if feed.size() > 50:
					feed.pop_front()
	_mx.unlock()

func fetch() -> Dictionary:
	_pump()
	if not _is_open():
		_mx.lock()
		var code = _ws.get_close_code()
		_mx.unlock()
		return {"source": label, "context": context, "error": "the connection to the server closed (code %d)" % code, "failed": true}
	_mx.lock()
	var st = _state.duplicate(true)
	_mx.unlock()
	if st.is_empty():
		return {"source": server_source if server_source != "" else label, "context": context, "error": "", "nodes": [], "pods": [], "workloads": [], "services": []}
	st["context"] = context
	st["provider"] = "via KubeFactory server (%s)" % role
	return st

func run_action(a: Dictionary) -> Dictionary:
	_mx.lock()
	_seq += 1
	var id = _seq
	_ws.send_text(JSON.stringify({"op": "act", "id": id, "action": a}))
	_mx.unlock()
	var deadline = Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		_pump()
		_mx.lock()
		var r = _results.get(id)
		if r != null:
			_results.erase(id)
		_mx.unlock()
		if r != null:
			return r if typeof(r) == TYPE_DICTIONARY else {"ok": false, "msg": "the server's answer was not understood"}
		if not _is_open():
			return {"ok": false, "msg": "the connection to the server closed"}
		OS.delay_msec(20)
	return {"ok": false, "msg": "the server did not answer in time"}

# Fetches and actions run on worker threads and cleanup on the main thread:
# every use of the WebSocketPeer goes through _mx.
func _is_open() -> bool:
	_mx.lock()
	var open = _ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	_mx.unlock()
	return open

func cleanup() -> void:
	_mx.lock()
	_ws.close(1000, "bye")
	_mx.unlock()
