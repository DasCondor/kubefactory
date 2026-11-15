extends VBoxContainer
# The in-game text editor: a plain, Notepad++-style editor for KubeFactory's
# own settings files, and a read-only viewer for files from a container.
#
#   theme        System (the default: follows the computer's light or dark
#                mode), Light or Dark
#   keys         Standard (Notepad++-like shortcuts), Vim (modal: normal,
#                insert, : commands, / search) or Nano (^O ^X ^W ^K ^U ...)
#   view         line numbers, word wrap, font size
#   tools        find / replace, go to line, duplicate / delete / move a line,
#                upper / lower case, trim trailing spaces, sort lines, comment
#
# A container's file opens read-only: storage inspection never writes. JSON is
# checked before it is saved, and the file before the save is kept as .bak.
# Files that hold credentials are not offered (see hud.gd, editor_files()).

signal closed

const THEMES = {
	"dark": {"bg": Color(0.11, 0.12, 0.14), "text": Color(0.86, 0.88, 0.9), "line": Color(0.16, 0.17, 0.2), "num": Color(0.45, 0.48, 0.53),
		"caret": Color(1.0, 0.76, 0.3), "sel": Color(0.26, 0.36, 0.56, 0.85), "string": Color(0.62, 0.85, 0.55), "number": Color(0.96, 0.7, 0.45),
		"symbol": Color(0.7, 0.74, 0.8), "comment": Color(0.5, 0.55, 0.6), "bar": Color(0.07, 0.08, 0.09), "bar_text": Color(0.82, 0.84, 0.87)},
	"light": {"bg": Color(1, 1, 1), "text": Color(0.1, 0.1, 0.12), "line": Color(0.93, 0.95, 1.0), "num": Color(0.52, 0.55, 0.6),
		"caret": Color(0.1, 0.1, 0.12), "sel": Color(0.68, 0.8, 1.0, 0.95), "string": Color(0.64, 0.2, 0.1), "number": Color(0.0, 0.45, 0.2),
		"symbol": Color(0.25, 0.25, 0.3), "comment": Color(0.42, 0.5, 0.42), "bar": Color(0.9, 0.91, 0.93), "bar_text": Color(0.14, 0.14, 0.17)},
}
const KEY_MODES = ["standard", "vim", "nano"]
const NANO_HELP = "^G Help   ^O Write Out   ^W Where Is   ^\\ Replace   ^K Cut   ^U Paste   ^_ Go To Line   M-U Undo   M-E Redo   ^X Exit"

var settings: Dictionary = {}
var save_setting: Callable = Callable()
var files: Array = []          # [[label, path]] that may be edited
var path = ""
var read_only = false
var title = ""

var ed: CodeEdit
var _file_pick: OptionButton
var _theme_pick: OptionButton
var _keys_pick: OptionButton
var _lines_box: CheckBox
var _wrap_box: CheckBox
var _find: LineEdit
var _replace: LineEdit
var _goto: LineEdit
var _save_btn: Button
var _nano_bar: Label
var _status: Label
var _bars: Array = []
var _saved_text = ""
var _msg = ""
var _keys = "standard"
var _vim = "normal"            # normal | insert | command
var _vim_cmd = ""              # what follows ":" or "/" while it is typed
var _vim_pending = ""          # "d", "y", "g" waiting for their second key
var _clip = ""
var _ask_close = false         # nano "Save modified buffer?" / standard "unsaved" prompt

func setup(opts: Dictionary) -> void:
	settings = opts.get("settings", {})
	save_setting = opts.get("save_setting", Callable())
	files = opts.get("files", [])
	path = str(opts.get("path", ""))
	read_only = bool(opts.get("read_only", false))
	title = str(opts.get("title", ""))
	_build()
	if opts.has("text"):
		_load_text(str(opts["text"]))
	elif path != "":
		_open_path(path)
	elif not files.is_empty():
		_open_path(str(files[0][1]))
	else:
		_load_text("")
		_msg = "No editable files here."
	_apply_all()

