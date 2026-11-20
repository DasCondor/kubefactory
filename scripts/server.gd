extends Node
# KubeFactory as a server (docs/SERVER.md): one instance owns the connection to
# a cluster or Docker engine; players connect to it over WebSocket like game
# clients and never hold any infrastructure credential themselves.
#
#   KubeFactory --headless -- --server[=port] [--listen=<address>] [--tls-cert=<pem> --tls-key=<pem>] [usual source options]
#
# - Every player signs in with a token. Only SHA-256 hashes of tokens are kept
#   (server-tokens.json); new tokens are written once to server-new-tokens.txt
#   for the admin to hand out and delete.
# - Roles are enforced here, not by the client: a viewer can only read (tier 1:
#   state, logs, events, storage listings); an operator can act up to the tier
#   in server-tokens.json. The server's own read-only mode wins over both.
# - Every action is written to the server's audit log with the token's name.
# - It listens on 127.0.0.1 unless --listen names another address; with
#   --tls-cert and --tls-key it speaks wss://. Without TLS, put it behind an
#   SSH tunnel or a TLS reverse proxy.

const K = preload("res://scripts/kutil.gd")

const PROTOCOL = 1
const MAX_CLIENTS = 32
const MAX_MESSAGE = 1 << 20
const ROLE_TIER = {"viewer": 1, "operator": 4}

var cluster = null
var port = 7666
var address = "127.0.0.1"
var tls_cert = ""
var tls_key = ""

var _tcp = TCPServer.new()
var _tls: TLSOptions = null
var _clients = {}        # id -> {ws, name, role, tier, authed, since, pending_tls}
var _seq = 0
var _last_state = ""

# Where the token hashes live: KF_SERVER_DIR if set (a separate folder per server), else the user-data folder.
static func data_dir() -> String:
	var d = OS.get_environment("KF_SERVER_DIR")
	return d if d != "" else OS.get_user_data_dir()

static func tokens_path() -> String:
	return data_dir().path_join("server-tokens.json")

# {sha256 hex: {name, role, tier}}; on first start, one operator and one viewer token
static func load_tokens() -> Dictionary:
	var t = K.read_json(tokens_path())
	if typeof(t) == TYPE_DICTIONARY and not t.is_empty():
		return t
	t = {}
	var lines = ["KubeFactory server tokens, created %s UTC." % Time.get_datetime_string_from_system(true),
		"Hand each to one person, then delete this file: the server keeps only their hashes.", ""]
	for role in ["operator", "viewer"]:
		var tok = Crypto.new().generate_random_bytes(24).hex_encode()
		t[tok.sha256_text()] = {"name": role + "-1", "role": role, "tier": ROLE_TIER[role]}
		lines.append("%s-1 (%s): %s" % [role, role, tok])
	var f = FileAccess.open(tokens_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify(t, "  "))
	f.close()
	var nf = FileAccess.open(data_dir().path_join("server-new-tokens.txt"), FileAccess.WRITE)
	nf.store_string("\n".join(PackedStringArray(lines)) + "\n")
	nf.close()
	return t

func start() -> Dictionary:
	if tls_cert != "" or tls_key != "":
		var key = CryptoKey.new()
		var cert = X509Certificate.new()
		if key.load(tls_key) != OK or cert.load(tls_cert) != OK:
			return {"ok": false, "msg": "the TLS certificate or key could not be read"}
		_tls = TLSOptions.server(key, cert)
	var err = _tcp.listen(port, address)
	if err != OK:
		return {"ok": false, "msg": "cannot listen on %s:%d (error %d)" % [address, port, err]}
	load_tokens()
	cluster.state_updated.connect(_on_state)
	cluster.action_finished.connect(_on_action_finished)
	var scheme = "wss" if _tls != null else "ws"
	var warn = "" if address in ["127.0.0.1", "::1", "localhost"] or _tls != null else "  WARNING: plain ws:// on a network address; use --tls-cert/--tls-key or a TLS proxy."
	print("KubeFactory server: %s://%s:%d  (tokens: %s)%s" % [scheme, address, port, tokens_path().get_file(), warn])
	cluster.audit("server listening on %s://%s:%d" % [scheme, address, port])
	return {"ok": true, "msg": "%s://%s:%d" % [scheme, address, port]}

func stop() -> void:
	for id in _clients:
		_clients[id]["ws"].close(1001, "server stopping")
	_clients.clear()
	_tcp.stop()

