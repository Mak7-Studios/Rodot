@tool
extends Node

var language: String = "Luau"
const Adapter = preload("values.gd")

@export var archivable := true:
	set(value):
		archivable = value
		set_meta("rodot_archivable", value)
@export_file("*.luau") var source: String = "":
	set(value):
		source = value
		if Engine.is_editor_hint() and is_inside_tree(): update_configuration_warnings()
@export var enabled: bool = true:
	set(value):
		if enabled == value: return
		enabled = value
		if enabled and is_node_ready() and not Engine.is_editor_hint(): _queue_script()
@export_enum("Legacy", "Server", "Client", "Plugin") var run_context := 0

func _enter_tree() -> void:
	set_meta("rodot_class", "ModuleScript" if is_module_script() else "Script")

func _ready() -> void:
	if not Engine.is_editor_hint() and (enabled or is_module_script()): _queue_script()

func _queue_script() -> void:
	if not is_inside_tree() or source.is_empty(): return
	var runtime := get_node_or_null("/root/Rodot")
	if runtime == null:
		runtime = load("res://addons/rodot/runtime/runtime.gd").new()
		runtime.name = "Rodot"
		get_tree().root.add_child(runtime)
	runtime.register_script(self)

func is_module_script() -> bool:
	return false

func can_run() -> bool:
	if not enabled or run_context == 3: return false
	if run_context == 0 or not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer is OfflineMultiplayerPeer: return true
	return multiplayer.is_server() == (run_context == 1)

func _rodot_get(key: String) -> Dictionary:
	match key:
		"Source": return Adapter.value(FileAccess.get_file_as_string(source) if FileAccess.file_exists(source) else "")
		"SourcePath": return Adapter.value(source)
		"Disabled": return Adapter.value(not enabled)
		"RunContext": return Adapter.value(Adapter.enum_value("RunContext", run_context))
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	match key:
		"Source": return Adapter.failure("Edit Source in the Luau editor or assign SourcePath")
		"SourcePath":
			if not value is String or not (value.is_empty() or value.begins_with("res://") and value.ends_with(".luau")):
				return Adapter.failure("SourcePath must be a project .luau path")
			source = value
			if is_inside_tree() and not Engine.is_editor_hint() and (enabled or is_module_script()): _queue_script()
		"Disabled":
			if not value is bool: return Adapter.failure("Disabled must be a boolean")
			enabled = not value
		"RunContext":
			if not Adapter.is_number(value) or value < 0 or value > 3 or int(value) != value: return Adapter.failure("Expected Enum.RunContext")
			run_context = int(value)
		_:
			return {}
	return {"handled": true}

func _get_configuration_warnings() -> PackedStringArray:
	if source.is_empty(): return PackedStringArray(["Double-click this node to create a script."])
	if not FileAccess.file_exists(source): return PackedStringArray(["The script file is missing: " + source])
	return PackedStringArray()
