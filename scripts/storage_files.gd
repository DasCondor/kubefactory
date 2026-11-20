extends RefCounted
# Shared limits for the editor and its backends. The writer receives data on stdin.

const LIMIT = 65536

static func text_problem(bytes: PackedByteArray) -> String:
	if bytes.size() > LIMIT:
		return "Editing is limited to complete text files of 64 KiB or less."
	for b in bytes:
		if b == 0 or b < 9 or (b > 13 and b < 32):
			return "Binary files and databases can be inspected, but not edited."
	if bytes.get_string_from_utf8().to_utf8_buffer() != bytes:
		return "Only UTF-8 text files can be edited."
	return ""

static func write_problem(a: Dictionary) -> String:
	var hash = str(a.get("expected", ""))
	if hash.length() != 64 or not hash.is_valid_hex_number(false):
		return "Reopen the complete file before saving."
	var path = str(a.get("path", ""))
	if path.contains("\n") or path.contains("\r") or str(a.get("root", "")).contains("\n") or str(a.get("root", "")).contains("\r"):
		return "Paths containing line breaks cannot be edited."
	return text_problem(str(a.get("text", "")).to_utf8_buffer())

static func result(line: String) -> Dictionary:
	var ok = line.begins_with("OK ")
	return {"ok": ok, "kind": "" if ok else "invalid", "msg": "Saved. Previous file: " + line.trim_prefix("OK ") if ok else line.trim_prefix("ERROR "),
		"data": {"backup": line.trim_prefix("OK ")} if ok else {}}

static func exchange(pipe: FileAccess, input: String, result: Array) -> void:
	pipe.store_string(input + "\n")
	pipe.flush()
	result.append(pipe.get_line())

static func cli_args(args: PackedStringArray) -> PackedStringArray:
	# Godot 4.3 wraps Windows arguments but does not escape their inner quotes.
	if OS.get_name() == "Windows":
		for i in args.size():
			args[i] = args[i].replace("\"", "\\\"")
	return args

static func docker_write(args: PackedStringArray, a: Dictionary) -> Dictionary:
	args = cli_args(args)
	var proc = OS.execute_with_pipe("docker", args)
	if proc.is_empty():
		return result("ERROR Could not start Docker.")
	var answer = []
	var worker = Thread.new()
	worker.start(exchange.bind(proc["stdio"], Marshalls.utf8_to_base64(str(a["text"])) if str(a["text"]) != "" else "", answer))
	var deadline = Time.get_ticks_msec() + 20000
	while worker.is_alive() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(20)
	if worker.is_alive():
		OS.kill(proc["pid"])
	worker.wait_to_finish()
	proc["stdio"].close()
	proc["stderr"].close()
	return result(str(answer[0]) if not answer.is_empty() and str(answer[0]) != "" else "ERROR Save did not finish. Reopen the file to check its contents before retrying.")
