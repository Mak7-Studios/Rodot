extends RefCounted

const Values = preload("values.gd")

var _follow_camera: Camera3D
var _follow_target: Node3D
var _offset := Vector3.ZERO
var _look_offset := Vector3.ZERO
var _follow_speed := 0.0

var _blend_camera: Camera3D
var _blend_target: Camera3D
var _blend_previous: Camera3D
var _blend_start := Transform3D.IDENTITY
var _blend_lens := Vector4.ZERO
var _blend_offsets := Vector2.ZERO
var _blend_frustum := Vector2.ZERO
var _blend_time := 0.0
var _blend_duration := 0.0
var _completed: Array[Camera3D] = []

func command(operation: String, args: Array, viewport: Viewport) -> Variant:
	match operation:
		"current": return viewport.get_camera_3d() if is_instance_valid(viewport) else null
		"stop_following":
			_stop_following()
			return null
		"cancel_blend":
			_clear_blend(true)
			return null
	var camera = args[0] if not args.is_empty() else null
	if not camera is Camera3D or not _active_node(camera): return {"__error": "Expected a Camera3D in the scene tree"}
	if camera == _blend_camera: return {"__error": "Choose a scene Camera3D for this operation"}
	match operation:
		"set_current":
			_stop_following()
			_clear_blend(true)
			camera.make_current()
		"follow":
			var target = args[1] if args.size() > 1 else null
			var offset = args[2] if args.size() > 2 and args[2] != null else Vector3(0, 3, 6)
			var speed = args[3] if args.size() > 3 and args[3] != null else 8.0
			var look = args[4] if args.size() > 4 and args[4] != null else Vector3.ZERO
			if not target is Node3D or not _active_node(target) or camera == target or camera.is_ancestor_of(target):
				return {"__error": "Follow expects a live Node3D target outside the camera's own branch"}
			if not offset is Vector3 or not offset.is_finite() or not look is Vector3 or not look.is_finite() or not Values.is_number(speed) or speed < 0.0:
				return {"__error": "Follow expects Vector3 offsets and a nonnegative speed"}
			_clear_blend(true)
			_follow_camera = camera
			_follow_target = target
			_offset = offset
			_look_offset = look
			_follow_speed = speed
			camera.make_current()
			if speed == 0.0: _update_follow(0.0)
		"blend_to":
			var duration = args[1] if args.size() > 1 and args[1] != null else 0.5
			if not Values.is_number(duration) or duration < 0.0: return {"__error": "Blend duration must be a nonnegative number"}
			_start_blend(camera, duration)
		_: return {"__error": "Unknown camera operation: " + operation}
	return null

func update(delta: float, events: Array) -> void:
	_update_follow(delta)
	_update_blend(delta)
	for camera in _completed:
		if _active_node(camera): events.append([0, "camera:blend_finished", [camera]])
	_completed.clear()

func clear() -> void:
	_stop_following()
	_clear_blend(false)
	_completed.clear()

func _active_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and node.is_inside_tree() and not node.is_queued_for_deletion()

func _stop_following() -> void:
	_follow_camera = null
	_follow_target = null

func _update_follow(delta: float) -> void:
	if not _active_node(_follow_camera) or not _active_node(_follow_target) or not _follow_camera.is_current():
		_stop_following()
		return
	var target := _follow_target.global_position
	var desired := target + _offset
	var weight := 1.0 if _follow_speed == 0.0 else 1.0 - exp(-_follow_speed * delta)
	var position := _follow_camera.global_position.lerp(desired, weight)
	var focus := target + _look_offset
	var direction := focus - position
	if direction.is_zero_approx():
		_follow_camera.global_position = position
		return
	var up := Vector3.BACK if absf(direction.normalized().dot(Vector3.UP)) > 0.999 else Vector3.UP
	_follow_camera.look_at_from_position(position, focus, up)

func _start_blend(target: Camera3D, duration: float) -> void:
	var viewport := target.get_viewport()
	var from := viewport.get_camera_3d()
	var has_source := _active_node(from)
	var previous := from
	if is_instance_valid(_blend_camera) and from == _blend_camera:
		previous = _blend_previous if is_instance_valid(_blend_previous) else null
	_stop_following()
	_clear_blend(from != _blend_camera)
	if not has_source or from == target or duration == 0.0:
		target.make_current()
		_completed.append(target)
		return
	_blend_start = from.global_transform
	_blend_lens = Vector4(from.fov, from.size, from.near, from.far)
	_blend_offsets = Vector2(from.h_offset, from.v_offset)
	_blend_frustum = from.frustum_offset
	_blend_camera = Camera3D.new()
	_blend_camera.name = "RodotCameraBlend"
	_blend_camera.set_meta("rodot_internal", true)
	_blend_camera.projection = from.projection
	_blend_camera.keep_aspect = from.keep_aspect
	_blend_camera.cull_mask = from.cull_mask
	_blend_camera.environment = from.environment
	_blend_camera.attributes = from.attributes
	_blend_camera.doppler_tracking = from.doppler_tracking
	viewport.add_child(_blend_camera, false, Node.INTERNAL_MODE_FRONT)
	_blend_target = target
	_blend_previous = previous
	_blend_time = 0.0
	_blend_duration = duration
	_apply_blend(0.0)
	_blend_camera.make_current()

func _apply_blend(weight: float) -> void:
	_blend_camera.global_transform = _blend_start.interpolate_with(_blend_target.global_transform, weight)
	if _blend_camera.projection != _blend_target.projection: weight = 0.0
	_blend_camera.fov = lerpf(_blend_lens.x, _blend_target.fov, weight)
	_blend_camera.size = lerpf(_blend_lens.y, _blend_target.size, weight)
	_blend_camera.near = lerpf(_blend_lens.z, _blend_target.near, weight)
	_blend_camera.far = lerpf(_blend_lens.w, _blend_target.far, weight)
	_blend_camera.h_offset = lerpf(_blend_offsets.x, _blend_target.h_offset, weight)
	_blend_camera.v_offset = lerpf(_blend_offsets.y, _blend_target.v_offset, weight)
	_blend_camera.frustum_offset = _blend_frustum.lerp(_blend_target.frustum_offset, weight)

func _update_blend(delta: float) -> void:
	if not is_instance_valid(_blend_camera): return
	if not _active_node(_blend_camera) or not _blend_camera.is_current():
		_clear_blend(false)
		return
	if not _active_node(_blend_target) or _blend_target.get_viewport() != _blend_camera.get_viewport():
		_clear_blend(true)
		return
	_blend_time += delta
	if _blend_time >= _blend_duration:
		_blend_target.make_current()
		_completed.append(_blend_target)
		_clear_blend(false)
		return
	var progress := _blend_time / _blend_duration
	_apply_blend(smoothstep(0.0, 1.0, progress))

func _clear_blend(restore: bool) -> void:
	if is_instance_valid(_blend_camera):
		if restore and _active_node(_blend_camera) and _blend_camera.is_current() and _active_node(_blend_previous) and _blend_previous.get_viewport() == _blend_camera.get_viewport():
			_blend_previous.make_current()
		_blend_camera.queue_free()
	_blend_camera = null
	_blend_target = null
	_blend_previous = null
