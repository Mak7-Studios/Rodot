@tool
extends VBoxContainer

signal file_action_requested(mode: String)
signal current_script_changed(path: String)
signal native_scripts_requested

var completion_model := preload("completion.gd").new()
var documents: Dictionary = {}
var document_keys: Array[String] = []
var current_key := ""
var pending_key := ""
var deferred_close := ""
var untitled_count := 0
var loading := false
var tabs: TabBar
var code_area: PanelContainer
var sidebar: TabContainer
var file_list: ItemList
var file_filter: LineEdit
var outline_list: ItemList
var api_list: ItemList
var api_detail: RichTextLabel
var api_filter: LineEdit
var breadcrumb: Label
var status: Button
var position_label: Label
var find_bar: HBoxContainer
var find_text: LineEdit
var replacement: LineEdit
var close_dialog: ConfirmationDialog
var conflict_dialog: ConfirmationDialog
var notice: AcceptDialog
var validate_timer: Timer
var session_timer: Timer
var editor_font: Font
var editor_font_size := 16
var test_mode := false

func _ready() -> void:
	name = "LuauWorkspace"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)
	_build_toolbar()
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 215
	add_child(split)
	_build_sidebar(split)
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(center)
	tabs = TabBar.new()
	tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	tabs.tab_changed.connect(_tab_changed)
	tabs.tab_close_pressed.connect(func(index): request_close(document_keys[index]))
	center.add_child(tabs)
	_build_find(center)
	code_area = PanelContainer.new()
	code_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(code_area)
	var bottom := HBoxContainer.new()
	center.add_child(bottom)
	status = Button.new()
	status.flat = true
	status.text = "Open a Luau script to begin"
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.alignment = HORIZONTAL_ALIGNMENT_LEFT
	status.pressed.connect(_go_to_error)
	bottom.add_child(status)
	position_label = Label.new()
	bottom.add_child(position_label)
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Unsaved script"
	close_dialog.ok_button_text = "Save and close"
	close_dialog.add_button("Discard", false, "discard")
	close_dialog.confirmed.connect(_save_before_close)
	close_dialog.custom_action.connect(func(action):
		if action == "discard":
			_close_document(deferred_close)
			deferred_close = ""
			close_dialog.hide()
	)
	add_child(close_dialog)
	conflict_dialog = ConfirmationDialog.new()
	conflict_dialog.title = "File changed on disk"
	conflict_dialog.ok_button_text = "Overwrite disk file"
	conflict_dialog.add_button("Reload from disk", false, "reload")
	conflict_dialog.confirmed.connect(func(): _write_document(pending_key, true))
	conflict_dialog.custom_action.connect(func(action):
		if action == "reload":
			_reload_document(pending_key)
			conflict_dialog.hide()
	)
	add_child(conflict_dialog)
	notice = AcceptDialog.new()
	add_child(notice)
	validate_timer = Timer.new()
	validate_timer.one_shot = true
	validate_timer.wait_time = 0.7
	validate_timer.timeout.connect(validate_current)
	add_child(validate_timer)
	session_timer = Timer.new()
	session_timer.one_shot = true
	session_timer.wait_time = 1.5
	session_timer.timeout.connect(_save_session)
	add_child(session_timer)
	refresh_files()
	_refresh_reference()
	if not test_mode: _restore_session()

func _button(text_value: String, callback: Callable, parent: Node, tooltip := "") -> Button:
	var button := Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _build_toolbar() -> void:
	var toolbar := HBoxContainer.new()
	add_child(toolbar)
	_button("Back", func(): native_scripts_requested.emit(), toolbar, "Return to Godot's built-in script editor")
	var menu := MenuButton.new()
	menu.text = "File"
	toolbar.add_child(menu)
	var popup := menu.get_popup()
	for item in [["New script", 0], ["Open…", 1], ["Save", 2], ["Save as…", 3], ["Save all", 4], ["Close tab", 5]]: popup.add_item(item[0], item[1])
	popup.id_pressed.connect(func(id):
		match id:
			0: new_script()
			1: request_open()
			2: save_current()
			3: save_as()
			4: save_all()
			5: request_close(current_key)
	)
	_button("Save", save_current, toolbar, "Ctrl+S")
	breadcrumb = Label.new()
	breadcrumb.text = "Luau"
	breadcrumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	breadcrumb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	toolbar.add_child(breadcrumb)
	_button("Find", func(): show_find(false), toolbar, "Ctrl+F")
	_button("Check", validate_current, toolbar, "Check syntax without running the script")