func _process(_delta: float) -> void:
	while _tcp.is_connection_available() and _clients.size() < MAX_CLIENTS:
		var conn = _tcp.take_connection()
		var ws = WebSocketPeer.new()
		ws.inbound_buffer_size = MAX_MESSAGE
		ws.outbound_buffer_size = 16 << 20
		var stream: StreamPeer = conn
		if _tls != null:
			var t = StreamPeerTLS.new()
			if t.accept_stream(conn, _tls) != OK:
				continue
			stream = t
		if ws.accept_stream(stream) != OK:
			continue
		_seq += 1
		_clients[_seq] = {"ws": ws, "name": "", "role": "", "tier": 0, "authed": false, "since": Time.get_ticks_msec()}
	for id in _clients.keys():
		var c = _clients[id]
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var st = ws.get_ready_state()
		if st == WebSocketPeer.STATE_CLOSED:
			if c["authed"]:
				cluster.audit("server: %s left" % c["name"])
			_clients.erase(id)
			continue
		if c.has("close_at"):
			if Time.get_ticks_msec() >= c["close_at"]:
				ws.close(4003, "invalid token")
				c.erase("close_at")
			continue
		if not c["authed"] and Time.get_ticks_msec() - c["since"] > 10000:
			ws.close(4001, "sign in within 10 s")
			continue
		while st == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
			var d = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if typeof(d) == TYPE_DICTIONARY:
				_handle(id, d)

func _send(id: int, msg: Dictionary) -> void:
	var c = _clients.get(id)
	if c != null and c["ws"].get_ready_state() == WebSocketPeer.STATE_OPEN:
		c["ws"].send_text(JSON.stringify(msg))

func _handle(id: int, d: Dictionary) -> void:
	var c = _clients[id]
	var op = str(d.get("op", ""))
	if not c["authed"]:
		if op != "hello":
			c["ws"].close(4001, "sign in first")
			return
		var tok = str(d.get("token", ""))
		var who = load_tokens().get(tok.sha256_text(), {}) if tok.length() >= 16 else {}
		if who.is_empty():
			cluster.audit("server: a sign-in was refused")
			_send(id, {"type": "hello", "ok": false, "msg": "That token is not valid on this server."})
			c["close_at"] = Time.get_ticks_msec() + 500     # let the refusal reach them before closing
			return
		c["authed"] = true
		c["name"] = str(who.get("name", "player")).left(40)
		c["role"] = str(who.get("role", "viewer"))
		c["tier"] = clampi(int(who.get("tier", ROLE_TIER.get(c["role"], 1))), 1, 5)
		cluster.audit("server: %s joined as %s" % [c["name"], c["role"]])
		_send(id, {"type": "hello", "ok": true, "protocol": PROTOCOL, "name": c["name"], "role": c["role"], "tier": c["tier"],
			"read_only": cluster.read_only, "source": cluster.state.get("source", ""), "context": cluster.state.get("context", ""), "file_write": cluster.cap("file_write")})
		_send(id, {"type": "state", "state": cluster.state})
		return
	match op:
		"act":
			_act(id, d)
		_:
			_send(id, {"type": "error", "msg": "unknown request"})

# One request from a player: checked against their role and the server's
# read-only mode, then run against the server's own source; the answer goes back
# to them alone.
func _act(id: int, d: Dictionary) -> void:
	var c = _clients[id]
	var rid = int(d.get("id", 0))
	var a = d.get("action", {})
	if typeof(a) != TYPE_DICTIONARY or str(a.get("op", "")) == "" or cluster.backend == null:
		_send(id, {"type": "result", "id": rid, "result": {"ok": false, "msg": "not an action"}})
		return
	var tier = K.tier_of(a, cluster.state)
	var limit = mini(c["tier"], cluster.max_tier(str(a.get("ns", ""))))
	if tier > limit:
		cluster.audit("server: REFUSED %s for %s (%s, up to MK.%d here)" % [cluster.describe(a), c["name"], c["role"], limit])
		_send(id, {"type": "result", "id": rid, "result": {"ok": false, "msg": "Your role and this namespace's policy allow up to MK.%d here (%s); this is MK.%d." % [limit, c["role"], tier]}})
		return
	if tier > 1 and cluster.read_only:
		cluster.audit("server: BLOCKED (read-only) %s for %s" % [cluster.describe(a), c["name"]])
		_send(id, {"type": "result", "id": rid, "result": {"ok": false, "msg": "The server is in read-only mode."}})
		return
	if tier > 1:
		cluster.audit("server: %s by %s" % [cluster.describe(a), c["name"]])
	var b = cluster.backend
	var t = Thread.new()
	t.start(func():
		var r = b.run_action(a)
		(func():
			t.wait_to_finish()
			_send(id, {"type": "result", "id": rid, "result": r})
			if tier > 1:
				cluster.action_finished.emit(a, r)).call_deferred())

func _on_state(st: Dictionary) -> void:
	var sig = JSON.stringify(st)
	if sig == _last_state:
		return
	_last_state = sig
	for id in _clients:
		if _clients[id]["authed"]:
			_send(id, {"type": "state", "state": st})

func _on_action_finished(a: Dictionary, r: Dictionary) -> void:
	var public_action = a.duplicate()
	public_action.erase("text")
	public_action.erase("expected")
	for id in _clients:
		if _clients[id]["authed"]:
			_send(id, {"type": "feed", "action": public_action, "ok": bool(r.get("ok", false))})

func clients() -> Array:
	return _clients.values().filter(func(c): return c["authed"]).map(func(c): return {"name": c["name"], "role": c["role"]})
