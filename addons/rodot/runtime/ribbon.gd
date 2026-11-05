@tool
extends MeshInstance3D

const Values = preload("values.gd")
const Content = preload("content.gd")

@export var attachment_0: Node3D
@export var attachment_1: Node3D
@export var enabled := true
@export var color := Color.WHITE
@export var color_ramp: Gradient
@export_range(0, 1, 0.01) var ribbon_transparency := 0.0
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg", "*.tres", "*.res") var texture := "":
	set(value):
		texture = value
		if is_inside_tree(): _texture_loader.load_into(self, texture, _apply_texture)

var _material: StandardMaterial3D
var _texture_loader := Content.new()
var _texture_error := ""

func _validate_property(property: Dictionary) -> void:
	if property.name in ["mesh", "material_override", "cast_shadow", "transparency"]:
		property.usage &= ~(PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)

func _enter_tree() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_texture_loader.load_into(self, texture, _apply_texture)

func _exit_tree() -> void:
	_texture_loader.cancel()
	mesh = null
	material_override = null

func _apply_texture(image: Texture2D, error: String) -> void:
	_material.albedo_texture = image
	_texture_error = error
	if Engine.is_editor_hint(): update_configuration_warnings()
	elif not error.is_empty(): push_warning(error)

func _has_endpoints() -> bool:
	return is_instance_valid(attachment_0) and is_instance_valid(attachment_1) and attachment_0.is_inside_tree() and attachment_1.is_inside_tree()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _has_endpoints(): warnings.append("Assign Attachment 0 and Attachment 1.")
	if not _texture_error.is_empty(): warnings.append(_texture_error)
	return warnings

func _strip(left: PackedVector3Array, right: PackedVector3Array, opacity: PackedFloat32Array) -> void:
	if left.size() < 2:
		mesh = null
		return
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var inverse := global_transform.affine_inverse()
	for i in range(left.size()):
		var fraction := float(i) / (left.size() - 1)
		var tint := color * (color_ramp.sample(fraction) if color_ramp else Color.WHITE)
		tint.a *= (1.0 - ribbon_transparency) * (opacity[i] if i < opacity.size() else 1.0)
		vertices.append(inverse * left[i])
		vertices.append(inverse * right[i])
		colors.append(tint)
		colors.append(tint)
		uv.append(Vector2(fraction, 0))
		uv.append(Vector2(fraction, 1))
		if i == 0: continue
		var start := (i - 1) * 2
		indices.append_array(PackedInt32Array([start, start + 1, start + 2, start + 1, start + 3, start + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var ribbon := ArrayMesh.new()
	ribbon.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = ribbon

func _rodot_get(key: String) -> Dictionary:
	match key:
		"Attachment0": return Values.value(attachment_0)
		"Attachment1": return Values.value(attachment_1)
		"Color": return Values.value(color)
		"Transparency": return Values.value(ribbon_transparency)
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	match key:
		"Attachment0", "Attachment1":
			if value != null and not value is Node3D: return Values.failure("Expected a 3D attachment or nil")
			if key == "Attachment0": attachment_0 = value
			else: attachment_1 = value
			if Engine.is_editor_hint(): update_configuration_warnings()
		"Color":
			if not value is Color: return Values.failure("Color expects Color3")
			color = value
		"Transparency":
			if not Values.is_number(value): return Values.failure("Transparency expects a number")
			ribbon_transparency = clampf(value, 0, 1)
		"Texture":
			if not value is String or not Content.accepts_texture(value): return Values.failure("Invalid texture path or asset ID")
			texture = value
		_: return {}
	return {"handled": true}