# ---------------------------------------------------------------- building

func _btn(text: String, cb: Callable) -> Button:
	var b = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _pick(items: Array, current: String, cb: Callable) -> OptionButton:
	var o = OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	for i in items.size():
		o.add_item(str(items[i][1]), i)
		if str(items[i][0]) == current:
			o.select(i)
	o.item_selected.connect(func(i): cb.call(str(items[i][0])))
	return o

func _row() -> HBoxContainer:
	var r = HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	add_child(r)
	_bars.append(r)
	return r

func _build() -> void:
	add_theme_constant_override("separation", 6)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top = _row()
	if read_only or files.is_empty():
		var t = Label.new()
		t.text = title if title != "" else path.get_file()
		top.add_child(t)
	else:
		# the open file is always the one named, even when it is not one of the usual ones
		if path != "" and not files.any(func(f): return str(f[1]) == path):
			files.push_front([path.get_file(), path])
		_file_pick = _pick(files.map(func(f): return [f[1], f[0]]), path, func(p): _switch_to(p))
		top.add_child(_file_pick)
	var sp = Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	_theme_pick = _pick([["system", "Theme: system"], ["light", "Theme: light"], ["dark", "Theme: dark"]], str(settings.get("editor_theme", "system")), func(v): _set_opt("editor_theme", v))
	top.add_child(_theme_pick)
	_keys_pick = _pick([["standard", "Keys: standard"], ["vim", "Keys: Vim"], ["nano", "Keys: Nano"]], str(settings.get("editor_keys", "standard")), func(v): _set_opt("editor_keys", v))
	top.add_child(_keys_pick)
	_lines_box = CheckBox.new()
	_lines_box.text = "Line numbers"
	_lines_box.focus_mode = Control.FOCUS_NONE
	_lines_box.button_pressed = bool(settings.get("editor_lines", true))
	_lines_box.toggled.connect(func(on): _set_opt("editor_lines", on))
	top.add_child(_lines_box)
	_wrap_box = CheckBox.new()
	_wrap_box.text = "Wrap"
	_wrap_box.focus_mode = Control.FOCUS_NONE
	_wrap_box.button_pressed = bool(settings.get("editor_wrap", false))
	_wrap_box.toggled.connect(func(on): _set_opt("editor_wrap", on))
	top.add_child(_wrap_box)
	top.add_child(_btn(" A- ", func(): _set_opt("editor_font", maxi(int(settings.get("editor_font", 15)) - 1, 9))))
	top.add_child(_btn(" A+ ", func(): _set_opt("editor_font", mini(int(settings.get("editor_font", 15)) + 1, 32))))
	_save_btn = _btn("Save", save)
	_save_btn.disabled = read_only
	top.add_child(_save_btn)
	var tools = _row()
	_find = LineEdit.new()
	_find.placeholder_text = "Find"
	_find.custom_minimum_size.x = 200
	_find.text_submitted.connect(func(_t): find_next())
	tools.add_child(_find)
	tools.add_child(_btn("Next", find_next))
	tools.add_child(_btn("Previous", func(): find_next(true)))
	_replace = LineEdit.new()
	_replace.placeholder_text = "Replace with"
	_replace.custom_minimum_size.x = 180
	_replace.editable = not read_only
	tools.add_child(_replace)
	var r1 = _btn("Replace", replace_one)
	r1.disabled = read_only
	tools.add_child(r1)
	var r2 = _btn("All", replace_all)
	r2.disabled = read_only
	tools.add_child(r2)
	_goto = LineEdit.new()
	_goto.placeholder_text = "Line"
	_goto.custom_minimum_size.x = 70
	_goto.text_submitted.connect(func(t): go_to_line(int(t)))
	tools.add_child(_goto)
	tools.add_child(_btn("Go", func(): go_to_line(int(_goto.text))))
	var menu = MenuButton.new()
	menu.text = "Edit"
	menu.flat = false
	var pm = menu.get_popup()
	for item in ["Duplicate line", "Delete line", "Move line up", "Move line down", "UPPERCASE", "lowercase", "Trim trailing spaces", "Sort lines", "Toggle # comment", "Undo", "Redo"]:
		pm.add_item(item)
	pm.id_pressed.connect(_tool)
	menu.disabled = read_only
	tools.add_child(menu)
	ed = CodeEdit.new()
	ed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ed.highlight_current_line = true
	ed.draw_tabs = true
	ed.indent_use_spaces = true
	ed.indent_size = 2
	ed.auto_brace_completion_enabled = false
	ed.editable = not read_only
	ed.gui_input.connect(_on_key)
	ed.caret_changed.connect(_refresh_status)
	ed.text_changed.connect(_refresh_status)
	add_child(ed)
	_nano_bar = Label.new()
	_nano_bar.text = NANO_HELP
	add_child(_nano_bar)
	_status = Label.new()
	add_child(_status)