func _build_sidebar(parent: Node) -> void:
	sidebar = TabContainer.new()
	sidebar.custom_minimum_size.x = 200
	sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(sidebar)
	var files := VBoxContainer.new()
	files.name = "Files"
	sidebar.add_child(files)
	file_filter = LineEdit.new()
	file_filter.placeholder_text = "Filter scripts"
	file_filter.text_changed.connect(func(_text): refresh_files())
	files.add_child(file_filter)
	file_list = ItemList.new()
	file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	file_list.item_activated.connect(func(index): open_path(file_list.get_item_metadata(index)))
	files.add_child(file_list)
	outline_list = ItemList.new()
	outline_list.name = "Outline"
	outline_list.item_activated.connect(func(index):
		var code := current_editor()
		if code != null:
			code.set_caret_line(outline_list.get_item_metadata(index))
			code.grab_focus()
	)
	sidebar.add_child(outline_list)
	var reference := VBoxContainer.new()
	reference.name = "API"
	sidebar.add_child(reference)
	api_filter = LineEdit.new()
	api_filter.placeholder_text = "Find a property or function"
	api_filter.text_changed.connect(func(_text): _refresh_reference())
	reference.add_child(api_filter)
	api_list = ItemList.new()
	api_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	api_list.item_selected.connect(func(index):
		var entry: Dictionary = api_list.get_item_metadata(index)
		api_detail.text = api_list.get_item_text(index) + "\n" + (entry.signature if not entry.signature.is_empty() else entry.type)
	)
	reference.add_child(api_list)
	api_detail = RichTextLabel.new()
	api_detail.custom_minimum_size.y = 72
	api_detail.text = "Rodot API\nSelect a property or function."
	reference.add_child(api_detail)

func _build_find(parent: Node) -> void:
	find_bar = HBoxContainer.new()
	find_bar.hide()
	parent.add_child(find_bar)
	find_text = LineEdit.new()
	find_text.placeholder_text = "Find"
	find_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	find_text.text_submitted.connect(func(_text): find_next())
	find_text.text_changed.connect(func(value):
		if current_editor() != null: current_editor().set_search_text(value)
	)
	find_bar.add_child(find_text)
	replacement = LineEdit.new()
	replacement.placeholder_text = "Replace with"
	replacement.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	find_bar.add_child(replacement)
	_button("Previous", func(): find_next(true), find_bar)
	_button("Next", find_next, find_bar)
	_button("Replace", replace_one, find_bar)
	_button("All", replace_all, find_bar)
	_button("×", func(): find_bar.hide(), find_bar)

func current_editor() -> CodeEdit:
	return documents[current_key].editor if documents.has(current_key) else null

func current_path() -> String:
	return "" if current_key.begins_with("untitled:") else current_key

func set_scene_context(root_node: Node, selected: Node = null) -> void:
	completion_model.set_context(root_node, current_path(), selected)

func new_script(is_module := false) -> void:
	untitled_count += 1
	var template := "local module = {}\n\nreturn module\n" if is_module else "local parent = script.Parent\n\nprint(parent.Name)\n"
	_open_document("untitled:" + str(untitled_count), template, "")

func request_open() -> void:
	file_action_requested.emit("open")

func open_path(path: String) -> void:
	if not path.ends_with(".luau") or not FileAccess.file_exists(path):
		_message("Cannot open Luau script: " + path)
		return
	if documents.has(path):
		tabs.current_tab = document_keys.find(path)
		if not is_dirty(path): _reload_document(path)
		return
	var source := FileAccess.get_file_as_string(path)
	_open_document(path, source, source)

func _open_document(key: String, source: String, saved: String) -> void:
	loading = true
	var code := preload("code.gd").new()
	code.completion_model = completion_model
	code.text = source
	code.changed_callback = func(): _document_changed(key)
	if editor_font != null: code.add_theme_font_override("font", editor_font)
	code.add_theme_font_size_override("font_size", editor_font_size)
	documents[key] = {"editor": code, "saved": saved, "error_line": -1, "diagnostic": ""}
	document_keys.append(key)
	code_area.add_child(code)
	code.caret_changed.connect(_update_position)
	code.font_size_changed.connect(func(size_value):
		editor_font_size = size_value
		for document in documents.values(): document.editor.add_theme_font_size_override("font_size", size_value)
		if not test_mode: session_timer.start()
	)
	tabs.add_tab(_title(key))
	tabs.current_tab = document_keys.size() - 1
	loading = false
	_tab_changed(tabs.current_tab)
	code.grab_focus()
	if not test_mode: session_timer.start()

