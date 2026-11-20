extends SceneTree
# Check from here: where it connects for each kind of binding, and what the
# probe reports against a listener this test opens on 127.0.0.1.
#
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/port_check_test.gd

const K = preload("res://scripts/kutil.gd")
var failures = 0

func check(ok: bool, what: String, got = "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if ok else "  got: " + str(got)))
	if not ok:
		failures += 1

func _init() -> void:
	var pod = {"net": {"segments": []}}
	check(K._check_target({"target": "80/tcp", "ip": "127.0.0.1", "published": "8080"}, pod) == {"host": "127.0.0.1", "port": 8080, "proto": "tcp", "local": true}, "a loopback binding is checked on loopback")
	check(K._check_target({"target": "53/udp", "ip": "0.0.0.0", "published": "53"}, pod) == {"host": "127.0.0.1", "port": 53, "proto": "udp", "local": true}, "every interface is checked through loopback, and keeps its protocol")
	check(K._check_target({"target": "80/tcp", "ip": "::", "published": "80"}, pod)["host"] == "::1", "IPv6 wildcard goes to ::1")
	check(K._check_target({"target": "32400/tcp", "ip": "192.0.2.20", "published": "32400"}, pod) == {"host": "192.0.2.20", "port": 32400, "proto": "tcp", "local": false}, "a bound LAN address is checked at that address")
	check(K._check_target({"target": "80/tcp", "ip": "", "published": ""}, pod).has("none"), "an automatic host port is not checked")
	check(K._check_target({"target": "80/tcp"}, pod).has("none"), "a port that is not published is not checked")
	check(K._check_target({"target": "8123/tcp", "host_network": true}, pod)["host"] == "127.0.0.1", "host networking is checked on loopback")
	var mv = {"net": {"segments": [{"name": "lan30", "driver": "macvlan", "ip": "192.0.2.53"}]}}
	check(K._check_target({"target": "80/tcp"}, mv) == {"host": "192.0.2.53", "port": 80, "proto": "tcp", "local": false}, "a macvlan container is checked at its own address")
	check(K.port_probe("127.0.0.1", 53, "udp")["tcp"] == "unknown", "UDP stays unknown")
	# a listener that answers HTTP: the probe runs on a thread while this one answers
	var server = TCPServer.new()
	var port = 0
	for candidate in range(47810, 47860):
		if server.listen(candidate, "127.0.0.1") == OK:
			port = candidate
			break
	check(port > 0, "a local test listener is open", port)
	var probe = Thread.new()
	probe.start(K.port_probe.bind("127.0.0.1", port, "tcp"))
	var deadline = Time.get_ticks_msec() + 5000
	var conn: StreamPeerTCP = null
	while probe.is_alive() and Time.get_ticks_msec() < deadline:
		if conn == null and server.is_connection_available():
			conn = server.take_connection()
		if conn != null:
			conn.poll()
			if conn.get_available_bytes() > 0:
				conn.get_partial_data(conn.get_available_bytes())
				conn.put_data("HTTP/1.0 204 No Content\r\n\r\n".to_ascii_buffer())
				conn.disconnect_from_host()
				conn = null
		OS.delay_msec(5)
	var r = probe.wait_to_finish()
	server.stop()
	check(r["tcp"] == "connected", "TCP connects to a listener", r)
	check(r["http"] == "HTTP 204", "HTTP is reported separately from TCP", r)
	# the same port, now closed
	var closed = K.port_probe("127.0.0.1", port, "tcp", 2000)
	# Linux and macOS report the refusal; Windows only times out, and says so
	check(closed["tcp"] == "refused or unreachable" or (closed["tcp"] == "timed out" and str(closed.get("note", "")).contains("look the same")),
		"a closed port is never reported as connected, and a timeout says what it cannot tell", closed)
	check(closed["http"] == "", "no HTTP result without a connection", closed)
	print("PORT CHECK PASSED" if failures == 0 else "PORT CHECK FAILED")
	quit(0 if failures == 0 else 1)
