extends Node
# Browser "High" graphics: fetches the model library's Standard-tier machines
# and Krew from the same site the demo is served from (<site>/model-viewer/
# assets/, published by .github/workflows/pages.yml), checks every file
# against the catalog's SHA-256, and hands the bytes to models.gd.
#
# Same origin only, read-only, about 13 MB once per visit (the browser's cache
# keeps it). Anything missing or not matching its checksum is left out, and the
# game draws that model in code as on Standard.

const Models = preload("res://scripts/models.gd")

signal progress(done_bytes, total_bytes)
signal finished(ok, msg)

const CATEGORIES = ["machines", "krew", "tools"]
const PARALLEL = 4

var base = ""
var _queue = []
var _files = {}
var _catalog = {}
var _done = 0
var _total = 0
var _active = 0
var _bad = 0

static func site_base() -> String:
	if not OS.has_feature("web"):
		return ""
	return str(JavaScriptBridge.eval("new URL('model-viewer/assets/', location.href).href", true))

func fetch(asset_base: String = "") -> void:
	base = asset_base if asset_base != "" else site_base()
	if base == "":
		finished.emit(false, "No address for the model library.")
		return
	_http_get(base + "catalog.json", func(code, body: PackedByteArray):
		var d = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
		if typeof(d) != TYPE_DICTIONARY or typeof(d.get("models")) != TYPE_ARRAY:
			finished.emit(false, "The model library's catalog could not be read (HTTP %d)." % code)
			return
		_catalog = d
		for m in d["models"]:
			if not str(m.get("category", "")) in CATEGORIES:
				continue
			var v = m.get("variants", {}).get("standard")
			if typeof(v) != TYPE_DICTIONARY:
				continue
			_queue.append(v)
			_total += int(v.get("bytes", 0))
		progress.emit(0, _total)
		for i in PARALLEL:
			_next())

var _ended = false

func _next() -> void:
	if _queue.is_empty():
		if _active == 0 and not _ended:
			_ended = true
			Models.web_load(_catalog, _files)
			finished.emit(not _files.is_empty(), "%d models loaded%s." % [_files.size(), (", %d left out" % _bad) if _bad > 0 else ""])
		return
	var v = _queue.pop_front()
	var rel = str(v["path"]).trim_prefix("assets/")
	_active += 1
	_http_get(base + rel, func(code, body: PackedByteArray):
		_active -= 1
		if code == 200 and _sha256(body) == str(v.get("sha256", "")):
			_files[rel] = body
		else:
			_bad += 1
			if _bad <= 3:
				print("model library: %s left out (HTTP %d, %d bytes)" % [rel, code, body.size()])
		_done += int(v.get("bytes", 0))
		progress.emit(_done, _total)
		_next())

func _http_get(url: String, done: Callable) -> void:
	var r = HTTPRequest.new()
	r.max_redirects = 0
	# In the browser, fetch() has already unpacked a gzipped answer (GitHub
	# Pages gzips JSON and .glb) but the Content-Encoding header is still
	# there, so Godot would inflate it a second time and get nothing: the
	# catalog failed with HTTP 200. The browser negotiates compression itself.
	r.accept_gzip = false
	add_child(r)
	r.request_completed.connect(func(_result, code, _headers, body):
		r.queue_free()
		done.call(code, body))
	if r.request(url) != OK:
		r.queue_free()
		done.call(0, PackedByteArray())

static func _sha256(b: PackedByteArray) -> String:
	var h = HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(b)
	return h.finish().hex_encode()