func _title(key: String) -> String:
	var title := "Untitled " + key.get_slice(":", 1) if key.begins_with("untitled:") else key.get_file()
	return title + (" •" if is_dirty(key) else "")

func is_dirty(key: String) -> bool:
	return documents.has(key) and documents[key].editor.text != documents[key].saved

func _tab_changed(index: int) -> void:
	if index < 0 or index >= document_keys.size(): return
	current_key = document_keys[index]
	for key in documents: documents[key].editor.visible = key == current_key
	breadcrumb.text = current_path() if not current_path().is_empty() else _title(current_key)
	completion_model.set_context(completion_model.scene_root, current_path(), completion_model.script_node)
	_refresh_outline()
	_update_position()
	current_script_changed.emit(current_path())
	if not loading: validate_timer.start()

func _document_changed(key: String) -> void:
	if loading or not documents.has(key): return
	var index := document_keys.find(key)
	if index >= 0: tabs.set_tab_title(index, _title(key))
	if key == current_key:
		_refresh_outline()
		validate_timer.start()
		_update_position()
	if not test_mode: session_timer.start()

func save_current() -> bool:
	if not documents.has(current_key): return false
	if current_path().is_empty():
		save_as()
		return false
	return _write_document(current_key)

func save_as() -> void:
	if not documents.has(current_key): return
	pending_key = current_key
	file_action_requested.emit("save")

func save_to_path(path: String) -> bool:
	var key := pending_key if documents.has(pending_key) else current_key
	if not documents.has(key): return false
	if not path.ends_with(".luau"): path += ".luau"
	if documents.has(path) and path != key:
		_message("That file is already open in another tab.")
		return false
	if path != key:
		var document: Dictionary = documents[key]
		document.saved = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
		documents.erase(key)
		documents[path] = document
		document_keys[document_keys.find(key)] = path
		document.editor.changed_callback = func(): _document_changed(path)
		if deferred_close == key: deferred_close = path
		current_key = path
		pending_key = path
	return _write_document(path, true)

func _write_document(key: String, force := false) -> bool:
	if not documents.has(key) or key.begins_with("untitled:"): return false
	var document: Dictionary = documents[key]
	if not force and FileAccess.file_exists(key) and FileAccess.get_file_as_string(key) != document.saved:
		pending_key = key
		conflict_dialog.dialog_text = key + " changed outside Rodot.\nOverwrite it with this tab, reload the disk version, or cancel."
		conflict_dialog.popup_centered(Vector2i(520, 160))
		return false
	var file := FileAccess.open(key, FileAccess.WRITE)
	if file == null:
		_message("Cannot save " + key + ": " + error_string(FileAccess.get_open_error()))
		return false
	file.store_string(document.editor.text)
	file.close()
	document.saved = document.editor.text
	tabs.set_tab_title(document_keys.find(key), _title(key))
	breadcrumb.text = key
	current_script_changed.emit(key)
	refresh_files()
	if not test_mode: _save_session()
	if deferred_close == key:
		deferred_close = ""
		_close_document(key)
	return true

func save_all() -> void:
	for key in document_keys.duplicate():
		if not key.begins_with("untitled:") and is_dirty(key): _write_document(key)

func _reload_document(key: String) -> void:
	if not documents.has(key) or not FileAccess.file_exists(key): return
	loading = true
	var source := FileAccess.get_file_as_string(key)
	documents[key].editor.text = source
	documents[key].saved = source
	loading = false
	tabs.set_tab_title(document_keys.find(key), _title(key))
	if current_key == key: validate_timer.start()

func request_close(key: String) -> void:
	if not documents.has(key): return
	if is_dirty(key):
		deferred_close = key
		close_dialog.dialog_text = "Save changes to " + _title(key).trim_suffix(" •") + "?"
		close_dialog.popup_centered(Vector2i(460, 140))
	else: _close_document(key)

