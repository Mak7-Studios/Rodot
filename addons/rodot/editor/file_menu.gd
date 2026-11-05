@tool
extends EditorContextMenuPlugin

var open_script: Callable

func _popup_menu(paths: PackedStringArray) -> void:
	var scripts: Array[String] = []
	for path in paths:
		if path.ends_with(".luau"): scripts.append(path)
	if scripts.is_empty(): return
	add_context_menu_item("Edit in Luau", func(_selected_paths):
		for path in scripts: open_script.call(path)
	)
