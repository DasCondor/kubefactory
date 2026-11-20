@tool
extends EditorPlugin

var _exporter: EditorExportPlugin

class SetupExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "KubeFactorySetupFiles"

	func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		var writer = "res://agent/storage_write.sh"
		add_file(writer, FileAccess.get_file_as_bytes(writer), false)
		# apps/.gdignore keeps editable credentials outside the resource scanner.
		for id in ["web", "redis", "postgres", "wordpress", "media", "media-vpn", "monitoring"]:
			var path = "res://apps/%s.k8s.yaml" % id
			if FileAccess.file_exists(path):
				add_file(path, FileAccess.get_file_as_bytes(path), false)
			else:
				push_error("Missing built-in setup: " + path)

func _enter_tree() -> void:
	_exporter = SetupExport.new()
	add_export_plugin(_exporter)

func _exit_tree() -> void:
	remove_export_plugin(_exporter)
