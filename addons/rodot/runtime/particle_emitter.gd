@tool
extends Node3D

const Adapter = preload("values.gd")
const Content = preload("content.gd")
const DIRECTIONS := [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3.LEFT, Vector3.DOWN, Vector3.FORWARD]
const ENUMS := {"EmissionDirection": "NormalId", "Shape": "ParticleEmitterShape", "ShapeStyle": "ParticleEmitterShapeStyle", "ShapeInOut": "ParticleEmitterShapeInOut"}
const RANGES := {"Lifetime": "lifetime", "Speed": "speed", "Rotation": "particle_rotation", "RotSpeed": "rot_speed"}
const CURVES := {"Size": "size_curve", "Transparency": "transparency_curve", "Squash": "squash_curve"}
const DEFAULTS := {"Size": 0.5, "Transparency": 0.0, "Squash": 0.0}
const MAX_PARTICLES := 1024

class Particle:
	var sprite: Sprite3D
	var velocity: Vector3
	var life: float
	var age := 0.0
	var angle: float
	var spin: float
	var variation: float

@export var enabled := true
@export_range(0, 1000, 1) var rate := 12.0
@export var lifetime := Vector2(1, 1.5)
@export var speed := Vector2(2, 4)
@export var acceleration := Vector3(0, -2, 0)
@export_range(0, 20, 0.01, "or_greater") var drag := 0.0
@export var spread_angle := Vector2(20, 20)
@export_enum("Right", "Top", "Back", "Left", "Bottom", "Front") var emission_direction: int = 1
@export var locked_to_part := false
@export_range(0, 1, 0.01) var velocity_inheritance := 0.0
@export_range(0, 1, 0.01) var time_scale := 1.0

@export_group("Shape")
@export_enum("Box", "Sphere", "Cylinder", "Disc") var shape: int = 0
@export_enum("Volume", "Surface") var shape_style: int = 0
@export_enum("Outward", "Inward", "InAndOut") var shape_in_out: int = 0

@export_group("Appearance")
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.dds", "*.svg", "*.tres", "*.res") var texture := "":
	set(value):
		texture = value
		if is_inside_tree(): _reload_texture()
@export var color_ramp: Gradient
@export var size_curve: Curve
@export var transparency_curve: Curve
@export var squash_curve: Curve
@export var particle_rotation := Vector2.ZERO
@export var rot_speed := Vector2.ZERO
@export_range(0, 10, 0.01, "or_greater") var brightness := 1.0
@export_range(0, 1, 0.01) var light_influence := 0.0
@export_range(0, 1, 0.01) var local_transparency_modifier := 0.0
@export var z_offset := 0.0
@export_storage var sequence_envelopes: Dictionary = {}

var _image: Texture2D
var _texture_loader := Content.new()
var _texture_error := ""
var _fallback: Texture2D
var _particles: Array[Particle] = []
var _carry := 0.0

func _enter_tree() -> void:
	set_meta("rodot_class", "ParticleEmitter")
	_reload_texture()

func _exit_tree() -> void:
	_texture_loader.cancel()
	clear()

func _reload_texture() -> void:
	if _fallback == null:
		var ramp := Gradient.new()
		ramp.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
		var dot := GradientTexture2D.new()
		dot.gradient = ramp
		dot.width = 32
		dot.height = 32
		dot.fill = GradientTexture2D.FILL_RADIAL
		dot.fill_from = Vector2(0.5, 0.5)
		dot.fill_to = Vector2(1.0, 0.5)
		_fallback = dot
	_texture_loader.load_into(self, texture, _apply_texture)

func _apply_texture(image: Texture2D, error: String) -> void:
	_image = _fallback if texture.is_empty() else image
	_texture_error = error
	for particle in _particles:
		particle.sprite.texture = _image
	if Engine.is_editor_hint(): update_configuration_warnings()
	elif not error.is_empty() and not Content.asset_id(texture).is_empty(): push_warning(error)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not get_parent() is Node3D: warnings.append("Add ParticleEmitter under a 3D node or Part.")
	if not _texture_error.is_empty(): warnings.append(_texture_error)
	return warnings

