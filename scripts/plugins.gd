extends RefCounted
# Backend plugins (docs/PLUGINS.md): finding them and trusting them.
#
# A plugin is a folder with a plugin.json and the program it names. It runs
# as its own process and speaks JSON lines (backend_plugin.gd). Nothing in a
# plugin folder runs until the operator has trusted that exact plugin: the
# trust is kept as a SHA-256 over plugin.json and every file it lists, so a
# changed plugin is untrusted again until approved anew (as kubeconfig
# credential helpers are, connections.gd).
#
# Folders searched: <game folder>/plugins and <user data>/plugins.

const K = preload("res://scripts/kutil.gd")

const API = 1
const MAX_FILES = 64

static func dirs() -> Array:
	return [K.data_path("plugins"), OS.get_user_data_dir().path_join("plugins")]

# [{id, name, version, description, dir, command, files, hash, trusted, actions_allowed, error}]
static func discover() -> Array:
	var out = []
	var trust = _trust()
	for base in dirs():
		var d = DirAccess.open(base)
		if d == null:
			continue
		for sub in d.get_directories():
			var p = load_manifest(base.path_join(sub))
			p["trusted"] = p["error"] == "" and trust.get(p["id"], {}).get("hash", "") == p["hash"]
			p["actions_allowed"] = p["trusted"] and bool(trust.get(p["id"], {}).get("actions", false))
			out.append(p)
	return out

static func load_manifest(dir: String) -> Dictionary:
	var p = {"id": dir.get_file(), "name": dir.get_file(), "version": "", "description": "", "dir": dir, "command": [], "files": [], "hash": "", "error": ""}
	var m = K.read_json(dir.path_join("plugin.json"))
	if typeof(m) != TYPE_DICTIONARY:
		p["error"] = "plugin.json is missing or not JSON"
		return p
	if int(m.get("api", 0)) != API:
		p["error"] = "written for plugin API %s; this KubeFactory speaks %d" % [str(m.get("api", "?")), API]
		return p
	var cmd = m.get("command", [])
	if typeof(cmd) != TYPE_ARRAY or cmd.is_empty() or not cmd.all(func(x): return typeof(x) == TYPE_STRING):
		p["error"] = "plugin.json needs a command: a list of strings"
		return p
	var files = m.get("files", [])
	if typeof(files) != TYPE_ARRAY or files.size() > MAX_FILES or not files.all(func(x): return typeof(x) == TYPE_STRING and not str(x).contains("..") and not str(x).is_absolute_path()):
		p["error"] = "plugin.json files must be a list of paths inside the plugin folder"
		return p
	p["name"] = str(m.get("name", p["id"])).left(60)
	p["version"] = str(m.get("version", "")).left(20)
	p["description"] = str(m.get("description", "")).left(300)
	p["command"] = cmd
	p["files"] = files
	# the hash covers the manifest and every file it says the plugin is made of
	var h = HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(FileAccess.get_file_as_bytes(dir.path_join("plugin.json")))
	for f in files:
		var full = dir.path_join(f)
		if not FileAccess.file_exists(full):
			p["error"] = "listed file %s is missing" % f
			return p
		h.update(str(f).to_utf8_buffer())
		h.update(FileAccess.get_file_as_bytes(full))
	p["hash"] = h.finish().hex_encode()
	return p

static func _trust_path() -> String:
	return OS.get_user_data_dir().path_join("plugin-trust.json")

static func _trust() -> Dictionary:
	var t = K.read_json(_trust_path())
	return t if typeof(t) == TYPE_DICTIONARY else {}

static func _save_trust(t: Dictionary) -> void:
	var f = FileAccess.open(_trust_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(t, "  "))
		f.close()

# Trust exactly this version of a plugin (its hash). actions: may it change infrastructure.
static func set_trust(p: Dictionary, trusted: bool, actions: bool = false) -> void:
	var t = _trust()
	if trusted and p.get("error", "") == "":
		t[p["id"]] = {"hash": p["hash"], "actions": actions, "name": p["name"], "at": Time.get_datetime_string_from_system(true)}
	else:
		t.erase(p["id"])
	_save_trust(t)

static func find(id: String) -> Dictionary:
	for p in discover():
		if p["id"] == id:
			return p
	return {}
