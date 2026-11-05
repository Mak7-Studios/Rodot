@tool
extends Node3D

signal ended
signal played
signal stopped

const Values = preload("values.gd")

@export_file("*.wav", "*.ogg", "*.mp3", "*.tres", "*.res") var sound_id := "":
	set(value):
		sound_id = value
		_sync_stream()
@export_range(0, 10, 0.01, "or_greater") var volume := 1.0:
	set(value):
		volume = maxf(0.0, value)
		_sync_controls()
@export_range(0.01, 4, 0.01, "or_greater") var playback_speed := 1.0:
	set(value):
		playback_speed = maxf(0.01, value)
		_sync_controls()
@export var looped := false:
	set(value):
		looped = value
		_sync_stream()
@export var autoplay := false
@export_range(0.01, 10000, 0.1) var roll_off_max_distance := 100.0:
	set(value):
		roll_off_max_distance = maxf(0.01, value)
		_sync_controls()
@export var bus: StringName = &"Master":
	set(value):
		bus = value
		_sync_controls()

var _player: Node
var _position := 0.0
var _paused := false

func _enter_tree() -> void:
	set_meta("rodot_class", "Sound")
	_player = AudioStreamPlayer3D.new() if get_parent() is Node3D else AudioStreamPlayer.new()
	_player.name = "RodotAudio"
	_player.set_meta("rodot_internal", true)
	add_child(_player, false, Node.INTERNAL_MODE_FRONT)
	_player.finished.connect(func():
		_position = 0.0
		ended.emit()
	)
	_sync_controls()
	_sync_stream()
	if autoplay and not Engine.is_editor_hint(): play()

func _exit_tree() -> void:
	if is_instance_valid(_player):
		_player.stop()
		_player.queue_free()
	_player = null
	_paused = false

func _sync_controls() -> void:
	if not is_instance_valid(_player): return
	_player.volume_db = linear_to_db(maxf(volume, 0.00001))
	_player.pitch_scale = playback_speed
	_player.bus = bus
	if _player is AudioStreamPlayer3D: _player.max_distance = roll_off_max_distance

func _sync_stream() -> void:
	if not is_instance_valid(_player): return
	var was_playing: bool = _player.playing
	var previous_position: float = _player.get_playback_position() if was_playing else _position
	var source := load(sound_id) as AudioStream if ResourceLoader.exists(sound_id, "AudioStream") else null
	if source != null:
		source = source.duplicate() as AudioStream
		if source is AudioStreamWAV:
			source.loop_mode = AudioStreamWAV.LOOP_FORWARD if looped else AudioStreamWAV.LOOP_DISABLED
			source.loop_end = int(source.get_length() * source.mix_rate)
		elif source is AudioStreamOggVorbis or source is AudioStreamMP3:
			source.loop = looped
	_player.stream = source
	if was_playing and source != null: _player.play(minf(previous_position, source.get_length()))
	if Engine.is_editor_hint(): update_configuration_warnings()

func _get_configuration_warnings() -> PackedStringArray:
	if not sound_id.is_empty() and not ResourceLoader.exists(sound_id, "AudioStream"):
		return PackedStringArray(["Choose a project audio file for Sound Id."])
	return PackedStringArray()

func play() -> void:
	if not is_instance_valid(_player) or _player.stream == null: return
	_paused = false
	_player.play(_position)
	played.emit()

func stop() -> void:
	if is_instance_valid(_player):
		var was_playing: bool = _player.playing or _paused
		_player.stop()
		if was_playing: stopped.emit()
	_position = 0.0
	_paused = false

func pause() -> void:
	if not is_instance_valid(_player) or not _player.playing or _paused: return
	_position = _player.get_playback_position()
	_paused = true
	_player.stop()

func resume() -> void:
	if not _paused or not is_instance_valid(_player) or _player.stream == null: return
	_paused = false
	_player.play(_position)

func _rodot_get(key: String) -> Dictionary:
	match key:
		"Playing", "IsPlaying": return Values.value(is_instance_valid(_player) and _player.playing and not _paused)
		"IsLoaded": return Values.value(is_instance_valid(_player) and _player.stream != null)
		"TimePosition": return Values.value(_player.get_playback_position() if is_instance_valid(_player) and _player.playing else _position)
		"TimeLength": return Values.value(_player.stream.get_length() if is_instance_valid(_player) and _player.stream != null else 0.0)
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	match key:
		"Playing":
			if not value is bool: return Values.failure("Playing must be a boolean")
			if value: play()
			else: stop()
		"TimePosition":
			if not Values.is_number(value): return Values.failure("TimePosition must be a number")
			_position = maxf(0.0, value)
			if is_instance_valid(_player) and _player.playing: _player.seek(_position)
		"SoundId":
			if not value is String or (not value.is_empty() and not ResourceLoader.exists(value, "AudioStream")):
				return Values.failure("SoundId expects a project audio path")
			sound_id = value
		"IsPlaying", "IsLoaded", "TimeLength": return Values.failure(key + " is read-only")
		_: return {}
	return {"handled": true}
