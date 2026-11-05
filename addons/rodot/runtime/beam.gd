@tool
extends "ribbon.gd"

@export_range(0, 100, 0.01, "or_greater") var width_0 := 0.25
@export_range(0, 100, 0.01, "or_greater") var width_1 := 0.25
@export var curve_size_0 := 0.0
@export var curve_size_1 := 0.0
@export_range(1, 64, 1) var segments := 12
@export var face_camera := true

func _enter_tree() -> void:
	set_meta("rodot_class", "Beam")
	super._enter_tree()

func _process(_delta: float) -> void:
	if not enabled or not _has_endpoints():
		if mesh != null: mesh = null
		return
	var start := attachment_0.global_position
	var end := attachment_1.global_position
	if start.is_equal_approx(end):
		if mesh != null: mesh = null
		return
	var control_start := start + attachment_0.global_basis.x.normalized() * curve_size_0
	var control_end := end - attachment_1.global_basis.x.normalized() * curve_size_1
	var count := clampi(segments, 1, 64) if curve_size_0 != 0.0 or curve_size_1 != 0.0 or color_ramp != null else 1
	var camera := get_viewport().get_camera_3d() if face_camera else null
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	for i in range(count + 1):
		var t := float(i) / count
		var point := start.bezier_interpolate(control_start, control_end, end, t) if count > 1 else start.lerp(end, t)
		var tangent := start.bezier_derivative(control_start, control_end, end, t).normalized()
		if tangent.is_zero_approx(): tangent = (end - start).normalized()
		var up := attachment_0.global_basis.y.normalized()
		if camera != null: up = (camera.global_position - point).cross(tangent).normalized()
		up = (up - tangent * up.dot(tangent)).normalized()
		if up.is_zero_approx(): up = tangent.cross(Vector3.RIGHT if absf(tangent.x) < 0.9 else Vector3.UP).normalized()
		var half_width := up * maxf(0, lerpf(width_0, width_1, t)) * 0.5
		left.append(point + half_width)
		right.append(point - half_width)
	_strip(left, right, PackedFloat32Array())

func _rodot_get(key: String) -> Dictionary:
	var fields := {"Width0": width_0, "Width1": width_1, "CurveSize0": curve_size_0, "CurveSize1": curve_size_1}
	if fields.has(key): return Values.value(fields[key])
	return super._rodot_get(key)

func _rodot_set(key: String, value: Variant) -> Dictionary:
	var fields := {"Width0": "width_0", "Width1": "width_1", "CurveSize0": "curve_size_0", "CurveSize1": "curve_size_1"}
	if not fields.has(key): return super._rodot_set(key, value)
	if not Values.is_number(value): return Values.failure(key + " expects a number")
	set(fields[key], value)
	return {"handled": true}
