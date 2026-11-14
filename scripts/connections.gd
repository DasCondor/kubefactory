extends RefCounted
# Saved cluster connections: which kubeconfigs the player has added, and which
# credential helpers they have approved.
#
# A connection is a pointer to a kubeconfig file. The file stays where it is and
# is read only by the native companion when connecting; its contents are never
# copied into settings, logs, the audit trail or anything sent elsewhere.
# A pasted kubeconfig has no file, so it is written to the game's own user folder
# (connections/<id>.yaml, readable only through this account) and treated the same.

const K = preload("res://scripts/kutil.gd")
const Agent = preload("res://scripts/agent.gd")

static func _file() -> String:
	return OS.get_user_data_dir().path_join("connections.json")

static func _dir() -> String:
	return OS.get_user_data_dir().path_join("connections")

static func _load() -> Dictionary:
	var d = K.read_json(_file())
	if typeof(d) != TYPE_DICTIONARY:
		d = {}
	if typeof(d.get("profiles")) != TYPE_ARRAY:
		d["profiles"] = []
	if typeof(d.get("trusted_exec")) != TYPE_ARRAY:
		d["trusted_exec"] = []
	return d

static func _save(d: Dictionary) -> void:
	var f = FileAccess.open(_file(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "  "))
		f.close()

# Saved profiles, preceded by the kubeconfig in its default place if there is
# one and it has not been added by hand: [{id, name, path, base_dir, pasted, implicit}]
static func profiles() -> Array:
	var res = []
	var d = _load()
	var known = {}
	for p in d["profiles"]:
		if FileAccess.file_exists(str(p.get("path", ""))):
			known[str(p["path"]).to_lower().replace("\\", "/")] = true
			res.append(p)
	if Agent.available():
		var r = Agent.request("kubeconfig.discover", {}, 10.0)
		if r["ok"]:
			# As kubectl does: the files KUBECONFIG names come first when it is set,
			# then the default location. Neither is copied or saved.
			var found = []
			var env_n = 0
			for f in r["data"].get("files", []):
				var p = str(f["path"])
				if known.has(p.to_lower().replace("\\", "/")):
					continue
				known[p.to_lower().replace("\\", "/")] = true
				if str(f.get("why", "")) == "default location":
					found.append({"id": "default", "name": "Default kubeconfig", "path": p, "base_dir": "", "pasted": false, "implicit": true})
				else:
					found.insert(env_n, {"id": "env%d" % env_n, "name": "KUBECONFIG: " + p.get_file(), "path": p, "base_dir": "", "pasted": false, "implicit": true})
					env_n += 1
			res = found + res
	return res

static func find(id: String) -> Dictionary:
	for p in profiles():
		if str(p["id"]) == id:
			return p
	return {}

static func _new_id(d: Dictionary) -> String:
	var n = 1
	var used = {}
	for p in d["profiles"]:
		used[str(p["id"])] = true
	while used.has("c%d" % n):
		n += 1
	return "c%d" % n

static func add_file(path: String, name: String = "") -> Dictionary:
	var d = _load()
	for p in d["profiles"]:
		if str(p.get("path", "")).to_lower() == path.to_lower():
			return p
	var p = {"id": _new_id(d), "name": name if name != "" else path.get_file(), "path": path, "base_dir": "", "pasted": false}
	d["profiles"].append(p)
	_save(d)
	return p

# base_dir: where the files a pasted kubeconfig refers to by relative path live ("" if it has none).
static func add_pasted(content: String, name: String, base_dir: String = "") -> Dictionary:
	var d = _load()
	DirAccess.make_dir_recursive_absolute(_dir())
	var id = _new_id(d)
	var path = _dir().path_join(id + ".yaml")
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {}
	f.store_string(content)
	f.close()
	var p = {"id": id, "name": name if name != "" else "Pasted kubeconfig", "path": path, "base_dir": base_dir, "pasted": true}
	d["profiles"].append(p)
	_save(d)
	return p

static func remove(id: String) -> void:
	var d = _load()
	for p in d["profiles"]:
		if str(p["id"]) == id:
			if p.get("pasted", false) and str(p.get("path", "")).begins_with(_dir()):
				DirAccess.remove_absolute(str(p["path"]))   # our own copy; a file the player pointed at is never deleted
			d["profiles"].erase(p)
			break
	_save(d)

static func set_base_dir(id: String, dir: String) -> void:
	var d = _load()
	for p in d["profiles"]:
		if str(p["id"]) == id:
			p["base_dir"] = dir
	_save(d)

# A credential helper is approved per kubeconfig file + context + exact command.
static func _exec_key(prof: Dictionary, context: String, command: String) -> String:
	return "%s|%s|%s" % [str(prof.get("path", "")).to_lower(), context, command]

static func exec_trusted(prof: Dictionary, context: String, command: String) -> bool:
	return command != "" and _load()["trusted_exec"].has(_exec_key(prof, context, command))

static func trust_exec(prof: Dictionary, context: String, command: String) -> void:
	var d = _load()
	var k = _exec_key(prof, context, command)
	if not d["trusted_exec"].has(k):
		d["trusted_exec"].append(k)
		_save(d)

# What the agent needs to open this profile: a path, or pasted content with its base dir.
static func source_of(prof: Dictionary) -> Dictionary:
	if prof.get("pasted", false):
		return {"content": FileAccess.get_file_as_string(str(prof["path"])), "base_dir": str(prof.get("base_dir", ""))}
	return {"path": str(prof["path"])}