# ---------------------------------------------------------------- settings and look

func _set_opt(key: String, value) -> void:
	settings[key] = value
	if save_setting.is_valid():
		save_setting.call(key, value)
	_apply_all()

static func theme_of(choice: String) -> String:
	if choice in ["light", "dark"]:
		return choice
	if DisplayServer.is_dark_mode_supported():
		return "dark" if DisplayServer.is_dark_mode() else "light"
	return "dark"

func _apply_all() -> void:
	var c: Dictionary = THEMES[theme_of(str(settings.get("editor_theme", "system")))]
	for k in [["background_color", "bg"], ["font_color", "text"], ["font_readonly_color", "text"], ["current_line_color", "line"], ["line_number_color", "num"],
			["caret_color", "caret"], ["selection_color", "sel"], ["word_highlighted_color", "sel"]]:
		ed.add_theme_color_override(k[0], c[k[1]])
	var sb = StyleBoxFlat.new()
	sb.bg_color = c["bg"]
	sb.set_content_margin_all(6)
	ed.add_theme_stylebox_override("normal", sb)
	ed.add_theme_stylebox_override("read_only", sb)
	ed.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	ed.add_theme_font_size_override("font_size", int(settings.get("editor_font", 15)))
	ed.gutters_draw_line_numbers = bool(settings.get("editor_lines", true))
	ed.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if bool(settings.get("editor_wrap", false)) else TextEdit.LINE_WRAPPING_NONE
	ed.syntax_highlighter = _highlighter(c)
	for l in [_status, _nano_bar]:
		l.add_theme_color_override("font_color", c["bar_text"])
		var lb = StyleBoxFlat.new()
		lb.bg_color = c["bar"]
		lb.set_content_margin_all(4)
		l.add_theme_stylebox_override("normal", lb)
	_keys = str(settings.get("editor_keys", "standard"))
	if not _keys in KEY_MODES:
		_keys = "standard"
	_nano_bar.visible = _keys == "nano"
	_vim = "normal" if _keys == "vim" else "insert"
	_vim_cmd = ""
	_vim_pending = ""
	_caret_look()
	_refresh_status()

func _highlighter(c: Dictionary) -> CodeHighlighter:
	var h = CodeHighlighter.new()
	h.number_color = c["number"]
	h.symbol_color = c["symbol"]
	h.function_color = c["text"]
	h.member_variable_color = c["text"]
	h.add_color_region("\"", "\"", c["string"])
	if not path.to_lower().ends_with(".json"):
		h.add_color_region("#", "", c["comment"], true)
	for w in ["true", "false", "null", "yes", "no"]:
		h.add_keyword_color(w, c["number"])
	return h

func _caret_look() -> void:
	ed.caret_type = TextEdit.CARET_TYPE_BLOCK if _keys == "vim" and _vim != "insert" else TextEdit.CARET_TYPE_LINE