func _process(delta: float) -> void:
	var step := delta * maxf(0.0, time_scale)
	for i in range(_particles.size() - 1, -1, -1):
		var particle := _particles[i]
		particle.age += step
		if particle.age >= particle.life:
			particle.sprite.hide()
			particle.sprite.queue_free()
			_particles.remove_at(i)
			continue
		var force := acceleration
		if not particle.sprite.top_level: force = global_basis.inverse() * force
		particle.velocity = (particle.velocity + force * step) * exp(-maxf(0, drag) * step)
		particle.sprite.position += particle.velocity * step
		particle.angle += particle.spin * step
		_update_sprite(particle)
	if enabled and get_parent() is Node3D:
		_carry += maxf(0, rate) * step
		var count := int(_carry)
		_carry -= count
		if count > 0: emit(count)
	else:
		_carry = 0.0

func emit(count: int) -> void:
	if not is_inside_tree() or not get_parent() is Node3D or _image == null: return
	for i in range(clampi(count, 0, MAX_PARTICLES - _particles.size())):
		var particle := Particle.new()
		var sprite := Sprite3D.new()
		sprite.top_level = not locked_to_part
		sprite.texture = _image
		sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sprite.set_meta("rodot_internal", true)
		add_child(sprite, false, Node.INTERNAL_MODE_FRONT)
		var offset := _random_offset()
		var direction := _random_direction(offset)
		particle.sprite = sprite
		particle.life = maxf(0.01, _random_range(lifetime))
		particle.angle = deg_to_rad(_random_range(particle_rotation))
		particle.spin = deg_to_rad(_random_range(rot_speed))
		particle.variation = randf_range(-1.0, 1.0)
		particle.velocity = direction * _random_range(speed)
		var parent_velocity := Vector3.ZERO
		if get_parent() is RigidBody3D: parent_velocity = get_parent().linear_velocity * velocity_inheritance
		if sprite.top_level:
			sprite.global_position = to_global(offset)
			particle.velocity = global_basis.orthonormalized() * particle.velocity + parent_velocity
		else:
			sprite.position = offset
			particle.velocity += global_basis.inverse() * parent_velocity
		_particles.append(particle)
		_update_sprite(particle)

func clear() -> void:
	for particle in _particles:
		particle.sprite.hide()
		particle.sprite.queue_free()
	_particles.clear()

func _random_range(limits: Vector2) -> float:
	return randf_range(minf(limits.x, limits.y), maxf(limits.x, limits.y))

func _random_offset() -> Vector3:
	var parent := get_parent()
	var dimensions: Vector3 = parent.size if parent.get_script() == preload("part.gd") else Vector3.ZERO
	var offset := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	match shape:
		1:
			var y := randf_range(-1, 1)
			var theta := randf() * TAU
			var radius := sqrt(1.0 - y * y)
			offset = Vector3(radius * cos(theta), y, radius * sin(theta))
			if shape_style == 0: offset *= pow(randf(), 1.0 / 3.0)
		2, 3:
			var theta := randf() * TAU
			var radius := 1.0 if shape_style == 1 else sqrt(randf())
			offset = Vector3(cos(theta) * radius, offset.y if shape == 2 else 0.0, sin(theta) * radius)
		_:
			if shape_style == 1: offset[randi_range(0, 2)] = -1.0 if randf() < 0.5 else 1.0
	return offset * dimensions * 0.5

func _random_direction(offset: Vector3) -> Vector3:
	var direction: Vector3 = DIRECTIONS[clampi(emission_direction, 0, 5)]
	if shape != 0 and offset.length_squared() > 0.0:
		direction = offset.normalized()
		if shape_in_out == 1 or (shape_in_out == 2 and randf() < 0.5): direction = -direction
	var up := Vector3.UP if absf(direction.y) < 0.999 else Vector3.BACK
	var basis := Basis.looking_at(direction, up)
	var pitch := deg_to_rad(randf_range(-absf(spread_angle.y), absf(spread_angle.y)))
	var yaw := deg_to_rad(randf_range(-absf(spread_angle.x), absf(spread_angle.x)))
	return basis * Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3.FORWARD

func _update_sprite(particle: Particle) -> void:
	var sprite := particle.sprite
	var progress := clampf(particle.age / particle.life, 0, 1)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		sprite.global_basis = camera.global_basis.orthonormalized() * Basis(Vector3.BACK, particle.angle)
	var diameter := maxf(0.0, _sample_curve("Size", progress, particle.variation))
	var squash := _sample_curve("Squash", progress, particle.variation)
	var aspect := exp(clampf(squash, -4, 4) * 0.5)
	sprite.scale = Vector3(aspect, 1.0 / aspect, 1)
	if _image != null: sprite.pixel_size = maxf(0.00001, diameter / maxf(_image.get_width(), _image.get_height()))
	var tint := color_ramp.sample(progress) if color_ramp else Color.WHITE
	var opacity := (1.0 - clampf(_sample_curve("Transparency", progress, particle.variation), 0, 1)) * (1.0 - local_transparency_modifier)
	sprite.modulate = Color(tint.r * brightness, tint.g * brightness, tint.b * brightness, opacity)
	sprite.shaded = light_influence >= 0.5
	sprite.sorting_offset = z_offset

