@tool
extends EditorDebuggerPlugin

signal jump_requested(path: String, line: int)

const MAX_ERRORS := 150

var panels: Dictionary = {}
var messages: Dictionary = {}

func _has_capture(capture: String) -> bool:
	return capture == "rodot"

func _setup_session(id: int) -> void:
	var session := get_session(id)
	var log_view := RichTextLabel.new()
	log_view.name = "Luau"
	log_view.selection_enabled = true
	log_view.scroll_following = true
	log_view.meta_clicked.connect(func(location):
		if location is Array and location.size() == 2:
			jump_requested.emit(location[0], location[1])
	)
	panels[id] = log_view
	messages[id] = []
	log_view.add_text("Luau runtime errors appear here.")
	session.started.connect(_reset.bind(id))
	session.add_session_tab(log_view)

func _reset(id: int) -> void:
	if not is_instance_valid(panels.get(id)): return
	messages[id].clear()
	panels[id].clear()
	panels[id].add_text("Luau runtime errors appear here.")

func _capture(message: String, data: Array, id: int) -> bool:
	if message != "rodot:luau_error" or data.size() != 3: return false
	if not is_instance_valid(panels.get(id)): return true
	var log_view: RichTextLabel = panels[id]
	var entries: Array = messages[id]
	if entries.is_empty(): log_view.clear()
	var entry := [str(data[0]), int(data[1]), str(data[2]).left(16000)]
	entries.append(entry)
	if entries.size() > MAX_ERRORS:
		entries.pop_front()
		log_view.clear()
		for stored in entries: _append(log_view, stored)
	else:
		_append(log_view, entry)
	return true

func _append(log_view: RichTextLabel, entry: Array) -> void:
	var path: String = entry[0]
	var line: int = entry[1]
	if path.begins_with("res://") and path.ends_with(".luau") and line > 0 and FileAccess.file_exists(path):
		log_view.push_meta([path, line])
		log_view.add_text("%s:%d" % [path.trim_prefix("res://"), line])
		log_view.pop()
		log_view.newline()
	log_view.add_text(entry[2].strip_edges())
	log_view.newline()
	log_view.newline()

func close() -> void:
	for id in panels:
		var panel: RichTextLabel = panels[id]
		if not is_instance_valid(panel): continue
		var session := get_session(id)
		if is_instance_valid(session): session.remove_session_tab(panel)
		panel.queue_free()
	panels.clear()
	messages.clear()