# ---------------------------------------------------------------- files

func _load_text(t: String) -> void:
	ed.text = t
	_saved_text = t
	ed.clear_undo_history()
	ed.set_caret_line(0)
	ed.set_caret_column(0)

func _open_path(p: String) -> void:
	path = p
	var t = FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else ""
	_load_text(t)
	_msg = "" if FileAccess.file_exists(p) else "New file: it is created when you save."

func _switch_to(p: String) -> void:
	if modified():
		_msg = "Save or undo your changes first."
		if _file_pick != null:
			for i in files.size():
				if str(files[i][1]) == path:
					_file_pick.select(i)
		_refresh_status()
		return
	_open_path(p)
	_apply_all()

func modified() -> bool:
	return not read_only and ed.text != _saved_text

func save() -> bool:
	if read_only:
		_msg = "Read-only: this file is not saved anywhere."
		_refresh_status()
		return false
	if path == "":
		_msg = "Nothing to save to."
		_refresh_status()
		return false
	if path.to_lower().ends_with(".json"):
		var j = JSON.new()
		if j.parse(ed.text) != OK:
			_msg = "Not saved: that is not valid JSON (line %d: %s)." % [j.get_error_line(), j.get_error_message()]
			go_to_line(j.get_error_line())
			_refresh_status()
			return false
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_msg = "Could not write %s." % path.get_file()
		_refresh_status()
		return false
	f.store_string(ed.text)
	f.close()
	_saved_text = ed.text
	_msg = "Saved %s (the previous version is %s.bak)." % [path.get_file(), path.get_file()]
	_refresh_status()
	return true

func request_close() -> void:
	if modified():
		_ask_close = true
		_msg = "Unsaved changes.  Y: save and close   N: close without saving   any other key: keep editing"
		_refresh_status()
		ed.grab_focus()
		return
	closed.emit()

# ---------------------------------------------------------------- tools

func _line() -> int:
	return ed.get_caret_line()

func find_next(back: bool = false) -> void:
	var what = _find.text
	if what == "":
		_msg = "Type something to find."
		_refresh_status()
		return
	var flags = TextEdit.SEARCH_BACKWARDS if back else 0
	var from_col = ed.get_caret_column() + (0 if back else 1)
	if back and ed.has_selection():
		from_col = ed.get_selection_from_column()
	var at: Vector2i = ed.search(what, flags, _line(), maxi(from_col - (1 if back else 0), 0))
	if at.x < 0:
		_msg = "\"%s\" not found." % what
	else:
		ed.select(at.y, at.x, at.y, at.x + what.length())
		ed.set_caret_line(at.y)
		ed.set_caret_column(at.x + what.length())
		ed.center_viewport_to_caret()
		_msg = ""
	_refresh_status()

func replace_one() -> void:
	if read_only:
		return
	if ed.has_selection() and ed.get_selected_text() == _find.text and _find.text != "":
		ed.insert_text_at_caret(_replace.text)
	find_next()

func replace_all() -> void:
	if read_only or _find.text == "":
		return
	var n = ed.text.count(_find.text)
	ed.begin_complex_operation()
	ed.text = ed.text.replace(_find.text, _replace.text)
	ed.end_complex_operation()
	_msg = "Replaced %d." % n
	_refresh_status()

func go_to_line(n: int) -> void:
	if n < 1:
		return
	ed.set_caret_line(mini(n, ed.get_line_count()) - 1)
	ed.set_caret_column(0)
	ed.center_viewport_to_caret()
	ed.grab_focus()

func duplicate_line() -> void:
	var l = _line()
	ed.insert_line_at(l + 1, ed.get_line(l))
	ed.set_caret_line(l + 1)

