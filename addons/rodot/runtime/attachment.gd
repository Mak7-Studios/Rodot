@tool
extends Node3D

const Values = preload("values.gd")

func _enter_tree() -> void:
	set_meta("rodot_class", "Attachment")

func _rodot_get(key: String) -> Dictionary:
	match key:
		"Position": return Values.value(position)
		"Orientation": return Values.value(rotation_degrees)
		"CFrame": return Values.value(transform)
		"WorldPosition": return Values.value(global_position if is_inside_tree() else position)
		"WorldOrientation":
			var angles := global_rotation if is_inside_tree() else rotation
			return Values.value(angles * (180.0 / PI))
		"WorldCFrame": return Values.value(global_transform if is_inside_tree() else transform)
		"Axis": return Values.value(basis.x.normalized())
		"SecondaryAxis": return Values.value(basis.y.normalized())
		"WorldAxis": return Values.value((global_basis if is_inside_tree() else basis).x.normalized())
		"WorldSecondaryAxis": return Values.value((global_basis if is_inside_tree() else basis).y.normalized())
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	var fields := {"Position": "position", "Orientation": "rotation_degrees", "CFrame": "transform", "WorldPosition": "global_position", "WorldCFrame": "global_transform"}
	if not fields.has(key):
		if key in ["WorldOrientation", "Axis", "SecondaryAxis", "WorldAxis", "WorldSecondaryAxis"]: return Values.failure(key + " is read-only")
		return {}
	if (key.ends_with("CFrame") and not value is Transform3D) or (not key.ends_with("CFrame") and not value is Vector3):
		return Values.failure("Wrong type for " + key)
	var native: String = fields[key]
	if not is_inside_tree(): native = native.trim_prefix("global_")
	set(native, value)
	return {"handled": true}
