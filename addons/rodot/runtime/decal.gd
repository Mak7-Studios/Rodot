@tool
extends Node3D

const Content = preload("content.gd")

enum Side { RIGHT, TOP, BACK, LEFT, BOTTOM, FRONT }

@export_enum("Front:5", "Back:2", "Right:0", "Left:3", "Top:1", "Bottom:4") var face: int = Side.FRONT:
	set(value):
		face = clampi(value, 0, 5)
		_sync()
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg", "*.tres", "*.res") var texture: String = "":
	set(value):
		texture = value
		if is_inside_tree(): _load_texture()
@export var color3 := Color.WHITE:
	set(value):
		color3 = value
		_sync()
@export_range(0, 1, 0.01) var transparency := 0.0:
	set(value):
		transparency = clampf(value, 0, 1)
		_sync()

var _image: Texture2D
var _texture_loader := Content.new()
var _texture_error := ""
var _surface: MeshInstance3D
var _last_size := Vector3.ZERO

func _enter_tree() -> void:
	set_meta("rodot_class", "Decal")
	_load_texture()

func _exit_tree() -> void:
	_texture_loader.cancel()

func _process(_delta: float) -> void:
	if _parent_size() != _last_size: _sync()

func _parent_size() -> Vector3:
	var parent := get_parent()
	if not parent is Node3D: return Vector3.ZERO
	var mesh := parent as MeshInstance3D
	if mesh == null: mesh = parent.get_node_or_null("RodotMesh") as MeshInstance3D
	if mesh != null and mesh.mesh is BoxMesh: return mesh.mesh.size
	return Vector3.ZERO

func _load_texture() -> void:
	_texture_loader.load_into(self, texture, _apply_texture)

func _apply_texture(image: Texture2D, error: String) -> void:
	_image = image
	_texture_error = error
	_sync()
	if not Engine.is_editor_hint() and not error.is_empty() and not Content.asset_id(texture).is_empty(): push_warning(error)

func _sync() -> void:
	if not is_inside_tree(): return
	if not is_instance_valid(_surface):
		_surface = get_node_or_null("RodotDecalSurface") as MeshInstance3D
		if _surface == null:
			_surface = MeshInstance3D.new()
			_surface.name = "RodotDecalSurface"
			_surface.set_meta("rodot_internal", true)
			add_child(_surface, false, Node.INTERNAL_MODE_FRONT)
		_surface.mesh = QuadMesh.new()
		_surface.material_override = StandardMaterial3D.new()
		_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_last_size = _parent_size()
	_surface.visible = _last_size != Vector3.ZERO and _image != null and transparency < 1
	var normal: Vector3 = [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3.LEFT, Vector3.DOWN, Vector3.FORWARD][face]
	var up := Vector3.UP
	if face == Side.TOP: up = Vector3.BACK
	elif face == Side.BOTTOM: up = Vector3.FORWARD
	_surface.transform = Transform3D(Basis.looking_at(-normal, up), normal * (_last_size * 0.5 + Vector3.ONE * 0.002))
	var dimensions := Vector2(_last_size.x, _last_size.y)
	if face in [Side.RIGHT, Side.LEFT]: dimensions = Vector2(_last_size.z, _last_size.y)
	elif face in [Side.TOP, Side.BOTTOM]: dimensions = Vector2(_last_size.x, _last_size.z)
	_surface.mesh.size = dimensions.max(Vector2.ONE * 0.001)
	var material := _surface.material_override as StandardMaterial3D
	material.albedo_texture = _image
	material.albedo_color = Color(color3.r, color3.g, color3.b, 1.0 - transparency)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if Engine.is_editor_hint(): update_configuration_warnings()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _parent_size() == Vector3.ZERO: warnings.append("Add this Decal beneath a Rodot Part or a MeshInstance3D with a BoxMesh.")
	if texture.is_empty(): warnings.append("Choose a texture file to display the Decal.")
	elif not _texture_error.is_empty(): warnings.append(_texture_error)
	return warnings

func _rodot_get(key: String) -> Dictionary:
	var face_value := {"__type": "EnumItem", "EnumType": "NormalId", "Name": Side.keys()[face].capitalize()}
	var fields := {"Face": face_value, "Texture": texture, "Color3": color3, "Color": color3, "Transparency": transparency}
	return {"handled": true, "value": fields[key]} if fields.has(key) else {"handled": false}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	var fields := {"Face": "face", "Texture": "texture", "Color3": "color3", "Color": "color3", "Transparency": "transparency"}
	if not fields.has(key): return {"handled": false}
	var expected := {"Face": TYPE_INT, "Texture": TYPE_STRING, "Color3": TYPE_COLOR, "Color": TYPE_COLOR, "Transparency": TYPE_FLOAT}
	var numeric := key in ["Face", "Transparency"] and typeof(value) in [TYPE_INT, TYPE_FLOAT]
	if typeof(value) != expected[key] and not numeric: return {"handled": true, "error": "Wrong type for " + key}
	if key == "Face" and (value != int(value) or value < 0 or value > 5): return {"handled": true, "error": "Face must be an Enum.NormalId value"}
	if key == "Texture" and not Content.accepts_texture(value): return {"handled": true, "error": "Invalid texture path or asset ID: " + value}
	set(fields[key], value)
	return {"handled": true}