func _sample_curve(key: String, time: float, variation: float) -> float:
	var curve: Curve = get(CURVES[key])
	var envelope: Curve = sequence_envelopes.get(key)
	var base: float = curve.sample(time) if curve else DEFAULTS[key]
	return base + envelope.sample(time) * variation if envelope else base

func _new_curve(points: Array, field: String) -> Curve:
	var curve := Curve.new()
	for point in points:
		var amount: float = point.get(field, 0.0)
		curve.min_value = minf(curve.min_value, amount)
		curve.max_value = maxf(curve.max_value, amount)
		curve.add_point(Vector2(point.Time, amount), 0, 0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return curve

func _number_sequence(key: String) -> Dictionary:
	var curve: Curve = get(CURVES[key])
	var envelope: Curve = sequence_envelopes.get(key)
	var points: Array = []
	if curve:
		for i in range(curve.point_count):
			var point := curve.get_point_position(i)
			points.append({"__type": "NumberSequenceKeypoint", "Time": point.x, "Value": point.y, "Envelope": envelope.sample(point.x) if envelope else 0.0})
	else:
		for time in [0.0, 1.0]: points.append({"__type": "NumberSequenceKeypoint", "Time": time, "Value": DEFAULTS[key], "Envelope": 0.0})
	return {"__type": "NumberSequence", "Keypoints": points}

func _color_sequence() -> Dictionary:
	var points: Array = []
	if color_ramp:
		for i in range(color_ramp.get_point_count()):
			points.append({"__type": "ColorSequenceKeypoint", "Time": color_ramp.get_offset(i), "Value": color_ramp.get_color(i)})
	else:
		for time in [0.0, 1.0]: points.append({"__type": "ColorSequenceKeypoint", "Time": time, "Value": Color.WHITE})
	return {"__type": "ColorSequence", "Keypoints": points}

func _rodot_get(key: String) -> Dictionary:
	if ENUMS.has(key): return Adapter.value(Adapter.enum_value(ENUMS[key], get(key.to_snake_case())))
	if RANGES.has(key):
		var limits: Vector2 = get(RANGES[key])
		return Adapter.value({"__type": "NumberRange", "Min": minf(limits.x, limits.y), "Max": maxf(limits.x, limits.y)})
	if CURVES.has(key): return Adapter.value(_number_sequence(key))
	if key == "Color": return Adapter.value(_color_sequence())
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	if ENUMS.has(key):
		if not Adapter.is_number(value) or int(value) != value or not Adapter.enums()[ENUMS[key]].values().has(int(value)):
			return Adapter.failure("Expected Enum." + ENUMS[key])
		set(key.to_snake_case(), int(value))
	elif RANGES.has(key):
		if not value is Dictionary or value.get("__type") != "NumberRange": return Adapter.failure("Expected NumberRange")
		set(RANGES[key], Vector2(value.Min, value.Max))
	elif CURVES.has(key):
		if not value is Dictionary or value.get("__type") != "NumberSequence": return Adapter.failure("Expected NumberSequence")
		set(CURVES[key], _new_curve(value.Keypoints, "Value"))
		sequence_envelopes[key] = _new_curve(value.Keypoints, "Envelope")
	elif key == "Color":
		if not value is Dictionary or value.get("__type") != "ColorSequence": return Adapter.failure("Expected ColorSequence")
		var offsets := PackedFloat32Array()
		var colors := PackedColorArray()
		for point in value.Keypoints:
			offsets.append(point.Time)
			var color: Dictionary = point.Value
			colors.append(Color(color.R, color.G, color.B))
		var ramp := Gradient.new()
		ramp.offsets = offsets
		ramp.colors = colors
		color_ramp = ramp
	elif key == "Texture":
		if not value is String: return Adapter.failure("Expected a texture path")
		if not Content.accepts_texture(value): return Adapter.failure("Invalid texture path or asset ID: " + value)
		texture = value
	else:
		return {}
	return {"handled": true}