func _save_before_close() -> void:
	if not documents.has(deferred_close): return
	current_key = deferred_close
	if current_key.begins_with("untitled:"): save_as()
	else: _write_document(current_key)

func _close_document(key: String) -> void:
	if not documents.has(key): return
	var index := document_keys.find(key)
	documents[key].editor.queue_free()
	documents.erase(key)
	document_keys.remove_at(index)
	tabs.remove_tab(index)
	if document_keys.is_empty():
		current_key = ""
		breadcrumb.text = "Luau"
		status.text = "Open a Luau script to begin"
		position_label.text = ""
		current_script_changed.emit("")
	else: _tab_changed(tabs.current_tab)
	if not test_mode: _save_session()

func unsaved_status() -> String:
	var names: Array[String] = []
	for key in document_keys:
		if is_dirty(key): names.append(_title(key).trim_suffix(" •"))
	return "Unsaved Luau scripts: " + ", ".join(names) if not names.is_empty() else ""

func validate_current() -> Dictionary:
	var code := current_editor()
	if code == null: return {}
	var document: Dictionary = documents[current_key]
	if document.error_line >= 0 and document.error_line < code.get_line_count(): code.set_line_background_color(document.error_line, Color.TRANSPARENT)
	document.error_line = -1
	if not ClassDB.class_exists("Luau"):
		document.diagnostic = "Restart Godot to load the bundled Luau compiler"
		_update_position()
		return {"ok": false, "message": document.diagnostic}
	var bytecode = ClassDB.class_call_static("Luau", "compile", code.text)
	if not bytecode is PackedByteArray:
		document.diagnostic = "Luau compiler is unavailable in this editor session"
		_update_position()
		return {"ok": false, "message": document.diagnostic}
	var loaded: bool = not bytecode.is_empty() and bytecode[0] != 0
	var message: String = "Syntax OK" if loaded else bytecode.slice(1).get_string_from_utf8()
	document.diagnostic = message
	if not loaded:
		var regex := RegEx.new()
		regex.compile(":(\\d+):")
		var match_value := regex.search(message)
		if match_value:
			document.error_line = int(match_value.get_string(1)) - 1
			if document.error_line >= 0 and document.error_line < code.get_line_count(): code.set_line_background_color(document.error_line, Color(0.9, 0.2, 0.25, 0.14))
	_update_position()
	return {"ok": loaded, "message": message, "line": document.error_line}

func _go_to_error() -> void:
	if documents.has(current_key) and documents[current_key].error_line >= 0:
		current_editor().set_caret_line(documents[current_key].error_line)
		current_editor().grab_focus()

func _update_position() -> void:
	if current_editor() == null or status == null: return
	position_label.text = "Ln %d, Col %d   ·   Luau" % [current_editor().get_caret_line() + 1, current_editor().get_caret_column() + 1]
	var message: String = documents[current_key].diagnostic
	status.text = message if not message.is_empty() else "Luau"
	status.tooltip_text = message
	status.modulate = Color("ff9b9b") if documents[current_key].error_line >= 0 else Color.WHITE

func _refresh_outline() -> void:
	outline_list.clear()
	if current_editor() == null: return
	var regex := RegEx.new()
	regex.compile('(?m)^\\s*(?:local\\s+)?function\\s+([A-Za-z_][A-Za-z0-9_.:]*)\\s*\\(')
	var source := current_editor().text
	for item in regex.search_all(source):
		var index := outline_list.add_item(item.get_string(1))
		outline_list.set_item_metadata(index, source.left(item.get_start()).count("\n"))

func _refresh_reference() -> void:
	if api_list == null: return
	api_list.clear()
	var reference: Dictionary = completion_model.reference_entries()
	var names := reference.keys()
	names.sort()
	for name in names:
		if not api_filter.text.is_empty() and not name.to_lower().contains(api_filter.text.to_lower()): continue
		var index := api_list.add_item(name)
		api_list.set_item_metadata(index, reference[name])

