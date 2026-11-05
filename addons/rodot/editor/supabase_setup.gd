@tool
extends RefCounted

const Config = preload("../runtime/supabase_config.gd")
const MENU := "Rodot Supabase Setup…"
const HELPER := "res://addons/rodot/editor/credentials/rodot-credential.win64.exe"

var _dialog: ConfirmationDialog
var _url: LineEdit
var _secret: LineEdit
var _status: Label
var _loaded_scope := ""
var _storage_message := ""

func install(plugin: EditorPlugin) -> void:
	plugin.add_tool_menu_item(MENU, _open)
	_dialog = ConfirmationDialog.new()
	_dialog.title = "Rodot Supabase Setup"
	_dialog.dialog_hide_on_ok = false
	_dialog.ok_button_text = "Save"
	_dialog.add_button("Forget Key", true, "forget")
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = 420
	_dialog.add_child(content)
	var url_label := Label.new()
	url_label.text = "Supabase URL"
	content.add_child(url_label)
	_url = LineEdit.new()
	_url.placeholder_text = "https://your-project.supabase.co"
	content.add_child(_url)
	var key_label := Label.new()
	key_label.text = "Secret key"
	content.add_child(key_label)
	_secret = LineEdit.new()
	_secret.secret = true
	_secret.max_length = 2048
	_secret.placeholder_text = "sb_secret_…"
	content.add_child(_secret)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status)
	_dialog.confirmed.connect(_save)
	_dialog.custom_action.connect(func(action):
		if action == "forget": _forget()
	)
	_dialog.visibility_changed.connect(func():
		if not _dialog.visible: _secret.clear()
	)
	plugin.add_child(_dialog)
	ProjectSettings.settings_changed.connect(_refresh)
	_refresh()

func uninstall(plugin: EditorPlugin) -> void:
	plugin.remove_tool_menu_item(MENU)
	ProjectSettings.settings_changed.disconnect(_refresh)
	_clear_environment()
	if is_instance_valid(_dialog): _dialog.queue_free()

func _open() -> void:
	_refresh()
	_url.text = str(ProjectSettings.get_setting(Config.URL, ""))
	_secret.clear()
	_status.text = _storage_message if not _storage_message.is_empty() else "Enter the URL and a Supabase secret key for this project."
	_dialog.popup_centered()

func _refresh() -> void:
	var base := Config.origin(str(ProjectSettings.get_setting(Config.URL, "")))
	var id := Config.scope(base) if not base.is_empty() else ""
	if id == _loaded_scope: return
	_clear_environment()
	_loaded_scope = id
	_storage_message = ""
	if id.is_empty() or not _has_vault(): return
	var result := _vault("read", id)
	if result.begins_with("ok:") and Config.valid_key(result.substr(3)):
		_use_key(id, result.substr(3))
		_storage_message = "A key is saved for this project and URL. Leave the key field empty to keep it."
	elif result == "error":
		_storage_message = "Windows Credential Manager is unavailable. You can set a key for this editor session."

func _save() -> void:
	var base := Config.origin(_url.text)
	if base.is_empty():
		_status.text = "Enter the Supabase project URL, such as https://your-project.supabase.co."
		return
	var key := _secret.text.strip_edges()
	if not key.is_empty() and not Config.valid_key(key):
		_status.text = "Enter a Supabase secret key beginning with sb_secret_, or a legacy service_role key."
		return
	var previous = ProjectSettings.get_setting(Config.URL, "")
	ProjectSettings.set_setting(Config.URL, base)
	var result := ProjectSettings.save()
	if result != OK:
		ProjectSettings.set_setting(Config.URL, previous)
		_status.text = "Could not save the project URL: " + error_string(result)
		return
	_refresh()
	if not key.is_empty():
		_use_key(_loaded_scope, key)
		var saved := _has_vault() and _vault("write", _loaded_scope, key) == "ok"
		_storage_message = "Key saved in Windows Credential Manager for this project." if saved else "Key set for this editor session. Persistent key storage is unavailable."
	_secret.clear()
	_url.text = base
	_status.text = _storage_message if not _storage_message.is_empty() else "URL saved. Enter a secret key before using Supabase."

func _forget() -> void:
	if not _loaded_scope.is_empty() and _has_vault() and _vault("forget", _loaded_scope) != "ok":
		_status.text = "Windows Credential Manager could not remove the saved key."
		return
	_clear_environment()
	_secret.clear()
	_storage_message = "Key removed for this project."
	_status.text = _storage_message

func _use_key(id: String, key: String) -> void:
	OS.set_environment(Config.EDITOR_SCOPE, id)
	OS.set_environment(Config.EDITOR_KEY, key)

func _clear_environment() -> void:
	OS.unset_environment(Config.EDITOR_KEY)
	OS.unset_environment(Config.EDITOR_SCOPE)

func _has_vault() -> bool:
	return OS.get_name() == "Windows" and FileAccess.file_exists(HELPER)

func _vault(action: String, id: String, key := "") -> String:
	var process := OS.execute_with_pipe(ProjectSettings.globalize_path(HELPER), PackedStringArray([action, id]))
	if process.is_empty(): return "error"
	var pipe: FileAccess = process.stdio
	if action == "write": pipe.store_line(key)
	var reply := pipe.get_line().strip_edges()
	pipe.close()
	return reply if not reply.is_empty() else "error"
