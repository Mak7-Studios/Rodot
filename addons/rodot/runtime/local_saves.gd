extends RefCounted

const DIRECTORY := "user://rodot/saves"
const MAX_BYTES := 2 * 1024 * 1024

static func access(operation: String, slot: Variant, value: Variant = null) -> Variant:
	if not slot is String or not _valid_slot(slot):
		return {"__error": "Save slot names must use 1 to 64 letters, numbers, underscores, or dashes"}
	var path := DIRECTORY.path_join("slot_" + slot.to_lower() + ".json")
	match operation:
		"has": return FileAccess.file_exists(path)
		"read": return read_record(path)
		"write": return write_record(path, value)
	return {"__error": "Unknown local save operation: " + operation}

static func _valid_slot(slot: String) -> bool:
	if slot.is_empty() or slot.length() > 64: return false
	for character in slot.to_lower():
		if character not in "abcdefghijklmnopqrstuvwxyz0123456789_-": return false
	return true

static func _valid_value(value: Variant, depth := 0) -> bool:
	if depth > 32: return false
	if value == null or value is bool or value is String or value is int: return true
	if value is float: return is_finite(value)
	if value is Array:
		for element in value:
			if not _valid_value(element, depth + 1): return false
		return true
	if value is Dictionary:
		if value.get("__type") == "Instance": return false
		for key in value:
			if not key is String or not _valid_value(value[key], depth + 1): return false
		return true
	return false

static func write_record(path: String, value: Variant, revision := "") -> Variant:
	if value == null or not _valid_value(value):
		return {"__error": "Save data must be finite numbers, strings, booleans, or tables of saveable values"}
	var record := {"version": 1, "value": value}
	if not revision.is_empty(): record.revision = revision
	var bytes := JSON.stringify(record, "", true, true).to_utf8_buffer()
	if bytes.size() > MAX_BYTES: return {"__error": "Save slot exceeds 2 MiB"}
	var result := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if result != OK: return {"__error": "Could not create the save folder: " + error_string(result)}
	var destination := ProjectSettings.globalize_path(path)
	var temporary := "%s.%s.%s.tmp" % [destination, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return {"__error": "Could not open the save file: " + error_string(FileAccess.get_open_error())}
	file.store_buffer(bytes)
	file.flush()
	result = file.get_error()
	file.close()
	if result == OK: result = DirAccess.rename_absolute(temporary, destination)
	if result != OK:
		DirAccess.remove_absolute(temporary)
		return {"__error": "Could not write the save slot: " + error_string(result)}
	return true

static func read_record(path: String) -> Variant:
	if not FileAccess.file_exists(path): return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"__error": "Could not open the save slot: " + error_string(FileAccess.get_open_error())}
	if file.get_length() > MAX_BYTES: return {"__error": "Save slot exceeds 2 MiB"}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary or json.data.get("version") != 1 or not json.data.has("value"):
		return {"__error": "Save slot is damaged or uses an unsupported format"}
	if not _valid_value(json.data.value): return {"__error": "Save slot contains unsupported data"}
	return {"data": json.data.value, "revision": json.data.get("revision", "")}