func _script_paths(path: String, output: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	for file in directory.get_files():
		if file.ends_with(".luau"): output.append(path.path_join(file))
	for child in directory.get_directories():
		var child_path := path.path_join(child)
		if not child.begins_with(".") and child_path != "res://addons/rodot": _script_paths(child_path, output)

func refresh_files() -> void:
	if file_list == null: return
	file_list.clear()
	var paths: Array[String] = []
	_script_paths("res://", paths)
	paths.sort()
	for path in paths:
		if not file_filter.text.is_empty() and not path.to_lower().contains(file_filter.text.to_lower()): continue
		var index := file_list.add_item(path.trim_prefix("res://"))
		file_list.set_item_metadata(index, path)
		file_list.set_item_tooltip(index, path)

func show_find(with_replace: bool) -> void:
	find_bar.show()
	replacement.visible = with_replace
	find_text.grab_focus()
	if current_editor() != null and current_editor().has_selection(): find_text.text = current_editor().get_selected_text()

func find_next(backwards := false) -> void:
	var code := current_editor()
	if code == null or find_text.text.is_empty(): return
	var flags := TextEdit.SEARCH_BACKWARDS if backwards else 0
	var column := maxi(0, code.get_caret_column() - 1) if backwards else code.get_caret_column()
	var result := code.search(find_text.text, flags, code.get_caret_line(), column)
	if result.x >= 0:
		code.select(result.y, result.x, result.y, result.x + find_text.text.length())
		code.set_caret_line(result.y)
		code.set_caret_column(result.x if backwards else result.x + find_text.text.length())

func replace_one() -> void:
	var code := current_editor()
	if code == null: return
	if code.has_selection() and code.get_selected_text().nocasecmp_to(find_text.text) == 0: code.insert_text_at_caret(replacement.text)
	find_next()

func replace_all() -> void:
	var code := current_editor()
	if code == null or find_text.text.is_empty(): return
	var source := code.text.replacen(find_text.text, replacement.text)
	code.begin_complex_operation()
	code.select_all()
	code.insert_text_at_caret(source)
	code.end_complex_operation()

func show_reference() -> void:
	sidebar.current_tab = 2
	api_filter.grab_focus()

func _message(message: String) -> void:
	notice.dialog_text = message
	notice.popup_centered(Vector2i(520, 160))

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey or not event.pressed or event.echo: return
	if event.is_command_or_control_pressed():
		match event.keycode:
			KEY_S:
				if event.shift_pressed: save_as()
				else: save_current()
			KEY_N: new_script()
			KEY_O: request_open()
			KEY_W: request_close(current_key)
			KEY_F: show_find(false)
			KEY_H: show_find(true)
			KEY_SPACE:
				if current_editor() != null: current_editor().request_code_completion(true)
			_: return
		get_viewport().set_input_as_handled()

func _save_session() -> void:
	if test_mode: return
	var session := session_data()
	DirAccess.make_dir_recursive_absolute("res://.godot/rodot")
	var file := FileAccess.open("res://.godot/rodot/session.json", FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(session))

func session_data() -> Dictionary:
	var session := {"current": current_key, "documents": [], "font_size": editor_font_size}
	for key in document_keys:
		var code: CodeEdit = documents[key].editor
		session.documents.append({"key": key, "text": code.text, "saved": documents[key].saved, "line": code.get_caret_line(), "column": code.get_caret_column()})
	return session

func _restore_session() -> void:
	if not FileAccess.file_exists("res://.godot/rodot/session.json"): return
	var session = JSON.parse_string(FileAccess.get_file_as_string("res://.godot/rodot/session.json"))
	if not session is Dictionary: return
	restore_data(session)

func restore_data(session: Dictionary) -> void:
	editor_font_size = clampi(int(session.get("font_size", editor_font_size)), 9, 48)
	for document in session.get("documents", []):
		if not document is Dictionary or not document.has_all(["key", "text", "saved", "line", "column"]): continue
		var key: String = document.key
		if not key.begins_with("untitled:") and not FileAccess.file_exists(key) and document.text == document.saved: continue
		var source: String = FileAccess.get_file_as_string(key) if document.text == document.saved and FileAccess.file_exists(key) else document.text
		_open_document(key, source, source if document.text == document.saved else document.saved)
		if key.begins_with("untitled:"): untitled_count = maxi(untitled_count, int(key.get_slice(":", 1)))
		current_editor().set_caret_line(document.line)
		current_editor().set_caret_column(document.column)
	if documents.has(session.get("current", "")): tabs.current_tab = document_keys.find(session.current)

func _exit_tree() -> void:
	if not test_mode and tabs != null: _save_session()
