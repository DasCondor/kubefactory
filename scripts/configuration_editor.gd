extends VBoxContainer

signal closed
signal exported(path)

const Editor = preload("res://scripts/text_editor.gd")
var editor
var approval = ConfirmationDialog.new()
var filename = "configuration.yaml"
var _snapshot = ""
var _upload_callback
var _read_callback
var _file_input
var _file_reader
var _file_overlay
var _cancel_callback
var _browser_filename = ""
var _status = Label.new()
var _json = false

func setup(text: String, name: String, settings: Dictionary, save_setting: Callable) -> void:
	filename = name.get_file()
	_json = filename.get_extension().to_lower() == "json"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var toolbar = HFlowContainer.new()
	add_child(toolbar)
	for action in [["Open plan JSON" if _json else "Open YAML", _open], ["Export plan JSON" if _json else "Export YAML", request_export]]:
		var button = Button.new()
		button.text = action[0]
		button.pressed.connect(action[1])
		toolbar.add_child(button)
	_status.text = ("Local build plan JSON." if _json else ("Docker Compose draft. VLAN and route labels need real network policy." if filename.begins_with("compose") else "Kubernetes / k3s.")) + " Review and approve the export. No cluster or engine changes are made here."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	editor = Editor.new()
	add_child(editor)
	editor.setup({"text": text, "title": filename, "path": OS.get_user_data_dir().path_join("configuration-draft.json" if _json else "configuration-draft.yaml"), "settings": settings, "save_setting": save_setting})
	editor._save_btn.text = "Save draft"
	editor.closed.connect(func(): closed.emit())
	approval.title = "Approve plan export" if _json else "Approve YAML export"
	approval.exclusive = true
	approval.dialog_autowrap = true
	approval.ok_button_text = "Approve export"
	approval.confirmed.connect(_approved)
	add_child(approval)

func request_export() -> void:
	_snapshot = editor.ed.text
	if _json:
		var candidate = JSON.parse_string(_snapshot)
		var plan = preload("res://scripts/build_plan.gd")
		var problem = plan.problem(plan.migrate(candidate) if candidate is Dictionary else {})
		if problem != "":
			_status.text = problem
			return
	if _snapshot.strip_edges() == "":
		_status.text = "Add or open a YAML configuration first."
		return
	approval.dialog_text = "Export %s?\n\nYou are approving the %s currently shown in the editor.\nThe configuration will be saved or downloaded for your review." % [filename, "plan JSON" if _json else "YAML"]
	approval.popup_centered(Vector2i(mini(440, int(get_viewport_rect().size.x) - 24), 180))
	approval.get_cancel_button().grab_focus.call_deferred()

func _approved() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(_snapshot.to_utf8_buffer(), filename, "application/json" if _json else "application/yaml")
		_mark_exported(filename)
		return
	DisplayServer.file_dialog_show("Export reviewed plan" if _json else "Export reviewed YAML", OS.get_environment("USERPROFILE"), filename, false,
		DisplayServer.FILE_DIALOG_MODE_SAVE_FILE, PackedStringArray(["*.json;Build plan JSON" if _json else "*.yaml,*.yml;YAML configuration"]), _save_selected)

func _save_selected(ok: bool, paths: PackedStringArray, _filter: int) -> void:
	if not ok or paths.is_empty():
		return
	var error = write_file(paths[0], _snapshot)
	if error != OK:
		_status.text = "Export failed: " + error_string(error)
		return
	_mark_exported(paths[0])

static func write_file(path: String, text: String) -> Error:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.flush()
	var error = file.get_error()
	file.close()
	return error

func _mark_exported(path: String) -> void:
	_status.text = "Exported " + path
	if editor.ed.text == _snapshot:
		editor._saved_text = _snapshot
	exported.emit(path)

func _open() -> void:
	if editor.modified():
		_status.text = "Save your draft or export it before opening another configuration."
		return
	if OS.has_feature("web"):
		var document = JavaScriptBridge.get_interface("document")
		if _file_overlay != null:
			_file_overlay.remove()
		_file_overlay = document.createElement("div")
		_file_overlay.setAttribute("role", "dialog")
		_file_overlay.setAttribute("aria-label", "Open build plan JSON" if _json else "Open YAML configuration")
		_file_overlay.setAttribute("style", "position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:10000;width:380px;max-width:calc(100% - 32px);box-sizing:border-box;padding:24px;background:#171c20;color:white;border:2px solid #fa9448;box-shadow:0 0 0 100vmax #000a;font:16px sans-serif")
		var label = document.createElement("label")
		label.textContent = "Choose a build plan JSON file" if _json else "Choose a YAML configuration"
		_file_input = document.createElement("input")
		_file_input.type = "file"
		_file_input.accept = ".json" if _json else ".yaml,.yml"
		_file_input.setAttribute("aria-label", "Choose plan JSON file" if _json else "Choose YAML file")
		_file_input.setAttribute("style", "display:block;width:100%;margin:18px 0;font-size:16px")
		label.appendChild(_file_input)
		_file_overlay.appendChild(label)
		var cancel = document.createElement("button")
		cancel.textContent = "Cancel"
		_cancel_callback = JavaScriptBridge.create_callback(_cancel_browser_file)
		cancel.addEventListener("click", _cancel_callback)
		_file_overlay.appendChild(cancel)
		document.body.appendChild(_file_overlay)
		_upload_callback = JavaScriptBridge.create_callback(_browser_file_selected)
		_file_input.addEventListener("change", _upload_callback)
		_file_input.focus()
		return
	DisplayServer.file_dialog_show("Open build plan JSON" if _json else "Open YAML configuration", OS.get_environment("USERPROFILE"), "", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.json;Build plan JSON" if _json else "*.yaml,*.yml;YAML configuration"]), _open_selected)

func _open_selected(ok: bool, paths: PackedStringArray, _filter: int) -> void:
	if not ok or paths.is_empty():
		return
	var file = FileAccess.open(paths[0], FileAccess.READ)
	if file == null:
		_status.text = "Could not read the selected file."
		return
	load_yaml(file.get_as_text(), paths[0].get_file())
	file.close()

func _browser_file_selected(_args: Array) -> void:
	if _file_input.files.length == 0:
		return
	var file = _file_input.files.item(0)
	_browser_filename = str(file.name)
	_file_reader = JavaScriptBridge.create_object("FileReader")
	_read_callback = JavaScriptBridge.create_callback(_browser_file_read)
	_file_reader.addEventListener("load", _read_callback)
	_file_reader.readAsText(file)

func _browser_file_read(_args: Array) -> void:
	load_yaml(str(_file_reader.result), _browser_filename)
	_cancel_browser_file([])
	editor.ed.grab_focus()

func _cancel_browser_file(_args: Array) -> void:
	if _file_overlay != null:
		_file_overlay.remove()
	JavaScriptBridge.get_interface("document").getElementById("canvas").focus()

func _exit_tree() -> void:
	if OS.has_feature("web") and _file_overlay != null:
		_file_overlay.remove()

func load_yaml(text: String, name: String) -> void:
	filename = name.get_file()
	editor._load_text(text)
	_status.text = "Opened " + filename + ". The original file is preserved. Export writes your reviewed copy."