func delete_line() -> String:
	var l = _line()
	var t = ed.get_line(l)
	ed.begin_complex_operation()
	if ed.get_line_count() == 1:
		ed.set_line(0, "")
	elif l < ed.get_line_count() - 1:
		ed.remove_text(l, 0, l + 1, 0)
	else:
		ed.remove_text(l - 1, ed.get_line(l - 1).length(), l, t.length())
		ed.set_caret_line(l - 1)
	ed.end_complex_operation()
	return t

func move_line(d: int) -> void:
	var l = _line()
	var o = l + d
	if o < 0 or o >= ed.get_line_count():
		return
	var a = ed.get_line(l)
	ed.begin_complex_operation()
	ed.set_line(l, ed.get_line(o))
	ed.set_line(o, a)
	ed.end_complex_operation()
	ed.set_caret_line(o)

func _map_lines(f: Callable) -> void:
	var from = _line()
	var to = from
	if ed.has_selection():
		from = ed.get_selection_from_line()
		to = ed.get_selection_to_line()
	ed.begin_complex_operation()
	for i in range(from, to + 1):
		ed.set_line(i, f.call(ed.get_line(i)))
	ed.end_complex_operation()

func _tool(id: int) -> void:
	if read_only:
		return
	match id:
		0: duplicate_line()
		1: delete_line()
		2: move_line(-1)
		3: move_line(1)
		4:
			if ed.has_selection():
				ed.insert_text_at_caret(ed.get_selected_text().to_upper())
			else:
				_map_lines(func(s): return s.to_upper())
		5:
			if ed.has_selection():
				ed.insert_text_at_caret(ed.get_selected_text().to_lower())
			else:
				_map_lines(func(s): return s.to_lower())
		6:
			ed.begin_complex_operation()
			for i in ed.get_line_count():
				ed.set_line(i, ed.get_line(i).rstrip(" \t"))
			ed.end_complex_operation()
		7:
			var lines = ed.text.split("\n")
			lines.sort()
			ed.begin_complex_operation()
			ed.text = "\n".join(lines)
			ed.end_complex_operation()
		8: _map_lines(func(s): return s.trim_prefix("# ") if s.begins_with("# ") else ("# " + s))
		9: ed.undo()
		10: ed.redo()
	_refresh_status()

# ---------------------------------------------------------------- keys

