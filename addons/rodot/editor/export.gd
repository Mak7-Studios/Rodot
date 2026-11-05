@tool
extends EditorExportPlugin

func _get_name() -> String:
	return "RodotSources"

func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
	_include_sources("res://")

func _include_sources(path: String) -> void:
	if path == preload("../runtime/content.gd").ROOT.trim_suffix("/"): return
	var directory := DirAccess.open(path)
	if directory == null: return
	for file in directory.get_files():
		if file.get_extension() in ["luau", "json"]:
			var full_path := path.path_join(file)
			add_file(full_path, FileAccess.get_file_as_bytes(full_path), false)
	for child in directory.get_directories():
		if not child.begins_with("."):
			_include_sources(path.path_join(child))

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with("res://addons/rodot/editor/credentials/"):
		skip()
		return
	if path.get_extension() == "luau":
		add_file(path, FileAccess.get_file_as_bytes(path), false)
		skip()
