@tool
extends "ribbon.gd"

@export_range(0.01, 30, 0.01) var lifetime := 0.5
@export_range(0.001, 10, 0.001) var min_length := 0.05
@export var fade_tail := true

var _left := PackedVector3Array()
var _right := PackedVector3Array()
var _times := PackedFloat64Array()
var _clock := 0.0

func _enter_tree() -> void:
	set_meta("rodot_class", "Trail")
	super._enter_tree()

func _exit_tree() -> void:
	clear()
	super._exit_tree()

func clear() -> void:
	_left.clear()
	_right.clear()
	_times.clear()
	mesh = null

func _process(delta: float) -> void:
	_clock += delta
	var duration := maxf(0.01, lifetime)
	while not _times.is_empty() and (_clock - _times[0] > duration or _times.size() > 255):
		_times.remove_at(0)
		_left.remove_at(0)
		_right.remove_at(0)
	if enabled and _has_endpoints():
		var a := attachment_0.global_position
		var b := attachment_1.global_position
		if _times.is_empty() or maxf(a.distance_to(_left[-1]), b.distance_to(_right[-1])) >= maxf(0.001, min_length):
			_left.append(a)
			_right.append(b)
			_times.append(_clock)
	var opacity := PackedFloat32Array()
	if fade_tail:
		for time in _times: opacity.append(clampf(1.0 - (_clock - time) / duration, 0, 1))
	_strip(_left, _right, opacity)