func _on_key(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed:
		return
	var k: InputEventKey = ev
	if _ask_close:
		_ask_close = false
		ed.accept_event()
		if k.keycode == KEY_Y:
			if save():
				closed.emit()
		elif k.keycode == KEY_N:
			_saved_text = ed.text
			closed.emit()
		else:
			_msg = ""
			_refresh_status()
		return
	match _keys:
		"vim":
			_vim_key(k)
		"nano":
			_nano_key(k)
		_:
			_standard_key(k)

func _eat() -> void:
	ed.accept_event()

func _standard_key(k: InputEventKey) -> void:
	if k.keycode == KEY_ESCAPE and modified():
		_eat()
		request_close()
		return
	if not k.ctrl_pressed and not k.alt_pressed:
		return
	if k.ctrl_pressed and not k.shift_pressed:
		match k.keycode:
			KEY_S: save()
			KEY_F: _find.grab_focus()
			KEY_H: _replace.grab_focus()
			KEY_G: _goto.grab_focus()
			KEY_D: _tool(0)
			KEY_SLASH: _tool(8)
			KEY_EQUAL: _set_opt("editor_font", mini(int(settings.get("editor_font", 15)) + 1, 32))
			KEY_MINUS: _set_opt("editor_font", maxi(int(settings.get("editor_font", 15)) - 1, 9))
			_: return
		_eat()
	elif k.ctrl_pressed and k.shift_pressed and k.keycode == KEY_K:
		_eat()
		_tool(1)
	elif k.alt_pressed and k.keycode in [KEY_UP, KEY_DOWN]:
		_eat()
		_tool(2 if k.keycode == KEY_UP else 3)

func _nano_key(k: InputEventKey) -> void:
	if k.alt_pressed and k.keycode in [KEY_U, KEY_E]:
		_eat()
		_tool(9 if k.keycode == KEY_U else 10)
		return
	if not k.ctrl_pressed:
		return
	match k.keycode:
		KEY_O: save()
		KEY_X:
			if modified():
				_ask_close = true
				_msg = "Save modified buffer?   Y Yes   N No   any other key: Cancel"
				_refresh_status()
			else:
				closed.emit()
		KEY_W: _find.grab_focus()
		KEY_BACKSLASH: _replace.grab_focus()
		KEY_K:
			if not read_only:
				_clip += delete_line() + "\n"
		KEY_U:
			if not read_only and _clip != "":
				ed.insert_line_at(_line(), _clip.trim_suffix("\n"))
				_clip = ""
		KEY_MINUS: _goto.grab_focus()      # ^_ (Ctrl+Shift+minus on most keyboards)
		KEY_G: _nano_bar.visible = not _nano_bar.visible
		_: return
	_eat()

# Vim, the parts people reach for: h j k l w b 0 ^ $ gg G, x dd yy p P u ^R,
# i a A I o O, / n N, and :w :q :q! :wq :x :<line> :set nu / nonu / wrap / nowrap.
func _vim_key(k: InputEventKey) -> void:
	if _vim == "insert":
		if k.keycode == KEY_ESCAPE or (k.ctrl_pressed and k.keycode == KEY_BRACKETLEFT):
			_eat()
			_vim = "normal"
			ed.set_caret_column(maxi(ed.get_caret_column() - 1, 0))
			_caret_look()
			_refresh_status()
		return
	_eat()
	if _vim == "command":
		match k.keycode:
			KEY_ESCAPE:
				_vim = "normal"
				_vim_cmd = ""
			KEY_ENTER, KEY_KP_ENTER:
				var c = _vim_cmd
				_vim = "normal"
				_vim_cmd = ""
				_vim_run(c)
			KEY_BACKSPACE:
				_vim_cmd = _vim_cmd.left(-1)
				if _vim_cmd == "":
					_vim = "normal"
			_:
				if k.unicode >= 32:
					_vim_cmd += char(k.unicode)
		_refresh_status()
		return
	var ch = char(k.unicode) if k.unicode >= 32 else ""
	if k.ctrl_pressed and k.keycode == KEY_R:
		ed.redo()
	elif k.keycode == KEY_ESCAPE:
		_vim_pending = ""
	elif _vim_pending != "":
		var p = _vim_pending + ch
		_vim_pending = ""
		match p:
			"dd":
				if not read_only:
					_clip = delete_line() + "\n"
			"yy":
				_clip = ed.get_line(_line()) + "\n"
				_msg = "1 line yanked"
			"gg":
				go_to_line(1)
	else:
		match ch:
			"h": ed.set_caret_column(maxi(ed.get_caret_column() - 1, 0))
			"l": ed.set_caret_column(ed.get_caret_column() + 1)
			"j": ed.set_caret_line(mini(_line() + 1, ed.get_line_count() - 1))
			"k": ed.set_caret_line(maxi(_line() - 1, 0))
			"0": ed.set_caret_column(0)
			"^": ed.set_caret_column(ed.get_line(_line()).length() - ed.get_line(_line()).strip_edges(true, false).length())
			"$": ed.set_caret_column(ed.get_line(_line()).length())
			"w": _vim_word(1)
			"b": _vim_word(-1)
			"G": go_to_line(ed.get_line_count())
			"x":
				if not read_only and ed.get_caret_column() < ed.get_line(_line()).length():
					var c = ed.get_caret_column()
					ed.remove_text(_line(), c, _line(), c + 1)
			"d", "y", "g": _vim_pending = ch
			"p", "P":
				if not read_only and _clip != "":
					if _clip.ends_with("\n"):
						var at = _line() + (1 if ch == "p" else 0)
						if at < ed.get_line_count():
							ed.insert_line_at(at, _clip.trim_suffix("\n"))
						else:
							_append_line(_clip.trim_suffix("\n"))
						ed.set_caret_line(mini(at, ed.get_line_count() - 1))
					else:
						ed.insert_text_at_caret(_clip)
			"u": ed.undo()
			"i", "a", "A", "I", "o", "O":
				if read_only:
					_msg = "E21: cannot make changes, this file is read-only"
				else:
					match ch:
						"a": ed.set_caret_column(ed.get_caret_column() + 1)
						"A": ed.set_caret_column(ed.get_line(_line()).length())
						"I": ed.set_caret_column(ed.get_line(_line()).length() - ed.get_line(_line()).strip_edges(true, false).length())
						"o":
							_append_after(_line())
						"O":
							ed.insert_line_at(_line(), "")
							ed.set_caret_line(_line() - 1 if _line() > 0 else 0)
							ed.set_caret_column(0)
					_vim = "insert"
			":", "/":
				_vim = "command"
				_vim_cmd = ch
			"n": find_next()
			"N": find_next(true)
	_caret_look()
	_refresh_status()

func _append_line(t: String) -> void:
	var last = ed.get_line_count() - 1
	ed.insert_text("\n" + t, last, ed.get_line(last).length())

func _append_after(l: int) -> void:
	if l >= ed.get_line_count() - 1:
		_append_line("")
	else:
		ed.insert_line_at(l + 1, "")
	ed.set_caret_line(l + 1)
	ed.set_caret_column(0)

func _vim_word(d: int) -> void:
	var l = _line()
	var c = ed.get_caret_column()
	var s = ed.get_line(l)
	if d > 0:
		var i = c
		while i < s.length() and s[i] != " ":
			i += 1
		while i < s.length() and s[i] == " ":
			i += 1
		if i >= s.length() and l < ed.get_line_count() - 1:
			ed.set_caret_line(l + 1)
			ed.set_caret_column(0)
		else:
			ed.set_caret_column(i)
	else:
		var i = c - 1
		while i > 0 and s[i] == " ":
			i -= 1
		while i > 0 and s[i - 1] != " ":
			i -= 1
		ed.set_caret_column(maxi(i, 0))

func _vim_run(c: String) -> void:
	if c.begins_with("/"):
		_find.text = c.substr(1)
		find_next()
		return
	var cmd = c.trim_prefix(":").strip_edges()
	match cmd:
		"w": save()
		"q":
			if modified():
				_msg = "E37: No write since last change (add ! to override)"
			else:
				closed.emit()
		"q!":
			_saved_text = ed.text
			closed.emit()
		"wq", "x":
			if not modified() or save():
				closed.emit()
		"set nu", "set number": _set_opt("editor_lines", true)
		"set nonu", "set nonumber": _set_opt("editor_lines", false)
		"set wrap": _set_opt("editor_wrap", true)
		"set nowrap": _set_opt("editor_wrap", false)
		_:
			if cmd.is_valid_int():
				go_to_line(int(cmd))
			else:
				_msg = "E492: Not an editor command: " + cmd

# ---------------------------------------------------------------- status

func mode_text() -> String:
	match _keys:
		"vim":
			match _vim:
				"insert": return "-- INSERT --"
				"command": return _vim_cmd
				_: return "-- NORMAL --" + ("  " + _vim_pending if _vim_pending != "" else "")
		"nano":
			return "nano"
	return "standard keys"

func _refresh_status() -> void:
	if _status == null or ed == null:
		return
	var parts = PackedStringArray(["Ln %d, Col %d" % [_line() + 1, ed.get_caret_column() + 1], "%d lines" % ed.get_line_count(), mode_text()])
	if read_only:
		parts.append("read-only")
	elif modified():
		parts.append("modified")
	if _msg != "":
		parts.append(_msg)
	_status.text = "   ·   ".join(parts)
