extends SceneTree
# The in-game text editor, driven with real key events:
#   ... -s tests/live/editor_test.gd -- --demo
# It edits a throw-away file in the user folder (removed afterwards), never the
# game's own settings files. KF_SHOTS=<dir> saves screenshots. The operator's
# settings.json is restored.

var _fails = []
var game

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(200)])
	if not ok:
		_fails.append(what)

func _key(code: int, ch: String = "", ctrl = false, shift = false, alt = false) -> void:
	for down in [true, false]:
		var e = InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.unicode = ch.unicode_at(0) if ch != "" else 0
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		e.alt_pressed = alt
		e.pressed = down
		root.push_input(e)
		await process_frame

func _type(s: String) -> void:
	for c in s:
		var code = OS.find_keycode_from_string(c.to_upper()) if c != ":" and c != "/" and c != "$" else KEY_NONE
		await _key(code, c)

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_SHOTS")
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	await create_timer(0.4).timeout
	root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _open(path: String, ro = false, text = null):
	game.hud.open_editor(path, text, ro, "test")
	for i in 6:
		await process_frame
	var te = game.hud._editor
	te.ed.grab_focus()
	await process_frame
	return te

func _run() -> void:
	var spath = OS.get_user_data_dir().path_join("settings.json")
	var before = FileAccess.get_file_as_string(spath) if FileAccess.file_exists(spath) else ""
	var dir = OS.get_user_data_dir().path_join("editor-test")
	DirAccess.make_dir_recursive_absolute(dir)
	var file = dir.path_join("sample.json")
	var f = FileAccess.open(file, FileAccess.WRITE)
	f.store_string("{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n")
	f.close()
	game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	var deadline = Time.get_ticks_msec() + 25000
	while game.cluster.backend == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.2).timeout
	await create_timer(1.0).timeout
	game.hud.close_modal(false)
	var hud = game.hud
	# what it offers
	var offered = hud.editor_files().map(func(e): return str(e[0]))
	_check("files that hold credentials are not offered", not offered.any(func(n): return n.get_file() in ["portainer.json", "vpn.env"]), offered)
	# --- standard keys, dark theme, line numbers
	hud._save_setting("editor_keys", "standard")
	hud._save_setting("editor_theme", "dark")
	hud._save_setting("editor_lines", true)
	var te = await _open(file)
	_check("it opens the file", te.ed.get_line_count() >= 5 and te.ed.get_line(1).contains("\"a\""), te.ed.get_line(1))
	_check("and names it in the file list", te._file_pick.get_item_text(te._file_pick.selected) == "sample.json", te._file_pick.get_item_text(te._file_pick.selected))
	_check("dark theme", te.ed.get_theme_color("background_color").get_luminance() < 0.3)
	_check("line numbers on", te.ed.gutters_draw_line_numbers)
	await _shot("editor_dark")
	te.ed.set_caret_line(1)
	await _key(KEY_D, "d", true)
	_check("Ctrl+D duplicates the line", te.ed.get_line(2) == te.ed.get_line(1), te.ed.get_line(2))
	var moved = te.ed.get_line(te.ed.get_caret_line())
	var from_line = te.ed.get_caret_line()
	await _key(KEY_DOWN, "", false, false, true)
	_check("Alt+Down moves the line down", te.ed.get_caret_line() == from_line + 1 and te.ed.get_line(from_line + 1) == moved, te.ed.get_caret_line())
	te.ed.text = "{ not json"
	await _key(KEY_S, "s", true)
	_check("invalid JSON is not saved", FileAccess.get_file_as_string(file).contains("\"a\""), te._msg)
	te.ed.text = "{\n  \"a\": 10\n}\n"
	await _key(KEY_S, "s", true)
	_check("Ctrl+S saves, and keeps the old file as .bak", FileAccess.get_file_as_string(file).contains("10") and FileAccess.file_exists(file + ".bak"), te._msg)
	# unsaved changes are not thrown away by Esc / X
	te.ed.text = "{\n  \"a\": 11\n}\n"
	hud.close_modal()
	await process_frame
	_check("closing with unsaved changes asks first", hud._modal_kind == "editor" and te._ask_close, te._msg)
	await _key(KEY_N, "n")
	await process_frame
	_check("N closes without saving", hud._modal_kind != "editor" and FileAccess.get_file_as_string(file).contains("10"))
	# --- light theme, line numbers off
	hud._save_setting("editor_theme", "light")
	hud._save_setting("editor_lines", false)
	te = await _open(file)
	_check("light theme", te.ed.get_theme_color("background_color").get_luminance() > 0.8)
	_check("line numbers off", not te.ed.gutters_draw_line_numbers)
	await _shot("editor_light")
	hud._editor_closing = true
	hud.close_modal()
	# --- Vim
	hud._save_setting("editor_keys", "vim")
	hud._save_setting("editor_theme", "system")
	hud._save_setting("editor_lines", true)
	te = await _open(file)
	_check("Vim starts in normal mode with a block caret", te._vim == "normal" and te.ed.caret_type == TextEdit.CARET_TYPE_BLOCK, te.mode_text())
	var lines0 = te.ed.get_line_count()
	await _type("dd")
	_check("dd deletes a line", te.ed.get_line_count() == lines0 - 1, te.ed.get_line_count())
	await _type("u")
	_check("u undoes it", te.ed.get_line_count() == lines0, te.ed.get_line_count())
	var l0 = te.ed.get_line(te.ed.get_caret_line())
	await _type("x")
	_check("x deletes a character", te.ed.get_line(te.ed.get_caret_line()).length() == l0.length() - 1)
	await _type("u")
	await _type("i")
	_check("i enters insert mode", te._vim == "insert", te.mode_text())
	await _key(KEY_ESCAPE)
	_check("Esc goes back to normal mode (and does not close the editor)", te._vim == "normal" and hud._modal_kind == "editor")
	await _shot("editor_vim")
	await _type(":w")
	await _key(KEY_ENTER)
	_check(":w saves", not te.modified(), te._msg)
	await _type(":q")
	await _key(KEY_ENTER)
	await process_frame
	_check(":q closes", hud._modal_kind != "editor")
	# --- Nano
	hud._save_setting("editor_keys", "nano")
	te = await _open(file)
	_check("Nano shows its help line", te._nano_bar.visible and te._nano_bar.text.contains("^O Write Out"))
	await _shot("editor_nano")
	te.ed.set_caret_line(1)
	var cut = te.ed.get_line(1)
	await _key(KEY_K, "k", true)
	_check("^K cuts the line", te.ed.get_line(1) != cut and te._clip.contains(cut.strip_edges()))
	await _key(KEY_U, "u", true)
	_check("^U pastes it back", te.ed.get_line(1) == cut, te.ed.get_line(1))
	await _key(KEY_O, "o", true)
	_check("^O writes the file out", not te.modified(), te._msg)
	await _key(KEY_X, "x", true)
	await process_frame
	_check("^X exits", hud._modal_kind != "editor")
	# --- a container's file: read-only
	hud._save_setting("editor_keys", "standard")
	te = await _open("", true, "server {\n  listen 80;\n}\n")
	_check("a container's file opens read-only", not te.ed.editable and te._save_btn.disabled and not te.save())
	hud.close_modal()
	# tidy up
	for n in ["sample.json", "sample.json.bak"]:
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
	game.queue_free()
	await process_frame
	if before == "":
		DirAccess.remove_absolute(spath)
	else:
		var sf = FileAccess.open(spath, FileAccess.WRITE)
		sf.store_string(before)
		sf.close()
	print("EDITOR PASSED" if _fails.is_empty() else "EDITOR FAILED: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
