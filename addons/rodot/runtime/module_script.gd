@tool
extends "script.gd"

func is_module_script() -> bool:
	return true

func _validate_property(property: Dictionary) -> void:
	if property.name in ["enabled", "run_context"]: property.usage &= ~PROPERTY_USAGE_EDITOR
