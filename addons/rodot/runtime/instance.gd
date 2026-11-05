@tool
extends Node

@export var archivable := true:
	set(value):
		archivable = value
		set_meta("rodot_archivable", value)

@export var rodot_locked: bool:
	get:
		return bool(get_meta("_edit_lock_", false))
	set(value):
		if value: set_meta("_edit_lock_", true)
		elif has_meta("_edit_lock_"): remove_meta("_edit_lock_")

func _enter_tree() -> void:
	set_meta("rodot_class", "Instance")
